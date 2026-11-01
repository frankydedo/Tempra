"""Tempra forecasting worker.

Reads Tempra's history database, forecasts the next hours with Mistral's Timestral
(zero-shot, probabilistic) and writes the results back to the `forecasts` table,
where the app picks them up.

Forecasts are multivariate:
  * System block (1-minute steps, next hour): CPU, GPU, memory pressure, SoC temperature and
    system power are forecast jointly as variates of one series, so the model can use how they
    move together. Whether the Mac is on its adapter is a past covariate; time of day is a
    known-future covariate.
  * Battery block (5-minute steps, next 12 hours): Timestral forecasts system power together
    with CPU and GPU load under an explicit power-source scenario (known-future covariate).
    Battery level is then derived from that power and the battery's energy (mAh × V), which
    stays physically consistent even before the history contains many discharges. While
    charging, the battery level itself is forecast with power and adapter state as covariates.

Run once:      python worker.py --db <history.sqlite> --once
Run as daemon: python worker.py --db <history.sqlite> --interval 60 --parent-pid <pid>
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import traceback

import numpy as np

LOW_Q, HIGH_Q = 0.1, 0.9

# System block: 1-minute resolution, 3 days of context, 1 hour ahead.
SYSTEM_STEP, SYSTEM_CONTEXT, SYSTEM_HORIZON, SYSTEM_MIN_POINTS = 60, 3 * 1440, 60, 60
SYSTEM_VARIATES = {  # column -> clip range of the forecast
    "cpu": (0.0, 1.0),
    "gpu": (0.0, 1.0),
    "mem_pressure": (0.0, 1.0),
    "soc_temp": (0.0, 120.0),
    "sys_power": (0.0, None),
}

# Battery block: 5-minute resolution, 7 days of context, 12 hours ahead.
BATTERY_STEP, BATTERY_CONTEXT, BATTERY_HORIZON, BATTERY_MIN_POINTS = 300, 7 * 288, 144, 24
EMPTY_PCT, FULL_PCT = 3.0, 99.0


def log(*args) -> None:
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10)
    conn.execute("PRAGMA busy_timeout = 10000")
    return conn


# MARK: - Data

def load_matrix(conn, columns, step, context, now):
    """Regularly spaced (len(columns), T) matrix from the minute table, NaN = missing,
    ending at the last complete step. Leading steps with no data at all are trimmed."""
    end = (now // step) * step
    start = end - context * step
    averages = ", ".join(f"AVG({c})" for c in columns)
    rows = conn.execute(
        f"SELECT CAST(ts / ? AS INTEGER) * ? AS b, {averages} FROM minute "
        f"WHERE ts >= ? AND ts < ? GROUP BY b", (step, step, start, end)).fetchall()
    matrix = np.full((len(columns), context), np.nan, dtype=np.float32)
    for bucket, *values in rows:
        i = int((bucket - start) // step)
        if 0 <= i < context:
            matrix[:, i] = [np.nan if v is None else v for v in values]
    has_data = np.flatnonzero(~np.all(np.isnan(matrix), axis=0))
    if has_data.size == 0:
        return matrix[:, :0], end
    return matrix[:, has_data[0]:], end


def time_of_day(first_ts: float, count: int, step: int) -> np.ndarray:
    """(2, count) sine/cosine of the local hour: a known-future covariate for daily rhythms."""
    offset = time.localtime(first_ts).tm_gmtoff
    seconds = (first_ts + offset + np.arange(count) * step) % 86400
    angle = 2 * np.pi * seconds / 86400
    return np.stack([np.sin(angle), np.cos(angle)]).astype(np.float32)


def meta_json(conn, key: str) -> dict:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    try:
        return json.loads(row[0]) if row and row[0] else {}
    except json.JSONDecodeError:
        return {}


def valid_points(series: np.ndarray) -> int:
    return int(np.sum(~np.isnan(series)))


def quantiles(fc, variate: int, fill: float):
    """(median, low, high) for one variate of a batch-of-one forecast, as float64 arrays."""
    out = []
    for q in (fc.median, fc.quantile(LOW_Q), fc.quantile(HIGH_Q)):
        a = np.asarray(q, dtype=np.float64)[0, variate]
        out.append(np.nan_to_num(a, nan=fill))
    return out


def smooth(values: np.ndarray, window: int = 5) -> np.ndarray:
    """Centered moving average. Timestral decodes the horizon in 32-step patches, which can leave a
    small step in the quantile paths at patch boundaries; this keeps the bands visually continuous."""
    if len(values) < window:
        return values
    pad = window // 2
    padded = np.pad(values, pad, mode="edge")
    return np.convolve(padded, np.ones(window) / window, mode="valid")


def payload(metric, now, start, step, median, low, high, context_points, model_name, summary=None, **extra):
    return {
        "metric": metric, "generated_at": now, "start": start, "step": step,
        "median": np.round(median, 4).tolist(), "low": np.round(low, 4).tolist(),
        "high": np.round(high, 4).tolist(), "low_level": LOW_Q, "high_level": HIGH_Q,
        "context_points": context_points, "model": model_name, "summary": summary, **extra,
    }


def first_crossing(values: np.ndarray, threshold: float, below: bool) -> int | None:
    hits = np.flatnonzero(values <= threshold if below else values >= threshold)
    return int(hits[0]) if hits.size else None


def eta(series, threshold, below, step):
    i = first_crossing(series, threshold, below)
    return None if i is None else float((i + 1) * step)


# MARK: - System block

def system_forecasts(conn, model, model_name, now) -> list[dict]:
    columns = list(SYSTEM_VARIATES) + ["on_ac"]
    matrix, end = load_matrix(conn, columns, SYSTEM_STEP, SYSTEM_CONTEXT, now)
    targets, on_ac = matrix[:-1], matrix[-1:]
    if valid_points(targets[0]) < SYSTEM_MIN_POINTS:
        log(f"system: collecting data ({valid_points(targets[0])}/{SYSTEM_MIN_POINTS} points)")
        return []

    T = targets.shape[1]
    first_ts = end - T * SYSTEM_STEP
    known = time_of_day(first_ts, T + SYSTEM_HORIZON, SYSTEM_STEP)
    t0 = time.perf_counter()
    fc = model.forecast(targets[None], prediction_length=SYSTEM_HORIZON,
                        past_covariates=on_ac[None], known_covariates=known[None])
    log(f"system: {len(SYSTEM_VARIATES)} variates jointly, {SYSTEM_HORIZON} steps "
        f"in {(time.perf_counter() - t0) * 1000:.0f} ms")

    results = []
    for v, (column, (lo, hi)) in enumerate(SYSTEM_VARIATES.items()):
        series = targets[v]
        if valid_points(series) < SYSTEM_MIN_POINTS:
            continue  # e.g. a metric added recently
        median, low, high = (np.clip(smooth(a), lo, hi) for a in quantiles(fc, v, float(np.nanmean(series))))
        results.append(payload(column, now, end + SYSTEM_STEP, SYSTEM_STEP, median, low, high,
                               valid_points(series), model_name,
                               covariates=["jointly with " + ", ".join(c for c in SYSTEM_VARIATES if c != column),
                                           "adapter state", "time of day"]))
    return results


# MARK: - Battery block

def battery_forecast(conn, model, model_name, now) -> dict | None:
    state = meta_json(conn, "battery_state")
    if not state:
        log("battery: waiting for battery state from the app")
        return None
    columns = ["sys_power", "cpu", "gpu", "on_ac", "batt_pct"]
    matrix, end = load_matrix(conn, columns, BATTERY_STEP, BATTERY_CONTEXT, now)
    power = matrix[0]
    if valid_points(power) < BATTERY_MIN_POINTS:
        log(f"battery: collecting data ({valid_points(power)}/{BATTERY_MIN_POINTS} points)")
        return None

    T, H, step = matrix.shape[1], BATTERY_HORIZON, BATTERY_STEP
    first_ts = end - T * step
    tod = time_of_day(first_ts, T + H, step)
    on_ac_history = matrix[3]
    percent = float(state["percent"])
    energy_wh = state["nominal_mah"] / 1000 * state["voltage"]
    t0 = time.perf_counter()

    def power_if(plugged: bool):
        """System power, CPU and GPU forecast jointly, given the adapter state from now on."""
        scenario = np.concatenate([on_ac_history, np.full(H, 1.0 if plugged else 0.0, dtype=np.float32)])
        known = np.concatenate([scenario[None], tod])[None]
        fc = model.forecast(matrix[None, :3], prediction_length=H, known_covariates=known)
        return [smooth(a) for a in quantiles(fc, 0, float(np.nanmean(power)))]

    def drain(start_pct, p_median, p_low, p_high):
        """Battery level if the battery supplies the forecast power. More power = lower level."""
        def level(p):
            return np.clip(start_pct - np.cumsum(np.maximum(p, 0)) * step / 3600 / energy_wh * 100, 0, 100)
        return level(p_median), level(p_high), level(p_low)

    unplugged = drain(percent, *power_if(plugged=False))
    empty = {"seconds": eta(unplugged[0], EMPTY_PCT, True, step),
             "low": eta(unplugged[1], EMPTY_PCT, True, step),
             "high": eta(unplugged[2], EMPTY_PCT, True, step)}
    covariates = ["system power (Timestral, with CPU and GPU load)", "adapter scenario", "time of day",
                  "battery energy %.0f Wh" % energy_wh]

    if not state["on_ac"]:
        median, low, high = unplugged
        summary = {"kind": "time_to_empty", **empty, "horizon": H * step}
    elif state["charging"]:
        # Forecast the level itself while charging: adapter held on, power as a past covariate.
        known = np.concatenate([np.concatenate([on_ac_history, np.ones(H, dtype=np.float32)])[None], tod])[None]
        fc = model.forecast(matrix[None, 4:5], prediction_length=H,
                            past_covariates=matrix[None, 0:1], known_covariates=known)
        median, low, high = (np.clip(a, 0, 100) for a in quantiles(fc, 0, percent))
        # Charging can't go backwards.
        median, low, high = (np.maximum.accumulate(np.maximum(a, percent)) for a in (median, low, high))
        summary = {"kind": "time_to_full", "seconds": eta(median, FULL_PCT, False, step),
                   "low": eta(high, FULL_PCT, False, step), "high": eta(low, FULL_PCT, False, step),
                   "horizon": H * step, "if_unplugged": empty}
        covariates = ["system power", "adapter scenario", "time of day"]
    else:
        # Plugged in but not charging (e.g. held at the charge limit): level stays put.
        median = low = high = np.full(H, percent)
        summary = {"kind": "held", "percent": percent, "horizon": H * step, "if_unplugged": empty}

    log(f"battery: {summary['kind']} in {(time.perf_counter() - t0) * 1000:.0f} ms")
    return payload("batt_pct", now, end + step, step, median, low, high,
                   valid_points(power), model_name, summary, covariates=covariates)


# MARK: - Battery health

def health_forecast(conn, model, model_name, now) -> dict | None:
    rows = conn.execute("SELECT day, health FROM battery_daily ORDER BY day").fetchall()
    if len(rows) < 14:
        return None
    days = np.array([r[0] for r in rows])
    first, last = days[0], days[-1]
    n = int((last - first) // 86400) + 1
    series = np.full(n, np.nan, dtype=np.float32)
    for day, health in rows:
        series[int((day - first) // 86400)] = health
    fc = model.forecast(series[None, None], prediction_length=180)
    median, low, high = (np.clip(a, 0.0, 1.0) for a in quantiles(fc, 0, float(np.nanmean(series))))
    i80 = first_crossing(median, 0.8, below=True)
    return payload("health", now, float(last + 86400), 86400, median, low, high, valid_points(series),
                   model_name, {"kind": "health_in_6_months", "value": float(median[-1]),
                                "days_to_80": None if i80 is None else i80 + 1})


# MARK: - Loop

def run_once(db_path: str, model, model_name: str) -> None:
    now = time.time()
    conn = connect(db_path)
    try:
        results = []
        for block in (system_forecasts, battery_forecast, health_forecast):
            try:
                out = block(conn, model, model_name, now)
            except sqlite3.OperationalError as exc:  # e.g. a column the app hasn't migrated yet
                log(f"{block.__name__}: skipped ({exc})")
                continue
            if isinstance(out, dict):
                results.append(out)
            elif out:
                results.extend(out)

        with conn:
            for p in results:
                conn.execute("INSERT OR REPLACE INTO forecasts (metric, generated_at, payload) VALUES (?, ?, ?)",
                             (p["metric"], now, json.dumps(p)))
            set_meta(conn, "forecaster_last_run", str(now))
            set_meta(conn, "forecaster_error", "")
            set_meta(conn, "forecaster_model", model_name)
    finally:
        conn.close()


def set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))


def report_error(db_path: str, message: str) -> None:
    try:
        conn = connect(db_path)
        with conn:
            set_meta(conn, "forecaster_error", message)
        conn.close()
    except Exception:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("--model", default="mistralai/Timestral-5M")
    parser.add_argument("--interval", type=float, default=60)
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    log(f"loading {args.model}")
    try:
        import torch
        from timestral import TimestralForecaster

        torch.set_num_threads(2)  # stay light: this runs in the background on a laptop
        model = TimestralForecaster.from_pretrained(args.model, device="cpu")
    except Exception as exc:  # missing package, no network on first download, ...
        report_error(args.db, f"Could not load {args.model}: {exc}")
        traceback.print_exc()
        return 1
    log("model ready")

    while True:
        try:
            run_once(args.db, model, args.model)
        except Exception as exc:
            report_error(args.db, str(exc))
            traceback.print_exc()
        if args.once:
            return 0
        deadline = time.time() + args.interval
        while time.time() < deadline:
            # Exit when Tempra quits (we get re-parented to launchd).
            if args.parent_pid and os.getppid() != args.parent_pid:
                log("parent exited, stopping")
                return 0
            time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
