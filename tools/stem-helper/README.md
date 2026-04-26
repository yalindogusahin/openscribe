# stem-helper

CLI that the OpenScribe C++ app launches via `NSTask` to split a track into
4 stems (vocals, drums, bass, other) using Facebook's `htdemucs` model.
Apple-Silicon-only, fully offline (model weights live next to the script in
`torch_cache/`).

## Setup (dev / on first machine)

```bash
cd tools/stem-helper
python3.11 -m venv venv
./venv/bin/pip install -r requirements.txt
TORCH_HOME="$(pwd)/torch_cache" ./venv/bin/python -c \
    "from demucs.pretrained import get_model; get_model('htdemucs')"
```

The C++ app finds the helper by walking up from the .app bundle looking for
`tools/stem-helper/`, or via the `OPENSCRIBE_STEM_HELPER` env var.

PyInstaller bundling has been tried twice and reliably hangs at the modulegraph
analysis pass; we ship the venv directory for now and may revisit packaging
(py2app / conda-pack) later.

## Run directly

```
./venv/bin/python separate.py --input /path/to/song.mp3 --output-dir /tmp/stems/
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
