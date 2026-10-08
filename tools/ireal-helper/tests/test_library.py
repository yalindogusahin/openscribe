import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import urllib.parse

spec = importlib.util.spec_from_file_location('library', Path(__file__).parents[1] / 'library.py')
library = importlib.util.module_from_spec(spec)
spec.loader.exec_module(library)


def encoded(title='Practice', music='T44{C^7 |A-7 |D-7 |G7 }', composer='Example'):
    # obfusc50 is its own inverse, including its unchanged short tail.
    scrambled = library.unscramble(music)
    return 'irealb://' + urllib.parse.quote(f'{title}={composer}==Swing=C=={library.PREFIX}{scrambled}==120=3')


class LibraryTests(unittest.TestCase):
    def test_long_payload_round_trip(self):
        music = '{*AT44C^7 |A-7 |D-7 |G7 }' * 12
        song = library.songs_from_link(encoded(music=music), 'test')[0]
        self.assertEqual(song['music'], music)
        self.assertEqual(song['composer'], 'Example')
        self.assertEqual(song['key'], 'C')

    def test_empty_composer_keeps_metadata(self):
        song = library.songs_from_link(encoded(composer=''), 'test')[0]
        self.assertEqual((song['composer'], song['style'], song['key']), ('', 'Swing', 'C'))

    def test_playlist_and_unicode(self):
        one = urllib.parse.unquote(encoded('Água & Luz').split('://')[1])
        two = urllib.parse.unquote(encoded('Second').split('://')[1])
        playlist = 'irealb://' + urllib.parse.quote(one + '===' + two + '===My Playlist')
        self.assertEqual([s['title'] for s in library.songs_from_link(playlist, 'test')], ['Água & Luz', 'Second'])

    def test_legacy_public_protocol(self):
        url = 'irealbook://' + urllib.parse.quote('Practice=Composer=Swing=C=n={*AT44C |D-7 G7 |C Z')
        song = library.songs_from_link(url, 'test')[0]
        self.assertEqual(song['title'], 'Practice')
        self.assertIn('Dm7', song['bars'][1]['chords'])

    def test_marks_and_alternate_chords(self):
        bars, unknown = library.chart_bars('{*AT44C^7 |N1D-7 (G7b9) }N2C/E Z')
        self.assertEqual(unknown, [])
        self.assertEqual(bars[0]['left'], '{')
        self.assertIn('4/4', bars[0]['annotation'])
        self.assertEqual(bars[1]['right'], '}')
        self.assertIn('2.', bars[2]['annotation'])
        self.assertEqual(bars[2]['chords'], ['C/E'])

    def test_deduplication_and_safe_queue(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'charts').mkdir()
            db = sqlite3.connect(':memory:')
            db.executescript('CREATE TABLE queue(url TEXT PRIMARY KEY,priority INTEGER,kind TEXT); CREATE TABLE songs(id TEXT PRIMARY KEY,title TEXT,summary TEXT);')
            page = ('<a href="' + encoded() + '">song</a>') * 2
            page += '<a href="https://example.com/threads/no.1/">outside</a>'
            page += '<a href="/threads/practice.123/page-2">next</a>'
            library.process_page(db, directory, library.FORUM + '/threads/practice.123/', page.encode())
            self.assertEqual(db.execute('select count(*) from songs').fetchone()[0], 1)
            self.assertEqual(db.execute('select url from queue').fetchall(), [(library.FORUM + '/threads/practice.123/page-2',)])
            self.assertEqual(len(list((directory / 'charts').glob('*.json'))), 1)

    def test_essentials_does_not_crawl_forum(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'charts').mkdir()
            db = sqlite3.connect(':memory:')
            db.executescript('CREATE TABLE queue(url TEXT PRIMARY KEY,priority INTEGER,kind TEXT); CREATE TABLE songs(id TEXT PRIMARY KEY,title TEXT,summary TEXT);')
            page = '<a href="/threads/unrelated.123/">other thread</a><a href="/threads/pop-400.8483/page-2">next</a>'
            library.process_page(db, directory, library.ESSENTIAL_URLS[0], page.encode(), follow_forum=False)
            self.assertEqual(db.execute('select count(*) from queue').fetchone()[0], 0)

    def test_cell_spacing_and_empty_measures(self):
        cells = library.chart_cells('{C   |    |D   }    |N2G   Z')
        self.assertEqual([i for i, c in enumerate(cells) if c.get('chord')], [0, 8, 16])
        self.assertEqual(cells[4]['left'], '|')
        self.assertEqual(cells[11]['right'], '}')
        self.assertEqual(cells[16]['annotations'], ['N2'])

    def test_compressed_spacing(self):
        self.assertEqual(library.chart_cells('C XyQLZD KclXyQZ'),
                         library.chart_cells('C     |D | x   Z'))

    def test_out_of_past_preserves_second_ending_indent(self):
        music = (Path(__file__).parent / 'out_of_past.txt').read_text()
        cells = library.chart_cells(music)
        self.assertEqual(len(cells), 96)
        self.assertEqual(cells[63]['right'], '}')
        self.assertTrue(all(not c.get('chord') for c in cells[64:68]))
        self.assertEqual(cells[68]['annotations'], ['N2'])
        self.assertEqual(cells[68]['chord'], 'C7')
        self.assertEqual(cells[95]['right'], 'Z')

    def test_invalid_link(self):
        self.assertEqual(library.songs_from_link('https://example.com/', 'test'), [])
        self.assertEqual(library.songs_from_link('irealb://bad', 'test'), [])


if __name__ == '__main__':
    unittest.main()
