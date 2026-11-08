#!/usr/bin/env python3
# Unreal 内嵌着色器逐支 Oodle 压缩（11-01 无主之地3：两套抽取 0 支）：translator/shader_split.py ue_inline_shaders / oodle_frames。
#   每支代码 = u64 原长 + i32 数组长 + 一条 Oodle 流（每 256 KiB 块：2 字节块头，低 4 位 0xC、第 6 位存储块；非存储块再跟 3 字节大端量子头，低 18 位 = 压缩长 - 1）。
#   游戏解码器换成替身（记下被调的流），期望按上面的规则手算，不跑被测实现推：
#   ① 合法单块流：调一次解码器、出 1 支 vs，标签 = 「标签#UE<Oodle 头偏移>」，控制段 / 代码区逐字节等于手放的
#   ② 1120 字节声称 6.6 MB（真包里让游戏解码器 Break 的那种假候选）：解码器一次都不调、0 支、不报红
#   ③ 两块流（原长 256 KiB + 100）：帧结构成立；少一个字节 / 多一个字节 / 第二块换压缩器都不成立
#   ④ 存储块（块头 0xCC，后跟原样 256 KiB 以内的字节）：帧结构成立
#   ⑤ 解码器拒收（替身回 None）：0 支、不报红
#   ⑥ 勇者斗恶龙 XI S 的 zlib 写法（i32 长度 + zlib 流 → LSLG）照常出 1 支
#   ⑦ 裸 LSLG 前 4 字节碰巧像长度、区间里有控制段但代码长 0（11-01 无主之地3 Geranium.pak：Oodle 流字面量里的 LSLG）：不认、不报红（修前认成空代码像素着色器报红）
import os, struct, sys, tempfile, unittest, zlib
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
CTL = bytes.fromhex('34127698'); GFX = bytes.fromhex('78563412')


def record(tag=b'SV'):
    code = GFX + bytes(range(4, 0x40))
    ctl = bytearray(0x880); ctl[0:4] = CTL; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, len(code))
    return b'LSLG' + tag + bytes(10) + struct.pack('<I', len(code)) + code + struct.pack('<I', 0x880) + bytes(ctl) + bytes(24), bytes(ctl), code


def block(payload, first=True, kind=0x0c, stored=False):
    if stored: return bytes([0xcc if first else 0x4c, kind]) + payload
    return bytes([0x8c if first else 0x0c, kind]) + (len(payload) - 1).to_bytes(3, 'big') + payload


def array(stream, raw):
    return struct.pack('<Q', raw) + struct.pack('<i', len(stream)) + stream


class UeOodleInline(unittest.TestCase):
    def setUp(self):
        self.calls = []; self.answer = {}
        def fake(comp, n, need=True):
            self.calls.append((bytes(comp), n)); return self.answer.get(bytes(comp))
        SS.oodle = fake

    def test_1_single_block(self):
        rec, ctl, code = record(); stream = block(b'\x11' * 50)
        self.answer[stream] = rec
        d = b'\0' * 7 + array(stream, len(rec)) + b'\0' * 9; at = 7 + 12
        out = []; SS.ue_inline_shaders(d, 'syn', out)
        self.assertEqual(self.calls, [(stream, len(rec))])
        self.assertEqual([(w, st) for w, st, _, _ in out], [(f'syn#UE{at:x}', 'vs')])
        self.assertEqual(out[0][2], ctl); self.assertEqual(out[0][3], code)

    def test_2_bogus_length_never_decoded(self):
        stream = block(b'\x22' * (1120 - 5))   # 帧结构只够 1120 字节的一块，原长却称 6685182（26 块）
        out = []; SS.ue_inline_shaders(b'\0' * 4 + array(stream, 6685182), 'syn', out)
        self.assertEqual((self.calls, out), ([], []))

    def test_3_two_blocks(self):
        raw = 0x40000 + 100
        s = block(b'\x33' * 900) + block(b'\x44' * 60, first=False)
        d = b'\0' * 12 + s + b'\0' * 8
        self.assertTrue(SS.oodle_frames(d, 12, len(s), raw))
        self.assertFalse(SS.oodle_frames(d, 12, len(s) - 1, raw))
        self.assertFalse(SS.oodle_frames(d, 12, len(s) + 1, raw))
        s2 = block(b'\x33' * 900) + block(b'\x44' * 60, first=False, kind=0x06)
        self.assertFalse(SS.oodle_frames(s2, 0, len(s2), raw))

    def test_4_stored_block(self):
        s = block(b'\x55' * 300, stored=True)
        self.assertTrue(SS.oodle_frames(s, 0, len(s), 300))
        self.assertFalse(SS.oodle_frames(s, 0, len(s), 301))

    def test_5_decoder_rejects(self):
        stream = block(b'\x66' * 50)   # self.answer 里没有 → 替身回 None
        out = []; SS.ue_inline_shaders(array(stream, 4000), 'syn', out)
        self.assertEqual((len(self.calls), out), (1, []))

    def test_6_zlib_kept(self):
        rec, ctl, code = record(b'SP'); z = zlib.compress(rec)
        d = b'\0' * 3 + struct.pack('<i', len(z)) + z
        out = []; SS.ue_inline_shaders(d, 'syn', out)
        self.assertEqual([(w, st) for w, st, _, _ in out], [(f'syn#UE{7:x}', 'ps')])
        self.assertEqual((out[0][2], out[0][3]), (ctl, code))


    def test_7_empty_code_not_a_shader(self):
        ctl = bytearray(0x880); ctl[0:4] = CTL; struct.pack_into('<I', ctl, 0x20, 0x880)   # +0x704 代码长 = 0
        body = b'LSLG' + b'SP' + bytes(10) + struct.pack('<I', 0) + struct.pack('<I', 0x880) + bytes(ctl) + bytes(24)
        d = b'\0' * 8 + struct.pack('<I', len(body)) + body + b'\0' * 8
        out = []; SS.ue_inline_shaders(d, 'syn', out)
        self.assertEqual(out, [])


def main():
    global SS
    with tempfile.TemporaryDirectory(prefix='ue-oodle-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(UeOodleInline))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'Unreal 内嵌 Oodle 着色器：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
