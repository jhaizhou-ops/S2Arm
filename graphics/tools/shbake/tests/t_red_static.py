#!/usr/bin/env python3
# red_static_programs 单测（10-21 pair）：
#  ① 条目键配方对游戏原值：巫师3 staticshadernx.cache 里 deferredLight.fx（宏 __XBOX_WAVESIM_ITERATION_N=1、STENCIL_TEX_FETCH_CHANNEL=0、IS_PURE_DEFERRED_LIGHT_POINT=1）
#     的 VS / PS 条目键 = 0xeaf842e76ea51bed / 0x47903a05b6fc1a3e（取自游戏缓存文件，不由本实现算出）；
#  ② 手搓 ARM64：adrp/add x1 "a.fx" → bl；adrp/add x1 "DEF" → bl；mov x1, x23（"1"）→ bl；adrp/add x1 "b.fx" → bl；期望两个窗口（a.fx: [DEF, 1]，b.fx: []）。
# 旧代码反证：没有 red_static_programs.py（导入失败 = 红）。用法：t_red_static.py [shbake 目录]
import sys, os, struct
D = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, D)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
try: import red_static_programs as R
except Exception as e: print(f'✗ 导入 red_static_programs 失败：{e}'); print('期望 REDengine 静态程序 全过 → 真结果 失败 1 / 1'); sys.exit(1)
d = [('__XBOX_WAVESIM_ITERATION_N', '1'), ('STENCIL_TEX_FETCH_CHANNEL', '0'), ('IS_PURE_DEFERRED_LIGHT_POINT', '1')]
hv, hp = R.key_hash('deferredLight.fx', d, 0), R.key_hash('deferredLight.fx', d, 1)
check(hv == 0xeaf842e76ea51bed and hp == 0x47903a05b6fc1a3e, f'条目键配方 = 游戏缓存原值（VS 0xeaf842e76ea51bed / PS 0x47903a05b6fc1a3e）→ 真结果 {hv:#x} / {hp:#x}')
STR = 0x2000
strs = {}; blob = b''
for s_ in ('a.fx', 'DEF', '1', 'b.fx'): strs[s_] = STR + len(blob); blob += s_.encode() + b'\0'
def adrp(dr, pc, tgt):
    imm = (tgt >> 12) - (pc >> 12); return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5) | dr
def add(dr, nr, imm): return 0x91000000 | (imm << 10) | (nr << 5) | dr
def bl(pc, tgt): return 0x94000000 | (((tgt - pc) >> 2) & 0x3ffffff)
MOV_X1_X23 = 0xaa1703e1; RET = 0xd65f03c0; F = 0x1000
code = []
def emit(w): code.append(w)
def load(reg, s_): pc = len(code) * 4; emit(adrp(reg, pc, strs[s_])); emit(add(reg, reg, strs[s_] & 0xfff))
load(23, '1'); load(1, 'a.fx'); emit(bl(len(code) * 4, F)); load(1, 'DEF'); emit(bl(len(code) * 4, F)); emit(MOV_X1_X23); emit(bl(len(code) * 4, F))
load(1, 'b.fx'); emit(bl(len(code) * 4, F)); emit(RET)
img = bytearray(0x3000); struct.pack_into(f'<{len(code)}I', img, 0, *code); img[STR:STR + len(blob)] = blob
ws = R.windows(bytes(img), 0x1000)
check(ws == [('a.fx', ['DEF', '1']), ('b.fx', [])], f'窗口：a.fx → [DEF, 1]（"1" 经 mov x1, x23 带来），b.fx → [] → 真结果 {ws}')
# ③ 曲面细分按接口接到已配出的 vs + ps（10-21 gfxsh-extract）：手搓 SPH——vs1 写 0b1111、vs2 写 0b11；hs 读 0b1111 写 0xff；ds 读 0xff 写 0b1111；
#    ps1 读属性 0.x、ps2 读属性 1.x；已配程序 (vs1,ps1)(vs1,ps2)(vs2,ps1)。期望（手算）：只有 vs1（写 = hs 读）、只有 ps1（读 ⊆ ds 写）→ {(vs1, hs, ds, -, ps1)}
def sph_code(kind, im=0, om=0, ps_attrs=()):
    h = bytearray(0x50); h[0] = kind
    def setb(b): h[b >> 3] |= 1 << (b & 7)
    for i in range(128):
        if im >> i & 1: setb(192 + i)
        if om >> i & 1: setb(432 + i)
    for a, c in ps_attrs: setb(192 + a * 8 + c * 2)
    return bytes(0x30) + bytes(h)
C = {'vs1': sph_code(1, 0, 0b1111), 'vs2': sph_code(1, 0, 0b11), 'hs1': sph_code(1, 0b1111, 0xff), 'ds1': sph_code(1, 0xff, 0b1111),
     'ps1': sph_code(2, ps_attrs=[(0, 0)]), 'ps2': sph_code(2, ps_attrs=[(1, 0)])}
import tempfile, collections
with tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False) as f:
    f.write('# 键\t阶段\t来源\t变体号\n')
    for k in C: f.write(f'{k}\t{k[:2]}\tcontent/content0/staticshadernx.cache@zs0x1@adj0x0\t0\n')
try: tp = R.tess_programs(f.name, {('vs1', 'ps1'), ('vs1', 'ps2'), ('vs2', 'ps1')}, collections.Counter(), code_of=lambda k: C[k])
except Exception as e: tp = f'异常 {e}'
os.unlink(f.name)
check(tp == {('vs1', 'hs1', 'ds1', '-', 'ps1')}, f'曲面：vs 写 = hs 读、ps 读 ⊆ ds 写、ps 取 vs 已配的 → 真结果 {tp}')
print(f'期望 REDengine 静态程序 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
