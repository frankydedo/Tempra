"""Tempra forecasting worker.

Reads Tempra's history database, forecasts the next hours with Mistral's Timestral
(zero-shot, probabilistic) and writes the results back to the `forecasts` table,
where the app picks them up.

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
from dataclasses import dataclass

import numpy as np

LOW_Q, HIGH_Q = 0.1, 0.9


@dataclass
class Spec:
    key: str            # forecast id, also shown by the app
    column: str         # column in the history tables
    table: str          # "minute" or "hour"
    step: int           # seconds between points
    context: int        # history points fed to the model
    horizon: int        # points to predict
    min_points: int     # don't forecast before we have this much history
    clip: tuple[float, float] | None = None


SPECS = [
    # Battery level, 5-minute resolution, next 12 hours from the last 7 days.
    Spec("batt_pct", "batt_pct", "minute", 300, 7 * 288, 144, 24, (0.0, 100.0)),
    # Load, pressure, temperature and power: 1-minute resolution, next hour from the last 3 days.
    Spec("cpu", "cpu", "minute", 60, 3 * 1440, 60, 60, (0.0, 1.0)),
    Spec("gpu", "gpu", "minute", 60, 3 * 1440, 60, 60, (0.0, 1.0)),
    Spec("mem_pressure", "mem_pressure", "minute", 60, 3 * 1440, 60, 60, (0.0, 1.0)),
    Spec("soc_temp", "soc_temp", "minute", 60, 3 * 1440, 60, 60, (0.0, 120.0)),
    Spec("sys_power", "sys_power", "minute", 60, 3 * 1440, 60, 60, (0.0, None)),
]


def log(*args) -> None:
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10)
    conn.execute("PRAGMA busy_timeout = 10000")
    return conn


def load_series(conn: sqlite3.Connection, spec: Spec, now: float) -> tuple[np.ndarray, float]:
    """Return a regularly spaced series (NaN = missing) ending at the last complete step."""
    end = (now // spec.step) * spec.step
    start = end - spec.context * spec.step
    rows = conn.execute(
        f"SELECT CAST(ts / ? AS INTEGER) * ? AS b, AVG({spec.column}) FROM {spec.table} "
        f"WHERE ts >= ? AND ts < ? AND {spec.column} IS NOT NULL GROUP BY b",
        (spec.step, spec.step, start, end),
    ).fetchall()
    values = np.full(spec.context, np.nan, dtype=np.float32)
    for bucket, value in rows:
        idx = int((bucket - start) // spec.step)
        if 0 <= idx < spec.context:
            values[idx] = value
    # Trim leading NaNs (before Tempra was installed) so the model sees only real history.
    valid = np.flatnonzero(~np.isnan(values))
    if valid.size == 0:
        return values[:0], end
    return values[valid[0]:], end


def latest(conn: sqlite3.Connection, column: str) -> float | None:
    row = conn.execute(f"SELECT {column} FROM raw WHERE {column} IS NOT NULL ORDER BY ts DESC LIMIT 1").fetchone()
    return row[0] if row else None


def first_crossing(values: np.ndarray, threshold: float, below: bool) -> int | None:
    hits = np.flatnonzero(values <= threshold if below else values >= threshold)
    return int(hits[0]) if hits.size else None


def battery_summary(median, low, high, step: int, on_ac: bool) -> dict:
    """Time until empty (on battery) or full (charging), with an uncertainty range."""
    if on_ac:
        target, below = 99.0, False
        kind = "time_to_full"
        # Faster charging = the high quantile reaches full first.
        fast, slow = high, low
    else:
        target, below = 3.0, True
        kind = "time_to_empty"
        # Faster drain = the low quantile reaches empty first.
        fast, slow = low, high

    def eta(series):
        i = first_crossing(series, target, below)
        return None if i is None else (i + 1) * step

    return {"kind": kind, "seconds": eta(median), "low": eta(fast), "high": eta(slow),
            "horizon": len(median) * step}


def health_forecast(conn: sqlite3.Connection, model, now: float) -> dict | None:
    rows = conn.execute("SELECT day, health FROM battery_daily ORDER BY day").fetchall()
    if len(rows) < 14:
        return None
    days = np.array([r[0] for r in rows])
    first, last = days[0], days[-1]
    n = int((last - first) // 86400) + 1
    series = np.full(n, np.nan, dtype=np.float32)
    for day, health in rows:
        series[int((day - first) // 86400)] = health
    horizon = 180
    fc = model.forecast(series[None, :], prediction_length=horizon)
    median, low, high = (np.clip(np.asarray(a, dtype=np.float64).reshape(-1), 0.0, 1.0)
                         for a in (fc.median, fc.quantile(LOW_Q), fc.quantile(HIGH_Q)))
    i80 = first_crossing(median, 0.8, below=True)
    return {
        "metric": "health", "generated_at": now, "start": float(last + 86400), "step": 86400,
        "median": median.round(4).tolist(), "low": low.round(4).tolist(), "high": high.round(4).tolist(),
        "low_level": LOW_Q, "high_level": HIGH_Q, "context_points": int(np.sum(~np.isnan(series))),
        "summary": {"kind": "health_in_6_months", "value": float(median[-1]),
                    "days_to_80": None if i80 is None else i80 + 1},
    }


def run_once(db_path: str, model, model_name: str) -> None:
    now = time.time()
    conn = connect(db_path)
    try:
        ready = []
        for spec in SPECS:
            try:
                series, end = load_series(conn, spec, now)
            except sqlite3.OperationalError as exc:  # e.g. a column the app hasn't migrated yet
                log(f"{spec.key}: skipped ({exc})")
                continue
            if np.sum(~np.isnan(series)) < spec.min_points:
                log(f"{spec.key}: collecting data ({np.sum(~np.isnan(series))}/{spec.min_points} points)")
                continue
            ready.append((spec, series, end))

        results = []
        for spec, series, end in ready:
            t0 = time.perf_counter()
            fc = model.forecast(series[None, :], prediction_length=spec.horizon)
            median = np.asarray(fc.median, dtype=np.float64).reshape(-1)
            low = np.asarray(fc.quantile(LOW_Q), dtype=np.float64).reshape(-1)
            high = np.asarray(fc.quantile(HIGH_Q), dtype=np.float64).reshape(-1)
            median, low, high = (np.nan_to_num(a, nan=float(np.nanmean(series))) for a in (median, low, high))
            if spec.clip:
                lo, hi = spec.clip
                median, low, high = (np.clip(a, lo, hi) for a in (median, low, high))
            payload = {
                "metric": spec.key, "generated_at": now, "start": end + spec.step, "step": spec.step,
                "median": median.round(4).tolist(), "low": low.round(4).tolist(), "high": high.round(4).tolist(),
                "low_level": LOW_Q, "high_level": HIGH_Q,
                "context_points": int(np.sum(~np.isnan(series))), "model": model_name,
                "summary": None,
            }
            if spec.key == "batt_pct":
                on_ac = latest(conn, "on_ac")
                payload["summary"] = battery_summary(median, low, high, spec.step, bool(on_ac))
            results.append(payload)
            log(f"{spec.key}: forecast {spec.horizon} steps in {(time.perf_counter() - t0) * 1000:.0f} ms")

        health = health_forecast(conn, model, now)
        if health:
            health["model"] = model_name
            results.append(health)

        with conn:
            for payload in results:
                conn.execute("INSERT OR REPLACE INTO forecasts (metric, generated_at, payload) VALUES (?, ?, ?)",
                             (payload["metric"], now, json.dumps(payload)))
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
