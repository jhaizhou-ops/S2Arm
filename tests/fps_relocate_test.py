#!/usr/bin/env python3
"""tools/fps_relocate.py 单测：合成两版镜像，期望按构造写死（不跑被测实现推导）。
真数据核过（10-29，写在工具文件头）：巫师3 4.04c → 4.04a 判同构（610 处全差 −0x1F0）；怪猎 3.9.0 → 15.0.0 数据段 / bss 不同、拒。"""
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import fps_relocate as fr

DATA, DSZ, BSS = 0x2000, 0x100, 0x80


def image(ptrs=None, extra=None):
    """镜像：代码 0–0x1000、只读 0x1000–0x2000、数据 0x2000–0x2100；数据里在 ptrs 给的位置放 8 字节指针值"""
    img = bytearray(DATA + DSZ)
    for i in range(DATA, DATA + DSZ, 8): img[i:i + 8] = struct.pack('<Q', 0x1234 + i)   # 普通数据
    for off, v in (ptrs or {}).items(): img[DATA + off:DATA + off + 8] = struct.pack('<Q', v)
    for off, v in (extra or {}).items(): img[DATA + off:DATA + off + 8] = struct.pack('<Q', v)
    return bytes(img)


def mod(img, bss=BSS, dsz=DSZ):
    return img, 'aa' * 16, [(0, 0x1000), (0x1000, 0x1000), (DATA, dsz)], bss


class Isomorphic(unittest.TestCase):
    def test_pointer_shift_only(self):
        # 两个指向代码的指针，新版代码段短 0x10：都差 −0x10 → 同构，2 处不同
        old = mod(image({0x10: 0x500, 0x40: 0x800}))
        new = mod(image({0x10: 0x4f0, 0x40: 0x7f0}))
        ok, why = fr.isomorphic(old, new)
        self.assertTrue(ok, why)
        self.assertIn('2 处不同', why)
        self.assertIn('-0x10', why)

    def test_identical(self):
        ok, why = fr.isomorphic(mod(image()), mod(image()))
        self.assertTrue(ok, why)
        self.assertIn('0 处不同', why)

    def test_two_deltas_rejected(self):
        # 一处差 −0x10、一处差 +0x4：数据本身改了，不同构
        old = mod(image({0x10: 0x500, 0x40: 0x800}))
        new = mod(image({0x10: 0x4f0, 0x40: 0x804}))
        ok, why = fr.isomorphic(old, new)
        self.assertFalse(ok)
        self.assertIn('差值不止一种', why)

    def test_bss_or_data_size_differs(self):
        self.assertFalse(fr.isomorphic(mod(image()), mod(image(), bss=BSS + 8))[0])
        self.assertFalse(fr.isomorphic(mod(image()), mod(image() + bytes(8), dsz=DSZ + 8))[0])


class Relocate(unittest.TestCase):
    TABLE = 'build 1fee6f3f1d2a6a91\npresent display\nw main 0x411dcfc i32 60   # 限帧\nslot 2041 f32 200 100\n'

    def test_build_line_replaced_rows_kept(self):
        body, bad = fr.relocate(self.TABLE, '4bc4a8a814fd46a4831b3aa8e689886b')
        self.assertEqual(bad, [])
        self.assertEqual(body.splitlines(), ['build 4bc4a8a814fd46a4', 'present display', 'w main 0x411dcfc i32 60   # 限帧', 'slot 2041 f32 200 100'])

    def test_code_rows_refused(self):
        _, bad = fr.relocate(self.TABLE + 'c main 0x100 word 3942f661 52800021\n', 'bb' * 16)
        self.assertEqual(bad, ['c main 0x100 word 3942f661 52800021'])


if __name__ == '__main__':
    unittest.main()
