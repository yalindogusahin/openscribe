#!/usr/bin/env python3
"""
OpenScribe chord-helper: estimate a song's chord progression with timing.

Usage:
    chord --input /path/to/song.wav --output /path/to/chords.json

Approach (all via librosa, which is already bundled for audio-separator, so
no extra heavy dependency ships):
    1. Load mono, run HPSS to isolate the harmonic component.
    2. Beat-track on the full signal to get a beat grid.
    3. Compute a CQT chromagram on the harmonic part.
    4. Beat-synchronise the chroma (one 12-d vector per beat).
    5. Match each beat against major / minor / 7th chord templates.
    6. Median-smooth the per-beat labels, then merge runs into segments.

Stdout protocol (matches stem-helper / transcribe-helper):
    progress: 0.00 .. progress: 1.00
    stage: <human-readable phase>
Output: a JSON file at --output with shape
    {"tempo": <bpm float>, "chords": [{"start": s, "end": s, "label": "Am"}, ...]}
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


# Pitch-class names. Sharps only — matches how iReal Pro / lead sheets are
# usually written for guitar/pop contexts.
_PITCH_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Chord quality templates as semitone offsets from the root, with a suffix and
# a complexity penalty. The penalty (0..1, subtracted from the match score)
# nudges the matcher toward simpler triads unless the extra chord tone is
# clearly present, so we don't label every major chord as a maj7.
_QUALITIES = [
    ("",   (0, 4, 7),      0.00),  # major triad
    ("m",  (0, 3, 7),      0.00),  # minor triad
    ("7",  (0, 4, 7, 10),  0.04),  # dominant 7
    ("m7", (0, 3, 7, 10),  0.05),  # minor 7
    ("maj7", (0, 4, 7, 11), 0.05),  # major 7
]


def _build_templates():
    """Return (labels, matrix) where matrix is shape (n_templates, 12),
    each row an L2-normalised binary chord template."""
    import numpy as np

    labels = []
    rows = []
    penalties = []
    for root in range(12):
        for suffix, offsets, penalty in _QUALITIES:
            vec = np.zeros(12, dtype=np.float32)
            for off in offsets:
                vec[(root + off) % 12] = 1.0
            norm = np.linalg.norm(vec)
            if norm > 0:
                vec /= norm
            labels.append(f"{_PITCH_NAMES[root]}{suffix}")
            rows.append(vec)
            penalties.append(penalty)
    return labels, np.array(rows, dtype=np.float32), np.array(penalties, dtype=np.float32)


def _median_smooth(indices, k: int):
    """Median filter a 1-D integer label sequence to remove single-beat
    flickers. k is the (odd) window length."""
    import numpy as np

    n = len(indices)
    if n == 0 or k <= 1:
        return indices
    half = k // 2
    out = np.empty(n, dtype=indices.dtype)
    for i in range(n):
        lo = max(0, i - half)
        hi = min(n, i + half + 1)
        vals, counts = np.unique(indices[lo:hi], return_counts=True)
        out[i] = vals[np.argmax(counts)]
    return out


def main() -> int:
    p = argparse.ArgumentParser(prog="chord", description=__doc__)
    p.add_argument("--input", "-i", required=True, help="path to input audio file")
    p.add_argument("--output", "-o", required=True, help="path to output .json file")
    p.add_argument("--no-chord-threshold", type=float, default=0.55,
                   help="below this match score a beat is labelled N (no chord)")
    p.add_argument("--smooth", type=int, default=5,
                   help="median-smoothing window in beats (odd; 1 disables)")
    p.add_argument("--min-duration", type=float, default=0.8,
                   help="segments shorter than this (s) are absorbed into a neighbour")
    args = p.parse_args()

    in_path = Path(args.input).expanduser().resolve()
    out_path = Path(args.output).expanduser().resolve()
    if not in_path.is_file():
        print(f"error: input file not found: {in_path}", file=sys.stderr)
        return 2
    out_path.parent.mkdir(parents=True, exist_ok=True)

    _emit_stage("Loading audio")
    _emit_progress(0.05)
    try:
        import numpy as np
        import librosa
    except Exception as e:  # noqa: BLE001
        print(f"error: librosa/numpy not available: {e}", file=sys.stderr)
        return 3

    sr = 22050
    try:
        y, sr = librosa.load(str(in_path), sr=sr, mono=True)
    except Exception as e:  # noqa: BLE001
        print(f"error: failed to load audio: {e}", file=sys.stderr)
        return 4
    if y.size == 0:
        print("error: audio is empty", file=sys.stderr)
        return 4

    _emit_stage("Separating harmonic content")
    _emit_progress(0.25)
    # Harmonic/percussive source separation: chords live in the harmonic part,
    # and stripping transients sharpens the chroma.
    y_harm, _ = librosa.effects.hpss(y)

    _emit_stage("Tracking beats")
    _emit_progress(0.45)
    hop = 512
    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, hop_length=hop)
    tempo = float(np.atleast_1d(tempo)[0])

    _emit_stage("Computing chromagram")
    _emit_progress(0.6)
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=sr, hop_length=hop)

    # Beat-synchronise: one representative chroma vector per beat interval.
    # Fall back to a fixed grid if beat tracking found nothing usable.
    if beat_frames is not None and len(beat_frames) >= 2:
        beat_frames = np.asarray(beat_frames)
        sync = librosa.util.sync(chroma, beat_frames, aggregate=np.median)
        beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop)
        # sync produces one column per inter-beat segment; build matching
        # [start, end) times. Cap the final segment at the audio duration.
        total_dur = librosa.get_duration(y=y, sr=sr)
        seg_starts = beat_times.tolist()
        seg_ends = beat_times[1:].tolist() + [total_dur]
        # sync's column count can differ from len(beat_frames) by one; align.
        n_cols = sync.shape[1]
        seg_starts = seg_starts[:n_cols]
        seg_ends = seg_ends[:n_cols]
        while len(seg_starts) < n_cols:  # pragma: no cover - defensive
            seg_starts.append(seg_ends[-1] if seg_ends else 0.0)
            seg_ends.append(total_dur)
    else:
        # No beats: chop into fixed ~0.5 s windows.
        total_dur = librosa.get_duration(y=y, sr=sr)
        win = max(1, int(round(0.5 * sr / hop)))
        n_cols = chroma.shape[1] // win
        sync = np.column_stack([
            np.median(chroma[:, i * win:(i + 1) * win], axis=1)
            for i in range(max(1, n_cols))
        ])
        times = librosa.frames_to_time(np.arange(sync.shape[1]) * win, sr=sr, hop_length=hop)
        seg_starts = times.tolist()
        seg_ends = times[1:].tolist() + [total_dur]

    _emit_stage("Matching chords")
    _emit_progress(0.8)
    labels, templates, penalties = _build_templates()

    # Normalise each beat's chroma so the match is a cosine similarity.
    norms = np.linalg.norm(sync, axis=0, keepdims=True)
    norms[norms == 0] = 1.0
    sync_n = sync / norms

    # scores: (n_templates, n_beats); apply per-template complexity penalty.
    scores = templates @ sync_n
    scores -= penalties[:, None]
    best_idx = np.argmax(scores, axis=0)
    best_score = scores[best_idx, np.arange(scores.shape[1])]

    # Beats with weak harmonic support → N (no chord). Use a sentinel index.
    NO_CHORD = -1
    best_idx = best_idx.astype(np.int64)
    best_idx[best_score < args.no_chord_threshold] = NO_CHORD

    if args.smooth and args.smooth > 1:
        best_idx = _median_smooth(best_idx, args.smooth | 1)

    # Merge consecutive identical labels into (idx, start, end) runs.
    runs = []
    i = 0
    n = len(best_idx)
    while i < n:
        j = i
        while j + 1 < n and best_idx[j + 1] == best_idx[i]:
            j += 1
        start = float(seg_starts[i])
        end = float(seg_ends[j])
        if end > start:
            runs.append([int(best_idx[i]), start, end])
        i = j + 1

    # Coalesce short runs: anything briefer than --min-duration is absorbed
    # into whichever neighbour it shares more of a boundary with (longer one),
    # then re-merged. This kills the per-beat flicker so the lane reads like a
    # lead sheet rather than a strobe.
    min_dur = max(0.0, args.min_duration)
    changed = True
    while changed and len(runs) > 1:
        changed = False
        for k in range(len(runs)):
            idx, start, end = runs[k]
            if end - start >= min_dur:
                continue
            left = runs[k - 1] if k > 0 else None
            right = runs[k + 1] if k + 1 < len(runs) else None
            if left and right:
                target = left if (left[2] - left[1]) >= (right[2] - right[1]) else right
            else:
                target = left or right
            if target is None:
                continue
            target[1] = min(target[1], start)
            target[2] = max(target[2], end)
            runs.pop(k)
            changed = True
            break
    # Re-merge now-adjacent identical labels.
    merged = []
    for idx, start, end in runs:
        if merged and merged[-1][0] == idx:
            merged[-1][2] = end
        else:
            merged.append([idx, start, end])

    chords = []
    for idx, start, end in merged:
        label = "N" if idx == NO_CHORD else labels[idx]
        chords.append({"start": round(start, 3),
                       "end": round(end, 3),
                       "label": label})

    _emit_stage("Writing output")
    _emit_progress(0.95)
    payload = {"tempo": round(tempo, 2), "chords": chords}
    out_path.write_text(json.dumps(payload, indent=2))

    _emit_progress(1.0)
    _emit_stage(f"Done: {len(chords)} chord segments")
    return 0


if __name__ == "__main__":
    sys.exit(main())
