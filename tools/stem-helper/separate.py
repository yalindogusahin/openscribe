#!/usr/bin/env python3
"""
OpenScribe stem-helper: separate an input track into 4 stems
(vocals, drums, bass, other) using Facebook's htdemucs model.

Usage:
    separate --input /path/to/song.mp3 --output-dir /tmp/stems/

Stdout:
    progress: 0.00 .. progress: 1.00   (one line per chunk)
Exit code: 0 success, non-zero on failure (human-readable msg on stderr).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


def _resolve_torch_home() -> None:
    """Pin TORCH_HOME to a path next to the binary so weights are bundled
    and we never touch the user's ~/.cache."""
    if os.environ.get("TORCH_HOME"):
        return
    if getattr(sys, "frozen", False):
        # PyInstaller bundle
        base = Path(sys._MEIPASS)  # type: ignore[attr-defined]
        cand = base / "torch_cache"
        if cand.exists():
            os.environ["TORCH_HOME"] = str(cand)
            return
    # dev mode: sibling torch_cache dir
    here = Path(__file__).resolve().parent
    cand = here / "torch_cache"
    if cand.exists():
        os.environ["TORCH_HOME"] = str(cand)


def _emit_progress(frac: float) -> None:
    frac = max(0.0, min(1.0, float(frac)))
    sys.stdout.write(f"progress: {frac:.4f}\n")
    sys.stdout.flush()


def _install_tqdm_hook():
    """Replace tqdm.tqdm so demucs's internal progress bar drives our
    `progress: x` lines."""
    import tqdm as _tqdm_mod

    real_tqdm = _tqdm_mod.tqdm

    class HookedTqdm(real_tqdm):  # type: ignore[misc]
        def __init__(self, iterable=None, *a, **kw):
            kw["disable"] = True  # silence its own bar
            super().__init__(iterable, *a, **kw)
            self._oscribe_total = self.total or (
                len(iterable) if iterable is not None and hasattr(iterable, "__len__") else 0
            )
            self._oscribe_done = 0
            if self._oscribe_total:
                _emit_progress(0.0)

        def update(self, n=1):
            super().update(n)
            self._oscribe_done += n
            if self._oscribe_total:
                _emit_progress(self._oscribe_done / self._oscribe_total)

    _tqdm_mod.tqdm = HookedTqdm
    # demucs imports `import tqdm` and uses tqdm.tqdm — patching the module
    # attribute is sufficient.


def _load_audio(path: Path, target_sr: int, target_ch: int):
    """Return a torch.Tensor of shape (channels, samples) at target_sr/target_ch.

    Tries soundfile first (libsndfile, no external deps). Falls back to demucs's
    AudioFile (ffmpeg) for compressed formats libsndfile can't open.
    """
    import numpy as np
    import torch

    audio = None
    sr = None
    try:
        import soundfile as sf

        data, sr = sf.read(str(path), always_2d=True, dtype="float32")
        # data: (samples, channels) -> (channels, samples)
        audio = torch.from_numpy(data.T.copy())
    except Exception:
        from demucs.audio import AudioFile

        audio = AudioFile(str(path)).read(
            streams=0, samplerate=target_sr, channels=target_ch
        )
        return audio  # already at target sr/channels

    # channel conversion
    if audio.shape[0] == 1 and target_ch == 2:
        audio = audio.repeat(2, 1)
    elif audio.shape[0] > target_ch:
        audio = audio[:target_ch]
    # sample-rate conversion via julius (already a demucs dep)
    if sr != target_sr:
        import julius

        audio = julius.resample_frac(audio, sr, target_sr)
    return audio


def _pick_device():
    import torch

    if torch.backends.mps.is_available() and torch.backends.mps.is_built():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def main() -> int:
    p = argparse.ArgumentParser(prog="separate", description=__doc__)
    p.add_argument("--input", "-i", required=True, help="path to input audio file")
    p.add_argument(
        "--output-dir",
        "-o",
        required=True,
        help="directory to write vocals.wav drums.wav bass.wav other.wav",
    )
    p.add_argument(
        "--device",
        choices=["auto", "cpu", "mps", "cuda"],
        default="auto",
        help="compute device (default: auto -> mps on Apple Silicon)",
    )
    p.add_argument(
        "--model",
        default="htdemucs",
        help="demucs model name (default htdemucs; htdemucs_ft for higher quality)",
    )
    p.add_argument(
        "--shifts",
        type=int,
        default=1,
        help="number of random time shifts to average (higher=better quality, slower)",
    )
    args = p.parse_args()

    in_path = Path(args.input).expanduser().resolve()
    out_dir = Path(args.output_dir).expanduser().resolve()
    if not in_path.is_file():
        print(f"error: input file not found: {in_path}", file=sys.stderr)
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    _resolve_torch_home()
    _install_tqdm_hook()

    # Imports after env tweaks so torch picks up TORCH_HOME.
    import numpy as np
    import torch
    import soundfile as sf
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    device = _pick_device() if args.device == "auto" else args.device
    print(f"info: device={device}", file=sys.stderr)

    t0 = time.time()
    try:
        model = get_model(args.model)
    except Exception as e:
        print(f"error: failed to load model {args.model!r}: {e}", file=sys.stderr)
        return 3
    model.eval()
    t_load = time.time() - t0
    print(f"info: model_load_s={t_load:.2f}", file=sys.stderr)

    # Load audio. Prefer libsndfile (soundfile) — it covers WAV/FLAC/AIFF/MP3/OGG/CAF
    # without external dependencies. Fall back to demucs's ffmpeg-based AudioFile for
    # formats libsndfile can't read (e.g. m4a/aac/mp4).
    try:
        wav = _load_audio(in_path, model.samplerate, model.audio_channels)
    except Exception as e:
        print(f"error: failed to read input audio: {e}", file=sys.stderr)
        return 4

    # AudioFile returns shape (channels, samples) at requested SR.
    ref = wav.mean(0)
    wav -= ref.mean()
    wav /= max(1e-8, wav.std())

    t1 = time.time()
    try:
        with torch.no_grad():
            sources = apply_model(
                model,
                wav[None],
                device=device,
                shifts=args.shifts,
                split=True,
                overlap=0.25,
                progress=True,
                num_workers=0,
            )[0]
    except (NotImplementedError, RuntimeError) as e:
        # MPS in torch <=2.11 caps Conv1d output channels at 65536; htdemucs trips
        # this. Fall back to CPU silently — the C++ caller never has to know.
        if device != "cpu":
            print(
                f"warn: {device} backend failed ({e!r}); retrying on cpu",
                file=sys.stderr,
            )
            device = "cpu"
            with torch.no_grad():
                sources = apply_model(
                    model,
                    wav[None],
                    device=device,
                    shifts=args.shifts,
                    split=True,
                    overlap=0.25,
                    progress=True,
                    num_workers=0,
                )[0]
        else:
            raise
    t_proc = time.time() - t1
    print(f"info: process_s={t_proc:.2f} device={device}", file=sys.stderr)

    sources = sources * wav.std() + ref.mean()

    # model.sources is e.g. ['drums','bass','other','vocals']
    sr = model.samplerate
    written = []
    for name, source in zip(model.sources, sources):
        out_path = out_dir / f"{name}.wav"
        # soundfile expects (samples, channels)
        audio = source.detach().cpu().numpy().T
        sf.write(str(out_path), audio, sr, subtype="PCM_16")
        written.append(out_path)

    _emit_progress(1.0)
    for p_ in written:
        print(f"info: wrote {p_}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:  # pragma: no cover
        import traceback

        traceback.print_exc()
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
