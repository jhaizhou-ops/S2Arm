#!/bin/bash
# 改写器跳转分析遇到函数中间解不出的字单测（runtime/rewriter/rewriter.c analyze，合成 NSO，约 3 秒）：bash tests/rewrite_undecodable_word_test.sh
# 门禁覆盖：runtime/rewriter/*
# 来由：朋友收集 梦想生活（010051F0207B2000）main 函数 [0x136c990, 0x136d580) 在 0x136cb20 有一个解不出的字 0xe7ffdefe（未分配编码、执行即陷入）。
#   analyze 逐字解函数、遇到解不出的字就停，后面 0x136d0b4 / 0x136d140 两处按字节表跳的 br x18 没进跳转分析，落到 gensite 的 dynbr：
#   拿 x16 / x17 当临时寄存器取目标，而那里它们是循环的活寄存器 → 跳过去后 x16 = 目标地址，循环永不结束（11-04 jhz 手测卡在加载页）。
# 合成函数 [0x100, 0x13c)：b 0x108 / 0xe7ffdefe / cmp w10,#3 / b.hi 0x138 / adr x18,0x120 / ldrb w0,[x14,x10] / add x18,x18,x0,lsl #2 / br x18(0x11c) /
#   三对 nop + b 0x138 / ret(0x138)。编码由 llvm-mc -triple=aarch64 汇编得出。
# ① 苹果 / 安卓：0 缺口、退出码 0、没有 br_untracked、br = 1（字节表跳转按 brcompact 改写）
# ② br x18 改成的跳板第一条先存 x16（苹果 stur x16,[sp,#-0x10]；安卓 stp x16,x17,[sp,#-0x10]!）：取目标前 x16 / x17 的原值先存下、落点前还原。
#    旧路径 dynbr 第一条就是 mrs x16, tpidrro_el0（x16 原值丢掉）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/in/exefs"; $PY - "$T/in/exefs/main" <<'PYEOF'
import struct, sys
code = [0x14000002, 0xe7ffdefe, 0x71000d5f, 0x54000168, 0x10000092, 0x386a69c0, 0x8b000a52, 0xd61f0240,
        0xd503201f, 0x14000005, 0xd503201f, 0x14000003, 0xd503201f, 0x14000001, 0xd65f03c0]
# 模块骨架同 tests/rewrite_jt_open_test.sh：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
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
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
PYEOF
rew() { local o=$1; shift; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/in/exefs/main" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
ra=$(rew apple S2A_TARGET=apple); rn=$(rew android S2A_TARGET=android)
[ "$ra" = 0 ] || tail -5 "$T/apple.log"; [ "$rn" = 0 ] || tail -5 "$T/android.log"
# br 处的 B → 跳板第一条
first() { $PY - "$T/$1" 0x11c <<'PYEOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, a = sys.argv[1], int(sys.argv[2], 16)
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
w, = struct.unpack_from('<I', b, a)
if w >> 26 != 0b000101: print(f'不是 B：{w:#x}'); sys.exit()
imm = w & 0x3ffffff; t = a + 4 * (imm - (1 << 26) if imm >> 25 else imm)
i = next(md.disasm(b[t:t + 4], t)); print(f'{i.mnemonic} {i.op_str}')
PYEOF
}
for o in apple android; do
  ng=$(grep -c '^GAP' "$T/$o.log"); un=$(grep -o "'br_untracked': [0-9]*" "$T/$o.log"); br=$(grep -o "'br': [0-9]*" "$T/$o.log")
  r=$([ $o = apple ] && echo "$ra" || echo "$rn")
  ck "① ${o}：退出码 ${r}、缺口 ${ng}、${un:-无 br_untracked}、${br:-无 br}" '[ "$r" = 0 ] && [ "$ng" = 0 ] && [ -z "$un" ] && [ "$br" = "'"'"'br'"'"': 1" ]'
  fi=$(first $o 2>&1); want=$([ $o = apple ] && echo "stur x16, [sp, #-0x10]" || echo "stp x16, x17, [sp, #-0x10]!")
  ck "② ${o}：跳板第一条「${fi}」（期望「${want}」）" '[ "$fi" = "$want" ]'
done
[ $bad = 0 ] && echo "✅ 解不出的字之后的 br x18 照常进跳转分析" || { echo "🔴 解不出的字之后的 br x18 没进跳转分析"; exit 1; }
