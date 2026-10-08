#!/usr/bin/env python3
"""Download public iReal forum charts into a resumable personal library.

No external dependencies. Original links and source URLs are retained. The
SQLite queue records every discovered thread, reply page and chart attachment.
A JSON snapshot makes completed charts available while the crawl continues.
"""
import argparse
import concurrent.futures
import fcntl
import gzip
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

FORUM = 'https://forums.irealpro.com'
PREFIX = '1r34LbKcu7'
PRIORITY = ('jazz-1460-standards.12753', 'brazilian-220.', 'pop-400.',
            'blues-50.', 'latin-50.', 'country-50.', 'out-of-the-past-benny-golson.')
ESSENTIAL_URLS = [FORUM + '/threads/' + slug + '/' for slug in (
    'jazz-1460-standards.12753', 'brazilian-220.4414', 'latin-50.8482',
    'blues-50.4782', 'pop-400.8483', 'country-50.6102',
    'out-of-the-past-benny-golson.18461')]
STOP = False


class Links(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.urls = []
    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            href = dict(attrs).get('href', '')
            if href:
                self.urls.append(href)


def unscramble(value):
    """iReal's reversible obfusc50 permutation (ireal-reader, MIT)."""
    value = value.removeprefix(PREFIX)
    output = []
    while len(value) > 50:
        block, value = value[:50], value[50:]
        if len(value) >= 2:
            chars = list(block)
            for i in (*range(5), *range(10, 24)):
                chars[i], chars[49-i] = block[49-i], block[i]
            block = ''.join(chars)
        output.append(block)
    return ''.join(output) + value


# This is a visual chart, not an expanded playback sequence: retain repeat
# signs, endings, comments, section markers, and alternate chords.
TOKEN = re.compile(r'XyQ|Kcl|LZ\|?|<[^>]*>|\*[A-Za-z]|T\d{2}|N\d|'
                   r'[A-GW][#b]?(?:min|maj|add|sus|alt|[0-9+\-^hob#])*(?:\([^)]*\))?(?:/[A-G][#b]?)?|.')


def chart_bars(music):
    bars, chords, annotations = [], [], []
    opening = ''
    unknown = set()
    def flush(ending='|'):
        nonlocal chords, annotations, opening
        if chords or annotations:
            bars.append({'chords': chords, 'annotation': ' · '.join(annotations),
                         'left': opening, 'right': ending})
            chords, annotations, opening = [], [], ''
    for token in TOKEN.findall(music):
        if token in ('|', 'LZ', 'LZ|', '[', ']', '{', '}', 'Z'):
            flush(token)
            opening = token if token in ('[', '{') else ''
        elif token == 'Kcl':
            flush()
            chords = ['%']
            flush()
        elif token.startswith('<'):
            annotations.append(re.sub(r'^\*\d\d', '', token[1:-1]))
        elif token.startswith('*'):
            annotations.append(token[1:])
        elif token.startswith('T') and token[1:].isdigit():
            annotations.append('12/8' if token == 'T12' else token[1] + '/' + token[2])
        elif token.startswith('N') and token[1:].isdigit():
            annotations.append(token[1:] + '.')
        elif token in ('S', 'Q', 'f'):
            annotations.append({'S': 'Segno', 'Q': 'Coda', 'f': 'Fermata'}[token])
        elif token in ('x', 'r', 'n', 'p'):
            chords.append({'x': '%', 'r': '%%', 'n': 'N.C.', 'p': '/'}[token])
        elif token and token[0] in 'ABCDEFGW':
            chords.append(token.replace('^', 'maj').replace('-', 'm').replace('h', 'ø').replace('o', '°'))
        elif token in ('(', ')'):
            chords.append(token)
        elif token in ('XyQ', 'Y', 's', 'l', 'U', ',', ' ') or token.isspace():
            pass
        else:
            unknown.add(token)
    flush('Z')
    return bars, sorted(unknown)


def chart_cells(music):
    """Preserve the protocol's 16-cell rows; barlines never consume a cell.

    Closing bars belong to the preceding occupied/blank cell. Compressed
    substitutions encode actual spaces, not measure delimiters.
    """
    music = music.replace('Kcl', '| x').replace('LZ', ' |').replace('XyQ', '   ').rstrip()
    cells = []
    current = {}
    def consume(chord=''):
        nonlocal current
        current['chord'] = chord
        cells.append(current)
        current = {}
    tokens = re.findall(r'<[^>]*>|\*[A-Za-z]|T\d{2}|N\d|'
                        r'[A-GW][#b]?(?:min|maj|add|sus|alt|[0-9+\-^hob#])*(?:\((?![A-G])[^)]*\))?(?:/[A-G][#b]?)?|\([^)]*\)|.', music)
    for token in tokens:
        if token in ('|', '[', '{'):
            if token == '|' and cells:
                cells[-1].setdefault('right', '|')
            current['left'] = token
        elif token in (']', '}', 'Z'):
            if cells:
                cells[-1]['right'] = token
        elif token == ' ':
            consume()
        elif token.startswith('('):
            target = cells[-1] if cells and cells[-1].get('chord') else current
            target['alternate'] = token
        elif token.startswith('<'):
            current.setdefault('comments', []).append(token[1:-1])
        elif token.startswith(('*', 'T', 'N')) or token in ('S', 'Q', 'f', 'U'):
            current.setdefault('annotations', []).append(token)
        elif token == 'Y':
            current['spacer'] = current.get('spacer', 0) + 1
        elif token in ('s', 'l', ','):
            continue
        elif token in ('x', 'r', 'n', 'p'):
            consume({'x': '%', 'r': '%%', 'n': 'N.C.', 'p': '/'}[token])
        elif token[0] in 'ABCDEFGW':
            consume(token.replace('W', '').replace('^', 'maj').replace('-', 'm').replace('h', 'ø').replace('o', '°'))
    if current.get('annotations') or current.get('comments'):
        cells.append(current)
    return cells


def rebuild_layout(directory):
    count = 0
    for path in (directory / 'charts').glob('*.json'):
        song = json.loads(path.read_text())
        song['cells'] = chart_cells(song['music'])
        song['layoutVersion'] = 2
        atomic_json(path, song)
        count += 1
    print(f'Rebuilt {count} chart layouts without network access.', flush=True)


def songs_from_link(link, source):
    if not link.startswith(('irealb://', 'irealbook://')):
        return []
    scheme, encoded = link.split('://', 1)
    decoded = urllib.parse.unquote(encoded)
    songs = []
    bodies = []
    if scheme == 'irealb':
        pending = []
        for part in decoded.split('==='):
            pending.append(part)
            candidate = '==='.join(pending)
            # Empty composer + empty reserved field also produces ===.
            if PREFIX in candidate:
                bodies.append(candidate)
                pending = []
    else:
        for group in decoded.split('==='):
            fields = group.split('=')
            bodies.extend('='.join(fields[i:i+6]) for i in range(0, len(fields)-5, 6))
    for body in bodies:
        fields = body.split('=')
        if scheme == 'irealb':
            index = next((i for i, f in enumerate(fields) if f.startswith(PREFIX)), None)
            if index is None or index < 4:
                continue
            # Current exports preserve the empty author/style slots.
            if index == 6:
                title, composer, style, key = fields[0], fields[1], fields[3], fields[4]
            else:
                header = [f for f in fields[:index] if f]
                if len(header) < 4:
                    continue
                title, composer, style, key = header[:4]
            music = unscramble(fields[index])
        else:
            if len(fields) < 6:
                continue
            title, composer, style, key = fields[:4]
            music = fields[5]
        if not title.strip() or not music.strip():
            continue
        bars, unknown = chart_bars(music)
        if not bars:
            continue
        canonical = json.dumps([title.strip(), composer.strip(), key, music], ensure_ascii=False)
        songs.append({'id': hashlib.sha256(canonical.encode()).hexdigest(),
                      'title': title.strip(), 'composer': composer.strip(),
                      'style': style, 'key': key, 'music': music, 'bars': bars,
                      'cells': chart_cells(music), 'layoutVersion': 2,
                      'unsupported': unknown, 'source': source,
                      'irealURL': scheme + '://' + urllib.parse.quote(body, safe='')})
    return songs


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'OpenScribe-iReal-Library/1.0',
                                              'Accept-Encoding': 'gzip'})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = response.read(24 * 1024 * 1024 + 1)
        if len(data) > 24 * 1024 * 1024:
            raise ValueError('Response exceeds 24 MB')
        if data[:2] == b'\x1f\x8b':
            data = gzip.decompress(data)
        return data, None
    except Exception as error:
        return None, str(error)


def atomic_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')))
    temp.replace(path)


def enqueue(db, url, priority=10, kind='page'):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.netloc != 'forums.irealpro.com':
        return
    if kind == 'page' and not re.fullmatch(r'/(?:threads/[^/]+/(?:page-\d+)?|attachments/[^/]+/?)', parsed.path):
        return
    url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, '', ''))
    db.execute('INSERT OR IGNORE INTO queue(url,priority,kind) VALUES(?,?,?)', (url, priority, kind))


def snapshot(db, directory, phase, error=''):
    counts = dict(db.execute('SELECT state,count(*) FROM queue GROUP BY state'))
    songs = db.execute('SELECT count(*) FROM songs').fetchone()[0]
    status = {'phase': phase, 'songs': songs, 'done': counts.get('done', 0),
              'pending': counts.get('pending', 0), 'failed': counts.get('failed', 0),
              'updated': time.time(), 'pid': os.getpid(), 'error': error}
    atomic_json(directory / 'status.json', status)
    # Snapshot only metadata; individual chart JSONs avoid reloading all charts
    # or rebuilding a multi-megabyte PDF just to search the library.
    catalog = [json.loads(row[0]) for row in db.execute('SELECT summary FROM songs ORDER BY title COLLATE NOCASE')]
    atomic_json(directory / 'catalog.json', catalog)
    print(json.dumps(status), flush=True)


def export_song(directory, song):
    path = directory / 'exports' / (song['id'] + '.html')
    if not path.exists():
        path.parent.mkdir(exist_ok=True)
        document = '<!doctype html><meta charset="utf-8"><title>' + html.escape(song['title']) + '</title><a href="' + html.escape(song['irealURL'], quote=True) + '">' + html.escape(song['title']) + '</a>'
        path.write_text(document)


def process_page(db, directory, url, data, follow_forum=True):
    text = data.decode('utf-8', errors='replace')
    parser = Links()
    parser.feed(text)
    links = parser.urls
    if text.strip().startswith(('irealb://', 'irealbook://')):
        links.append(text.strip())
    for link in links:
        if link.startswith(('irealb://', 'irealbook://')):
            try:
                songs = songs_from_link(link, url)
            except (ValueError, IndexError):
                continue
            for song in songs:
                if not db.execute('SELECT 1 FROM songs WHERE id=?', (song['id'],)).fetchone():
                    atomic_json(directory / 'charts' / (song['id'] + '.json'), song)
                    export_song(directory, song)
                    summary = {k: song[k] for k in ('id', 'title', 'composer', 'style', 'key', 'source')}
                    db.execute('INSERT INTO songs VALUES(?,?,?)', (song['id'], song['title'], json.dumps(summary, ensure_ascii=False)))
        else:
            absolute = urllib.parse.urljoin(url, html.unescape(link))
            path = urllib.parse.urlsplit(absolute).path
            if '/attachments/' in path:
                # Only chart exports, not arbitrary audio/photo attachments.
                if re.search(r'[.-](?:html?|ireal)[.-]', path, re.I):
                    enqueue(db, absolute, 1)
            elif follow_forum and '/threads/' in path:
                enqueue(db, absolute, 2 if '/page-' in path else 10)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output-dir', type=Path, required=True)
    ap.add_argument('--rebuild-layout', action='store_true')
    ap.add_argument('--scope', choices=('essentials', 'forum'), default='essentials')
    ap.add_argument('--refresh', action='store_true', help='Update previously downloaded playlist pages')
    ap.add_argument('--seed-dir', type=Path)
    ap.add_argument('--retry-failed', action='store_true')
    ap.add_argument('--revisit-done', action='store_true', help='Re-read completed pages after an importer update')
    ap.add_argument('--max-pages', type=int, default=0)
    args = ap.parse_args()
    directory = args.output_dir.expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'charts').mkdir(exist_ok=True)
    (directory / 'exports').mkdir(exist_ok=True)
    lock = (directory / 'sync.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('A library download is already running.', flush=True)
        return 0
    if args.rebuild_layout:
        rebuild_layout(directory)
        return 0
    stopfile = directory / 'pause'
    stopfile.unlink(missing_ok=True)
    db = sqlite3.connect(directory / 'library.sqlite')
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript('''CREATE TABLE IF NOT EXISTS queue(
        url TEXT PRIMARY KEY, priority INTEGER, kind TEXT, state TEXT DEFAULT 'pending',
        attempts INTEGER DEFAULT 0, error TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS songs(id TEXT PRIMARY KEY,title TEXT,summary TEXT);''')
    if args.revisit_done or args.refresh:
        db.execute("UPDATE queue SET state='pending',attempts=0 WHERE state='done' AND kind='page'")
    if args.retry_failed:
        db.execute("UPDATE queue SET state='pending',attempts=0 WHERE state='failed'")
    if args.scope == 'forum':
        enqueue(db, FORUM + '/sitemap.xml', 0, 'sitemap')
    else:
        for url in ESSENTIAL_URLS:
            enqueue(db, url, 0)
    if args.seed_dir and args.scope == 'forum':
        for seed in sorted(args.seed_dir.glob('ireal-sitemap*.xml')):
            data = seed.read_bytes()
            if data[:2] == b'\x1f\x8b': data = gzip.decompress(data)
            for node in ET.fromstring(data).iter():
                if node.tag.endswith('loc') and '/threads/' in (node.text or ''):
                    url = node.text
                    priority = 0 if any(p in url for p in PRIORITY) else (3 if any(p in url for p in ('playlist','collection','real-book','standards')) else 10)
                    enqueue(db, url, priority)
        seed = args.seed_dir / 'ireal-out-of-the-past-forum.html'
        if seed.exists():
            process_page(db, directory, FORUM + '/threads/out-of-the-past-benny-golson.18461/', seed.read_bytes())
    db.commit()
    # Also materialize portable iReal HTML exports for charts fetched by an
    # older importer, without downloading them again.
    for chart_path in (directory / 'charts').glob('*.json'):
        export_song(directory, json.loads(chart_path.read_text()))
    completed = 0
    snapshot(db, directory, 'downloading')
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            while not STOP and not stopfile.exists():
                rows = db.execute("SELECT url,kind,attempts FROM queue WHERE state='pending' ORDER BY priority,url LIMIT 2").fetchall()
                if not rows:
                    break
                started = time.monotonic()
                for (url, kind, attempts), (data, error) in zip(rows, pool.map(fetch, [r[0] for r in rows])):
                    if error:
                        db.execute("UPDATE queue SET state=?,attempts=attempts+1,error=?,priority=priority+100 WHERE url=?",
                                   ('failed' if attempts >= 2 or '403' in error or '404' in error else 'pending', error, url))
                        if '429' in error or '503' in error:
                            snapshot(db, directory, 'waiting', error)
                            # Back off instead of hammering a rate-limited host.
                            for _ in range(60):
                                if STOP or stopfile.exists(): break
                                time.sleep(1)
                    else:
                        try:
                            if kind == 'sitemap':
                                for node in ET.fromstring(data).iter():
                                    if not node.tag.endswith('loc') or not node.text: continue
                                    if '/sitemap' in node.text:
                                        enqueue(db, node.text, 0, 'sitemap')
                                    elif '/threads/' in node.text:
                                        priority = 0 if any(p in node.text for p in PRIORITY) else (3 if any(p in node.text for p in ('playlist','collection','real-book','standards')) else 10)
                                        enqueue(db, node.text, priority)
                            else:
                                process_page(db, directory, url, data, follow_forum=args.scope == 'forum')
                            db.execute("UPDATE queue SET state='done',error='' WHERE url=?", (url,))
                        except Exception as error:
                            db.execute("UPDATE queue SET state='failed',error=? WHERE url=?", (str(error), url))
                    completed += 1
                db.commit()
                if completed % 10 == 0: snapshot(db, directory, 'downloading')
                if args.max_pages and completed >= args.max_pages: break
                time.sleep(max(0, 1.0 - (time.monotonic() - started)))
    finally:
        remaining = db.execute("SELECT count(*) FROM queue WHERE state='pending'").fetchone()[0]
        failures = db.execute("SELECT count(*) FROM queue WHERE state='failed'").fetchone()[0]
        phase = 'paused' if remaining else ('incomplete' if failures else 'complete')
        snapshot(db, directory, phase)
        db.close()
    return 0


def stop(signum, frame):
    global STOP
    STOP = True


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    raise SystemExit(main())
