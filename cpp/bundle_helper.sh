#!/usr/bin/env bash
# Bundle the stem-separation helper into OpenScribeNative.app so the app is
# self-contained for new users. Pulls a portable Python interpreter, builds
# a venv with all ML deps, copies the helper script, then re-codesigns.
#
# Run AFTER ./build.sh has produced a fresh OpenScribeNative.app.
#
# Output layout inside the bundle:
#   OpenScribeNative.app/Contents/Resources/python/        -- python-build-standalone
#   OpenScribeNative.app/Contents/Resources/stem-helper/
#                                            site-packages/ -- pip --target install
#                                            separate.py    -- the helper script
#
# We deliberately avoid `python -m venv` here. python-build-standalone's
# binary uses @rpath references to libpython3.11.dylib that resolve
# relative to its own lib/ directory; venv with --copies dupes the binary
# into venv/bin/, where the rpath no longer points anywhere and dyld
# aborts. Sticking with the source interpreter and using `pip install
# --target=...` sidesteps the rpath problem entirely.
#
# Models (~760 MB total) are bundled too so first-run separation works
# without any network. They go inside the helper dir at runtime-discovered
# sibling locations (separate.py's _resolve_torch_home /
# _resolve_audio_separator_models pick them up automatically).
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="OpenScribeNative.app"
PY_VERSION="3.11.15+20260414"
PY_TAG="20260414"
PY_TARBALL="cpython-${PY_VERSION/+/%2B}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/${PY_TARBALL}"

if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE not found. Run ./build.sh first."
    exit 1
fi

RES="$BUNDLE/Contents/Resources"
PY_DIR="$RES/python"
HELPER_DIR="$RES/stem-helper"
CACHE_DIR="build/python-bundle"

# 1. Stage the python-build-standalone tarball (cached across builds).
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_DIR/python.tar.gz" ]; then
    echo "Downloading python-build-standalone..."
    curl -L -o "$CACHE_DIR/python.tar.gz" "$PY_URL"
fi

# 2. Extract Python *directly* into the bundle. No cp/ditto step: source and
#    destination both sit under an iCloud-synced folder, which makes any
#    file-level copy fail intermittently with "fcopyfile timed out" when
#    iCloud has evicted files. tar streams from the archive, sidestepping
#    the issue entirely.
echo "Extracting Python into bundle..."
rm -rf "$PY_DIR"
mkdir -p "$RES"
tar -xzf "$CACHE_DIR/python.tar.gz" -C "$RES"
# The tarball extracts to ./python/ — that's already $PY_DIR.

PY="$PY_DIR/bin/python3.11"
if [ ! -x "$PY" ]; then
    echo "error: bundled python not executable at $PY"
    exit 1
fi

# 3. Set up the helper directory and target site-packages location.
echo "Preparing site-packages target..."
rm -rf "$HELPER_DIR"
mkdir -p "$HELPER_DIR/site-packages"

SITE="$HELPER_DIR/site-packages"

# 4. Install ML deps directly into the bundle's site-packages. CPU torch
#    only — MPS is unstable for BS-Roformer (see StemSeparator notes).
#    audio-separator pulls in onnxruntime + librosa.
echo "Installing dependencies (this can take 3-5 minutes)..."
"$PY" -m pip install --upgrade pip
"$PY" -m pip install --target="$SITE" \
    "audio-separator[cpu]" \
    demucs \
    torch \
    numpy \
    soundfile \
    tqdm

# 5. Copy the helper script.
cp ../tools/stem-helper/separate.py "$HELPER_DIR/separate.py"

# 6. Smoke test the bundled site-packages.
echo "Smoke-testing helper..."
PYTHONPATH="$SITE" "$PY" -c "
from audio_separator.separator import Separator
import demucs, torch, numpy, soundfile
print('helper deps OK, torch', torch.__version__)
"

# 7. Pre-download stem-separation models into the bundle. Cached in
#    build/model-cache/ across runs so re-bundling doesn't re-download
#    760 MB of weights every time.
echo "Bundling models (this can take a few minutes on first run)..."
TORCH_CACHE="$HELPER_DIR/torch_cache"
ASEP_CACHE="$HELPER_DIR/audio_separator_models"
MODEL_BUILD_CACHE="build/model-cache"
mkdir -p "$MODEL_BUILD_CACHE/torch" "$MODEL_BUILD_CACHE/asep"

PYTHONPATH="$SITE" \
TORCH_HOME="$MODEL_BUILD_CACHE/torch" \
"$PY" - "$MODEL_BUILD_CACHE/asep" <<'PY'
import sys, os
asep_dir = sys.argv[1]
os.makedirs(asep_dir, exist_ok=True)

# Demucs models live under TORCH_HOME/hub/checkpoints/
from demucs.pretrained import get_model
for name in ("htdemucs", "htdemucs_6s"):
    print(f"  prefetching {name}...", flush=True)
    get_model(name)

# Roformer goes into audio_separator's model dir
print("  prefetching mel_band_roformer (BS-Roformer)...", flush=True)
from audio_separator.separator import Separator
sep = Separator(output_dir="/tmp", model_file_dir=asep_dir)
sep.load_model(model_filename="model_bs_roformer_ep_317_sdr_12.9755.ckpt")
PY

# Move cached models into the bundle (rsync handles existing dirs).
mkdir -p "$TORCH_CACHE/hub/checkpoints" "$ASEP_CACHE"
cp -a "$MODEL_BUILD_CACHE/torch/hub/checkpoints/." "$TORCH_CACHE/hub/checkpoints/"
cp -a "$MODEL_BUILD_CACHE/asep/." "$ASEP_CACHE/"

# 8. Strip caches and bytecode that bloat the bundle without runtime value.
echo "Pruning caches..."
find "$SITE" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find "$SITE" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$SITE" -name "*.pyc" -delete 2>/dev/null || true

# 9. Re-sign — adding files invalidated the existing signature.
echo "Re-signing..."
find "$BUNDLE" -name "._*" -delete
xattr -cr "$BUNDLE"
codesign --force --deep --options=runtime \
         --entitlements entitlements.plist \
         --sign - "$BUNDLE"

echo ""
echo "Done. Bundle size:"
du -sh "$BUNDLE"
echo ""
echo "Helper at: $BUNDLE/Contents/Resources/stem-helper/"
