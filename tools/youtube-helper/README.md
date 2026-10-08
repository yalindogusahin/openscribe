# youtube-helper

CLI that the OpenScribe C++ app launches via `NSTask` to download the audio
track of a YouTube video. Wraps `yt-dlp`. Produces a single audio file
(`<id>.<ext>`, typically `.m4a`) plus a `manifest.json` next to it.

## Setup (dev / on first machine)

```bash
cd tools/youtube-helper
python3.11 -m venv venv
./venv/bin/pip install -r requirements.txt
```

The C++ app finds the helper by walking up from the .app bundle looking for
`tools/youtube-helper/`, or via the `OPENSCRIBE_YOUTUBE_HELPER` env var.

## Run directly

```
./venv/bin/python download.py --url 'https://youtu.be/dQw4w9WgXcQ' \
                              --output-dir /tmp/yt/
```

Writes:

```
/tmp/yt/<videoId>.m4a         # the audio file
/tmp/yt/manifest.json         # url, title, id, ext, duration, filepath
```

### Stdout protocol

One event per line:

```
stage: Resolving video
stage: Downloading audio
progress: 0.0123
progress: 0.5000
progress: 1.0000
title: Never Gonna Give You Up
path: /tmp/yt/dQw4w9WgXcQ.m4a
```

`info: …` lines go to stderr. On error a single `error: <msg>` line on
stderr and a non-zero exit code.

### Exit codes

| code | meaning                                       |
| ---- | --------------------------------------------- |
| 0    | success — audio file + manifest written       |
| 1    | unexpected exception (traceback on stderr)    |
| 2    | bad arguments / not a recognizable YouTube URL|
| 3    | yt-dlp download failure (network, geo, age…)  |
| 4    | downloaded but the file we expected isn't on disk |
| 130  | interrupted (SIGINT)                          |

### Flags

| flag             | default                                            | notes                                |
| ---------------- | -------------------------------------------------- | ------------------------------------ |
| `--url`/`-u`     | required                                           | YouTube watch / shorts / youtu.be URL |
| `--output-dir`/`-o` | required                                        | dir for `<id>.<ext>` + manifest.json |
| `--format`       | `bestaudio[ext=m4a]/bestaudio[acodec=aac]/bestaudio` | yt-dlp format selector             |

## ffmpeg

We deliberately avoid yt-dlp's post-processors: the default format selector
prefers an m4a/AAC stream that AVFoundation can play natively, so no
re-encoding step is needed and the helper has no `ffmpeg` dependency. Videos
that don't expose an m4a stream fall back to whatever `bestaudio` resolves
to (often webm/opus); macOS 13+ AVFoundation handles those too.
