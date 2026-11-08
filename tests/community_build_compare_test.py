"""C2 的黑盒合成回归。期望值手写；不导入被测代码，不读游戏/补丁。"""
import csv
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[1] / 'tools/community_build_compare.py'
TITLE = '0100aabbccdd0000'
BID = '00112233445566778899aabbccddeeff'
COLUMNS = ['index_row', 'index_title_id', 'index_build_id', 'index_chars',
           'unpack_title_id', 'unpack_main_build_id', 'unpack_chars',
           'status', 'reason', 'index_path', 'unpack_path']


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.index = self.root / 'INDEX.tsv'
        self.unpack = self.root / 'unpack.tsv'
        self.write_index([(TITLE, BID)])
        self.write_unpack()

    def write_index(self, pairs):
        self.index.write_text('title_id\tbuild_id\n' + ''.join(
            f'{tid}\t{bid}\n' for tid, bid in pairs), encoding='utf-8')

    def write_unpack(self, builds='main:' + BID, title=TITLE, path=None):
        (path or self.unpack).write_text(
            f'title_id\t{title}\nname\t合成名字\ndisplay_version\t1.0\nbuilds\t{builds}\n',
            encoding='utf-8')

    def run_cli(self, *unpacks):
        return subprocess.run([sys.executable, str(TOOL), str(self.index),
                               *(str(p) for p in unpacks or [self.unpack])],
                              capture_output=True, encoding='utf-8', cwd=self.root,
                              timeout=10, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})

    def rows(self, *unpacks):
        p = self.run_cli(*unpacks)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, '')
        table = list(csv.reader(io.StringIO(p.stdout), delimiter='\t'))
        self.assertEqual(table[0], COLUMNS)
        self.assertTrue(all(len(r) == len(COLUMNS) for r in table))
        return [dict(zip(COLUMNS, r)) for r in table[1:]]

    def assert_rejected(self, text):
        p = self.run_cli()
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertEqual(p.stdout, '')
        self.assertIn(text, p.stderr)

    def test_complete_exact_table_case_and_origins(self):
        self.write_index([(TITLE.upper(), BID.upper())])
        self.assertEqual(self.rows(), [dict(zip(COLUMNS, [
            '1', TITLE.upper(), BID.upper(), '32', TITLE, BID, '32',
            'same_recorded_128', 'equal_32_hex_records', str(self.index), str(self.unpack)]))])

    def test_lengths_prefix_and_different_tail(self):
        values = [BID[:16], BID, BID + '00000000', BID + 'f' * 32,
                  BID[:-2] + '00', 'ff' + BID[2:]]
        self.write_index([(TITLE, b) for b in values])
        self.assertEqual([r['status'] for r in self.rows()],
                         ['prefix_only', 'same_recorded_128', 'prefix_only',
                          'prefix_only', 'different', 'different'])
        self.write_unpack('main:' + BID + '00000000')
        self.write_index([(TITLE, BID + '00000001')])
        self.assertEqual(self.rows()[0]['status'], 'different')
        self.write_index([(TITLE, BID + '00000000')])
        self.assertEqual(self.rows()[0]['status'], 'prefix_only')

    def test_no_trailing_zero_removal_or_padding(self):
        self.write_unpack('main:' + 'ab' * 15 + '00')
        self.write_index([(TITLE, 'ab' * 15), (TITLE, 'ab' * 15 + '01'), (TITLE, 'ab' * 15 + '00')])
        self.assertEqual([r['status'] for r in self.rows()], ['prefix_only', 'different', 'same_recorded_128'])
        self.assertEqual(self.rows()[0]['index_chars'], '30')

    def test_duplicate_index_and_unpack_order(self):
        second = self.root / 'second.tsv'
        self.write_unpack('main:' + 'ff' * 16, path=second)
        self.write_index([(TITLE, BID), (TITLE, BID)])
        rows = self.rows(second, self.unpack)
        self.assertEqual([(r['index_row'], r['unpack_path'], r['status']) for r in rows],
                         [('1', str(second), 'different'), ('1', str(self.unpack), 'same_recorded_128'),
                          ('2', str(second), 'different'), ('2', str(self.unpack), 'same_recorded_128')])
        self.assertEqual(self.run_cli(second, self.unpack).stdout, self.run_cli(second, self.unpack).stdout)

    def test_full_title_no_family_merge(self):
        self.write_index([(TITLE[:-3] + '800', BID), (TITLE[:-3] + '001', BID)])
        rows = self.rows()
        self.assertEqual([r['status'] for r in rows], ['missing', 'missing', 'missing'])
        self.assertEqual([r['reason'] for r in rows],
                         ['unpack_title_not_found', 'unpack_title_not_found', 'index_title_not_found'])
        self.assertEqual(rows[-1]['unpack_title_id'], TITLE)
        self.assertEqual(rows[-1]['index_row'], '')

    def test_exact_main_token_and_absence(self):
        for builds in ['sdk:' + BID, 'domain:' + BID, 'Main:' + BID, '', 'main:']:
            with self.subTest(builds=builds):
                self.write_unpack(builds)
                r = self.rows()[0]
                self.assertEqual((r['status'], r['reason']), ('missing', 'unpack_main_missing'))
        self.unpack.write_text(f'title_id\t{TITLE}\nname\t控制数据\n', encoding='utf-8')
        self.assertEqual(self.rows()[0]['reason'], 'unpack_main_missing')

    def test_sdk_does_not_replace_main(self):
        self.write_unpack(f'sdk:{BID} main:{"ff" * 16} subsdk0:{BID}')
        self.assertEqual(self.rows()[0]['status'], 'different')

    def test_invalid_builds_and_empty_index_value(self):
        bad = [BID + '0', 'zz' * 16, 'ＡＡ' * 16, ' ' + BID, '0x' + BID,
               'ab' * 7, 'ab' * 33]
        self.write_index([(TITLE, b) for b in bad] + [(TITLE, '')])
        rows = self.rows()
        self.assertEqual([r['status'] for r in rows], ['invalid'] * 7 + ['missing'])
        self.assertEqual([r['index_build_id'] for r in rows], bad + [''])
        self.assertEqual([r['index_chars'] for r in rows], [str(len(b)) for b in bad + ['']])
        self.write_index([(TITLE, BID)])
        self.write_unpack('main:not_hex')
        self.assertEqual(self.rows()[0]['reason'], 'unpack_build_invalid')

    def test_title_missing_or_invalid_is_visible(self):
        self.write_index([('', BID), ('1', BID), ('0' * 15 + 'Ｇ', BID)])
        rows = self.rows()
        self.assertEqual([r['status'] for r in rows], ['missing', 'invalid', 'invalid', 'missing'])
        self.write_index([(TITLE, BID)])
        self.write_unpack(title='wrong')
        self.assertEqual([r['status'] for r in self.rows()], ['missing', 'invalid'])

    def test_index_comments_quoted_fields_and_crlf(self):
        self.index.write_bytes(('# 合成注释\r\ngame\ttitle_id\tbuild_id\tpath\r\n'
                                f'"名字\t带引号"\t{TITLE}\t{BID}\t"不读取\n#邻居"\r\n').encode())
        self.unpack.write_bytes(f'title_id\t{TITLE}\r\nname\t合成\r\nbuilds\tmain:{BID}\r\n'.encode())
        self.assertEqual(self.rows()[0]['status'], 'same_recorded_128')
        quoted = self.root / '带\t引号"路径.tsv'
        quoted.write_bytes(self.unpack.read_bytes())
        self.assertEqual(self.rows(quoted)[0]['unpack_path'], str(quoted))

    def test_header_only_and_empty_files(self):
        self.write_index([])
        self.assertEqual(self.rows()[0]['reason'], 'index_title_not_found')
        self.index.write_text('', encoding='utf-8')
        self.assert_rejected('INDEX header')
        self.write_index([(TITLE, BID)])
        self.unpack.write_text('', encoding='utf-8')
        self.assert_rejected('empty unpack')

    def test_index_structure_errors_are_atomic(self):
        for text in ['title_id\n', 'title_id\tbuild_id\tbuild_id\n',
                     f'title_id\tbuild_id\n{TITLE}\t{BID}\n{TITLE}\n',
                     f'title_id\tbuild_id\n{TITLE}\t{BID}\textra\n',
                     'title_id\tbuild_id\n"unterminated\n']:
            with self.subTest(text=text):
                self.index.write_text(text, encoding='utf-8')
                self.assert_rejected('INDEX')

    def test_unpack_ambiguous_or_malformed_rejected(self):
        for extra in [f'title_id\t{TITLE}\n', 'builds\tmain:' + BID + '\n',
                      'unknown line\n', 'name\tbad\ttab\n']:
            with self.subTest(extra=extra):
                self.write_unpack()
                with self.unpack.open('a', encoding='utf-8') as f:
                    f.write(extra)
                self.assert_rejected('unpack')
        for builds in [f'main:{BID} main:{BID}', f'main:{BID} main:{"ff" * 16}', 'main', ':abcd']:
            with self.subTest(builds=builds):
                self.write_unpack(builds)
                self.assert_rejected('unpack')

    def test_invalid_utf8_nul_missing_file_and_late_error(self):
        second = self.root / 'second.tsv'
        for path in [self.index, self.unpack]:
            for b in [b'\xff', b'\x00']:
                self.write_index([(TITLE, BID)])
                self.write_unpack()
                with path.open('ab') as f:
                    f.write(b)
                self.assert_rejected('error')
        self.write_index([(TITLE, BID)])
        self.write_unpack()
        second.write_bytes(b'\xff')
        p = self.run_cli(self.unpack, second)
        self.assertEqual((p.returncode, p.stdout), (2, ''))
        self.unpack.unlink()
        self.assert_rejected('error')

    def test_readonly_no_neighbor_or_environment_scan(self):
        neighbor = self.root / 'DO_NOT_READ.pchtxt'
        neighbor.write_bytes(b'not metadata\xff')
        self.index.write_text(f'title_id\tbuild_id\tpath\n{TITLE}\t{BID}\t{neighbor}\n', encoding='utf-8')
        paths = [self.index, self.unpack, neighbor]
        before = [(p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in paths]
        for p in paths:
            p.chmod(0o444)
        names = sorted(self.root.iterdir())
        p = self.run_cli()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(sorted(self.root.iterdir()), names)
        self.assertEqual([(p.read_bytes(), p.stat().st_mtime_ns) for p in paths],
                         [(b, m) for b, m, _ in before])
        self.assertTrue(all(p.stat().st_mode & 0o222 == 0 for p in paths))


if __name__ == '__main__':
    unittest.main(verbosity=2)
