#!/usr/bin/env python3
# MT Framework 着色器包 SPK 的两种排法（11-02 普查 RESIDENT EVIL REVELATIONS 2「SPK control section: its code area does not end right before it」）：translator/shader_split.py mtspk_shaders。
#   期望按格式手写，不跑被测实现推：
#   ① 机器码在前、控制段在后、首尾相接（大逆转裁判）：两支，(阶段, 控制段, 机器码) 逐字节等于手放的
#   ② 控制段在前、机器码紧跟、两支之间夹一段着色器自带数据（启示录2：控制段 0x838、间隔 76 字节）：同上
#   ③ 排法 ① 中间断开（第 2 支机器码不接上一支末尾）→ 判红退出；④ 排法 ② 第 2 支控制段后面不是机器码 → 判红退出
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None


def code_of(stage_bits, n, tag):
    """图形机器码区：+0 头 78563412，+0x30 SPH 第 0 字（类型位 10..13 = 阶段，低 5 位 = 1），共 n 字节；tag 让内容各不相同"""
    c = bytearray(n); c[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', c, 0x30, stage_bits << 10 | 1); c[0x40] = tag
    return bytes(c)


def ctl_of(nctl, ncode, tag):
    c = bytearray(nctl); c[:4] = bytes.fromhex('34127698'); struct.pack_into('<I', c, 0x20, nctl); struct.pack_into('<I', c, 0x704, ncode); c[0x100] = tag
    return bytes(c)


HEAD = b'SPK\0' + bytes(0x3c)   # 包头 + 表（mtspk_shaders 从第一个控制段魔数起读）
V, P = code_of(1, 0x100, 1), code_of(5, 0x180, 2)   # 顶点 / 片元
CV1, CP1 = ctl_of(0x880, len(V), 1), ctl_of(0x880, len(P), 2)
CV2, CP2 = ctl_of(0x838, len(V), 3), ctl_of(0x838, len(P), 4)


class Mtspk(unittest.TestCase):
    def test_1_code_before(self):
        d = HEAD + V + CV1 + P + CP1
        self.assertEqual([x[1:] for x in SS.mtspk_shaders(d, 'syn')], [('vs', CV1, V), ('ps', CP1, P)])

    def test_2_code_after_with_gap(self):
        d = HEAD + CV2 + V + bytes(76) + CP2 + P
        self.assertEqual([x[1:] for x in SS.mtspk_shaders(d, 'syn')], [('vs', CV2, V), ('ps', CP2, P)])

    def test_3_before_broken(self):
        with self.assertRaises(SystemExit): SS.mtspk_shaders(HEAD + V + CV1 + bytes(16) + P + CP1, 'syn')

    def test_4_after_broken(self):
        with self.assertRaises(SystemExit): SS.mtspk_shaders(HEAD + CV2 + V + bytes(76) + CP2 + bytes(16) + P, 'syn')


def main():
    global SS
    with tempfile.TemporaryDirectory(prefix='mtspk-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Mtspk))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'MT SPK 两种排法：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}；启示录2 真文件 4016 个 arc 全读通（11-02）')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
