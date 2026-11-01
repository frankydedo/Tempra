#!/bin/zsh
# Installs Tempra's forecasting engine (Python + PyTorch + Timestral) into a private venv.
#
# Usage: setup.sh <target-dir>
# The target dir must contain pyproject.toml; the venv is created at <target-dir>/.venv.
# Tempra runs this from Settings; you can also run it yourself from Terminal.
set -euo pipefail

TARGET="${1:-$(cd "$(dirname "$0")" && pwd)}"
cd "$TARGET"

UV=""
for candidate in "$(command -v uv 2>/dev/null || true)" /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then UV="$candidate"; break; fi
done
if [[ -z "$UV" ]]; then
  echo "uv not found. Install it with: brew install uv" >&2
  exit 1
fi
echo "Using uv at $UV"

# PyTorch needs a native interpreter. On Apple Silicon make sure we get an arm64 Python,
# even when uv itself runs under Rosetta (e.g. an Intel Homebrew install).
PYTHON_REQUEST="3.12"
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then
  "$UV" python install cpython-3.12-macos-aarch64-none
  PYTHON_DIR="$("$UV" python dir)"
  ARM_PY=$(ls -d "$PYTHON_DIR"/cpython-3.12*-macos-aarch64-none/bin/python3.12 2>/dev/null | sort -V | tail -1)
  if [[ -n "$ARM_PY" ]]; then PYTHON_REQUEST="$ARM_PY"; fi
fi
echo "Using Python $PYTHON_REQUEST"

"$UV" venv --allow-existing --python "$PYTHON_REQUEST" .venv
"$UV" sync --python "$PYTHON_REQUEST"

echo "Checking installation…"
.venv/bin/python -c "import platform, torch, timestral; print('OK', platform.machine(), 'torch', torch.__version__)"
