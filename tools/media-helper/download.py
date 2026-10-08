#!/usr/bin/env python3
# YouTube/Instagram → audio CLI used by OpenScribe's "Open YouTube / Instagram
# URL…" command. Wraps yt-dlp. Stdout protocol mirrors stem-helper/separate.py
# so the Obj-C++ side can reuse the same line-parser shape.
#
# Stdout (machine-readable, one event per line):
#   stage: <human-readable phase>
#   progress: <0..1>
#   title: <video title>
#   path: <absolute path of final audio file>
#
# Stderr (human-readable, prefixed):
#   info: ...
#   error: <single line on fatal error>
#
# Exit codes:
#   0  success
#   1  unexpected exception
#   2  bad arguments / unsupported URL
#   3  yt-dlp download failure (network, geo-block, age gate, …)
#   4  no audio-only stream available in a format we can play
#  130  SIGINT
import argparse
import json
import os
import re
import sys
import traceback
from pathlib import Path


def emit(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def info(msg: str) -> None:
    sys.stderr.write(f"info: {msg}\n")
    sys.stderr.flush()


def fatal(msg: str, code: int) -> None:
    sys.stderr.write(f"error: {msg}\n")
    sys.stderr.flush()
    sys.exit(code)


# yt-dlp's progress hook fires on every chunk. We coalesce to ~1% steps so
# we don't flood the parent's pipe.
class ProgressEmitter:
    def __init__(self) -> None:
        self._last = -1.0

    def __call__(self, d: dict) -> None:
        status = d.get("status")
        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            if total > 0:
                frac = max(0.0, min(1.0, done / total))
                if frac - self._last >= 0.01 or frac >= 1.0:
                    emit(f"progress: {frac:.4f}")
                    self._last = frac
        elif status == "finished":
            emit("progress: 1.0000")
            emit("stage: Finalizing")


# yt-dlp accepts watch URLs, short links, /shorts/, /live/, music.youtube.com,
# plus Instagram reels/posts/tv (instagram.com and its ig.me shortener).
# We're lenient — only reject obvious garbage. yt-dlp itself will surface
# anything that's actually unsupported.
_URL_RE = re.compile(
    r"^https?://"
    r"(?:[\w-]+\.)*"
    r"(?:youtube\.com|youtu\.be|youtube-nocookie\.com"
    r"|instagram\.com|instagr\.am|ig\.me)"
    r"(?:/.*)?$",
    re.IGNORECASE,
)


def looks_like_supported_url(url: str) -> bool:
    return bool(_URL_RE.match(url.strip()))


def main() -> int:
    ap = argparse.ArgumentParser(description="Download YouTube/Instagram audio for OpenScribe")
    ap.add_argument("--url", "-u", required=True, help="YouTube or Instagram URL")
    ap.add_argument("--output-dir", "-o", required=True,
                    help="Directory to write the audio file into")
    ap.add_argument("--format", default="bestaudio[ext=m4a]/bestaudio[acodec=aac]/bestaudio",
                    help="yt-dlp format selector")
    ap.add_argument("--cookies-from-browser", default=None,
                    help="Browser to read cookies from (safari, chrome, firefox, "
                         "brave, edge, ...) — needed for login-gated Instagram posts")
    args = ap.parse_args()

    url = args.url.strip()
    if not looks_like_supported_url(url):
        fatal(f"Not a YouTube or Instagram URL: {url}", 2)

    out_dir = Path(args.output_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        from yt_dlp import YoutubeDL
        from yt_dlp.utils import DownloadError
    except ImportError as e:
        fatal(f"yt-dlp not installed: {e}", 1)

    emit("stage: Resolving video")

    progress_hook = ProgressEmitter()

    # Sink all yt-dlp chatter to stderr's info channel — its default progress
    # printer emits CR-terminated lines to stdout that collide with our
    # protocol's line-prefixed events.
    class _Silent:
        def debug(self, _msg): pass
        def info(self, _msg): pass
        def warning(self, msg): info(f"yt-dlp: {msg}")
        def error(self, msg): info(f"yt-dlp: {msg}")

    ydl_opts = {
        "format": args.format,
        "outtmpl": str(out_dir / "%(id)s.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "logger": _Silent(),
        "progress_hooks": [progress_hook],
        "retries": 3,
        "fragment_retries": 3,
        # Keep things deterministic — the AVFoundation pipeline only cares
        # about an audio stream it can decode (m4a/aac is the safe path).
        # If yt-dlp's chosen format isn't AAC the user can still load it —
        # AVFoundation handles webm/opus on macOS 13+, mp3 too.
    }
    if args.cookies_from_browser:
        # (browser,) — profile/keyring/container left as defaults. See
        # YoutubeDL.py's `cookiesfrombrowser` param docstring.
        ydl_opts["cookiesfrombrowser"] = (args.cookies_from_browser,)

    try:
        with YoutubeDL(ydl_opts) as ydl:
            emit("stage: Downloading audio")
            metadata = ydl.extract_info(url, download=True)
    except DownloadError as e:
        # Common: geo-block, age gate, removed video, sign-in required.
        msg = str(e).splitlines()[-1] if str(e) else "yt-dlp download failed"
        if not args.cookies_from_browser and (
            "login required" in msg.lower() or "rate-limit" in msg.lower()
        ):
            msg += " — enable a browser under Settings → Instagram/YouTube Login."
        fatal(msg, 3)
    except KeyboardInterrupt:
        return 130

    if metadata is None:
        fatal("yt-dlp returned no metadata", 3)

    if "entries" in metadata:
        # noplaylist=True should prevent this, but be defensive.
        entries = [e for e in metadata["entries"] if e]
        if not entries:
            fatal("No entries returned from playlist", 4)
        metadata = entries[0]

    title = metadata.get("title") or metadata.get("id") or "audio"
    requested = metadata.get("requested_downloads") or []
    final_path = None
    if requested:
        final_path = requested[0].get("filepath") or requested[0].get("_filename")
    if not final_path:
        # Fallback: yt-dlp didn't expose requested_downloads (older builds);
        # reconstruct from outtmpl using the resolved id+ext.
        vid = metadata.get("id")
        ext = metadata.get("ext")
        if vid and ext:
            final_path = str(out_dir / f"{vid}.{ext}")

    if not final_path or not Path(final_path).exists():
        fatal("Downloaded file not found on disk", 4)

    # One-line manifest the parent can persist for cache validation.
    manifest = {
        "url": url,
        "title": title,
        "id": metadata.get("id"),
        "ext": metadata.get("ext"),
        "duration": metadata.get("duration"),
        "filepath": final_path,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    emit(f"title: {title}")
    emit(f"path: {final_path}")
    info(f"saved {final_path}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
