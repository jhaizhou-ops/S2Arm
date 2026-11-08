#!/bin/bash
# 门禁覆盖：runtime/rewriter/rewriter.c runtime/rewriter/rewriter.h runtime/rewriter/main.c pack/stage_rewrite.sh
# 补丁包 [code] 段单测（改写器 S2A_CODE_PATCH / S2A_CODE_BUILD，补丁包_v1设计.md 12.11；合成 NSO，约 1 秒）：bash tests/code_patch_test.sh
# 合成 main 代码段（映像偏移；期望全部手算，不跑被测实现）：
#   0x0f8 nop  0x0fc nop  0x100 mov w8,#0x1400000  0x104 mov w9,#0x400000  0x108 ret          ← 甲处：前 8 字节 1f2003d5 1f2003d5
#   0x13c mov w0,#1  0x140 mov w8,#0x1400000  0x144 mov w9,#0x400000  0x148 ret              ← 乙处：前 4 字节 20008052，后同甲
#   0x17c mov w0,#1  0x180 mov w8,#0x1400000  0x184 mov w9,#0x400000  0x188 ret              ← 丙处：与乙逐字节同（乙丙特征相同 = 两处命中）
#   新字 mov w8,#0x800000 = 0x52a01008；原字 0x52a02808
# ① 同构建号、偏移 100、原字对 → 打；0x100 = 52a01008，code_patch.tsv 一行「100 已打 偏移」
# ② 同构建号、偏移 104 写 orig=52a02808（实际是 mov w9）→ 跳过、0x104 不变（52a08009）、日志有黄行
# ③ 构建号不同、偏移写错成 200、sig = 甲的前 8 | 后 4 → 特征唯一命中 0x100 → 打，结果行「100 已打 特征」
# ④ 构建号不同、sig = 乙的前 4 | 后 4（丙相同）→ 命中 2 处跳过；0x140 / 0x180 不变
# ⑤ 构建号不同、没 sig → 跳过
# ⑥ 行的模块是 sdk → main 不打、不写 main.code_patch.tsv
# ⑦ sig 里 ?? 通配：构建号不同、前 8 字节写成 1f20???? + nop → 第 3、4 字节通配仍唯一命中 0x100
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
"$PY" - "$T" "$REW" <<'PYEOF'
import os, struct, subprocess, sys
T, REW = sys.argv[1:]
bad = 0
def ck(name, ok):
    global bad; print(('通 ' if ok else '不通 ') + name); bad |= not ok
NOP, OLD, W9, RET, W0 = 0xD503201F, 0x52A02808, 0x52A08009, 0xD65F03C0, 0x52800020
NEW = 0x52A01008
words = {0xf8: NOP, 0xfc: NOP, 0x100: OLD, 0x104: W9, 0x108: RET,
         0x13c: W0, 0x140: OLD, 0x144: W9, 0x148: RET, 0x17c: W0, 0x180: OLD, 0x184: W9, 0x188: RET}
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
for o, w in words.items(): struct.pack_into('<I', text, o, w)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200; NCODE = 3
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * NCODE)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
BID = bytes(range(0x11, 0x21)); h[0x40:0x50] = BID; bid = BID.hex()   # 本包构建号 1112…20
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, bytes(0x1000)))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
open(T + '/main', 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(0x1000))
open(T + '/sites.tsv', 'w').write('模块\t偏移\t种类\t证据\n')
def le(w): return struct.pack('<I', w).hex()
def run(name, build, lines):
    out = f'{T}/{name}'; os.makedirs(out)
    p = f'{out}.patch.tsv'
    open(p, 'w').write(f'schema\t1\nprogram\t0100000000001000\nbuild\t{build}\nclass\tcorrectness\n\n[caps]\nfps60\t0\t# 别的段不影响\n[code]\n' + '\n'.join(lines) + '\n')
    r = subprocess.run([REW, T + '/main', out, 'main', T + '/sites.tsv'], env=dict(os.environ, S2A_CODE_PATCH=p, S2A_CODE_BUILD=bid), capture_output=True, text=True)
    img = open(out + '/main.patched.bin', 'rb').read() if os.path.exists(out + '/main.patched.bin') else b''
    w = lambda o: struct.unpack_from('<I', img, o)[0] if len(img) >= o + 4 else None
    tsv = open(out + '/main.code_patch.tsv').read() if os.path.exists(out + '/main.code_patch.tsv') else None
    return r.returncode, w, tsv, r.stdout + r.stderr
O, N = le(OLD), le(NEW)
rc, w, tsv, log = run('c1', bid, [f'main 100 orig={O} new={N}  # 甲'])
ck(f'① 同构建号按偏移打：rc 0、0x100 = 52a01008、结果行「100 已打 偏移」（rc={rc} 0x100={w(0x100) and hex(w(0x100))}）', rc == 0 and w(0x100) == NEW and '100\t已打\t偏移' in (tsv or ''))
rc, w, tsv, log = run('c2', bid.upper(), [f'main 104 orig={O} new={N}'])
ck(f'② 同构建号（大写也认）、原字不符 → 跳过、0x104 不变、黄行（0x104={w(0x104) and hex(w(0x104))}）', rc == 0 and w(0x104) == W9 and '跳过\t偏移' in (tsv or '') and '🟡' in log)
rc, w, tsv, log = run('c3', '00' * 16, [f'main 200 orig={O} new={N} sig={le(NOP)}{le(NOP)}|{le(W9)}'])
ck(f'③ 构建号不同、特征唯一命中 0x100 → 打，行「100 已打 特征」（0x100={w(0x100) and hex(w(0x100))}；0x140={w(0x140) and hex(w(0x140))}）', rc == 0 and w(0x100) == NEW and w(0x140) == OLD and '100\t已打\t特征' in (tsv or ''))
rc, w, tsv, log = run('c4', '00' * 16, [f'main 140 orig={O} new={N} sig={le(W0)}|{le(W9)}'])
ck('④ 构建号不同、特征命中 2 处 → 跳过、0x140 / 0x180 不变', rc == 0 and w(0x140) == OLD and w(0x180) == OLD and '命中 2 处' in (tsv or ''))
rc, w, tsv, log = run('c5', '00' * 16, [f'main 100 orig={O} new={N}'])
ck('⑤ 构建号不同、没 sig → 跳过、0x100 不变', rc == 0 and w(0x100) == OLD and '没有 sig' in (tsv or ''))
rc, w, tsv, log = run('c6', bid, [f'sdk 100 orig={O} new={N}'])
ck('⑥ 别的模块的行：main 不打、不写 main.code_patch.tsv', rc == 0 and w(0x100) == OLD and tsv is None)
rc, w, tsv, log = run('c7', '00' * 16, [f'main 100 orig={O} new={N} sig=1f20????{le(NOP)}|{le(W9)}'])
ck('⑦ sig 通配 ?? 仍唯一命中 0x100 → 打', rc == 0 and w(0x100) == NEW)
sys.exit(1 if bad else 0)
PYEOF
rc=$?; [ $rc = 0 ] && echo "补丁 [code] 单测全过" || echo "🔴 补丁 [code] 单测有不通"; exit $rc
