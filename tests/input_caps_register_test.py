#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original offline TSV fixtures; no game or device evidence."""
import csv
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import reglist

HEADER = ['程序号', '局目录名', 'styles', 'sixaxis_start', 'vib_calls', 'vib_nonzero',
          '手柄样式', '震动', '六轴', '状态']
PID = '0100000000001234'
BUILD = 'synthetic-build'
DATE = '2026-11-01'
TABLE = '名单_输入能力'
REG_HEADER = '程序号\t构建号\t项\t静态\t局内\t依据局\t日期\n'


def tsv(row=None, static=None):
    out = io.StringIO()
    writer = csv.writer(out, delimiter='\t', lineterminator='\n')
    writer.writerow(HEADER + (['声明引用'] if static is not None else []))
    if row is not None:
        writer.writerow(row + ([json.dumps(static, ensure_ascii=False)] if static is not None else []))
    return out.getvalue()


def measured():
    return [PID, '合成局; 保留名称', 'ProController', '2', '3', '0',
            '声明了：ProController', '只发零幅', '启动过', '已解析']


def static_data(value=False, ok=True):
    return dict(ok=ok, why='', styles=value, vibration=value, sixaxis=value,
                evidence=dict(styles=[], vibration=[], sixaxis=[]))


class RegistrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import input_caps_register
        cls.mod = input_caps_register

    def parse(self, text, build=BUILD):
        return self.mod.parse_scan(text, 'original.tsv', build, DATE)

    def test_dynamic_and_zero_amplitude(self):
        rows = self.parse(tsv(measured()))
        self.assertEqual(rows, [[PID, BUILD, item, '未知', '调用', '合成局; 保留名称', DATE]
                                for item in ('controller', 'rumble', 'gyro')])

    def test_negative_is_not_unsupported(self):
        row = [PID, '合成局', '-', '0', '0', '0', '未声明', '没调用', '没启动', '已解析']
        rows = self.parse(tsv(row, static_data()))
        self.assertEqual([r[3:5] for r in rows], [['未见', '未调用']] * 3)
        self.assertNotIn('unsupported', str(rows))
        self.assertNotIn('verified', str(rows))

    def test_static_positive_without_runtime(self):
        row = [PID, '缺摘要合成局', '未测', '-', '-', '-', '未测', '未测', '未测', '缺摘要行']
        self.assertEqual([r[3:5] for r in self.parse(tsv(row, static_data(True)))],
                         [['引用', '未测']] * 3)

    def test_incomplete_static_stays_unknown(self):
        row = measured(); row[-1] = '已解析；静态未知'
        self.assertEqual([r[3:5] for r in self.parse(tsv(row, static_data(True, False)))],
                         [['未知', '调用']] * 3)

    def test_conflict_preserves_both_evidence(self):
        row = measured(); row[-1] = '证据冲突：手柄样式、震动、六轴'
        self.assertEqual([r[3:5] for r in self.parse(tsv(row, static_data()))],
                         [['未见', '调用']] * 3)

    def test_invalid_scan_fails_with_location(self):
        for index, value in [(0, '../escape'), (2, 'Invented'), (3, '-1'), (4, 'x'),
                             (5, '4'), (6, '支持'), (7, 'yes'), (8, 'unknown'),
                             (9, '已验证'), (1, 'tab\tname'), (1, '局\x85名'), (1, '局\u2028名'), (1, '局\u2029名')]:
            with self.subTest(index=index):
                row = measured(); row[index] = value
                with self.assertRaisesRegex(ValueError, r'original.tsv:2:'):
                    self.parse(tsv(row))

    def test_malformed_static_json_and_header(self):
        with self.assertRaisesRegex(ValueError, 'original.tsv:2:'):
            self.parse(tsv(measured(), static_data()).replace('{"ok"', '{bad"ok"'))
        with self.assertRaisesRegex(ValueError, 'original.tsv:1:'):
            self.parse('wrong\theader\n')

    def test_explicit_build_required(self):
        for build in ('', ' ', 'x\ty', 'x\ny', 'x\x85y', 'x\u2028y', 'x\u2029y'):
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.parse(tsv(measured()), build)

    def test_invalid_date(self):
        with self.assertRaises(ValueError):
            self.mod.parse_scan(tsv(measured()), 'original.tsv', BUILD, '2026-02-30')

    def test_mapping(self):
        self.assertEqual(reglist.name_of('docs/名单_输入能力.tsv'), TABLE)

    def test_empty_does_not_touch_existing_bytes_or_create(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.mod.register(repo, self.parse(tsv()))
            self.assertEqual(list(repo.iterdir()), [])
            directory = repo / 'docs' / TABLE; directory.mkdir(parents=True)
            path = directory / (PID + '.tsv')
            path.write_bytes(b'untouched\r\ninvalid old content')
            before = path.stat().st_mtime_ns
            self.mod.register(repo, [])
            self.assertEqual(path.read_bytes(), b'untouched\r\ninvalid old content')
            self.assertEqual(path.stat().st_mtime_ns, before)

    def test_register_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = self.parse(tsv(measured()))
            self.mod.register(tmp, rows)
            path = Path(tmp) / 'docs' / TABLE / (PID + '.tsv')
            expected = REG_HEADER + ''.join('\t'.join(row) + '\n' for row in rows)
            self.assertEqual(path.read_text(), expected)
            before = path.stat().st_mtime_ns
            self.mod.register(tmp, rows)
            self.assertEqual(path.stat().st_mtime_ns, before)
            self.assertEqual(reglist.text(tmp, TABLE), expected)

    def test_invalid_existing_enums_refuse_before_write(self):
        for col, value in [(2, 'mouse'), (3, '不支持'), (4, '支持')]:
            with self.subTest(col=col), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp) / 'docs' / TABLE; directory.mkdir(parents=True)
                (directory / reglist.HEAD).write_text(REG_HEADER)
                row = [PID, BUILD, 'rumble', '未知', '未测', '旧合成局', DATE]
                row[col] = value
                path = directory / (PID + '.tsv')
                path.write_text(REG_HEADER + '\t'.join(row) + '\n')
                old = path.read_bytes()
                with self.assertRaisesRegex(ValueError, PID + r'.tsv:2:'):
                    self.mod.register(tmp, self.parse(tsv(measured())))
                self.assertEqual(path.read_bytes(), old)

    def test_no_unrelated_title_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            row = measured(); row[0] = '0100000000005678'
            self.mod.register(tmp, self.parse(tsv(row)))
            path = Path(tmp) / 'docs' / TABLE / (row[0] + '.tsv')
            old = path.read_bytes(); stamp = path.stat().st_mtime_ns
            self.mod.register(tmp, self.parse(tsv(measured())))
            self.assertEqual(path.read_bytes(), old)
            self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_registry_header_comments_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / 'docs' / TABLE; directory.mkdir(parents=True)
            head = directory / reglist.HEAD
            original = '# 仅声明和调用证据，设备体感未验\n' + REG_HEADER
            head.write_text(original)
            self.mod.register(tmp, self.parse(tsv(measured())))
            self.assertEqual(head.read_text(), original)

    def test_other_scanner_styles(self):
        row = measured(); row[2] = 'Invalid,Pokeball,System'; row[6] = '声明了：' + row[2]
        self.assertEqual(self.parse(tsv(row))[0][4], '调用')

    def test_multiple_titles_rejected(self):
        second = measured(); second[0] = '0100000000005678'
        text = tsv(measured()) + tsv(second).split('\n', 1)[1]
        with self.assertRaisesRegex(ValueError, '分款登记'):
            self.parse(text)

    def test_same_record_conflict_preserves_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = self.parse(tsv(measured()))
            self.mod.register(tmp, rows)
            path = Path(tmp) / 'docs' / TABLE / (PID + '.tsv')
            old = path.read_bytes()
            rows[1][4] = '未调用'
            with self.assertRaisesRegex(ValueError, '未覆盖历史证据'):
                self.mod.register(tmp, rows)
            self.assertEqual(path.read_bytes(), old)

    def test_cli_bad_last_row_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'input.tsv'
            bad = measured(); bad[-1] = '摘要行格式错'
            source.write_text(tsv(measured()) + tsv(bad).split('\n', 1)[1])
            repo = Path(tmp) / 'repo'
            run = subprocess.run([sys.executable, str(ROOT/'tools/input_caps_register.py'),
                                  str(source), '--build', BUILD, '--date', DATE,
                                  '--repo', str(repo)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 2)
            self.assertIn('input.tsv:3:', run.stderr)
            self.assertFalse(repo.exists())

    def test_cli_missing_build_no_output_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'input.tsv'; source.write_text(tsv(measured()))
            repo = Path(tmp) / 'repo'
            run = subprocess.run([sys.executable, str(ROOT/'tools/input_caps_register.py'),
                                  str(source), '--date', DATE, '--repo', str(repo)], capture_output=True)
            self.assertEqual(run.returncode, 2)
            self.assertFalse(repo.exists())


if __name__ == '__main__':
    unittest.main()
