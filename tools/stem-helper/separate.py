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
    """Pin TORCH_HOME so demucs's model downloads land in a stable, writable
    spot. Order: explicit env > sibling torch_cache (dev/legacy) > nothing
    (lets torch fall back to ~/.cache, only ever hit for dev outside the
    .app context)."""
    if os.environ.get("TORCH_HOME"):
        return
    here = Path(__file__).resolve().parent
    cand = here / "torch_cache"
    if cand.exists():
        os.environ["TORCH_HOME"] = str(cand)


def _resolve_audio_separator_models() -> Path:
    """Where audio-separator should look for / download Roformer / MDX
    weights. The C++ caller pins this to ~/Library/Application Support/
    OpenScribe/audio_separator_models so models live outside the (signed,
    read-only) .app bundle and persist across app upgrades."""
    env = os.environ.get("OPENSCRIBE_AUDIO_SEPARATOR_MODELS")
    if env:
        p = Path(env).expanduser()
        p.mkdir(parents=True, exist_ok=True)
        return p
    # dev fallback: sibling dir next to this script
    here = Path(__file__).resolve().parent
    p = here / "audio_separator_models"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _emit_progress(frac: float) -> None:
    frac = max(0.0, min(1.0, float(frac)))
    sys.stdout.write(f"progress: {frac:.4f}\n")
    sys.stdout.flush()


def _emit_stage(text: str) -> None:
    sys.stdout.write(f"stage: {text}\n")
    sys.stdout.flush()


def _install_tqdm_hook():
    """Replace tqdm.tqdm so the inner progress bar drives our `progress: x`
    lines. Both demucs (`apply_model`) and audio-separator (mdxc/roformer
    inference loops) call `from tqdm import tqdm` at module import time, so
    patching `tqdm.tqdm` *before* they're imported is sufficient.
    """
    import os
    import tqdm as _tqdm_mod

    real_tqdm = _tqdm_mod.tqdm
    null_sink = open(os.devnull, "w")

    class HookedTqdm(real_tqdm):  # type: ignore[misc]
        def __init__(self, iterable=None, *a, **kw):
            # Silence tqdm's own visual bar by directing it to /dev/null.
            # Crucial: do NOT pass `disable=True` — tqdm's __iter__ short-
            # circuits and never calls update() when disabled, so our hook
            # would never fire on iter-style usage like `for x in tqdm(...)`.
            kw["file"] = null_sink
            kw["mininterval"] = 0
            kw["miniters"] = 1
            super().__init__(iterable, *a, **kw)
            self._oscribe_total = self.total or (
                len(iterable) if iterable is not None and hasattr(iterable, "__len__") else 0
            )
            self._oscribe_last = -1.0
            if self._oscribe_total:
                _emit_progress(0.0)

        def update(self, n=1):
            super().update(n)
            if self._oscribe_total:
                frac = self.n / self._oscribe_total
                # Rate-limit to ~0.5% steps; always emit on completion.
                if frac - self._oscribe_last >= 0.005 or self.n >= self._oscribe_total:
                    _emit_progress(frac)
                    self._oscribe_last = frac

    _tqdm_mod.tqdm = HookedTqdm
    # Some libs do `from tqdm.auto import tqdm`; patch that path too. Not all
    # versions of tqdm ship `tqdm.auto`, so guard the import.
    try:
        import tqdm.auto as _tqdm_auto
        _tqdm_auto.tqdm = HookedTqdm
    except Exception:
        pass


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


def _run_roformer(in_path: Path, out_dir: Path, model_key: str) -> int:
    """High-quality 2-stem path using audio-separator + BS-Roformer-Viperx-1297.

    Output: vocals.wav + instrumental.wav + stems.json. Same protocol as the
    demucs path so the C++ caller doesn't have to branch on model.
    """
    import json
    import shutil

    model_dir = _resolve_audio_separator_models()

    # BS-Roformer trained by viperx (SDX23 winner). Outputs vocals + instrumental.
    model_filename = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"

    _emit_stage("Loading RoFormer model")
    try:
        from audio_separator.separator import Separator
    except Exception as e:
        print(f"error: audio-separator not installed: {e}", file=sys.stderr)
        return 5

    sep = Separator(
        output_dir=str(out_dir),
        output_format="WAV",
        model_file_dir=str(model_dir),
    )
    # audio-separator auto-picks MPS on Apple Silicon, but BS-Roformer's torch
    # ops stall indefinitely on a metal-gpu-stream tensor copy at ~7.9 GB
    # resident memory. Force CPU. Slower (~real-time on M1 for vocals/inst)
    # but deterministic. Revisit when audio-separator exposes a CoreML/ONNX
    # roformer backend.
    import torch
    sep.torch_device     = torch.device("cpu")
    sep.torch_device_mps = torch.device("cpu")
    try:
        sep.load_model(model_filename=model_filename)
    except Exception as e:
        print(f"error: failed to load roformer model: {e}", file=sys.stderr)
        return 6

    _emit_stage("Separating (this can take a few minutes)")
    try:
        out_files = sep.separate(str(in_path))
    except Exception as e:
        print(f"error: roformer separation failed: {e}", file=sys.stderr)
        return 7

    _emit_stage("Writing stems")

    # audio-separator names files like
    #   "<input_stem>_(Vocals)_<model>.wav"  /  "..._(Instrumental)_..."
    # Normalize to vocals.wav / instrumental.wav so the C++ side and cache
    # manifest stay model-agnostic.
    by_role: dict[str, Path] = {}
    for f in out_files:
        p = Path(f)
        if not p.is_absolute():
            p = out_dir / p
        low = p.name.lower()
        if "(vocals)" in low or low.startswith("vocals"):
            by_role["vocals"] = p
        elif "(instrumental)" in low or "instrumental" in low:
            by_role["instrumental"] = p

    written: list[tuple[str, Path]] = []
    for name in ("vocals", "instrumental"):
        src = by_role.get(name)
        if not src or not src.exists():
            print(f"error: roformer output missing {name}", file=sys.stderr)
            return 8
        dst = out_dir / f"{name}.wav"
        if src.resolve() != dst.resolve():
            shutil.move(str(src), str(dst))
        written.append((name, dst))

    manifest = {
        "model": model_key,
        "samplerate": 44100,
        "stems": [{"name": n, "file": p.name} for n, p in written],
    }
    (out_dir / "stems.json").write_text(json.dumps(manifest, indent=2))

    _emit_progress(1.0)
    for n, p_ in written:
        print(f"info: wrote {n}={p_}", file=sys.stderr)
    return 0


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
        help="model name. demucs: htdemucs, htdemucs_6s. roformer: mel_band_roformer",
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

    if args.model == "mel_band_roformer":
        return _run_roformer(in_path, out_dir, args.model)

    # Imports after env tweaks so torch picks up TORCH_HOME.
    import numpy as np
    import torch
    import soundfile as sf
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    device = _pick_device() if args.device == "auto" else args.device
    print(f"info: device={device}", file=sys.stderr)

    _emit_stage("Loading model")
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
    # Capture mean+std BEFORE in-place mutation so we can denormalize the
    # model output to the original peak. Earlier versions reused `wav.std()`
    # after `wav /= wav.std()`, which is ~1.0 — that's why every stem came
    # out volume-boosted.
    ref = wav.mean(0)
    src_mean = ref.mean()
    src_std  = max(1e-8, float(wav.std()))
    wav -= src_mean
    wav /= src_std

    _emit_stage("Separating")
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

    sources = sources * src_std + src_mean

    # model.sources is e.g. ['drums','bass','other','vocals'] for htdemucs
    # or ['drums','bass','other','vocals','guitar','piano'] for htdemucs_6s.
    sr = model.samplerate
    written = []
    for name, source in zip(model.sources, sources):
        out_path = out_dir / f"{name}.wav"
        # soundfile expects (samples, channels)
        audio = source.detach().cpu().numpy().T
        sf.write(str(out_path), audio, sr, subtype="PCM_16")
        written.append((name, out_path))

    # Write a manifest listing stems in a stable display order (vocals first,
    # "other" last). The C++ caller reads this to populate the mixer rows
    # without having to know per-model ordering rules.
    import json
    display_order = ["vocals", "drums", "bass", "guitar", "piano", "other"]
    by_name = {n: p for n, p in written}
    ordered = [
        {"name": n, "file": by_name[n].name}
        for n in display_order
        if n in by_name
    ]
    # Append anything unexpected at the end so we don't silently drop a stem.
    for n, p in written:
        if n not in display_order:
            ordered.append({"name": n, "file": p.name})
    manifest = {
        "model": args.model,
        "samplerate": sr,
        "stems": ordered,
    }
    (out_dir / "stems.json").write_text(json.dumps(manifest, indent=2))

    _emit_progress(1.0)
    for n, p_ in written:
        print(f"info: wrote {n}={p_}", file=sys.stderr)
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
