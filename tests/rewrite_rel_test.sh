#!/bin/bash
# 门禁覆盖：runtime/rewriter/rewriter.c runtime/rewriter/rewriter.h runtime/rewriter/main.c
# 改写器「独占存补 release」单测（rewriter.c rel_upgrade；合成 NSO，约 1 秒）：bash tests/rewrite_rel_test.sh
# 合成 main 代码段 7 组，各组首条在下表偏移、以 ret 收尾；期望全按 ARMv8 编码手算（stlxr / stlxp = stxr / stxp | bit 15），不跑被测实现：
#   甲 0x100 续作挂链（极品飞车 main 0x756670 形态）：ldxp x12,x11,[x0]; cmp; b.ne; stxp w10,x1,x9,[x0]; cbnz → stxp 改 stlxp
#   乙 0x140 32 位读改写：ldxr w9,[x8]; add w9,w9,#1; stxr w10,w9,[x8]; cbnz                                 → stxr 改 stlxr
#   丙 0x180 已是 stlxr（ldaxr / stlxr 序列一致）                                                             → 不改
#   丁 0x1c0 字节宽：ldxrb w9,[x8]; stxrb w10,w11,[x8]; cbnz                                                  → stxrb 改 stlxrb
#   戊 0x200 前 16 条内没有独占取的 stxr（数据字形态）                                                        → 不改
#   己 0x280 CASP x0,x1,x2,x3,[x8]（同一编码类，bit 31 = 0）                                                   → 不改
#   庚 0x2c0 stxp 离 ldxp 17 条（超出 16 条）                                                                  → 不改
#   S2A_REWRITE_REL=0：七组都不改（负对照：关掉识别）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
"$PY" - "$T" "$REW" <<'PYEOF'
import os, struct, subprocess, sys
T, REW = sys.argv[1:]
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
RET, NOP = 0xD65F03C0, 0xD503201F
# 编码按 ARMv8-A「Load/store exclusive」手写：size 001000 o2 L o1 Rs o0 Rt2 Rn Rt
def ldxp(rt, rt2, rn): return 0xC87F0000 | rt2 << 10 | rn << 5 | rt                    # 64 位 ldxp
def stxp(rs, rt, rt2, rn): return 0xC8200000 | rs << 16 | rt2 << 10 | rn << 5 | rt      # 64 位 stxp
def ldxr(rt, rn): return 0x885F7C00 | rn << 5 | rt                                      # 32 位 ldxr
def ldaxr(rt, rn): return 0x885FFC00 | rn << 5 | rt
def stxr(rs, rt, rn): return 0x88007C00 | rs << 16 | rn << 5 | rt
def stlxr(rs, rt, rn): return 0x8800FC00 | rs << 16 | rn << 5 | rt
def ldxrb(rt, rn): return 0x085F7C00 | rn << 5 | rt
def stxrb(rs, rt, rn): return 0x08007C00 | rs << 16 | rn << 5 | rt
def casp(rs, rt, rn): return 0x48207C00 | rs << 16 | rn << 5 | rt                      # 64 位 CASP（bit 31 = 0、bit 30 = 1）
def cbnz(rt, d): return 0x35000000 | ((d // 4) & 0x7FFFF) << 5 | rt
def bne(d): return 0x54000000 | ((d // 4) & 0x7FFFF) << 5 | 1
CMP_X12_X10 = 0xEB0A019F      # cmp x12,x10
ADD_W9 = 0x11000529           # add w9,w9,#1
groups = {0x100: [ldxp(12, 11, 0), CMP_X12_X10, bne(-8), stxp(10, 1, 9, 0), cbnz(10, -16), RET],
          0x140: [ldxr(9, 8), ADD_W9, stxr(10, 9, 8), cbnz(10, -12), RET],
          0x180: [ldaxr(9, 8), ADD_W9, stlxr(10, 9, 8), cbnz(10, -12), RET],
          0x1c0: [ldxrb(9, 8), stxrb(10, 11, 8), cbnz(10, -8), RET],
          0x200: [NOP, stxr(10, 9, 8), RET],
          0x280: [casp(0, 2, 8), RET],
          0x2c0: [ldxp(12, 11, 0)] + [NOP] * 16 + [stxp(10, 1, 9, 0), RET]}
STX = {0x100: 0x10c, 0x140: 0x148, 0x180: 0x188, 0x1c0: 0x1c4, 0x200: 0x204, 0x280: 0x280, 0x2c0: 0x2c0 + 4 * 17}   # 各组独占存所在
want = {0x100: 1, 0x140: 1, 0x180: 0, 0x1c0: 1, 0x200: 0, 0x280: 0, 0x2c0: 0}
name = {0x100: '甲 续作挂链 stxp → stlxp', 0x140: '乙 32 位读改写 stxr → stlxr', 0x180: '丙 已是 stlxr → 不改', 0x1c0: '丁 字节宽 stxrb → stlxrb',
        0x200: '戊 前面没有独占取 → 不改', 0x280: '己 CASP → 不改', 0x2c0: '庚 离独占取 17 条 → 不改'}
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
for o, ws in groups.items():
    for k, w in enumerate(ws): struct.pack_into('<I', text, o + 4 * k, w)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200; NCODE = (0x340 - 0x100) // 4
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * NCODE)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100; h[0x40:0x50] = bytes(range(0x11, 0x21))
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, bytes(0x1000)))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
open(T + '/main', 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000))
open(T + '/sites.tsv', 'w').write('模块\t偏移\t种类\t证据\n')
def run(tag, env):
    out = f'{T}/{tag}'; os.makedirs(out)
    r = subprocess.run([REW, T + '/main', out, 'main', T + '/sites.tsv'], env=dict(os.environ, **env), capture_output=True, text=True)
    img = open(out + '/main.patched.bin', 'rb').read() if os.path.exists(out + '/main.patched.bin') else b''
    return r.returncode, (lambda o: struct.unpack_from('<I', img, o)[0] if len(img) >= o + 4 else None), r.stdout + r.stderr
env = {k: v for k, v in os.environ.items() if not k.startswith('S2A_')}
os.environ.clear(); os.environ.update(env)
rc, w, log = run('on', {})
ck(f'开：改写退出 0（rc={rc}）', rc == 0)
for g, a in STX.items():
    orig = struct.unpack_from('<I', text, a)[0]; exp = orig | 0x8000 if want[g] else orig
    got = w(a); ck(f'开：{name[g]}（{a:#x}：期望 {exp:08x} → 真结果 {got and format(got, "08x")}）', got == exp)
ck('开：日志写明共 3 处', '独占存补 release：共 3 处' in log)
rc, w, log = run('off', {'S2A_REWRITE_REL': '0'})
same = all(w(a) == struct.unpack_from('<I', text, a)[0] for a in STX.values())
ck(f'关（S2A_REWRITE_REL=0）：七组独占存都不改（rc={rc}）', rc == 0 and same and '补 release' not in log)
print(f"{'🟢' if not bad else '🔴'} 改写器独占存补 release：{'全通' if not bad else '有不通'}")
sys.exit(1 if bad else 0)
PYEOF
