# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for OpenScribe stem-helper.
#
# Produces a "onedir" bundle (folder of dylibs + executable) at dist/separate/.
# We deliberately do NOT use onefile mode: the torch shared libraries are huge
# and onefile would re-extract them to /tmp on every launch (slow + leaks disk).
import os
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

ROOT = Path(SPECPATH).resolve()  # noqa: F821 - SPECPATH is injected by PyInstaller
TORCH_CACHE = ROOT / "torch_cache"

# Pre-baked weights — bundled at <bundle>/torch_cache/hub/checkpoints/...
weights_datas = []
ckpt_dir = TORCH_CACHE / "hub" / "checkpoints"
if ckpt_dir.is_dir():
    for f in ckpt_dir.iterdir():
        if f.is_file():
            weights_datas.append((str(f), "torch_cache/hub/checkpoints"))

# demucs ships YAML configs for "bag" models in demucs/remote/
demucs_datas = collect_data_files("demucs", includes=["**/*.yaml", "**/*.txt"])

# Hidden imports — modules demucs/dora pull in by name at runtime that
# PyInstaller's static analyzer can miss.
hidden = [
    "demucs.htdemucs",
    "demucs.hdemucs",
    "demucs.demucs",
    "demucs.transformer",
    "demucs.spec",
    "demucs.states",
    "demucs.repo",
    "demucs.pretrained",
    "demucs.apply",
    "demucs.audio",
    "dora.log",
    "torchaudio",
    "soundfile",
    "_soundfile_data",
    "julius",
    "einops",
    "omegaconf",
]

# Skip stuff we definitely don't need on macOS.
excludes = [
    "tkinter",
    "matplotlib",
    "PyQt5",
    "PyQt6",
    "PySide2",
    "PySide6",
    "IPython",
    "notebook",
    "pytest",
    "tensorboard",
    "torch.utils.tensorboard",
]

a = Analysis(  # noqa: F821
    ["separate.py"],
    pathex=[str(ROOT)],
    binaries=[],
    datas=weights_datas + demucs_datas,
    hiddenimports=hidden,
    hookspath=[],
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=None)  # noqa: F821

exe = EXE(  # noqa: F821
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="separate",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(  # noqa: F821
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="separate",
)
