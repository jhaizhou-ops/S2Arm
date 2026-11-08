#!/usr/bin/env python3
# #1131：NativeAOT 静态库产物校验——.a 里必须有成员，且每个成员是
# ELF64 / EM_AARCH64(183)（linux-bionic-arm64）。macOS 上 BSD ar 会把 ELF
# 成员静默丢掉、产出 8 字节空归档（t140 探测实测），本测试锁死该红线。
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'android/cs/archive_check.py'

ARMAG = b'!<arch>\n'


def elf64_aarch64(payload=b'\x90' * 16):
    # e_ident: ELFMAG, 64-bit, LSB, version 1; e_machine=AArch64(183)
    ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
    return ident + struct.pack('<HHIQQQIHHHHHH', 1, 183, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) + payload


def elf64_x86_64():
    ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
    return ident + struct.pack('<HHIQQQIHHHHHH', 1, 62, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)


def mach_o_64():
    return struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 6, 2, 0, 0, 0, 0)


def ar_member(name, data):
    name = name.encode() + b'/'
    name = name.ljust(16, b' ')
    hdr = (name + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6) +
           b'100644'.ljust(8) + str(len(data)).encode().ljust(10) + b'`\n')
    pad = b'\n' if len(data) % 2 else b''
    return hdr + data + pad


def ar(path, members):
    blob = ARMAG + b''.join(ar_member(n, d) for n, d in members)
    Path(path).write_bytes(blob)


class ArchiveCheckTest(unittest.TestCase):
    def run_tool(self, archive):
        return subprocess.run([sys.executable, str(TOOL), str(archive)],
                              capture_output=True, text=True)

    def test_valid_elf_aarch64_archive_passes(self):
        with tempfile.TemporaryDirectory() as td:
            ar(Path(td) / 'ok.a', [('x.o', elf64_aarch64()), ('y.o', elf64_aarch64())])
            r = self.run_tool(Path(td) / 'ok.a')
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)

    def test_empty_archive_is_red(self):
        # t140 实测：BSD ar 对 ELF 成员产出 8 字节「!<arch>\n」空归档——必须红。
        with tempfile.TemporaryDirectory() as td:
            Path(td, 'empty.a').write_bytes(ARMAG)
            r = self.run_tool(Path(td) / 'empty.a')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('0', r.stderr + r.stdout)

    def test_mach_o_member_is_red(self):
        # 宿主 Mach-O 对象混进 linux-bionic 静态库 = 配错目标，必须红。
        with tempfile.TemporaryDirectory() as td:
            ar(Path(td) / 'bad.a', [('x.o', mach_o_64())])
            r = self.run_tool(Path(td) / 'bad.a')
            self.assertNotEqual(r.returncode, 0)

    def test_wrong_machine_is_red(self):
        with tempfile.TemporaryDirectory() as td:
            ar(Path(td) / 'bad.a', [('x.o', elf64_x86_64())])
            r = self.run_tool(Path(td) / 'bad.a')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('AArch64', r.stderr + r.stdout)

    def test_missing_file_is_red(self):
        with tempfile.TemporaryDirectory() as td:
            r = self.run_tool(Path(td) / 'nope.a')
            self.assertNotEqual(r.returncode, 0)

    def test_not_an_archive_is_red(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, 'junk.a').write_bytes(b'not an archive')
            r = self.run_tool(Path(td) / 'junk.a')
            self.assertNotEqual(r.returncode, 0)

    def test_runs_without_doctor_module(self):
        # 判据拆成独立小模块后，archive_check 只依赖它；doctor.py 不在场也必须能跑。
        with tempfile.TemporaryDirectory() as td:
            android = Path(td) / 'android'
            (android / 'cs').mkdir(parents=True)
            (android / 'doctor').mkdir()
            shutil.copy2(TOOL, android / 'cs/archive_check.py')
            shutil.copy2(ROOT / 'android/doctor/archive_valid.py',
                         android / 'doctor/archive_valid.py')
            ar(android / 'ok.a', [('x.o', elf64_aarch64())])
            r = subprocess.run([sys.executable, str(android / 'cs/archive_check.py'),
                                str(android / 'ok.a')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)


if __name__ == '__main__':
    unittest.main()
