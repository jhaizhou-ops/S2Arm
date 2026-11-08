#!/usr/bin/env python3
"""v24.0 / v31 元数据单测（第 3 轮按两份真文件头部重写，第 5 轮加多 image 用例）；
期望值按夹具布局手写，不跑被测实现推导。

v31（丝之歌）：头部 31 对段，表在第 2/5/19/20 段；方法记录 36 字节（token @24），类型 88，image 40。
v24.0（空洞骑士）：头部 33 对段，表在第 2/5/19/21 段；方法 56，类型 104（methodStart @52、
method_count @80），image 32；没有 CodeGenModule，定位必须拒绝（判不出），不许猜。

多 image 用例（第 5 轮）：丝之歌真镜像里同时存在几十个 image 各自的 CodeGenModule，
setter 只在 UnityEngine.CoreModule.dll；定位按「目标 setter 所在 image」取名取模块，
别的 image 的模块不是歧义。同名 image 下两份模块记录仍然判不出。
"""
import importlib.util
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('judge', ROOT / 'tools/unity_fps_judge.py')
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)
loc = judge.loc

FRAME_ENTRY = 0x1080
VSYNC_ENTRY = 0x1090
STRINGS = (b'UnityEngine.CoreModule.dll\0UnityEngine\0Application\0QualitySettings\0'
           b'set_targetFrameRate\0set_vSyncCount\0')
TARGETS = [('Application', 'set_targetFrameRate'), ('QualitySettings', 'set_vSyncCount')]


def name(s):
    return STRINGS.index(s.encode() + b'\0')


def image_fixture():
    """与 v29 判定夹具相同：MOD0 @0x1300，名字串 0x1200，CodeGenModule @0x1380，指针表 0x1340。"""
    image = bytearray(0x400)
    struct.pack_into('<I', image, 4, 0x300)
    struct.pack_into('<4sIII', image, 0x300, b'MOD0', 0, 0x100, 0x500)
    image[0x200:0x200 + 27] = b'UnityEngine.CoreModule.dll\0'
    struct.pack_into('<QQQ', image, 0x380, 0x1200, 2, 0x1340)
    struct.pack_into('<QQ', image, 0x340, FRAME_ENTRY, VSYNC_ENTRY)
    return image


def fixture_v31():
    m = bytearray(1024)
    struct.pack_into('<II', m, 0, 0xFAB11BAF, 31)
    # 头部 8 + 31×8 = 256；第 0 段字面量表紧接头部（同丝之歌真文件：第 0 段偏移 0x100）
    for pair, off, size in [(0, 256, 8), (2, 264, len(STRINGS)), (5, 400, 72), (19, 480, 176), (20, 672, 40)]:
        struct.pack_into('<II', m, 8 + pair * 8, off, size)
    m[264:264 + len(STRINGS)] = STRINGS
    for i, (cls, meth) in enumerate(TARGETS):
        struct.pack_into('<II', m, 480 + i * 88, name(cls), name('UnityEngine'))
        struct.pack_into('<i', m, 480 + i * 88 + 36, i)
        struct.pack_into('<H', m, 480 + i * 88 + 64, 1)
        # name, declaringType, returnType, returnParameterToken, parameterStart, genericContainer,
        # token(+24), flags(+28), iflags, slot, parameterCount(+34)
        struct.pack_into('<IiiiiiIHHHH', m, 400 + i * 36, name(meth), i, 0, 0, 0, -1,
                         0x06000001 + i, 0x10, 0, 0xffff, 1)
    struct.pack_into('<IiiI', m, 672, name('UnityEngine.CoreModule.dll'), 0, 0, 2)
    return m, image_fixture()


def fixture_v24():
    m = bytearray(1024)
    struct.pack_into('<II', m, 0, 0xFAB11BAF, 24)
    # 头部 8 + 33×8 = 272（同空洞骑士真文件：第 0 段偏移 0x110）；image 在第 21 段
    for pair, off, size in [(0, 272, 8), (2, 280, len(STRINGS)), (5, 400, 112), (19, 512, 208), (21, 720, 32)]:
        struct.pack_into('<II', m, 8 + pair * 8, off, size)
    m[280:280 + len(STRINGS)] = STRINGS
    for i, (cls, meth) in enumerate(TARGETS):
        t = 512 + i * 104
        struct.pack_into('<II', m, t, name(cls), name('UnityEngine'))
        struct.pack_into('<i', m, t + 52, i)
        struct.pack_into('<H', m, t + 80, 1)
        mo = 400 + i * 56
        struct.pack_into('<Ii', m, mo, name(meth), i)
        struct.pack_into('<IHHHH', m, mo + 44, 0x06000001 + i, 0x10, 0, 0xffff, 1)
    struct.pack_into('<IiiI', m, 720, name('UnityEngine.CoreModule.dll'), 0, 0, 2)
    return m, image_fixture()


MULTI_STRINGS = STRINGS + b'Assembly-CSharp\0'   # Assembly-CSharp 的名字索引 = len(STRINGS)（102）


def fixture_v31_multi_image():
    """丝之歌形状：镜像里两个 image 各有自己的模块记录，setter 只在 UnityEngine.CoreModule.dll。

    手推期望值（不跑被测实现）：
    - 类型 0/1 = Application / QualitySettings（UnityEngine），各 1 个方法，token 0x06000001/2；
    - image 0 = UnityEngine.CoreModule.dll，类型 0..1、方法 2 个 → 加载器记录 @0x1380（名字 0x1200、
      方法数 2、指针表 0x1340），methodPointers[0/1] = 0x1080 / 0x1090；
    - image 1 = Assembly-CSharp，无类型、0 方法，模块记录 @0x12a0（名字 0x1240、1 方法、表 0x1360）。
      它不是在找的 setter 所在的 image，因此不是候选、不构成歧义。
    """
    m = bytearray(1024)
    struct.pack_into('<II', m, 0, 0xFAB11BAF, 31)
    for pair, off, size in [(0, 256, 8), (2, 264, len(MULTI_STRINGS)), (5, 400, 72),
                            (19, 480, 176), (20, 672, 80)]:
        struct.pack_into('<II', m, 8 + pair * 8, off, size)
    m[264:264 + len(MULTI_STRINGS)] = MULTI_STRINGS
    for i, (cls, meth) in enumerate(TARGETS):
        struct.pack_into('<II', m, 480 + i * 88, name(cls), name('UnityEngine'))
        struct.pack_into('<i', m, 480 + i * 88 + 36, i)
        struct.pack_into('<H', m, 480 + i * 88 + 64, 1)
        struct.pack_into('<IiiiiiIHHHH', m, 400 + i * 36, name(meth), i, 0, 0, 0, -1,
                         0x06000001 + i, 0x10, 0, 0xffff, 1)
    struct.pack_into('<IiiI', m, 672, 0, 0, 0, 2)                    # image 0：CoreModule，类型 0..1
    struct.pack_into('<IiiI', m, 712, len(STRINGS), -1, 0, 0)        # image 1：Assembly-CSharp，无类型
    image = image_fixture()
    image[0x240:0x240 + 16] = b'Assembly-CSharp\0'
    struct.pack_into('<QQQ', image, 0x2a0, 0x1240, 1, 0x1360)        # 别的 image 的模块记录
    struct.pack_into('<Q', image, 0x360, 0x10a0)                     # 它自己的 1 项指针表
    return m, image


def movz(rd, imm16):
    return 0x52800000 | imm16 << 5 | rd


def add_wzr(rd, imm12):
    return 0x11000000 | imm12 << 10 | 31 << 5 | rd


def bl(pc, target):
    return 0x94000000 | (((target - pc) // 4) & 0x3FFFFFF)


def code(image, pc, word):
    struct.pack_into('<I', image, pc - 0x1000, word)


class TestV31(unittest.TestCase):
    def test_v31_enough_target_60(self):
        m, b = fixture_v31()
        code(b, 0x105c, movz(0, 60))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        code(b, 0x106c, movz(0, 0))
        code(b, 0x1070, bl(0x1070, VSYNC_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '够')
        self.assertEqual([s['argument'] for s in report['sites']], [60, 0])

    def test_v31_not_enough_target_30(self):
        m, b = fixture_v31()
        code(b, 0x105c, add_wzr(0, 30))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '不够')
        self.assertEqual(report['sites'][0]['argument'], 30)

    def test_v31_metadata_version_and_mapping(self):
        m, b = fixture_v31()
        located = loc.locate(bytes(m), bytes(b), 0x1000, None, 0x1040, 0x80)
        self.assertEqual(located['metadata_version'], 31)
        self.assertEqual(located['codegen_module'], 0x1380)
        self.assertEqual([x['entry_va'] for x in located['methods']], [0x1080, 0x1090])

    def test_v31_token_read_at_24(self):
        # 只对调 +24 处的 token，映射跟着对调；v29 的 token 位 +20 在 v31 是 genericContainer（-1）
        m, b = fixture_v31()
        struct.pack_into('<I', m, 400 + 24, 0x06000002)
        struct.pack_into('<I', m, 436 + 24, 0x06000001)
        located = loc.locate(bytes(m), bytes(b), 0x1000, None, 0x1040, 0x80)
        self.assertEqual([x['entry_va'] for x in located['methods']], [0x1090, 0x1080])


class TestMultiImage(unittest.TestCase):
    def test_other_images_modules_are_not_ambiguous(self):
        m, b = fixture_v31_multi_image()
        located = loc.locate(bytes(m), bytes(b), 0x1000, None, 0x1040, 0x80)
        self.assertEqual(located['module'], 'UnityEngine.CoreModule.dll')
        self.assertEqual([(x['name'], x['codegen_module'], x['module_match']) for x in located['modules']],
                         [('UnityEngine.CoreModule.dll', 0x1380, 'strict_method_count')])
        self.assertEqual([x['entry_va'] for x in located['methods']], [0x1080, 0x1090])

    def test_multi_image_judge_enough(self):
        m, b = fixture_v31_multi_image()
        code(b, 0x105c, movz(0, 60))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        report = judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)
        self.assertEqual(report['verdict'], '够')
        self.assertEqual(report['sites'][0]['argument'], 60)

    def test_same_image_two_modules_still_ambiguous(self):
        # 同名 image 下再放一份合法模块记录 → 仍然判不出
        m, b = fixture_v31_multi_image()
        struct.pack_into('<QQQ', b, 0x1a0, 0x1200, 2, 0x1340)
        with self.assertRaisesRegex(loc.Invalid, 'ambiguous'):
            loc.locate(bytes(m), bytes(b), 0x1000, None, 0x1040, 0x80)


class TestV24(unittest.TestCase):
    def test_v24_tables_and_type_ranges(self):
        m, _ = fixture_v24()
        version, name_of, methods, types, images = loc.tables(bytes(m))
        self.assertEqual((version, methods, types, images), (24, (400, 2), (512, 2), (720, 1)))
        self.assertEqual(name_of(name('Application')), 'Application')
        self.assertEqual(loc.type_ranges(bytes(m), 24, name_of, 512, 2, 720, 1, 2),
                         [('UnityEngine.CoreModule.dll', 0, 2, 2)])

    def test_v24_judge_rejected_no_codegen_module(self):
        m, b = fixture_v24()
        code(b, 0x105c, movz(0, 60))
        code(b, 0x1060, bl(0x1060, FRAME_ENTRY))
        with self.assertRaisesRegex(loc.Invalid, 'v24.0'):
            judge.judge(bytes(m), bytes(b), 0x1000, 0x1040, 0x80)

    def test_v24_header_length_mismatch(self):
        # 字面量表不紧接 33 对头部（如 32 对头部的子版本，字面量表在 264）→ 拒绝，不按错位的段读
        m, _ = fixture_v24()
        struct.pack_into('<II', m, 8, 264, 8)
        with self.assertRaisesRegex(loc.Invalid, 'header length'):
            loc.tables(bytes(m))


if __name__ == '__main__':
    unittest.main()
