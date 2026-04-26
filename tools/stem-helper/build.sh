#!/usr/bin/env bash
# Build the OpenScribe stem-helper from a clean checkout.
#
# Output: tools/stem-helper/dist/separate/separate
#
#   ./separate --input song.mp3 --output-dir /tmp/stems
#
# Strategy:
#   1. create venv (python 3.11 — torch 2.11 wheels exist for 3.11/3.12)
#   2. install pinned deps from requirements.txt
#   3. ensure htdemucs weights are pre-baked under torch_cache/
#   4. run PyInstaller against separate.spec to produce dist/separate/

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

PYTHON="${PYTHON:-python3.11}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    if [ -x /opt/homebrew/bin/python3.11 ]; then
        PYTHON=/opt/homebrew/bin/python3.11
    else
        echo "error: python3.11 not found on PATH; install with 'brew install python@3.11'" >&2
        exit 1
    fi
fi

if [ ! -d venv ]; then
    echo "==> creating venv with $PYTHON"
    "$PYTHON" -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate

echo "==> installing python deps"
pip install --upgrade pip >/dev/null
pip install -r requirements.txt

echo "==> ensuring htdemucs weights are cached"
export TORCH_HOME="$SCRIPT_DIR/torch_cache"
mkdir -p "$TORCH_HOME/hub/checkpoints"
python - <<'PY'
# get_model triggers torch.hub download into TORCH_HOME if missing.
import os
from demucs.pretrained import get_model
m = get_model("htdemucs")
print("model sources:", m.sources)
PY

if ! ls "$TORCH_HOME/hub/checkpoints/"955717e8-*.th >/dev/null 2>&1; then
    echo "error: htdemucs weights did not land in $TORCH_HOME" >&2
    exit 2
fi

echo "==> running PyInstaller"
rm -rf build dist
pyinstaller --noconfirm separate.spec

echo "==> smoke-testing the bundle"
python - <<'PY' >/dev/null
import numpy as np, soundfile as sf
sr, dur = 44100, 5.0
t = np.linspace(0, dur, int(sr*dur), endpoint=False)
x = 0.3*np.sin(2*np.pi*220*t)
sf.write('/tmp/stem_helper_smoke.wav', np.stack([x, x], axis=1), sr)
PY
rm -rf /tmp/stem_helper_smoke_out
"$SCRIPT_DIR/dist/separate/separate" \
    --input /tmp/stem_helper_smoke.wav \
    --output-dir /tmp/stem_helper_smoke_out >/dev/null
for s in vocals drums bass other; do
    test -s "/tmp/stem_helper_smoke_out/$s.wav" || {
        echo "error: bundle did not produce $s.wav" >&2
        exit 3
    }
done

echo
echo "==> success: $SCRIPT_DIR/dist/separate/separate"
du -sh "$SCRIPT_DIR/dist/separate"
