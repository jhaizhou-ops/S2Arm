#!/usr/bin/env python3
# exe_shtab_programs 单测（10-21 gfxsh-extract）：手搓一个主程序镜像——两支顶点（基础 Type 0x21 / 实例化 Type 0x25 Flags 4）、三支片元（片元比顶点多一支：两列取值上限不同，表的列序与对齐唯一），
#   着色器块 = 0x40 字节引擎头 + 控制段；描述符（顶点 0x70、片元 0x30 字节，+0x20 指向块）；两个描述符指针数组（前一槽为空）；组合表 [(0,0),(1,1),(2,2),(1,3)]。
#   期望（手算）：表内程序 (v1,f1)、(v2,f2)、(v1,f3)，加实例化顶点 v2 × 基础顶点 v1 在表里配的 f1、f3 → 5 个；拿掉组合表 → 本款不适用。
# 旧代码反证：没有 exe_shtab_programs.py（导入失败 = 红）。用法：t_exe_shtab.py [shbake 目录]
import sys, os, struct
D = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, D)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
try: import exe_shtab_programs as E
except Exception as e: print(f'✗ 导入 exe_shtab_programs 失败：{e}'); print('期望 主程序内嵌着色器程序表 全过 → 真结果 失败 1 / 1'); sys.exit(1)
TEXT = 0x1000
def build(with_table=True):
    img = bytearray(0x8000); inv = {}; slots = set()
    def ptr(at, tgt): inv.setdefault(tgt, []).append(at); slots.add(at)
    BLK = 0x2000; sh = {}; blocks = {}
    for i, (k, st) in enumerate((('v1', 'vs'), ('v2', 'vs'), ('f1', 'ps'), ('f2', 'ps'), ('f3', 'ps'))):
        b = BLK + i * 0x200; c = b + 0x40; img[c:c + 4] = bytes.fromhex('34127698'); sh[c] = (k, st); blocks[k] = b
    VD = 0x4000; FD = 0x4400
    for i, (k, t, fl) in enumerate((('v1', 0x21, 0), ('v2', 0x25, 4))):
        d = VD + i * 0x70; struct.pack_into('<IIQ', img, d, t, 0, fl); ptr(d + 0x20, blocks[k])
    for i, (k, t, fl) in enumerate((('f1', 0x21, 0), ('f2', 0x25, 4), ('f3', 0x23, 0))):
        d = FD + i * 0x30; struct.pack_into('<IIQ', img, d, t, 0, fl); ptr(d + 0x20, blocks[k])
    VA = 0x5000; FA = 0x5100   # 下标 0 = 空槽（不写指针）
    for i in range(2): ptr(VA + 8 * (i + 1), VD + i * 0x70)
    for i in range(3): ptr(FA + 8 * (i + 1), FD + i * 0x30)
    if with_table:
        for j, (a, b) in enumerate(((0, 0), (1, 1), (2, 2), (1, 3))): struct.pack_into('<II', img, 0x6000 + 8 * j, a, b)
    for at, tg in [(a, t) for t, L in inv.items() for a in L]: struct.pack_into('<Q', img, at, 0xdead0000 + tg)   # 指针槽里写非零（真镜像里是重定位前的值）
    return bytes(img), inv, slots, sh
img, inv, slots, sh = build()
try:
    keys, arr, tab, at = E.find_tables(img, inv, slots, sh, TEXT)
    check(keys == {'vs': [None, 'v1', 'v2'], 'ps': [None, 'f1', 'f2', 'f3']} and at == 0x6008 and tab == [(1, 1), (2, 2), (1, 3)],
          f'认出两个描述符数组（下标 0 空槽）与组合表 @0x6008（首项全空去掉）→ 真结果 {keys} @{at:#x} {tab}')
    K, nt, nx = E.programs(img, keys, arr, tab)
    check(K == {('v1', 'f1'), ('v2', 'f2'), ('v1', 'f3'), ('v2', 'f1'), ('v2', 'f3')} and nt == 3 and nx == 2, f'程序：表内 3 + 实例化顶点配基础片元 2 → 真结果 {sorted(K)}（{nt} + {nx}）')
except ValueError as e: check(False, f'有表时应认出：{e}')
img, inv, slots, sh = build(with_table=False)
try: E.find_tables(img, inv, slots, sh, TEXT); check(False, '没有组合表时应报不适用，却认出了')
except ValueError as e: check('组合表' in str(e), f'没有组合表 → 本款不适用（{e}）')
print(f'期望 主程序内嵌着色器程序表 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
