#!/usr/bin/env python3
"""Fixture tests for tools/compare_apks.py (#1131 review item 4).

Fake APKs are real zips; `llvm-nm` is a stub script — either echoing a
fixed symbol table (size-delta cases) or `cat`ing the .so so its bytes
*are* the nm output (symbol-set cases). Exercises the owner-approved
criteria: path+size entry comparison, `.so` loadable-image comparison
(strip `.comment`/`.note.*`/symbol tables, then bytes — #1207 review
round 3; raw size deltas become notes only when loadable bytes match),
and sorted full-line dynamic-symbol diffs that keep `U` and duplicates.
"""
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPARE = HERE / 'compare_apks.py'

NM_CAT = '#!/bin/sh\nexec cat "$2"\n'          # .so bytes == nm output
NM_FIXED = '#!/bin/sh\nprintf "0000000000001234 T stable_sym\\n"\n'


def ndk_tool(name_pattern):
    """Fixture 用的 NDK host 工具；找不到返回 None（用例跳过，不猜第二套路径）。"""
    roots = [os.environ.get(k) for k in ('ANDROID_NDK_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')]
    roots += [str(Path.home() / 'Library/Android/sdk'), str(Path.home() / 'Android/Sdk')]
    for root in roots:
        if not root:
            continue
        for cand in sorted(Path(root).glob('ndk/*/toolchains/llvm/prebuilt/*/bin/' + name_pattern)):
            if cand.is_file() and os.access(cand, os.X_OK):
                return cand
    return None


class LoadableImageTest(unittest.TestCase):
    """.so 判据是「加载进内存的内容」：去 .comment/.note.*/符号表后逐字节（#1207 复审三轮）。

    真 ELF：NDK clang 出最小 .so；objcopy 给它加第二个 .comment 段（原始大小差，
    加载态相同 → 绿）；或把 .text 抽出来翻一个字节再塞回（原始同大，加载态不同 → 红）。
    """
    def setUp(self):
        self.clang = ndk_tool('aarch64-linux-android*-clang')
        self.nm = ndk_tool('llvm-nm')
        self.objcopy = ndk_tool('llvm-objcopy')
        if not all([self.clang, self.nm, self.objcopy]):
            self.skipTest('NDK clang / llvm-nm / llvm-objcopy 不全')
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-loadable-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.so = self.base / 'base.so'
        src = self.base / 'probe.c'
        src.write_text('int s2a_diag_probe(void){return 0x5a;}\n')
        subprocess.run([str(self.clang), '-nostdlib', '-shared', '-o', str(self.so), str(src)],
                       check=True)

    def apk(self, name, so):
        p = self.base / name
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('classes.dex', b'dex')
            z.writestr('lib/arm64-v8a/liba.so', so.read_bytes())
        return p

    def run_compare(self, left, right):
        return subprocess.run(
            [sys.executable, str(COMPARE), '--left', str(left),
             '--right', str(right), '--nm', str(self.nm)],
            capture_output=True, text=True)

    def test_comment_section_only_size_delta_passes(self):
        """同一 .so 加一个 .comment 段：原始大小差，加载态字节相同 → 绿。"""
        blob = self.base / 'comment.txt'
        blob.write_bytes(b'synthetic comment\n')
        padded = self.base / 'padded.so'
        subprocess.run([str(self.objcopy), '--add-section', f'.comment={blob}',
                        str(self.so), str(padded)], check=True)
        self.assertNotEqual(self.so.stat().st_size, padded.stat().st_size)
        r = self.run_compare(self.apk('l.apk', self.so), self.apk('r.apk', padded))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn('加载态字节相同', r.stdout)

    def test_text_byte_delta_is_red(self):
        """.text 翻一个字节：原始同大，加载态不同 → 红，并列段级定位。"""
        text = self.base / 'text.bin'
        subprocess.run([str(self.objcopy), '--dump-section', f'.text={text}', str(self.so)],
                       check=True)
        data = bytearray(text.read_bytes())
        data[0] ^= 0xFF
        text.write_bytes(bytes(data))
        patched = self.base / 'patched.so'
        subprocess.run([str(self.objcopy), '--update-section', f'.text={text}',
                        str(self.so), str(patched)], check=True)
        r = self.run_compare(self.apk('l.apk', self.so), self.apk('r.apk', patched))
        self.assertEqual(r.returncode, 1)
        self.assertIn('加载态内容不符', r.stderr)


class CompareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-compare-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.nm_cat = self.base / 'nm-cat'
        self.nm_cat.write_text(NM_CAT)
        self.nm_cat.chmod(0o755)
        self.nm_fixed = self.base / 'nm-fixed'
        self.nm_fixed.write_text(NM_FIXED)
        self.nm_fixed.chmod(0o755)

    def apk(self, name, entries):
        p = self.base / name
        with zipfile.ZipFile(p, 'w') as z:
            for entry, data in entries.items():
                z.writestr(entry, data)
        return p

    def run_compare(self, left, right, nm):
        return subprocess.run(
            [sys.executable, str(COMPARE), '--left', str(left),
             '--right', str(right), '--nm', str(nm)],
            capture_output=True, text=True)

    def test_identical_passes(self):
        entries = {'classes.dex': b'dex', 'lib/arm64-v8a/liba.so': b'0001 T sym\n'}
        r = self.run_compare(self.apk('l.apk', entries), self.apk('r.apk', dict(entries)),
                             self.nm_cat)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('两路产物等价', r.stdout)
        self.assertIn('字节)', r.stdout)  # reports both APK paths+sizes

    def test_so_size_delta_is_red(self):
        left = self.apk('l.apk', {'classes.dex': b'dex',
                                  'lib/arm64-v8a/liba.so': b'A' * 100})
        right = self.apk('r.apk', {'classes.dex': b'dex',
                                   'lib/arm64-v8a/liba.so': b'A' * 100 + b'pad'})
        r = self.run_compare(left, right, self.nm_fixed)
        self.assertEqual(r.returncode, 1)
        self.assertIn('.so 体积差 lib/arm64-v8a/liba.so', r.stderr)

    def test_non_so_size_delta_is_red(self):
        left = self.apk('l.apk', {'classes.dex': b'dex!'})
        right = self.apk('r.apk', {'classes.dex': b'dex!!'})
        r = self.run_compare(left, right, self.nm_fixed)
        self.assertEqual(r.returncode, 1)
        self.assertIn('条目大小不符 classes.dex', r.stderr)

    def test_entry_only_on_one_side_is_red(self):
        left = self.apk('l.apk', {'classes.dex': b'dex', 'assets/a.bin': b'a'})
        right = self.apk('r.apk', {'classes.dex': b'dex'})
        r = self.run_compare(left, right, self.nm_fixed)
        self.assertEqual(r.returncode, 1)
        self.assertIn('条目只在 left: assets/a.bin', r.stderr)

    def test_undefined_symbol_line_survives(self):
        """A ` U sym` line (no address column) keeps its type marker."""
        symtab = b'                U undef_sym\n0000000000000001 T def_sym\n'
        entries = {'classes.dex': b'dex', 'lib/arm64-v8a/liba.so': symtab}
        r = self.run_compare(self.apk('l.apk', entries), self.apk('r.apk', dict(entries)),
                             self.nm_cat)
        self.assertEqual(r.returncode, 0, r.stderr)
        other = {'classes.dex': b'dex',
                 'lib/arm64-v8a/liba.so': symtab.replace(b'U undef_sym', b'T undef_sym')}
        r = self.run_compare(self.apk('l2.apk', entries), self.apk('r2.apk', other),
                             self.nm_cat)
        self.assertEqual(r.returncode, 1)
        self.assertIn('动态符号不符', r.stderr)

    def test_symbol_multiplicity_differs_is_red(self):
        """Duplicate symbol lines are preserved: same set ≠ same list."""
        one = {'classes.dex': b'dex',
               'lib/arm64-v8a/liba.so': b'0000000000000001 T dup_sym\n'}
        two = {'classes.dex': b'dex',
               'lib/arm64-v8a/liba.so': (b'0000000000000001 T dup_sym\n'
                                       b'0000000000000002 T dup_sym\n')}
        r = self.run_compare(self.apk('l.apk', one), self.apk('r.apk', two), self.nm_cat)
        self.assertEqual(r.returncode, 1)
        self.assertIn('动态符号不符', r.stderr)

    def test_address_drift_still_equal(self):
        """Addresses are report-only: same type+name, different address → equal."""
        left = {'classes.dex': b'dex',
                'lib/arm64-v8a/liba.so': b'0000000000000001 T sym\n'}
        right = {'classes.dex': b'dex',
                 'lib/arm64-v8a/liba.so': b'00000000abcdef12 T sym\n'}
        r = self.run_compare(self.apk('l.apk', left), self.apk('r.apk', right),
                             self.nm_cat)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
