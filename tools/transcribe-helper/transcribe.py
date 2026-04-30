#!/usr/bin/env python3
"""
OpenScribe transcribe-helper: convert audio to MIDI via Spotify Basic Pitch.

Usage:
    transcribe --input /path/to/song.wav --output /path/to/notes.mid

Stdout protocol (matches stem-helper):
    progress: 0.00 .. progress: 1.00
    stage: <human-readable phase>
Exit code: 0 success, non-zero on failure.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _emit_progress(frac: float) -> None:
    frac = max(0.0, min(1.0, float(frac)))
    sys.stdout.write(f"progress: {frac:.4f}\n")
    sys.stdout.flush()


def _emit_stage(text: str) -> None:
    sys.stdout.write(f"stage: {text}\n")
    sys.stdout.flush()


def main() -> int:
    p = argparse.ArgumentParser(prog="transcribe", description=__doc__)
    p.add_argument("--input", "-i", required=True, help="path to input audio file")
    p.add_argument("--output", "-o", required=True, help="path to output .mid file")
    p.add_argument("--onset-threshold", type=float, default=0.5,
                   help="0..1; lower = more notes detected (default 0.5)")
    p.add_argument("--frame-threshold", type=float, default=0.3,
                   help="0..1; per-frame activity threshold (default 0.3)")
    p.add_argument("--minimum-note-length-ms", type=float, default=58.0,
                   help="discard notes shorter than this (default 58 ms)")
    args = p.parse_args()

    in_path = Path(args.input).expanduser().resolve()
    out_path = Path(args.output).expanduser().resolve()
    if not in_path.is_file():
        print(f"error: input file not found: {in_path}", file=sys.stderr)
        return 2
    out_path.parent.mkdir(parents=True, exist_ok=True)

    _emit_stage("Loading model")
    _emit_progress(0.05)

    # Basic Pitch's CoreML / ONNX backends ship the model weights inside the
    # installed package, so no separate model download or cache management.
    try:
        from basic_pitch.inference import predict
    except Exception as e:
        print(f"error: basic-pitch not installed: {e}", file=sys.stderr)
        return 3

    _emit_stage("Transcribing")
    _emit_progress(0.15)

    # predict() and its coremltools deps spam debug info to stdout
    # ("shape: (1, ...)", "dtype: float32", etc.) which would corrupt our
    # progress protocol. Redirect stdout into /dev/null for the inference
    # call only — our progress lines are emitted before/after, so they stay
    # on the real stdout.
    import contextlib
    import os as _os
    try:
        with open(_os.devnull, "w") as _devnull, \
             contextlib.redirect_stdout(_devnull):
            # predict() returns (model_output_dict, pretty_midi.PrettyMIDI,
            # note_events). Single inference call — no per-frame hook to
            # report finer-grained progress.
            _, midi_data, note_events = predict(
                str(in_path),
                onset_threshold=args.onset_threshold,
                frame_threshold=args.frame_threshold,
                minimum_note_length=args.minimum_note_length_ms,
            )
    except Exception as e:
        print(f"error: transcription failed: {e}", file=sys.stderr)
        return 4

    _emit_stage("Writing MIDI")
    _emit_progress(0.95)

    try:
        midi_data.write(str(out_path))
    except Exception as e:
        print(f"error: failed to write MIDI: {e}", file=sys.stderr)
        return 5

    # JSON sidecar for the in-app piano-roll overlay. We can't ship a real
    # MIDI parser in the C++ side just for this; basic-pitch already gives us
    # structured note events, so dump them next to the .mid for the host to
    # pick up. Format: list of {start, end, pitch, velocity}.
    notes_path = out_path.with_suffix(".notes.json")
    try:
        notes_list = []
        for ev in note_events:
            # ev = (start_sec, end_sec, pitch_midi, amplitude, [pitch_bends])
            notes_list.append({
                "start": float(ev[0]),
                "end":   float(ev[1]),
                "pitch": int(ev[2]),
                "velocity": float(ev[3]) if len(ev) > 3 else 1.0,
            })
        notes_path.write_text(json.dumps(notes_list))
    except Exception as e:
        # Sidecar failure is non-fatal: the .mid is what the user asked for.
        print(f"warning: failed to write notes sidecar: {e}", file=sys.stderr)

    _emit_progress(1.0)
    print(f"info: wrote {len(note_events)} notes to {out_path}", file=sys.stderr)
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
