#!/usr/bin/env python3
# nvn_uses 单测（10-21 pair）：手搓 ARM64 代码，按 RE 引擎（怪猎）的写法取 NVN 函数指针——函数开头 adrp x21 + add x21,#0x180 定表基址，
# 之后每个名字 adrp/add x1 → blr x19 → str x0,[x21,#槽]；读点 = adrp x8 页 + ldr x8,[x8,#表内偏移]。
# 期望（手算）：BindProgram 槽有 1 个读点 → 1；SetAlphaTest 槽没有读点 → 0；SetAlphaRef 有 2 个读点 → 2。
# 另核八方2（UE4）写法：加载器直存全局槽、调用处经 GOT 项读；重定位表解析。
# 旧代码反证：旧 nvn_uses 认不出「表基址在函数开头定好」的槽位，第 1 项三个数都是 0；不算 GOT 读，第 2 项 BindProgram 是 0。用法：t_nvn_uses.py [shbake 目录]；退出 0 = 全过
import sys, os, struct
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.argv = [sys.argv[0], '/nonexistent']   # nvn_uses 模块级会扫 argv[1] 目录：给个空目录名，只借它的 scan
src = open(os.path.join(D, 'nvn_uses.py')).read(); src = src[:src.index('\nnames = {')]
ns = {}; exec(compile(src, 'nvn_uses.py', 'exec'), ns)
def adrp(d, pc, tgt):
    imm = (tgt >> 12) - (pc >> 12); return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5) | d
def add(d, n, imm): return 0x91000000 | (imm << 10) | (n << 5) | d
def ldr(t, n, off): return 0xf9400000 | ((off // 8) << 10) | (n << 5) | t
def str_(t, n, off): return 0xf9000000 | ((off // 8) << 10) | (n << 5) | t
MOV_X0_X20, BLR_X19, RET = 0xaa1403e0, 0xd63f0260, 0xd65f03c0
STR_BASE, TAB = 0x1000, 0x2000
names = ['nvnCommandBufferBindProgram', 'nvnColorStateSetAlphaTest', 'nvnCommandBufferSetAlphaRef']
strs = b'\0'; so = {}
for n in names: so[n] = STR_BASE + len(strs); strs += n.encode() + b'\0'
slot = {names[0]: 0xb38, names[1]: 0x888, names[2]: 0xd08}
code = [RET, adrp(21, 4, TAB), add(21, 21, 0x180)]
for n in names:
    pc = len(code) * 4; code += [adrp(1, pc, so[n]), add(1, 1, so[n] & 0xfff), MOV_X0_X20, BLR_X19, str_(0, 21, slot[n])]
code += [RET]
for n, k in ((names[0], 1), (names[2], 2)):   # 读点
    for _ in range(k): pc = len(code) * 4; code += [adrp(8, pc, TAB), ldr(8, 8, 0x180 + slot[n]), BLR_X19, RET]
img = bytearray(0x3000); struct.pack_into(f'<{len(code)}I', img, 0, *code); img[STR_BASE:STR_BASE + len(strs)] = strs
fail = 0
got = ns['scan'](bytes(img), STR_BASE, names)
ok = got == {names[0]: 1, names[1]: 0, names[2]: 2}; fail += not ok
print(('✓ ' if ok else '✗ ') + f'表基址在函数开头定好的取函数写法：BindProgram 1 / SetAlphaTest 0 / SetAlphaRef 2 → 真结果 {[got[n] for n in names]}')
# 2) 八方2（UE4）写法：加载器 adrp 直存全局槽，调用处 adrp+ldr GOT 项（指向槽的相对重定位）再 ldr 函数指针。BindProgram 的 GOT 项读 3 次 → 3；SetAlphaTest 没有 GOT 读 → 0
G = 0x2800; code = [RET]
for n in names[:2]:
    pc = len(code) * 4; code += [adrp(1, pc, so[n]), add(1, 1, so[n] & 0xfff), MOV_X0_X20, BLR_X19, adrp(8, pc + 16, TAB), str_(0, 8, slot[n])]
code += [RET]
for _ in range(3): pc = len(code) * 4; code += [adrp(9, pc, G), ldr(9, 9, G & 0xfff), ldr(9, 9, 0), BLR_X19, RET]
img2 = bytearray(0x3000); struct.pack_into(f'<{len(code)}I', img2, 0, *code); img2[STR_BASE:STR_BASE + len(strs)] = strs
got2 = ns['scan'](bytes(img2), STR_BASE, names[:2], {TAB + slot[names[0]]: [G]})
ok = got2 == {names[0]: 3, names[1]: 0}; fail += not ok
print(('✓ ' if ok else '✗ ') + f'直存全局、调用处经 GOT 读：BindProgram 3 / SetAlphaTest 0 → 真结果 {[got2[n] for n in names[:2]]}')
# 3) 重定位表解析：手搓 MOD0 → .dynamic（DT_RELA 7 / DT_RELASZ 8）→ 两条 R_AARCH64_RELATIVE（1027）+ 一条别的类型，期望 {目标: [槽]} 只含两条相对重定位
im3 = bytearray(0x400); im3[0:4] = b'\0' * 4; struct.pack_into('<I', im3, 4, 0x10); im3[0x10:0x14] = b'MOD0'; struct.pack_into('<i', im3, 0x14, 0x100 - 0x10)
struct.pack_into('<qQqQqQ', im3, 0x100, 7, 0x200, 8, 72, 0, 0)
struct.pack_into('<QQqQQqQQq', im3, 0x200, 0x300, 1027, 0x2b38, 0x308, 1027, 0x2b38, 0x310, 257, 0x9999)
g3 = ns['got_of'](bytes(im3)); ok = g3 == {0x2b38: [0x300, 0x308]}; fail += not ok
print(('✓ ' if ok else '✗ ') + f'重定位表：0x2b38 ← [0x300, 0x308]、非相对重定位不收 → 真结果 {g3}')
print(f'期望 nvn_uses 3 项全过 → 真结果 失败 {fail} / 3')
sys.exit(1 if fail else 0)
