#!/usr/bin/env python3
"""原创 v29 + MOD0 夹具的交换间隔判定单测；期望值按夹具布局手写，不跑被测实现推导。

夹具布局（image_base = 0x1000，text 0x1040..0x10c0）：
- metadata：两个 setter（Application.set_targetFrameRate → 0x1080，QualitySettings.set_vSyncCount → 0x1090）
- CodeGenModule 记录在 0x1300（名字串 0x1200、方法数 2、指针表 0x1340）
- 每个用例往 text 里写不同的 w0 常量与 BL
"""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('judge', ROOT / 'tools/unity_fps_judge.py')
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)

FRAME_ENTRY = 0x1080
VSYNC_ENTRY = 0x1090


def fixture():
    metadata = bytearray(1024)
    struct.pack_into('<II', metadata, 0, 0xFAB11BAF, 29)
    strings = (b'UnityEngine.CoreModule.dll\0UnityEngine\0Application\0QualitySettings\0'
               b'set_targetFrameRate\0set_vSyncCount\0')
    metadata[256:256 + len(strings)] = strings

    def name(s):
        return strings.index(s.encode() + b'\0')

    for pair, offset, size in [(2, 256, len(strings)), (5, 400, 64), (19, 480, 176), (20, 672, 40)]:
        struct.pack_into('<II', metadata, 8 + pair * 8, offset, size)
    for i, (cls, meth) in enumerate([('Application', 'set_targetFrameRate'),
                                    ('QualitySettings', 'set_vSyncCount')]):
        struct.pack_into('<II', metadata, 480 + i * 88, name(cls), name('UnityEngine'))
        struct.pack_into('<i', metadata, 480 + i * 88 + 36, i)
        struct.pack_into('<H', metadata, 480 + i * 88 + 64, 1)
        struct.pack_into('<IiiiiIHHHH', metadata, 400 + i * 32, name(meth), i, 0, 0, -1,
                         0x06000001 + i, 0x10, 0, 0xffff, 1)
    struct.pack_into('<IiiI', metadata, 672, name('UnityEngine.CoreModule.dll'), 0, 0, 2)
    image = bytearray(0x400)
    struct.pack_into('<I', image, 4, 0x300)               # MOD0 在 0x1300
    struct.pack_into('<4sIII', image, 0x300, b'MOD0', 0, 0x400 - 0x300, 0x800 - 0x300)
    image[0x200:0x200 + 27] = b'UnityEngine.CoreModule.dll\0'   # 名字串 VA 0x1200
    struct.pack_into('<QQQ', image, 0x380, 0x1200, 2, 0x1340)    # CodeGenModule @0x1380
    struct.pack_into('<QQ', image, 0x340, FRAME_ENTRY, VSYNC_ENTRY)
    return metadata, image


def movz(rd, imm16, shift=0):
    return 0x52800000 | shift << 21 | imm16 << 5 | rd


def movn(rd, imm16, shift=0):
    return 0x12800000 | shift << 21 | imm16 << 5 | rd


def add_wzr(rd, imm12):
    return 0x11000000 | imm12 << 10 | 31 << 5 | rd


def bl(pc, target):
    diff = (target - pc) // 4
    return 0x94000000 | (diff & 0x3FFFFFF)


def code(image, pc, word):
    struct.pack_into('<I', image, pc - 0x1000, word)


class TestJudge(unittest.TestCase):
    def test_enough_negative_one(self):
        # targetFrameRate = -1（movn w0,#0），vSyncCount = 0（movz w0,#0）
        m, b = fixture()
        code(b, 0x105c, movn(0, 0))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        code(b, 0x106c, movz(0, 0))
        code(b, 0x1070, bl(0x1070, VSYNC_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '够')
        self.assertEqual([s['argument'] for s in report['sites']], [-1, 0])
        self.assertEqual([s['pc'] for s in report['sites']], [0x1060, 0x1070])

    def test_enough_vsync_nonzero(self):
        # vSyncCount = 1 → 够，即使 targetFrameRate = 30
        m, b = fixture()
        code(b, 0x105c, movz(0, 30))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        code(b, 0x106c, movz(0, 1))
        code(b, 0x1070, bl(0x1070, VSYNC_ENTRY))
        self.assertEqual(judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)['verdict'], '够')

    def test_not_enough_target_30(self):
        # targetFrameRate = 30（ADD w0, wzr, #30），vSyncCount = 0 → 不够
        m, b = fixture()
        code(b, 0x105c, add_wzr(0, 30))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        code(b, 0x106c, movz(0, 0))
        code(b, 0x1070, bl(0x1070, VSYNC_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '不够')
        self.assertIn('30', report['reason'])
        self.assertEqual(report['sites'][0]['argument'], 30)

    def test_undecidable_register_argument(self):
        # w0 来自内存：LDR w0, [x1] → 判不出
        m, b = fixture()
        code(b, 0x105c, 0xB9400020)
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        code(b, 0x106c, movz(0, 0))
        code(b, 0x1070, bl(0x1070, VSYNC_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '判不出')
        self.assertIsNone(report['sites'][0]['argument'])

    def test_undecidable_branch_crossed(self):
        # 常量写在分支里（BL 前有 B），实参不可知
        m, b = fixture()
        code(b, 0x1058, bl(0x1058, 0x10b0))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '判不出')
        self.assertIn('分支', report['sites'][0]['how'])

    def test_undecidable_no_call_site(self):
        # 有 setter 映射但游戏代码里没有直接 BL → 判不出
        m, b = fixture()
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '判不出')
        self.assertEqual(report['sites'], [])

    def test_absent_is_unlimited_only_when_asked(self):
        # 同一份夹具：缺省判不出，显式 --absent-is-unlimited 才判够
        m, b = fixture()
        strict = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        loose = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80, None, True)
        self.assertEqual(strict['verdict'], '判不出')
        self.assertEqual(loose['verdict'], '够')
        self.assertIn('假设', loose['reason'])

    def test_mod0_bounds_used_when_not_given(self):
        m, b = fixture()
        code(b, 0x105c, movz(0, 60))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000)
        self.assertEqual(report['verdict'], '够')
        self.assertEqual(report['sites'][0]['argument'], 60)

    def test_movk_or_pattern_and_zero_forms(self):
        # MOV w0, wzr = 0；ORR w0, wzr, #0x1E 不可由单个逻辑立即数表示，用 ADD 路径另测
        m, b = fixture()
        code(b, 0x105c, 0x2A1F03E0)
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        self.assertEqual(judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)['sites'][0]['argument'], 0)

    def test_cli_exit_codes_and_read_only(self):
        m, b = fixture()
        code(b, 0x105c, add_wzr(0, 30))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        with tempfile.TemporaryDirectory() as td:
            mp, bp = Path(td) / 'metadata.dat', Path(td) / 'main.patched.bin'
            mp.write_bytes(m)
            bp.write_bytes(b)
            cmd = [sys.executable, str(ROOT / 'tools/unity_fps_judge.py'), str(mp), str(bp),
                   '--image-base', '0x1000', '--text-start', '0x1040', '--text-size', '0x80']
            result = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)          # 不够
            self.assertIn('不够', result.stdout)
            self.assertEqual(mp.read_bytes(), bytes(m))
            self.assertEqual(bp.read_bytes(), bytes(b))
            code(b, 0x105c, movz(0, 60))
            bp.write_bytes(b)
            result = subprocess.run(cmd + ['--json'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)          # 够
            self.assertEqual(json.loads(result.stdout)['verdict'], '够')

    def test_unsupported_metadata_version_rejected(self):
        # 第 1 轮用 v31 当「不支持」；第 3 轮起 v31 已支持，改用不存在的版本 99
        m, b = fixture()
        struct.pack_into('<I', m, 4, 99)  # 不存在的版本
        with self.assertRaises(judge.loc.Invalid):
            judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)

    def test_ambiguous_module_rejected(self):
        m, b = fixture()
        # 再放一份合法模块记录指向同一名字串 → 结构定位不唯一
        struct.pack_into('<QQQ', b, 0x100, 0x1200, 2, 0x1340)
        with self.assertRaises(judge.loc.Invalid):
            judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)


if __name__ == '__main__':
    unittest.main()
