# Tempra

A native macOS menu bar app that monitors your Mac's vital signs live and over time
(CPU, memory, temperatures, battery, power, disk, network, processes) and forecasts
where they're heading with [Mistral Timestral](https://huggingface.co/mistralai/Timestral-5M),
running locally.

- **Menu bar**: an icon plus a live value (CPU, memory pressure, temperature, battery or power — configurable).
- **Summary panel**: click the icon for the essentials and the latest forecasts.
- **Dashboard window**: full history charts (15 min → 30 days), per-core CPU, memory breakdown,
  thermals, battery & power details, battery health, disk & network, process list and forecasts.

## Build

Requirements: macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
scripts/build.sh            # builds build/Tempra.app
scripts/build.sh --install  # also copies it to /Applications and launches it
```

To work in Xcode: `xcodegen generate && open Tempra.xcodeproj`.

## Forecasting (Timestral)

Forecasts run in a background Python process (`forecaster/worker.py`) that reads the history
database every 5 minutes and writes probabilistic forecasts (10th/50th/90th percentile) back to it.

Install the engine once from **Settings → Forecasting → Install** (needs `uv`), or from Terminal:

```bash
forecaster/setup.sh ~/Library/Application\ Support/Tempra/forecaster
```

The model weights are downloaded from Hugging Face on first run. Forecasts appear after about an
hour of history (two hours for battery; two weeks of daily samples for battery health).

| Forecast | Resolution | Context | Horizon |
|---|---|---|---|
| Battery level → time to empty/full | 5 min | 7 days | 12 h |
| CPU, memory pressure, SoC temperature, system power | 1 min | 3 days | 1 h |
| Battery health | 1 day | all | 180 days |

## Data

Everything stays on this Mac, in `~/Library/Application Support/Tempra/history.sqlite`:
raw samples for 24 h, 1-minute averages for 30 days, hourly averages forever.

## Notes

- Temperatures come from Apple Silicon's HID sensors through private IOKit APIs, so the app is
  not sandboxed and not App Store-eligible. A macOS update could change sensor names.
- Per-component power (CPU/GPU/ANE watts) needs root via `powermetrics`/IOReport — planned for later.
- Debug builds can render every view to PNG: `Tempra -TempraSnapshotDir /some/dir`.
