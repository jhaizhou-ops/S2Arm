#!/usr/bin/env python3
# BNSH 容器指针越界（10-30 超级机器人大战 X：465 MB 的文件里读到偏移 0x5381bbab670，struct.error 让整款一支直连着色器都出不了）：
#   translator/shader_split.py bnsh_shaders / scan_blob。期望按规则手写，不跑被测实现推：
#   ① 合法容器（字段都是相对容器起点的偏移）：读出 1 支 vs，键 = 「标签#BNSH@偏移#var0」，控制段 / 代码区逐字节等于手放的
#   ② 着色器指针越界的容器：不抛异常、不出着色器，SKIPPED 多一条、原因含「outside the file」
#   ③ 同一段数据里先越界容器、后合法容器（scan_blob）：越界的跳过，合法的照常读出 1 支（旧代码在 ② 处抛 struct.error，③ 一支都没有）
#   ④ 代码区越过文件尾：同 ② 跳过
#   ⑤ NVN2 程序槽 7 / 8 的任务 / 网格（11-05 时之笛：只读 6 个槽，3D 场景 466 支网格 + 11 支任务全不在映射表）：按控制段 +0x56 阶段字节 6 / 7 读成 ts / ms，代码区逐字节对
#   ⑥ 槽 6–8 里不是 NVN2 控制段的字（指出文件外 / 指向非 0x98761234 的数据）不当阶段记录：只出槽 4 的 ps，不报错
#   ⑦ 槽 7 里的 NVN2 控制段阶段字节不是 6 / 7（这里放计算 5）：整份报红退出（认不出的布局不静默收）
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
CTL = bytes.fromhex('34127698'); GFX = bytes.fromhex('78563412')


def container(sc=0x300, ncode=0x40, size=0x2000):
    """One BNSH: 1 variation, 1 program, a vertex shader with a 0x880-byte control section at 0x400 and a 0x40-byte code area at 0x1000 (offsets from the container start)"""
    d = bytearray(size)
    d[0:8] = b'BNSH\0\0\0\0'; struct.pack_into('<I', d, 0x1c, size); d[0x60:0x64] = b'grsc'
    struct.pack_into('<IQ', d, 0x7c, 1, 0x100)          # variation count, variation table
    struct.pack_into('<Q', d, 0x100 + 0x10, 0x200)      # variation 0 → program
    struct.pack_into('<Q', d, 0x200 + 8, sc)            # program → vertex shader record (other stages 0)
    struct.pack_into('<QQII', d, 0x300 + 8, 0x400, 0x1000, ncode, 0x880)
    d[0x400:0x404] = CTL; struct.pack_into('<I', d, 0x400 + 0x20, 0x880); struct.pack_into('<I', d, 0x400 + 0x704, 0x40)
    d[0x1000:0x1004] = GFX; d[0x1004:0x1040] = bytes(range(4, 0x40))
    return d


def nvn2_container(slots):
    """One BNSH whose one program has {slot: (stage byte, code fill byte)} NVN2 records, or a raw word where the value is an int; control sections 0xe0 bytes (version 0xc9,
    code length at +0x44), code areas 0x100 bytes"""
    d = bytearray(0x4000)
    d[0:8] = b'BNSH\0\0\0\0'; struct.pack_into('<I', d, 0x1c, len(d)); d[0x60:0x64] = b'grsc'
    struct.pack_into('<IQ', d, 0x7c, 1, 0x100); struct.pack_into('<Q', d, 0x100 + 0x10, 0x200)
    at = 0x400
    for si, rec in slots.items():
        if isinstance(rec, int): struct.pack_into('<Q', d, 0x200 + 8 + 8 * si, rec); continue
        stage, fill = rec
        c = bytearray(0xe0); c[:4] = CTL; c[4:8] = b'\xc9\0\0\0'; struct.pack_into('<I', c, 0x44, 0x100); c[0x56] = stage
        d[at + 0x20:at + 0x100] = c; d[at + 0x100:at + 0x200] = bytes([fill]) * 0x100
        struct.pack_into('<QQII', d, at + 8, at + 0x20, at + 0x100, 0x100, 0xe0); struct.pack_into('<Q', d, 0x200 + 8 + 8 * si, at)
        at += 0x300
    return bytes(d)


class BnshBounds(unittest.TestCase):
    def test_1_valid(self):
        d = bytes(container()); out = SS.bnsh_shaders(d, 0, 'syn')
        self.assertEqual([(w, st) for w, st, _, _ in out], [('syn#BNSH@0x0#var0', 'vs')])
        self.assertEqual(out[0][2], d[0x400:0x400 + 0x880]); self.assertEqual(out[0][3], d[0x1000:0x1040])

    def test_2_pointer_out(self):
        n = len(SS.SKIPPED); d = bytes(container(sc=0x5381bbab670))
        self.assertEqual(SS.bnsh_shaders(d, 0, 'syn'), [])
        self.assertEqual(len(SS.SKIPPED), n + 1); self.assertIn('outside the file', SS.SKIPPED[-1][1])

    def test_3_scan_keeps_the_good_one(self):
        bad, good = container(sc=0x5381bbab670), container()
        out = []; SS.scan_blob(bytes(bad + good), 'syn', out)
        self.assertEqual([(w, st) for w, st, _, _ in out], [(f'syn#BNSH@{len(bad):#x}#var0', 'vs')])

    def test_4_code_past_end(self):
        n = len(SS.SKIPPED); d = bytes(container(ncode=0x100000))
        self.assertEqual(SS.bnsh_shaders(d, 0, 'syn'), [])
        self.assertEqual(len(SS.SKIPPED), n + 1); self.assertIn('past the file end', SS.SKIPPED[-1][1])

    def test_5_nvn2_task_mesh_slots(self):
        d = nvn2_container({4: (1, 0x11), 7: (6, 0x22), 8: (7, 0x33)}); out = SS.bnsh_shaders(d, 0, 'syn')
        self.assertEqual(sorted((st, code[0]) for _, st, _, code in out), [('ms', 0x33), ('ps', 0x11), ('ts', 0x22)])
        self.assertEqual({SS.STAGE_NAME[st] for _, st, _, _ in out}, {'pixel', 'task', 'mesh'})

    def test_6_other_words_past_slot_5(self):
        d = bytearray(nvn2_container({4: (1, 0x11), 6: 0x10_0000, 7: 0x40}))
        self.assertEqual([st for _, st, _, _ in SS.bnsh_shaders(bytes(d), 0, 'syn')], ['ps'])

    def test_7_wrong_stage_in_slot_7(self):
        with self.assertRaises(SystemExit): SS.bnsh_shaders(nvn2_container({4: (1, 0x11), 7: (5, 0x22)}), 0, 'syn')


def main():
    global SS
    # The real shader_split import reads only this isolated synthetic profile (never a user's game, never its CLI main())
    with tempfile.TemporaryDirectory(prefix='bnsh-bounds-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(BnshBounds))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'BNSH 指针越界：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}；真实游戏未验')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
