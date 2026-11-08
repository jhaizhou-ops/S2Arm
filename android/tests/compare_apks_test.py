#!/usr/bin/env python3
# #1131：等价核对脚本——两路（docker / host）同提交产物的条目名集合、非 .so
# 条目大小、.so 动态符号「名字+类型」集合一致；.so 另按加载态字节比
# （#1207 复审三轮：去 .comment/.note.*/符号表后相同判绿，不同判红并列段级差异，
# objcopy 不可用无法证明时大小差维持判红）。
import io
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'android/tools/compare_apks.py'


def make_apk(path, entries):
    """entries: {name: bytes}"""
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            z.writestr(name, data)


def fake_nm(directory, mapping):
    """Fixture llvm-nm: prints canned output per input file name."""
    script = directory / 'llvm-nm'
    cases = ' '.join(f'{name}) cat <<\'EOF\'\n{out}\nEOF\n;;' for name, out in mapping.items())
    script.write_text(
        '#!/bin/sh\n'
        'for a in "$@"; do :; done\n'
        'case "$(basename "$a")" in\n'
        f'{cases}\n'
        'esac\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return script


class CompareApksTest(unittest.TestCase):
    def run_tool(self, left, right, nm):
        return subprocess.run(
            [sys.executable, str(TOOL), '--left', str(left), '--right', str(right),
             '--nm', str(nm)],
            capture_output=True, text=True)

    def test_identical_passes(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            entries = {'lib/arm64-v8a/liba.so': b'ELF-a', 'classes.dex': b'dex', 'res/x': b'r'}
            make_apk(td / 'a.apk', entries)
            make_apk(td / 'b.apk', dict(entries))   # 同样的路径与大小
            # 工具把同名 .so 解出为 l.so / r.so，fixture 按解出后的名字给输出
            nm = fake_nm(td, {'l.so': '  U foo\n0001 T bar\n',
                              'r.so': '  U foo\n0001 T bar\n'})
            r = self.run_tool(td / 'a.apk', td / 'b.apk', nm)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)

    def test_symbol_diff_fails_and_lists(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            # 两边 .so 内容不同，fixture llvm-nm 按内容给出不同符号表
            nm = td / 'llvm-nm'
            nm.write_text(
                '#!/bin/sh\n'
                'last=""; for a in "$@"; do last="$a"; done\n'
                'if grep -q LEFT "$last"; then\n'
                '  printf "  U foo\\n0001 T bar\\n0002 T only_left\\n"\n'
                'else\n'
                '  printf "  U foo\\n0001 T bar\\n"\n'
                'fi\n')
            nm.chmod(0o755)
            make_apk(td / 'l.apk', {'lib/arm64-v8a/liba.so': b'LEFT-xx'})
            make_apk(td / 'r.apk', {'lib/arm64-v8a/liba.so': b'RIGHT-y'})
            r = self.run_tool(td / 'l.apk', td / 'r.apk', nm)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('only_left', r.stdout + r.stderr)

    def test_entry_list_diff_fails_and_lists(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            make_apk(td / 'a.apk', {'a.txt': b'1234', 'b.txt': b'x'})
            make_apk(td / 'b.apk', {'a.txt': b'123456', 'b.txt': b'x', 'c.txt': b'new'})
            nm = fake_nm(td, {})
            r = self.run_tool(td / 'a.apk', td / 'b.apk', nm)
            self.assertNotEqual(r.returncode, 0)
            out = r.stdout + r.stderr
            self.assertIn('a.txt', out)
            self.assertIn('c.txt', out)

    def test_so_size_delta_is_red_even_with_same_symbols(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            make_apk(td / 'l.apk', {'lib/arm64-v8a/liba.so': b'ELF-same'})
            make_apk(td / 'r.apk', {'lib/arm64-v8a/liba.so': b'ELF-same+pad'})
            nm = fake_nm(td, {'l.so': '  U foo\n0001 T bar\n',
                              'r.so': '0009 T bar\n  U foo\n'})
            r = self.run_tool(td / 'l.apk', td / 'r.apk', nm)
            self.assertEqual(r.returncode, 1)
            self.assertIn('.so 体积差', r.stderr)

    def test_so_only_on_one_side_fails(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            make_apk(td / 'a.apk', {'lib/arm64-v8a/liba.so': b'x'})
            make_apk(td / 'b.apk', {'lib/arm64-v8a/libb.so': b'x'})
            nm = fake_nm(td, {})
            r = self.run_tool(td / 'a.apk', td / 'b.apk', nm)
            self.assertNotEqual(r.returncode, 0)


if __name__ == '__main__':
    unittest.main()
