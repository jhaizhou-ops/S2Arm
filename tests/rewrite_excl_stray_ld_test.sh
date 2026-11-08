#!/bin/bash
# 改写器独占窗口：两个 LL/SC 循环之间夹着别处的「clrex；ldaxr；cbz；b」（runtime/rewriter/rewriter.c find_windows），合成 NSO，约 3 秒：bash tests/rewrite_excl_stray_ld_test.sh
# 门禁覆盖：runtime/rewriter/*
# 取自 11-02 普查两款同一段库代码（01002B00111A2000 main 0x1049200、010089C00DA6A000 main 0x86cb50，改前各 4 处缺口、整个模块退出码 3）。合成代码段从 0x100 起，布局与原件逐条相同：
#   0x12c 的 ldaxr 后面是 cbz / b（不配独占存）；0x148 ldr w18 进寄存器，0x14c 起真 CAS 循环 ldaxr / cmp / b.ne / stlxr w0, w18 / cbnz
#   改前：窗口从 0x12c 一直扫到 0x158 的 stlxr，跨过 b、吞下 0x13c / 0x14c 两处跳转目标 → 窗口里有 b 断言失败 + 3 处「branch into window」
# 判据：苹果 / 安卓退出码 0、0 缺口；苹果产物 0x14c 改成跳补丁岛、岛里有 ldaxr + stlxr 且不再碰 x18；0x12c 原样还是 ldaxr；0x148 改成跳补丁岛（x18 在窗口外的读写照旧走单条改写）
# 指令用 clang 汇编（与被测改写器无关），地址手算
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
cat > "$T/c.s" <<'EOS'
.text
.p2align 2
a0:   ldaxr w16, [x13]
      cbnz w16, fail1
      stlxr w16, w10, [x13]
      cbnz w16, a0
      dmb ish
a1:   ldaxr w16, [x15]
      cbnz w16, clr2
      stlxr w17, wzr, [x15]
      cbnz w17, a1
      b loop
fail1: clrex
      ldaxr w13, [x11]
      cbz w13, out
      b a0
clr2: clrex
loop: cbz w16, out
      add x21, x15, w16, sxtw #2
      mov x22, x21
      ldr w18, [x22, #0x28]!
cas:  ldaxr w17, [x15]
      cmp w17, w16
      b.ne casf
      stlxr w0, w18, [x15]
      cbnz w0, cas
      b casd
casf: clrex
casd: cmp w16, w17
      mov w16, w17
      b.ne loop
out:  ret
EOS
xcrun clang -arch arm64 -c "$T/c.s" -o "$T/c.o" || { echo "🔴 汇编失败"; exit 1; }
otool -t "$T/c.o" | tail -n +3 | awk '{for (i = 2; i <= NF; i++) print $i}' > "$T/words"
$PY - "$T/words" "$T/exefs_main" <<'EOP'
import struct, sys
code = [int(w, 16) for w in open(sys.argv[1]).read().split()]
# 模块骨架同 tests/rewrite_excl_head_jt_adr_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[2], 'wb').write(bytes(h) + text + ro + data)
EOP
rew() { local r=$1 o=$2; shift 2; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$r" "$T/exefs_main" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
ra=$(rew "$REW" apple S2A_TARGET=apple); rn=$(rew "$REW" android S2A_TARGET=android)
for o in apple android; do
  r=$([ $o = apple ] && echo "$ra" || echo "$rn"); [ "$r" = 0 ] || grep -a '^GAP' "$T/$o.log" | head -5
  ng=$(grep -c '^GAP' "$T/$o.log")
  ck "① ${o}：退出码 ${r}、缺口 ${ng}（期望 0 / 0）" '[ "$r" = 0 ] && [ "$ng" = 0 ]'
done
out=$([ "$ra" = 0 ] && $PY - "$T/apple/main.patched.bin" <<'EOP' 2>&1
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
b = open(sys.argv[1], 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
def one(a): return next(md.disasm(b[a:a + 4], a))
def tgt(a):
    w, = struct.unpack_from('<I', b, a); imm = w & 0x3ffffff
    return a + 4 * (imm - (1 << 26) if imm >> 25 else imm) if w >> 26 == 0b000101 else None
p = tgt(0x14c); body = []
if p:
    for i in md.disasm(b[p:p + 256], p):
        body.append(i)
        if i.mnemonic == 'b': break
ms = [i.mnemonic for i in body]; regs = ' '.join(i.op_str for i in body)
ok = p is not None and 'ldaxr' in ms and 'stlxr' in ms and 'w18' not in regs and 'x18' not in regs
print('通' if ok else '不通', f'0x14c → 补丁岛 {p and hex(p)}：{" / ".join(ms)}（要有 ldaxr、stlxr，不碰 x18）')
s = one(0x12c); print('通' if s.mnemonic == 'ldaxr' else '不通', f'0x12c 原样：{s.mnemonic} {s.op_str}')
print('通' if tgt(0x148) else '不通', f'0x148 ldr w18 改成跳补丁岛：{one(0x148).mnemonic} {one(0x148).op_str}')
EOP
); echo "$out" | sed 's/^/  /'
ck "② 苹果产物三处都通（脚本出错也算不通）" '[ "$(echo "$out" | grep -c "^通")" = 3 ]'
[ $bad = 0 ] && echo "✅ 两个独占循环之间夹着不配对的 ldaxr 时窗口划对" || { echo "🔴 独占窗口划分有不通项"; exit 1; }
