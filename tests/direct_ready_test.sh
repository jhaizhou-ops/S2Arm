#!/bin/bash
# H02 / #147：合成输入 + 手算期望，真实 Python/C CLI 对拍；不联网、不读游戏。
# 门禁覆盖：tools/direct_ready.py tests/fixtures/direct_ready/*
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
python3 -B - "$H" <<'PY'
import hashlib
import os
from pathlib import Path
import resource
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop())
FIXTURE = ROOT / 'tests/fixtures/direct_ready'
A, B, C = '0000000000000001', '0000000000000002', '0000000000000003'
HEADER = '# input_rows = occurrences in seen input; not gameplay call frequency\nmissing_key\tinput_rows\n'


class DirectReadyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix='s2arm-direct-ready-')
        cls.addClassCleanup(cls.work.cleanup)
        cls.reference = Path(cls.work.name) / 'direct_ready_ref'
        cc = shlex.split(os.environ.get('CC', 'cc'))
        flags = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic']
        subprocess.run(
            [*cc, *flags, '-DDIRECT_READY_MAIN', str(FIXTURE / 'reference.c'), '-o', str(cls.reference)],
            check=True, capture_output=True, text=True, timeout=30,
        )
        # 同一份参考函数不依赖 CLI main，也能作为独立对象供运行时接缝对拍。
        subprocess.run(
            [*cc, *flags, '-c', str(FIXTURE / 'reference.c'), '-o', str(Path(cls.work.name) / 'reference.o')],
            check=True, capture_output=True, text=True, timeout=30,
        )
        cls.commands = {
            'Python': [sys.executable, '-B', str(ROOT / 'tools/direct_ready.py')],
            'C': [str(cls.reference)],
        }

    def run_cli(self, name, seen, keys, timeout=60):   # 只防挂死（同下方 10 万键用例的定法）：5 秒在 mini 负载 200+ 下 Python 起进程就超（11-02 a55b5c839 无缓存实跑红）
        return subprocess.run(
            [*self.commands[name], '--seen', str(seen), '--keys', str(keys)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
        )

    def check_data(self, seen_data, keys_data, status, expected=None):
        with tempfile.TemporaryDirectory(prefix='direct ready inputs ') as temp:
            seen, keys = Path(temp) / 'seen.tsv', Path(temp) / 'keys.tsv'
            seen.write_bytes(seen_data)
            keys.write_bytes(keys_data)
            before = [(hashlib.sha256(p.read_bytes()).digest(), p.stat().st_mtime_ns) for p in (seen, keys)]
            for name in self.commands:
                with self.subTest(implementation=name):
                    result = self.run_cli(name, seen, keys)
                    self.assertEqual(result.returncode, status, result.stderr)
                    if status == 2:
                        self.assertEqual(result.stdout, '')
                        self.assertTrue(result.stderr)
                    else:
                        self.assertEqual(result.stderr, '')
                        self.assertEqual(result.stdout, expected)
            after = [(hashlib.sha256(p.read_bytes()).digest(), p.stat().st_mtime_ns) for p in (seen, keys)]
            self.assertEqual(before, after, '输入内容和修改时间必须保持不变')

    def test_hand_calculated_fixture_and_frequency_order(self):
        self.check_data(
            (FIXTURE / 'seen.tsv').read_bytes(), (FIXTURE / 'keys.tsv').read_bytes(), 1,
            (FIXTURE / 'expected.txt').read_text(),
        )

    def test_empty_or_blank_only_seen_is_not_ready(self):
        expected = 'ready=0 seen=0 covered=0 missing=0\ncoverage=0/0 (no samples; not ready)\n' + HEADER
        for seen in (b'', b'\n \t\r\n'):
            for keys in (b'', (A + '\n').encode()):
                with self.subTest(seen=seen, keys=keys):
                    self.check_data(seen, keys, 1, expected)

    def test_full_coverage_counts_unique_keys(self):
        self.check_data(
            f'{A}\n{B}\n{A}\n'.encode(), f'{B}\n{A}\n{B}\n{C}\n'.encode(), 0,
            'ready=1 seen=2 covered=2 missing=0\ncoverage=2/2 (100.000000%)\n' + HEADER,
        )

    def test_one_missing(self):
        self.check_data(
            f'{A}\n{B}\n{C}\n'.encode(), f'{C}\n{A}\n'.encode(), 1,
            'ready=0 seen=3 covered=2 missing=1\ncoverage=2/3 (66.666667%)\n' + HEADER + f'{B}\t1\n',
        )

    def test_empty_keys_is_not_full_coverage(self):
        self.check_data(
            f'{A}\n'.encode(), b'', 1,
            'ready=0 seen=1 covered=0 missing=1\ncoverage=0/1 (0.000000%)\n' + HEADER + f'{A}\t1\n',
        )

    def test_uppercase_seen_is_a_gap_not_a_normalized_key(self):
        lower, upper = 'abcdef0123456789', 'ABCDEF0123456789'
        self.check_data(
            f'{lower}\n{upper}\n{lower}\n{upper}\n'.encode(), f'{lower}\n'.encode(), 1,
            'ready=0 seen=2 covered=1 missing=1\ncoverage=1/2 (50.000000%)\n' + HEADER + f'{upper}\t2\n',
        )

    def test_uppercase_keys_are_input_errors_even_when_seen_is_empty(self):
        for seen in (b'', b'abcdef0123456789\n', b'ABCDEF0123456789\n'):
            with self.subTest(seen=seen):
                self.check_data(seen, b'abcdef0123456789\nABCDEF0123456789\n', 2)

    def test_trailing_ascii_whitespace_crlf_and_unterminated_last_line(self):
        self.check_data(
            f'\n \t\r\n{A} \t\r\n{B}\t '.encode(), f'{B}\t\r\n{A} '.encode(), 0,
            'ready=1 seen=2 covered=2 missing=0\ncoverage=2/2 (100.000000%)\n' + HEADER,
        )

    def test_equal_counts_have_stable_ascii_order(self):
        self.check_data(
            f'{C}\n{B}\n{A}\n{B}\n{C}\n{A}\n'.encode(), b'', 1,
            'ready=0 seen=3 covered=0 missing=3\ncoverage=0/3 (0.000000%)\n' + HEADER
            + f'{A}\t2\n{B}\t2\n{C}\t2\n',
        )

    def test_unmapped_machine_code_is_a_gap(self):
        marker = 'code:0123456789abcdef'
        self.check_data(
            f'{marker}\n{A}\n'.encode(), f'0123456789abcdef\n{A}\n'.encode(), 1,
            'ready=0 seen=2 covered=1 missing=1\ncoverage=1/2 (50.000000%)\n' + HEADER + f'{marker}\t1\n',
        )

    def test_unmapped_marker_cannot_be_declared_available(self):
        self.check_data(b'code:0123456789abcdef\n', b'code:0123456789abcdef\n', 2)

    INVALID_ROWS = [
        (b'key\n', 'key'),
        (b'0123456789abcde\n', '0123456789abcde'),
        (b'0123456789abcdef0\n', '0123456789abcdef0'),
        (b'0123456789abcdeg\n', '0123456789abcdeg'),
        (b'0x0123456789abcdef\n', '0x0123456789abcdef'),
        (b' 0123456789abcdef\n', ' 0123456789abcdef'),
        (b'0123456789abcdef\t2\n', r'0123456789abcdef\x092'),
        (b'\xef\xbb\xbf0123456789abcdef\n', r'\xef\xbb\xbf0123456789abcdef'),
        (b'0123456789abc\x00ef\n', r'0123456789abc\x00ef'),
        (b'0123456789abcdef\xc2\xa0\n', r'0123456789abcdef\xc2\xa0'),
        (b'CODE:0123456789abcdef\n', 'CODE:0123456789abcdef'),
        (b'code:0123456789abcde\n', 'code:0123456789abcde'),
        (b'code:ABCDEF0123456789\n', 'code:ABCDEF0123456789'),
        (b'01234567\r89abcdef\n', r'01234567\x0d89abcdef'),
        (b'\xff\n', r'\xff'),
    ]

    def test_malformed_keys_fail_without_partial_summary(self):
        for data, _ in self.INVALID_ROWS:
            with self.subTest(data=data):
                self.check_data(A.encode() + b'\n', A.encode() + b'\n' + data, 2)

    def test_malformed_seen_is_retained_and_counted_as_a_gap(self):
        for data, display in self.INVALID_ROWS:
            with self.subTest(data=data):
                self.check_data(
                    A.encode() + b'\n' + data + data, A.encode() + b'\n', 1,
                    'ready=0 seen=2 covered=1 missing=1\ncoverage=1/2 (50.000000%)\n' + HEADER
                    + f'{display}\t2\n',
                )

    def test_long_bad_rows_and_raw_byte_sorting_are_not_truncated(self):
        long_row = b'z' * 512
        rows = [long_row, b'code:0123456789abcdef', b'\xff', b'bad\trow',
                b'\x00a', b'ABCDEF0123456789', long_row]
        self.check_data(
            b'\n'.join(rows) + b'\n', b'', 1,
            'ready=0 seen=6 covered=0 missing=6\ncoverage=0/6 (0.000000%)\n' + HEADER
            + 'z' * 512 + '\t2\n' + r'\x00a' + '\t1\nABCDEF0123456789\t1\n'
            + r'bad\x09row' + '\t1\ncode:0123456789abcdef\t1\n' + r'\xff' + '\t1\n',
        )

    def test_embedded_nul_and_literal_escape_are_distinct_keys(self):
        rows = [A.encode(), A.encode() + b'\x00first', A.encode() + b'\x00second',
                A.encode() + b'\\x00first']
        expected_rows = [
            A + r'\x00first' + '\t1\n',
            A + r'\x00second' + '\t1\n',
            A + r'\x5cx00first' + '\t1\n',
        ]
        self.check_data(
            b'\n'.join(rows), A.encode() + b'\n', 1,
            'ready=0 seen=4 covered=1 missing=3\ncoverage=1/4 (25.000000%)\n' + HEADER
            + ''.join(expected_rows),
        )

    def test_empty_seen_still_validates_keys(self):
        self.check_data(b'', b'not-a-key\n', 2)

    def test_missing_seen_is_unready_without_creating_a_file(self):
        expected = 'ready=0 seen=0 covered=0 missing=0\ncoverage=0/0 (no samples; not ready)\n' + HEADER
        with tempfile.TemporaryDirectory() as temp:
            keys = Path(temp) / 'keys.tsv'
            for data in (b'', A.encode() + b'\n'):
                keys.write_bytes(data)
                before = (keys.read_bytes(), keys.stat().st_mtime_ns)
                for name in self.commands:
                    for seen in (Path(temp) / 'absent.tsv', Path(temp) / 'absent-dir/seen.tsv'):
                        with self.subTest(implementation=name, seen=seen, keys=data):
                            result = self.run_cli(name, seen, keys)
                            self.assertEqual(result.returncode, 1, result.stderr)
                            self.assertEqual(result.stdout, expected)
                            self.assertEqual(result.stderr, '')
                            self.assertFalse(seen.exists())
                            self.assertEqual((keys.read_bytes(), keys.stat().st_mtime_ns), before)

    def test_missing_seen_still_validates_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            seen, keys = Path(temp) / 'absent.tsv', Path(temp) / 'keys.tsv'
            for data in (b'not-a-key\n', b'ABCDEF0123456789\n'):
                keys.write_bytes(data)
                for name in self.commands:
                    with self.subTest(implementation=name, keys=data):
                        result = self.run_cli(name, seen, keys)
                        self.assertEqual(result.returncode, 2)
                        self.assertEqual(result.stdout, '')
                        self.assertTrue(result.stderr)

    def test_missing_keys_and_other_file_errors_remain_input_errors(self):
        with tempfile.TemporaryDirectory() as temp:
            empty, missing = Path(temp) / 'empty.tsv', Path(temp) / 'absent.tsv'
            empty.write_bytes(b'')
            for name in self.commands:
                for seen, keys in ((empty, missing), (missing, missing),
                                   (empty, Path(temp)), (Path(temp), empty)):
                    with self.subTest(implementation=name, seen=seen, keys=keys):
                        result = self.run_cli(name, seen, keys)
                        self.assertEqual(result.returncode, 2)
                        self.assertEqual(result.stdout, '')
                        self.assertTrue(result.stderr)

    def test_missing_cli_arguments_are_input_errors(self):
        for name, command in self.commands.items():
            with self.subTest(implementation=name):
                result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertTrue(result.stderr)

    def test_100000_keys_full_coverage_and_full_gap_under_one_second(self):
        with tempfile.TemporaryDirectory() as temp:
            seen, keys = Path(temp) / 'seen.tsv', Path(temp) / 'keys.tsv'
            data = ''.join(f'{i:016x}\n' for i in range(100_000))
            seen.write_text(data)
            for covered in (True, False):
                keys.write_text(data if covered else '')
                for name in self.commands:
                    with self.subTest(implementation=name, covered=covered):
                        # 计子进程 CPU 时间（用户 + 系统），不计墙钟（10-29 列车线：mini 高负载误红类——墙钟含排队等核的时间，
                        #   负载 100+ 时线性实现也会过 1 秒）。CPU 时间只算它自己真干活的部分，平方级实现照样远超 1 秒；墙钟上限放到 60 秒只防挂死
                        before = resource.getrusage(resource.RUSAGE_CHILDREN)
                        start = time.perf_counter()
                        result = self.run_cli(name, seen, keys, timeout=60)
                        wall = time.perf_counter() - start
                        after = resource.getrusage(resource.RUSAGE_CHILDREN)
                        elapsed = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
                        expected = ('ready=1 seen=100000 covered=100000 missing=0' if covered
                                    else 'ready=0 seen=100000 covered=0 missing=100000')
                        self.assertEqual(result.returncode, 0 if covered else 1, result.stderr)
                        self.assertEqual(result.stdout.splitlines()[0], expected)
                        self.assertEqual(len(result.stdout.splitlines()), 4 if covered else 100_004)
                        if not covered:
                            self.assertEqual(result.stdout.splitlines()[4], '0000000000000000\t1')
                            self.assertEqual(result.stdout.splitlines()[-1], '000000000001869f\t1')
                        print(f'十万键 {name} {"全覆盖" if covered else "全缺口"}：期望 CPU <1 秒 → CPU {elapsed:.6f} 秒（墙钟 {wall:.3f} 秒）', flush=True)
                        self.assertLess(elapsed, 1.0)


unittest.main(verbosity=2)
PY
