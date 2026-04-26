# stem-helper

Self-contained CLI that the OpenScribe C++ app launches via `NSTask` to split a
track into 4 stems (vocals, drums, bass, other) using Facebook's `htdemucs`
model. Apple-Silicon-only, fully offline (model weights are baked into the
PyInstaller bundle).

## Build

```bash
cd tools/stem-helper
./build.sh
```

Produces `tools/stem-helper/dist/separate/separate` (an arm64 binary in a
folder of dylibs). The whole `dist/separate/` tree gets shipped inside the
.app bundle.

## Run

```
./separate --input /path/to/song.mp3 --output-dir /tmp/stems/
```

Writes:

```
/tmp/stems/vocals.wav
/tmp/stems/drums.wav
/tmp/stems/bass.wav
/tmp/stems/other.wav
```

(all 44.1 kHz stereo PCM_16)

### Stdout protocol

One line per chunk:

```
progress: 0.0000
progress: 0.1234
...
progress: 1.0000
```

Diagnostic info (model load time, device chosen, per-stem write paths) goes
to stderr prefixed with `info:`. On error, a single `error: <msg>` line on
stderr and a non-zero exit code.

### Exit codes

| code | meaning                                  |
| ---- | ---------------------------------------- |
| 0    | success — all 4 WAVs written             |
| 1    | unexpected exception (traceback on err)  |
| 2    | input file not found                     |
| 3    | model failed to load                     |
| 4    | input audio could not be decoded         |
| 130  | interrupted (SIGINT)                     |

### Flags

| flag             | default      | notes                                      |
| ---------------- | ------------ | ------------------------------------------ |
| `--input`/`-i`   | required     | path to source audio                       |
| `--output-dir`/`-o` | required  | dir for vocals/drums/bass/other.wav        |
| `--device`       | `auto`       | `auto` tries MPS then CPU; or pin to one   |
| `--model`        | `htdemucs`   | any demucs bag name (htdemucs_ft etc.)     |
| `--shifts`       | `1`          | random-shift averaging; higher=better+slow |

## MPS note

`torch 2.11`'s MPS backend caps `Conv1d` output channels at 65536, which
htdemucs trips. The script tries MPS first and silently retries on CPU when
that error fires. Net effect on M1/M2: separation runs on CPU. We keep the
MPS attempt in place because future torch versions are expected to lift the
cap. Caller doesn't need to know — exit code and stdout protocol are the
same either way.
