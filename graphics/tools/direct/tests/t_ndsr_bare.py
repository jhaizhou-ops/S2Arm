#!/usr/bin/env python3
# NDSR 条目流 + 裸 NVN2 程序（11-06 时之笛 Switch 2 版：开局 12 支计算着色器游戏文件里本来就有，抽取漏读 → 直连库没有 → 真机首遇现编、停帧 30 秒以上）：
#   translator/shader_split.py ndsr_shaders / scan_blob、ns2_shaders.py bare_programs。期望按格式手放的字节写，不跑被测实现推：
#   ① NDSR 条目不按 16 字节步长（中间夹着别的类型的条目）：两支都读出，控制段 / 代码区逐字节等于手放的（旧代码按 16 字节一条只读到第一支）
#   ② 同一控制段被两个条目引用、各配一份代码区：两支都出（agl_ndsr_vr_light.pck）
#   ③ 别的文件里 +0x28 处的 NDSR 包（NDVE 视频文件）：scan_blob 读出，来源串「标签@0x28#NDSR@包内偏移」
#   ④ 裸程序：控制段 +0x30 = 控制块长 0x200、代码区紧跟其后 → 读出；+0x30 = 0xe0（BNSH 的写法，代码在别处）与 0（NDSR / 内存的写法）不当裸程序
#   ⑤ 裸程序代码区越过文件尾：跳过、不报错
#   ⑥ 负对照：没有 NVN2 控制段的数据一支不出；裸程序不重复收别的读法已收的控制段
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None


def ctl(stage=5, ncode=0x100, block=0, fill=0):
    """A 0xe0-byte NVN2 control section: magic, version 0xc9, +0x30 block length, +0x44 code length, +0x56 stage, compute thread group 8×8×1 at +0x58; fill marks it apart"""
    c = bytearray(0xe0); c[:4] = bytes.fromhex('34127698'); c[4:8] = b'\xc9\0\0\0'
    struct.pack_into('<I', c, 0x30, block); struct.pack_into('<I', c, 0x44, ncode); c[0x56] = stage
    struct.pack_into('<3I', c, 0x58, 8, 8, 1); c[0x70] = fill
    return bytes(c)


def ndsr(items, size=0x4000):
    """An NDSR pack: 'NDSR' + header words, then 8-byte items (offset, size << 4 | type) from +0x14; items = [(type, offset, bytes or size)]; data placed at the offsets"""
    d = bytearray(size); d[:4] = b'NDSR'; struct.pack_into('<3I', d, 4, 0x10100, 0x20302, len(items)); struct.pack_into('<I', d, 0x10, 0x06020c00)
    for i, (t, off, data) in enumerate(items):
        n = len(data) if isinstance(data, bytes) else data
        struct.pack_into('<2I', d, 0x14 + 8 * i, off, n << 4 | t)
        if isinstance(data, bytes): d[off:off + n] = data
    return bytes(d)


C1, K1 = ctl(fill=1), bytes([0x11]) * 0x100
C2, K2 = ctl(fill=2), bytes([0x22]) * 0x100
K3 = bytes([0x33]) * 0x100
PACK = ndsr([(0xb, 0x3000, 0xc), (6, 0x1000, C1), (7, 0x2000, K1), (9, 0x3010, 4), (6, 0x1100, C2), (7, 0x2100, K2)])


class NdsrBare(unittest.TestCase):
    def test_1_items_off_the_16_byte_stride(self):
        out = SS.ndsr_shaders(PACK, 'syn')
        self.assertEqual([(w, st) for w, st, _, _ in out], [('syn#NDSR@0x1000', 'cs'), ('syn#NDSR@0x1100', 'cs')])
        self.assertEqual([(c, k) for _, _, c, k in out], [(C1, K1), (C2, K2)])

    def test_2_one_control_two_code_areas(self):
        d = ndsr([(6, 0x1000, C1), (7, 0x2000, K1), (6, 0x1000, C1), (7, 0x2100, K3)])
        self.assertEqual(sorted(k[0] for _, _, _, k in SS.ndsr_shaders(d, 'syn')), [0x11, 0x33])

    def test_3_pack_inside_another_file(self):
        f = b'NDVE' + bytes(0x24) + PACK; out = []
        SS.scan_blob(f, '/m.dat', out)
        self.assertEqual(sorted((w, k[0]) for w, _, _, k in out), [('/m.dat@0x28#NDSR@0x1000', 0x11), ('/m.dat@0x28#NDSR@0x1100', 0x22)])

    def test_4_bare_program(self):
        d = bytearray(0x2000)
        good = ctl(block=0x200, fill=4); d[0x100:0x1e0] = good; d[0x300:0x400] = bytes([0x44]) * 0x100   # control block 0x100..0x300, code right after
        d[0x800:0x8e0] = ctl(block=0xe0, fill=5); d[0x8e0:0x9e0] = bytes([0x55]) * 0x100                  # BNSH's +0x30 = 0xe0: not bare
        d[0xc00:0xce0] = ctl(block=0, fill=6); d[0xce0:0xde0] = bytes([0x66]) * 0x100                     # NDSR / memory's 0: not bare
        out = []; SS.scan_blob(bytes(d), '/b.bin', out)
        self.assertEqual([(w, st, c, k) for w, st, c, k in out], [('/b.bin#NVN2@0x100', 'cs', good, bytes([0x44]) * 0x100)])

    def test_5_bare_code_past_end(self):
        d = bytearray(0x400); d[0x100:0x1e0] = ctl(block=0x200, ncode=0x1000)
        out = []; SS.scan_blob(bytes(d), '/b.bin', out)
        self.assertEqual(out, [])

    def test_6_negative(self):
        out = []; SS.scan_blob(bytes(range(256)) * 64, '/n.bin', out); self.assertEqual(out, [])
        # a control section an NDSR pack inside the file already took (+0x30 written as a block length here) is not read again as bare
        c = ctl(block=0x200, fill=7); f = b'NDVE' + bytes(0x24) + ndsr([(6, 0x1000, c), (7, 0x1400, K1)])
        out = []; SS.scan_blob(f, '/m.dat', out)
        self.assertEqual([w for w, _, _, _ in out], ['/m.dat@0x28#NDSR@0x1000'])


def main():
    global SS
    # The real shader_split import reads only this isolated synthetic profile (never a user's game, never its CLI main())
    with tempfile.TemporaryDirectory(prefix='ndsr-bare-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NdsrBare))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'NDSR 条目流 + 裸 NVN2 程序：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
