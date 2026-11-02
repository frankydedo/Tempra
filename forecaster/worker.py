"""Tempra forecasting worker.

Reads Tempra's history database, forecasts the next hours with Mistral's Timestral
(zero-shot, probabilistic) and writes the results back to the `forecasts` table,
where the app picks them up.

Forecasts are multivariate:
  * System block (1-minute steps, 14 days of context, next hour): CPU, GPU, memory pressure, SoC temperature,
    fan speed and system power are forecast jointly; the fan's on/off state then follows the jointly
    forecast temperature and the switch-on/off temperatures learned from this Mac's history, as variates of one series, so the model can use how they
    move together. Whether the Mac is on its adapter is a past covariate; time of day is a
    known-future covariate.
  * Battery block (5-minute steps, 30 days of context, next 24 hours): Timestral forecasts system power together
    with CPU and GPU load under an explicit power-source scenario (known-future covariate).
    Battery level is then derived from that power and the battery's energy (mAh × V), which
    stays physically consistent even before the history contains many discharges. While
    charging, the battery level itself is forecast with power and adapter state as covariates.

Longer contexts let Timestral see daily and weekly habits. The model itself never changes
(zero-shot); forecasts improve as the history it reads grows, up to these windows.

Bands are self-calibrating: every scored forecast widens or narrows its metric's 10–90% band a
little, so that about 80% of what actually happens ends up inside it.

Accuracy: a snapshot of each forecast is kept until its horizon has passed, then scored against
what actually happened (mean absolute error, a naive "nothing changes" baseline, and how often
reality fell inside the 10–90% band). A 7-day summary is published for the app.

Run once:      python worker.py --db <history.sqlite> --once
Run as daemon: python worker.py --db <history.sqlite> --interval 60 --parent-pid <pid>
               SIGUSR1 makes the daemon refresh right away (the app sends it when the adapter
               is plugged or unplugged, so the battery forecast follows within a second).
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sqlite3
import sys
import time
import traceback

import numpy as np

LOW_Q, HIGH_Q = 0.1, 0.9

# System block: 1-minute resolution, 14 days of context (two full weeks), 1 hour ahead.
SYSTEM_STEP, SYSTEM_CONTEXT, SYSTEM_HORIZON, SYSTEM_MIN_POINTS = 60, 14 * 1440, 60, 60
SYSTEM_VARIATES = {  # column -> clip range of the forecast
    "cpu": (0.0, 1.0),
    "gpu": (0.0, 1.0),
    "mem_pressure": (0.0, 1.0),
    "soc_temp": (0.0, 120.0),
    "fan_rpm": (0.0, 10000.0),
    "sys_power": (0.0, None),
}

# Battery block: 5-minute resolution, 30 days of context (all minute history), 24 hours ahead
# (light use on a full battery easily lasts more than 12 hours).
BATTERY_STEP, BATTERY_CONTEXT, BATTERY_HORIZON, BATTERY_MIN_POINTS = 300, 30 * 288, 288, 24
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
    # Forecast jointly only the variates with enough history: a metric added recently, or one this
    # Mac doesn't have (fan speed on a fanless Mac), would otherwise be an all-missing variate.
    active = [i for i, c in enumerate(SYSTEM_VARIATES) if valid_points(matrix[i]) >= SYSTEM_MIN_POINTS]
    if not active:
        log(f"system: collecting data ({valid_points(matrix[0])}/{SYSTEM_MIN_POINTS} points)")
        return []
    names = [list(SYSTEM_VARIATES)[i] for i in active]
    targets, on_ac = matrix[active], matrix[-1:]

    T = targets.shape[1]
    first_ts = end - T * SYSTEM_STEP
    known = time_of_day(first_ts, T + SYSTEM_HORIZON, SYSTEM_STEP)
    t0 = time.perf_counter()
    fc = model.forecast(targets[None], prediction_length=SYSTEM_HORIZON,
                        past_covariates=on_ac[None], known_covariates=known[None])
    log(f"system: {len(names)} variates jointly, {SYSTEM_HORIZON} steps "
        f"in {(time.perf_counter() - t0) * 1000:.0f} ms")

    calibration = meta_json(conn, "band_calibration")
    paths = {}
    for v, column in enumerate(names):
        median, low, high = (smooth(a) for a in quantiles(fc, v, float(np.nanmean(targets[v]))))
        scale = calibration.get(column, 1.0)
        paths[column] = (median, median - (median - low) * scale, median + (high - median) * scale, scale)

    # Fan speed is still forecast jointly with the rest; its on/off state then follows the jointly
    # forecast SoC temperature and the thresholds this Mac's fan actually uses.
    fan_note = None
    if "fan_rpm" in paths and "soc_temp" in paths:
        thresholds = fan_thresholds(conn, now)
        if thresholds:
            on_at, off_at = thresholds
            fan_on = (targets[names.index("fan_rpm")][~np.isnan(targets[names.index("fan_rpm")])][-1:] > 0).any()
            temp_median, temp_low, temp_high, _ = paths["soc_temp"]
            fan_median, fan_low, fan_high, fan_scale = paths["fan_rpm"]
            paths["fan_rpm"] = (fan_hurdle(fan_median, temp_median, fan_on, on_at, off_at),
                                fan_hurdle(fan_low, temp_low, fan_on, on_at, off_at),
                                fan_hurdle(fan_high, temp_high, fan_on, on_at, off_at), fan_scale)
            fan_note = f"on above ~{on_at:.0f}°C, off below ~{off_at:.0f}°C (learned)"

    results = []
    for v, column in enumerate(names):
        lo, hi = SYSTEM_VARIATES[column]
        median, low, high, scale = paths[column]
        median, low, high = (np.clip(a, lo, hi) for a in (median, low, high))
        covariates = ["jointly with " + ", ".join(c for c in names if c != column), "adapter state", "time of day"]
        if column == "fan_rpm" and fan_note:
            covariates.append(fan_note)
        results.append(payload(column, now, end + SYSTEM_STEP, SYSTEM_STEP, median, low, high,
                               valid_points(targets[v]), model_name, band_scale=round(scale, 3),
                               covariates=covariates))
    return results


FAN_MIN_EVENTS = 2


def fan_thresholds(conn, now) -> tuple[float, float] | None:
    """SoC temperatures (minute averages) at which this Mac's fan has turned on and off in the last
    30 days. None until each has been seen at least FAN_MIN_EVENTS times."""
    rows = conn.execute(
        "WITH m AS (SELECT ts, fan_rpm AS f, soc_temp AS t, LAG(fan_rpm) OVER (ORDER BY ts) AS pf, "
        "LAG(ts) OVER (ORDER BY ts) AS pts FROM minute WHERE fan_rpm IS NOT NULL AND soc_temp IS NOT NULL "
        "AND ts >= ? AND ts < ?) "
        "SELECT pf = 0 AND f > 0, t FROM m WHERE ts - pts <= 120 AND ((pf = 0 AND f > 0) OR (pf > 0 AND f = 0))",
        (now - 30 * 86400, now)).fetchall()
    on = [t for turned_on, t in rows if turned_on]
    off = [t for turned_on, t in rows if not turned_on]
    if len(on) < FAN_MIN_EVENTS or len(off) < FAN_MIN_EVENTS:
        return None
    # The lower quartile of switch-on temperatures: the fan has come on at that point before.
    return float(np.percentile(on, 25)), float(np.median(off))


def fan_hurdle(rpm: np.ndarray, temperature: np.ndarray, on: bool, on_at: float, off_at: float) -> np.ndarray:
    """Fan speed path: 0 while the fan is off, the joint forecast's speed while it's on, switching
    with hysteresis on the forecast temperature (the fan starts above on_at, stops below off_at)."""
    out = np.zeros_like(rpm)
    for i, (speed, temp) in enumerate(zip(rpm, temperature)):
        on = temp > off_at if on else temp >= on_at
        out[i] = max(speed, 0.0) if on else 0.0
    return out


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
        charge = charge_forecast(conn, state, power_if(plugged=True), energy_wh, now)
        median, low, high = charge["paths"]
        target = charge["target"]
        full = target - 1 if target >= 100 else target - 0.5
        summary = {"kind": "time_to_full", "target": target,
                   "seconds": eta(median, full, False, step),
                   "low": eta(high, full, False, step), "high": eta(low, full, False, step),
                   "horizon": H * step, "if_unplugged": empty,
                   "macos_seconds": state.get("macos_minutes_to_full") and state["macos_minutes_to_full"] * 60,
                   "acceptance": charge["source"]}
        covariates = ["system power (Timestral)", "adapter %s" % (f"{state['adapter_watts']} W" if state.get("adapter_watts") else "rating unknown"),
                      "charge acceptance by battery level (%s)" % charge["source"],
                      "battery energy %.0f Wh" % energy_wh]
    else:
        # Plugged in but not charging (e.g. held at the charge limit): level stays put.
        median = low = high = np.full(H, percent)
        summary = {"kind": "held", "percent": percent, "horizon": H * step, "if_unplugged": empty}

    log(f"battery: {summary['kind']} in {(time.perf_counter() - t0) * 1000:.0f} ms")
    return payload("batt_pct", now, end + step, step, median, low, high,
                   valid_points(power), model_name, summary, covariates=covariates)


# MARK: - Charging

ADAPTER_EFFICIENCY = 0.9     # share of the adapter's rating that reaches the Mac
TAPER_START = 80.0           # Li-ion: constant current up to ~80%, then constant voltage (tapering)
TAPER_FLOOR = 0.08           # acceptance near 100%, as a share of the constant-current rate
LEARNED_BIN = 5              # battery-level bins (%) for the learned acceptance curve
LEARNED_MIN_MINUTES = 10


def taper(level: float) -> float:
    """Prior shape of how much power a Li-ion battery accepts at a given charge level (0–1)."""
    if level <= TAPER_START:
        return 1.0
    return max(TAPER_FLOOR, 1 - (1 - TAPER_FLOOR) * (level - TAPER_START) / (100 - TAPER_START))


def learned_acceptance(conn, now) -> dict[int, float]:
    """Median charging power per battery-level bin, from the last 30 days, using only minutes when
    the battery (not the adapter) was the limit, i.e. the adapter had headroom left."""
    rows = conn.execute(
        "SELECT batt_pct, batt_power, sys_power, adapter_w FROM minute WHERE ts >= ? AND on_ac > 0.5 "
        "AND ts < ? AND batt_power > 0.5 AND (charging IS NULL OR charging > 0.5)", (now - 30 * 86400, now)).fetchall()
    bins: dict[int, list[float]] = {}
    for level, power, system, adapter in rows:
        if level is None:
            continue
        if adapter and system is not None and ADAPTER_EFFICIENCY * adapter - system < power * 1.2:
            continue  # adapter-limited minute: says nothing about the battery
        bins.setdefault(int(level // LEARNED_BIN), []).append(power)
    return {b: float(np.median(v)) for b, v in bins.items() if len(v) >= LEARNED_MIN_MINUTES}


def charge_forecast(conn, state, system_power, energy_wh, now) -> dict:
    """Battery level while charging, from physics:
        battery power = min(what the battery accepts at its level, what the adapter has left
                            after the system's own consumption)
    System power is Timestral's forecast. Acceptance comes from your own charging history where it
    covers a level, otherwise from a Li-ion taper curve scaled to the current charging power (or,
    right after plugging in, calibrated so the time to full matches macOS's own estimate)."""
    level0 = float(state["percent"])
    step, H = BATTERY_STEP, BATTERY_HORIZON
    adapter = state.get("adapter_watts")
    sys_med, sys_low, sys_high = system_power
    learned = learned_acceptance(conn, now)
    # Charging is forecast to 100%. Whether macOS will pause at 80% this time (optimized charging)
    # can't be told from history; when it does, the app switches to the "held" state right away.
    target = 100.0

    now_power = float(state.get("battery_power") or 0)
    if now_power > 1:                       # current gauge reading
        cc_rate = now_power / taper(level0)
    elif learned:                           # gauge lags right after plugging in
        cc_rate = float(np.median([p / taper((b + 0.5) * LEARNED_BIN) for b, p in learned.items()]))
    else:
        cc_rate = 0.5 * (adapter or 60)

    def accepts(level: float, scale: float) -> float:
        learned_power = learned.get(int(level // LEARNED_BIN))
        return scale * (learned_power if learned_power is not None else cc_rate * taper(level))

    def simulate(scale: float, system: np.ndarray) -> np.ndarray:
        level, path = level0, np.empty(H)
        for i in range(H):
            headroom = ADAPTER_EFFICIENCY * adapter - max(system[i], 0) if adapter else np.inf
            battery_power = max(0.0, min(accepts(level, scale), headroom))
            level = min(target, level + battery_power * step / 3600 / energy_wh * 100)
            path[i] = level
        return path

    source = "learned + Li-ion prior" if learned else "Li-ion prior"
    scale = 1.0
    macos = state.get("macos_minutes_to_full")
    if macos and now_power <= 1 and not learned:
        # No reading and no history yet: calibrate the prior so it agrees with macOS.
        for _ in range(4):
            seconds = eta(simulate(scale, sys_med), FULL_PCT, False, step)
            if not seconds:
                scale *= 2
                continue
            scale = float(np.clip(scale * seconds / (macos * 60), 0.25, 4.0))
        source = "Li-ion prior calibrated to macOS"

    median = simulate(scale, sys_med)
    slow = simulate(scale * 0.85, sys_high)   # battery accepts less, system draws more
    fast = simulate(scale * 1.10, sys_low)
    return {"paths": (median, slow, fast), "target": target, "source": source}


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


# MARK: - Accuracy

SCORED_METRICS = {"cpu", "gpu", "mem_pressure", "soc_temp", "fan_rpm", "sys_power", "batt_pct"}
SNAPSHOT_INTERVAL = 15 * 60          # keep one forecast per metric every 15 minutes for scoring
ACCURACY_WINDOW = 7 * 86400          # the app shows the last 7 days
SCORE_RETENTION = 90 * 86400


def ensure_accuracy_tables(conn) -> None:
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS forecast_log (
        metric TEXT, generated_at REAL, start REAL, step REAL, median TEXT, low TEXT, high TEXT,
        PRIMARY KEY (metric, generated_at));
    CREATE TABLE IF NOT EXISTS forecast_scores (
        metric TEXT, generated_at REAL, points INTEGER, mae REAL, naive_mae REAL, coverage REAL,
        PRIMARY KEY (metric, generated_at));
    """)


def snapshot_forecasts(conn, results, now) -> None:
    """Keeps a copy of each forecast (at most every SNAPSHOT_INTERVAL) until it can be scored."""
    for p in results:
        metric = p["metric"]
        if metric not in SCORED_METRICS:
            continue
        # A battery level held at the charge limit is not a real prediction; don't let it inflate accuracy.
        if metric == "batt_pct" and (p.get("summary") or {}).get("kind") == "held":
            continue
        last = conn.execute(
            "SELECT MAX(t) FROM (SELECT MAX(generated_at) AS t FROM forecast_log WHERE metric = ? "
            "UNION ALL SELECT MAX(generated_at) FROM forecast_scores WHERE metric = ?)", (metric, metric)).fetchone()[0]
        if last is not None and now - last < SNAPSHOT_INTERVAL:
            continue
        conn.execute("INSERT OR REPLACE INTO forecast_log VALUES (?, ?, ?, ?, ?, ?, ?)",
                     (metric, now, p["start"], p["step"], json.dumps(p["median"]),
                      json.dumps(p["low"]), json.dumps(p["high"])))


def actual_values(conn, column, start, step, count) -> np.ndarray:
    rows = conn.execute(
        f"SELECT CAST(ts / ? AS INTEGER) * ? AS b, AVG({column}) FROM minute "
        f"WHERE ts >= ? AND ts < ? AND {column} IS NOT NULL GROUP BY b",
        (step, step, start, start + count * step)).fetchall()
    values = np.full(count, np.nan)
    for bucket, value in rows:
        i = int(round((bucket - start) / step))
        if 0 <= i < count:
            values[i] = value
    return values


# Band calibration: each scored forecast nudges its metric's band width so that, over time, about
# 80% of reality falls inside the 10–90% band (a simple online conformal-style correction).
CALIBRATION_RATE = 0.3
CALIBRATION_RANGE = (0.5, 5.0)


def calibrate_band(conn, metric: str, coverage: float) -> None:
    calibration = meta_json(conn, "band_calibration")
    scale = calibration.get(metric, 1.0) * float(np.exp(CALIBRATION_RATE * ((HIGH_Q - LOW_Q) - coverage)))
    calibration[metric] = float(np.clip(scale, *CALIBRATION_RANGE))
    set_meta(conn, "band_calibration", json.dumps(calibration))


BATTERY_MIN_SCORED_STEPS = 6   # 30 minutes


def battery_valid_steps(conn, generated_at, start, step, n, now) -> int | None:
    """How many leading steps of a battery forecast can be scored, or None to wait.

    A battery forecast assumes the Mac stays awake and on the same power source. It is scored as
    soon as that stops being true (adapter plugged/unplugged, or a gap such as sleep) or its whole
    horizon has passed, over the steps until then. Waiting for 24 unbroken hours would mean almost
    no battery forecast ever gets scored."""
    elapsed = min(n, int((now - 60 - start) // step))
    if elapsed <= 0:
        return None
    level = actual_values(conn, "batt_pct", start, step, elapsed)
    adapter = actual_values(conn, "on_ac", start, step, elapsed)
    # The power source when the forecast was made: the minute it was generated in.
    row = conn.execute("SELECT on_ac FROM minute WHERE ts <= ? AND on_ac IS NOT NULL ORDER BY ts DESC LIMIT 1",
                       (generated_at,)).fetchone()
    if row is None:
        return 0
    state = round(row[0])
    # Any bucket that isn't entirely on the same power source ends the forecast's validity.
    broken = np.isnan(level) | np.isnan(adapter) | (np.abs(np.nan_to_num(adapter, nan=-1) - state) > 0.05)
    hits = np.flatnonzero(broken)
    if hits.size:
        return int(hits[0])
    return elapsed if elapsed == n else None


def score_due_forecasts(conn, now) -> int:
    """Scores logged forecasts that have played out, then drops their snapshot."""
    scored = 0
    for metric, generated_at, start, step, median, low, high in conn.execute(
            "SELECT metric, generated_at, start, step, median, low, high FROM forecast_log").fetchall():
        median, low, high = (np.array(json.loads(a)) for a in (median, low, high))
        n = len(median)
        if metric == "batt_pct":
            usable = battery_valid_steps(conn, generated_at, start, step, n, now)
            if usable is None:
                continue
            minimum = BATTERY_MIN_SCORED_STEPS
        else:
            if start + n * step > now - 60:  # wait for the last minute to be rolled up
                continue
            usable, minimum = n, max(3, n // 2)
        actual = actual_values(conn, metric, start, step, n)
        anchor = actual_values(conn, metric, start - step, step, 1)[0]
        valid = ~np.isnan(actual)
        valid[usable:] = False
        conn.execute("DELETE FROM forecast_log WHERE metric = ? AND generated_at = ?", (metric, generated_at))
        if valid.sum() < minimum:
            continue  # Tempra wasn't running for long enough
        a = actual[valid]
        mae = float(np.mean(np.abs(median[valid] - a)))
        naive = None if np.isnan(anchor) else float(np.mean(np.abs(anchor - a)))
        coverage = float(np.mean((low[valid] <= a) & (a <= high[valid])))
        conn.execute("INSERT OR REPLACE INTO forecast_scores VALUES (?, ?, ?, ?, ?, ?)",
                     (metric, generated_at, int(valid.sum()), mae, naive, coverage))
        if metric in SYSTEM_VARIATES:
            calibrate_band(conn, metric, coverage)
        scored += 1
    conn.execute("DELETE FROM forecast_scores WHERE generated_at < ?", (now - SCORE_RETENTION,))
    conn.execute("DELETE FROM forecast_log WHERE generated_at < ?", (now - 2 * 86400,))
    return scored


def publish_accuracy(conn, now) -> None:
    """7-day summary per metric: typical error, skill vs. "nothing changes", band coverage."""
    summary = {}
    for metric, count, mae, naive_sum, mae_sum, coverage, since in conn.execute(
            "SELECT metric, COUNT(*), AVG(mae), SUM(naive_mae), SUM(CASE WHEN naive_mae IS NOT NULL THEN mae END), "
            "AVG(coverage), MIN(generated_at) FROM forecast_scores WHERE generated_at >= ? GROUP BY metric",
            (now - ACCURACY_WINDOW,)).fetchall():
        skill = None if not naive_sum else 1 - (mae_sum or 0) / naive_sum
        summary[metric] = {"forecasts": count, "mae": mae, "skill": skill, "coverage": coverage,
                           "target_coverage": HIGH_Q - LOW_Q, "since": since}
    set_meta(conn, "forecast_accuracy", json.dumps(summary))


# MARK: - Loop

def run_once(db_path: str, model, model_name: str) -> None:
    now = time.time()
    conn = connect(db_path)
    try:
        ensure_accuracy_tables(conn)
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
            snapshot_forecasts(conn, results, now)
            if score_due_forecasts(conn, now):
                log("accuracy: scored past forecasts")
            publish_accuracy(conn, now)
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

    refresh_requested = False

    def request_refresh(signum, frame):
        nonlocal refresh_requested
        refresh_requested = True

    signal.signal(signal.SIGUSR1, request_refresh)

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
            if refresh_requested:
                refresh_requested = False
                log("refresh requested by the app")
                break
            # Exit when Tempra quits (we get re-parented to launchd).
            if args.parent_pid and os.getppid() != args.parent_pid:
                log("parent exited, stopping")
                return 0
            time.sleep(0.25)


if __name__ == "__main__":
    sys.exit(main())
