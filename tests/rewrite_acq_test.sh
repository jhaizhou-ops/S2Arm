#!/bin/bash
# 门禁覆盖：runtime/rewriter/rewriter.c runtime/rewriter/rewriter.h runtime/rewriter/main.c
# 改写器「自旋取锁补 acquire」单测（rewriter.c acq_upgrade；合成 NSO，约 1 秒）：bash tests/rewrite_acq_test.sh
# 合成 main 代码段 7 组，各组首条在下表偏移、以 ret 收尾；期望全按 ARMv8 编码手算（ldaxr = ldxr | bit 15），不跑被测实现：
#   甲 0x100 标准自旋取锁：mov w9,#1; ldxr w10,[x8]; cbnz w10,←; stxr w10,w9,[x8]; cbnz w10,←ldxr; ldr w11,[x8,#4]  → ldxr 改 ldaxr
#   乙 0x140 同甲，出环先 dmb ish 再 ldr                                                                  → 不改
#   丙 0x180 同甲，出环先 ldar w11,[x8]                                                                    → 不改
#   丁 0x1c0 存零（放锁形状）：ldxr w9,[x8]; cmp w9,#1; b.ne ←; stxr w9,wzr,[x8]; cbnz w9,←; ldr          → 不改
#   戊 0x200 同甲但 stlxr（只有 release）                                                                  → 改
#   己 0x240 原子读改写：ldxr w10,[x8]; add w10,w10,#1; stxr w11,w10,[x8]; cbnz w11,←; ldr（环里不回头等） → 不改
#   庚 0x280 同甲、64 位 ldxr x10 / stxr w10,x9                                                            → 改
#   辛 0x2c0 同甲，出环只写（str w11,[x8,#4]; ret）                                                         → 不改
#   S2A_REWRITE_ACQ=0：七组都不改（负对照：关掉识别）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
"$PY" - "$T" "$REW" <<'PYEOF'
import os, struct, subprocess, sys
T, REW = sys.argv[1:]
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
RET, NOP, DMB, MOV_W9_1 = 0xD65F03C0, 0xD503201F, 0xD5033BBF, 0x52800029
def ldxr(rt, rn, x64=False): return (0xC85F7C00 if x64 else 0x885F7C00) | rn << 5 | rt
def stxr(rs, rt, rn, rel=False, x64=False): return (0xC8007C00 if x64 else 0x88007C00) | (0x8000 if rel else 0) | rs << 16 | rn << 5 | rt
def cbnz(rt, d): return 0x35000000 | ((d // 4) & 0x7FFFF) << 5 | rt
def bne(d): return 0x54000000 | ((d // 4) & 0x7FFFF) << 5 | 1
LDR_W11 = 0xB940050B          # ldr w11,[x8,#4]
STR_W11 = 0xB900050B          # str w11,[x8,#4]
LDAR_W11 = 0x88DFFD0B         # ldar w11,[x8]
CMP_W9_1 = 0x7100053F         # cmp w9,#1
ADD_W10 = 0x1100054A          # add w10,w10,#1
def lock(after, rel=False, x64=False):   # mov w9,#1 | ldxr | cbnz 回 ldxr | stxr | cbnz 回 ldxr | 出环
    return [MOV_W9_1, ldxr(10, 8, x64), cbnz(10, -4), stxr(10, 9, 8, rel, x64), cbnz(10, -12)] + after + [RET]
groups = {0x100: lock([LDR_W11]), 0x140: lock([DMB, LDR_W11]), 0x180: lock([LDAR_W11]),
          0x1c0: [ldxr(9, 8), CMP_W9_1, bne(-8), stxr(9, 31, 8), cbnz(9, -16), LDR_W11, RET],
          0x200: lock([LDR_W11], rel=True), 0x240: [ldxr(10, 8), ADD_W10, stxr(11, 10, 8), cbnz(11, -12), LDR_W11, RET],
          0x280: lock([LDR_W11], x64=True), 0x2c0: lock([STR_W11])}
LDX = {0x100: 0x104, 0x140: 0x144, 0x180: 0x184, 0x1c0: 0x1c0, 0x200: 0x204, 0x240: 0x240, 0x280: 0x284, 0x2c0: 0x2c4}   # 各组 ldxr 所在
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
for o, ws in groups.items():
    for k, w in enumerate(ws): struct.pack_into('<I', text, o + 4 * k, w)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200; NCODE = (0x300 - 0x100) // 4
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
def run(name, env):
    out = f'{T}/{name}'; os.makedirs(out)
    r = subprocess.run([REW, T + '/main', out, 'main', T + '/sites.tsv'], env=dict(os.environ, **env), capture_output=True, text=True)
    img = open(out + '/main.patched.bin', 'rb').read() if os.path.exists(out + '/main.patched.bin') else b''
    return r.returncode, (lambda o: struct.unpack_from('<I', img, o)[0] if len(img) >= o + 4 else None), r.stdout + r.stderr
env = {k: v for k, v in os.environ.items() if not k.startswith('S2A_')}
os.environ.clear(); os.environ.update(env)
want = {0x100: 1, 0x140: 0, 0x180: 0, 0x1c0: 0, 0x200: 1, 0x240: 0, 0x280: 1, 0x2c0: 0}
name = {0x100: '甲 标准自旋取锁 → 改', 0x140: '乙 出环先 dmb → 不改', 0x180: '丙 出环先 ldar → 不改', 0x1c0: '丁 存零（放锁形状）→ 不改',
        0x200: '戊 stlxr 只有 release → 改', 0x240: '己 原子读改写（不回头等）→ 不改', 0x280: '庚 64 位自旋取锁 → 改', 0x2c0: '辛 出环只写 → 不改'}
rc, w, log = run('on', {})
ck(f'开：改写退出 0（rc={rc}）', rc == 0)
for g, a in LDX.items():
    orig = struct.unpack_from('<I', text, a)[0]; exp = orig | 0x8000 if want[g] else orig
    got = w(a); ck(f'开：{name[g]}（{a:#x}：期望 {exp:08x} → 真结果 {got and format(got, "08x")}）', got == exp)
ck('开：日志写明共 3 处', '自旋取锁补 acquire：共 3 处' in log)
rc, w, log = run('off', {'S2A_REWRITE_ACQ': '0'})
same = all(w(a) == struct.unpack_from('<I', text, a)[0] for a in LDX.values())
ck(f'关（S2A_REWRITE_ACQ=0）：八组 ldxr 都不改（rc={rc}）', rc == 0 and same and '补 acquire' not in log)
print(f"{'🟢' if not bad else '🔴'} 改写器自旋取锁补 acquire：{'全通' if not bad else '有不通'}")
sys.exit(1 if bad else 0)
PYEOF
