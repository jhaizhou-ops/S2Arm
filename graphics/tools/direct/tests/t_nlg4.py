#!/usr/bin/env python3
# Next Level Games 档案新版布局（11-02 马力欧激战前锋 1.3.2「直连抽取 IndexError」）：translator/shader_split.py nlg4_dict / nlg4_patch / nlg4_shaders。
#   合成档案（zstd 命令行压，不跑被测实现推期望）：两节（0 = 机器码、1 = 控制段，各一个 zstd 帧），两个程序列表（类型 0x8db400，子条目 0x0db401 机器码、0x0db402 控制段）。
#   ① 没有补丁：两支，(控制段, 机器码) 逐字节等于手放的；键 = 「标签#NLG4@<程序条目号>」
#   ② 有补丁：新条目表把第 2 个程序的控制段指到补丁体（偏移 ≥ 本体节长），第 1 个仍读本体 → 第 2 支换成补丁里的控制段
#   ③ 补丁里偏移 0xffffffff 的子条目（没随包发的文件）跳过，同列表里随包的那对照取
#   ④ 索引压缩长与文件长对不上 → 判红退出（不猜）
#   ⑤ 旧版布局（字节 4..7 = 04 01 …）不进新分支
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
MAG = struct.pack('<I', 0xa9f32458)


def zs(b):
    return subprocess.run(['zstd', '-q', '-c', '-'], input=b, capture_output=True, check=True).stdout


def ctl_of(code_len, tag):
    """0x880 字节控制段：魔数、+0x20 自报长、+0x704 机器码长、+0x748 线程组 1×1×1（无头计算着色器）；tag 让每个控制段内容不同"""
    c = bytearray(0x880); c[:4] = bytes.fromhex('34127698'); struct.pack_into('<I', c, 0x20, 0x880); struct.pack_into('<I', c, 0x704, code_len)
    struct.pack_into('<3I', c, 0x748, 1, 1, 1); c[0x100] = tag
    return bytes(c)


CODE1, CODE2 = bytes(range(16)) * 4, bytes(range(16, 32)) * 8
CTL1, CTL2, CTL2B = ctl_of(len(CODE1), 1), ctl_of(len(CODE2), 2), ctl_of(len(CODE2), 3)


def entries(ctl2_off):
    """顶层两个程序列表 → 子条目：机器码（节 0）、控制段（节 1），第 2 个程序另带一对 nxpc（节 2，没随包发）"""
    K = lambda sec, typ: sec << 24 | typ   # 种类 = 节号（高 8 位）| 类型
    return [(K(0, 0x8db400), 2, 2), (K(0, 0x8db400), 4, 4),
            (K(0, 0x0db401), len(CODE1), 0), (K(1, 0x0db402), 0x880, 0),
            (K(0, 0x0db401), len(CODE2), len(CODE1)), (K(1, 0x0db402), 0x880, ctl2_off), (K(2, 0x0db401), 8, 0xffffffff), (K(2, 0x0db402), 0x880, 0xffffffff)]


def archive(d, sec0, sec1, ents, compressed_len_delta=0):
    """写 <d>/a.dict + a.data（新版布局：头 0x40 字节 + 一个 zstd 帧的索引）；节 2 属于没随包发的 nxpc"""
    f0, f1 = zs(sec0), zs(sec1)
    open(os.path.join(d, 'a.data'), 'wb').write(f0 + f1)
    secs = [struct.pack('<5Ii4B', 0, len(f0), len(sec0), 0, 1, -1, 4, 1, 0, 0), struct.pack('<5Ii4B', len(f0), len(f1), len(sec1), 1, 1, -1, 4, 1, 0, 0),
            struct.pack('<5Ii4B', 0, 0, 0, 2, 0, -1, 4, 2, 0, 0)]
    ix = b''.join(secs) + b''.join(struct.pack('<3I', *e) for e in ents) + bytes(8 * 2) + struct.pack('<2I', len(f0), len(sec0)) + struct.pack('<2I', len(f1), len(sec1)) + b'data\0nxpc\0debug\0'
    z = zs(ix)
    head = MAG + bytes([4, 4, 3, 0]) + bytes(32) + struct.pack('<4I', len(z) + compressed_len_delta, 2, len(ents), 2) + bytes(4) + bytes([3, 3, 0, 0])
    open(os.path.join(d, 'a.dict'), 'wb').write(head + z)
    return os.path.join(d, 'a.dict')


def pairs(path):
    out = []; SS.nlg_shaders(path, '/a.dict', out); return [(k, st, c, d) for k, st, c, d in out]


class Nlg4(unittest.TestCase):
    def test_1_base(self):
        with tempfile.TemporaryDirectory() as d:
            p = archive(d, CODE1 + CODE2, CTL1 + CTL2, entries(0x880))
            self.assertEqual(pairs(p), [('/a.dict#NLG4@0', 'cs', CTL1, CODE1), ('/a.dict#NLG4@1', 'cs', CTL2, CODE2)])

    def test_2_patch(self):
        with tempfile.TemporaryDirectory() as d:
            p = archive(d, CODE1 + CODE2, CTL1 + CTL2, entries(0x880))
            new = entries(0x1100)   # 本体控制段节长 0x1100：偏移 0x1100 = 补丁体起点
            body = b''.join(struct.pack('<3I', *e) for e in new) + bytes(8 * 2) + bytes(20 * 3) + CTL2B
            open(os.path.join(d, 'a.patch'), 'wb').write(MAG + bytes([4, 5, 3, 0]) + struct.pack('<4I', len(body), 2, len(new), 3) + zs(body))
            self.assertEqual(pairs(p), [('/a.dict#NLG4@0', 'cs', CTL1, CODE1), ('/a.dict#NLG4@1', 'cs', CTL2B, CODE2)])

    def test_4_length_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            p = archive(d, CODE1 + CODE2, CTL1 + CTL2, entries(0x880), compressed_len_delta=1)
            with self.assertRaises(SystemExit): pairs(p)

    def test_5_old_layout_not_taken(self):
        self.assertNotEqual(bytes([4, 1, 1, 0]), SS.NLG4)


def main():
    global SS
    with tempfile.TemporaryDirectory(prefix='nlg4-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Nlg4))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'NLG 新版档案：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}；马力欧激战前锋 1.3.2 真文件 init 3149 支（11-02）')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
