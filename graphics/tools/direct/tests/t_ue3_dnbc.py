#!/usr/bin/env python3
# Unreal Engine 3 包里的 NVN 着色器（11-02 普查 BioShock Infinite「直连抽取 0 支」）：translator/shader_split.py ue3_package / ue3_dnbc_shaders。期望按格式手写，不跑被测实现：
#   ① 整文件压缩的包（文件从 0 起是一串块）：解出的包与手放的原文逐字节相同
#   ② 摘要里带块表的包（表不按 4 字节对齐、前面是原样的摘要）：同上
#   ③ 包里压缩的着色器块里两条 DNBC 记录、中间夹别的字段：两条的代码段 / 控制段逐字节等于手放的，标签带块起点与记录偏移
#   ④ 明文文件里的着色器块（GlobalShaderCache-NX.bin）：同 ③
#   ⑤ DNBC 头的长度对不上（A 与 A + B 字段不一致）：判红退出，不猜
#   ⑥ 摘要块表指向的块，子块表加起来不等于块头的总长：判红退出（整文件压缩的判定只认头与子块表自洽的块；包都以同一标签开头，不能凭它判）
#   ⑦ 摘要块表是 24 字节一项 {u64 原偏移, u32 原长, u64 存储偏移, u32 存储长}（Outlast 2）：解出的包与手放的原文逐字节相同
#   ⑧ 整文件压缩、块大小 0x80000（Outlast 2）：同 ①
#   ⑨ LZ4 着色器记录 {u32 L, u8 0, u8, u16 控制段长, u16, u16 n, n × u16, LZ4 块到记录尾}（Outlast 2 GlobalShaderCache-Switch.bin、包里的材质着色器）：
#      两条（一条带 3 个 u16、一条不带）之间夹名字等别的字段：代码段 / 控制段逐字节等于手放的，标签带记录起点；解出来不是「代码 + 控制段」的假头不收
#   ⑩ 不压缩的包、摘要里碰巧凑出一张指向包头（偏移 0，也是块标签）的「块表」：原样返回（Outlast 2 的 32 KB 语音包曾因此判红）
# 控制段是否合法、属于哪一阶段由 shader_split 的 check / glslc_stage 判（别处有单测），这里换成按手放内容回答的替身，只测容器与记录切分
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import lz4.block

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
TAG = 0x9E2A83C1
CTL = bytes.fromhex('34127698') + bytes(0x40)   # 控制段：魔数 + 内容（替身 ctl_len 按全长）


def dnbc(code, ctl, tail=b'TEXCOORD0\0'):
    a, b = len(code), len(ctl)
    return b'DNBC' + struct.pack('<7I', 1, a, 0, b, a, len(tail), a + b) + code + ctl + tail


def shader_block(records, between=b'\x07\x00\x00\x00junk'):
    raw = between.join(records)
    comp = lz4.block.compress(raw, store_size=False)
    return struct.pack('<II', len(raw), len(comp)) + comp


def chunk(raw, bs=0x20000):
    blocks = [raw[i:i + bs] for i in range(0, len(raw), bs)]
    comp = [lz4.block.compress(b, store_size=False) for b in blocks]
    return struct.pack('<4I', TAG, bs, sum(map(len, comp)), len(raw)) + b''.join(struct.pack('<II', len(c), len(b)) for c, b in zip(comp, blocks)) + b''.join(comp)


CODE1, CODE2 = b'\x11' * 0x30, b'\x22' * 0x50
BODY = b'\x00' * 0x40 + shader_block([dnbc(CODE1, CTL), dnbc(CODE2, CTL)]) + b'\x55' * 0x30


CTL2 = bytearray(0x848); CTL2[:4] = bytes.fromhex('34127698')


def ctl2(ncode):
    c = bytearray(CTL2); struct.pack_into('<I', c, 0x704, ncode); return bytes(c)


def lz4rec(code, ctl, extra=()):
    comp = lz4.block.compress(code + ctl, store_size=False)
    body = struct.pack('<BBHHH', 0, 3, len(ctl), 0, len(extra)) + b''.join(struct.pack('<H', x) for x in extra) + comp
    return struct.pack('<I', len(body)) + body


class Ue3Dnbc(unittest.TestCase):
    def shaders(self, d, label='syn'):
        out = []; SS.ue3_dnbc_shaders(d, label, out); return out

    def test_1_whole_compressed(self):
        pkg = struct.pack('<I', TAG) + b'\x00' * 12 + BODY   # 原文：包头 + 正文
        f = chunk(pkg[:0x30]) + chunk(pkg[0x30:]) + b'\0' * 7
        self.assertEqual(SS.ue3_package(f, 'syn'), pkg)

    def test_2_chunk_table(self):
        head = struct.pack('<I', TAG) + b'summary-name\0'   # 摘要里的变长字串，表从奇数偏移开始
        parts = [BODY[:0x50], BODY[0x50:]]
        first = len(head) + 4 + 16 * len(parts); stored = []; off = first; uo = first
        for p in parts: c = chunk(p); stored.append((uo, len(p), off, len(c), c)); off += len(c); uo += len(p)
        f = head + struct.pack('<I', len(parts)) + b''.join(struct.pack('<4I', a, b, c, d) for a, b, c, d, _ in stored) + b''.join(x[4] for x in stored)
        want = f[:first] + BODY
        self.assertEqual(len(head) % 4, 1)
        self.assertEqual(SS.ue3_package(f, 'syn'), want)

    def test_3_records_in_package(self):
        got = self.shaders(BODY)
        self.assertEqual([(g[2], g[3]) for g in got], [(CTL, CODE1), (CTL, CODE2)])
        self.assertTrue(got[0][0].startswith('syn@0x48#DNBC@0x0'), got[0][0])   # 块起点 = 0x40 正文前缀 + 8 字节长度字段
        self.assertTrue(all(g[1] == 'fs' for g in got))

    def test_4_plain_file(self):
        got = self.shaders(b'GSMB' + b'\x01' * 12 + shader_block([dnbc(CODE2, CTL)]))
        self.assertEqual([(g[2], g[3]) for g in got], [(CTL, CODE2)])

    def test_5_bad_header(self):
        bad = bytearray(dnbc(CODE1, CTL)); struct.pack_into('<I', bad, 0x1c, 1)   # A + B 字段改错
        with self.assertRaises(SystemExit):
            self.shaders(shader_block([bytes(bad)]))

    def test_6_block_table(self):
        head = struct.pack('<I', TAG) + b'summary\0'
        c = bytearray(chunk(BODY)); first = len(head) + 4 + 16
        f = bytearray(head + struct.pack('<I', 1) + struct.pack('<4I', first, len(BODY), first, len(c)) + bytes(c))
        struct.pack_into('<I', f, first + 16, struct.unpack_from('<I', f, first + 16)[0] + 1)   # 第一个子块的存储长多 1：子块表加起来不等于块头总长
        with self.assertRaises(SystemExit):
            SS.ue3_package(bytes(f), 'syn')


    def test_7_wide_table(self):
        head = struct.pack('<I', TAG) + b'summary\0'
        parts = [BODY[:0x50], BODY[0x50:]]
        first = len(head) + 4 + 24 * len(parts); stored = []; off = first; uo = first
        for p in parts: c = chunk(p, 0x80000); stored.append((uo, len(p), off, len(c), c)); off += len(c); uo += len(p)
        f = head + struct.pack('<I', len(parts)) + b''.join(struct.pack('<QIQI', a, b, c, d) for a, b, c, d, _ in stored) + b''.join(x[4] for x in stored)
        self.assertEqual(SS.ue3_package(f, 'syn'), f[:first] + BODY)

    def test_8_whole_big_blocks(self):
        pkg = struct.pack('<I', TAG) + b'\x00' * 12 + BODY
        self.assertEqual(SS.ue3_package(chunk(pkg, 0x80000) + b'\0' * 3, 'syn'), pkg)

    def test_9_lz4_records(self):
        r1, r2 = lz4rec(CODE1, ctl2(len(CODE1))), lz4rec(CODE2, ctl2(len(CODE2)), (0, 1, 7))
        fake = struct.pack('<IBBHHH', 40, 0, 3, 0x848, 0, 0) + b'\x40' + b'not lz4 of code + control' * 2   # 头像、块解不出代码 + 控制段
        d = b'BMSG' + b'\x00' * 12 + fake + b'\x1c\0\0\0TMeshPaintDilatePixelShader\0' + r1 + b'GUID' * 4 + r2
        out = []; SS.ue3_lz4_shaders(d, 'syn', out)
        self.assertEqual([(o[2], o[3]) for o in out], [(ctl2(len(CODE1)), CODE1), (ctl2(len(CODE2)), CODE2)])
        self.assertEqual(out[0][0], f'syn#LZ4UE3@{d.find(r1):#x}')

    def test_10_uncompressed_false_table(self):
        pkg = struct.pack('<4I', TAG, 0x00c80372, 0x2e5, 5) + struct.pack('<I', 1) + struct.pack('<4I', 0, 5, 0, 0x10) + b'\x00' * 0x40   # 摘要里碰巧有「1 项、存储偏移 0（包头标签）、原长 = 包头 +12」
        self.assertEqual(SS.ue3_package(pkg, 'syn'), pkg)   # 存储偏移落在表前（包头）的不是块表：原样返回，不判红


def main():
    global SS
    # The real shader_split import reads only this isolated synthetic profile (never a user's game, never its CLI main())
    with tempfile.TemporaryDirectory(prefix='ue3-dnbc-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            SS.glslc_stage = lambda ctl, code: 'fs'
            SS.check = lambda where, st, ctl, code: None
            SS.ctl_len = lambda ctl: len(ctl)
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Ue3Dnbc))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    n, bad = result.testsRun, len(result.failures) + len(result.errors)
    print(f'{"✓" if not bad else "✗"} UE3 DNBC：{n} 项，{bad} 项不过')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
