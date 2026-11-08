#!/bin/bash
# 宽屏「宽高比上限」点单测（10-26 暗黑2 19:9 黑柱；graphics/widen/scan/wide_scan.py aspcap / aspcaps → 改写器跳板，合成 NSO，约 3 秒）：bash tests/widen_aspcap_test.sh
# 合成模块的代码段（从 0x100 起，下表偏移 + 0x100 = 模块偏移；期望按 AArch64 编码手算，不跑被测实现）：
#   0x00 movz w8,#0x1c72 = 0x52838e48 / 0x04 movk w8,#0x4007,lsl#16 = 0x72a800e8 / 0x08 fmov s1,w8 = 0x1e270101        19:9、先拿去算 → aspcap
#   0x0c movz w9,#0x1c72 = 0x52838e49 / 0x10 movk w9,#0x4007,lsl#16 = 0x72a800e9 / 0x14 str w9,[x8,#8] = 0xb9000909   19:9、先存进内存 → aspcaps
#   0x18 movz w10,#0x5555 = 0x528aaaaa / 0x1c movk w10,#0x4015,lsl#16 = 0x72a802aa / 0x20 fmov s2,w10 = 0x1e270142    21:9 → aspcap
#   0x24 movz w11,#0x1c72 / 0x28 movk w11,#0x4007 / 0x2c add w11,w11,#1 = 0x1100056b                                  先被别的指令用 → 不出
#   0x30 movz w12,#0x1c72 / 0x34 movk w12,#0x4008,lsl#16 = 0x72a8010c                                                 高半不是上限 → 不出
#   0x38 ret
# ① 扫描器只出 3 行：0x100 aspcap、0x10c aspcaps、0x118 aspcap
# ② 出包 C 改写器 0 缺口，widen.tsv = 0 0x100 aspcap 0x52838e48 / 1 0x10c aspcaps 0x52838e49 / 2 0x118 aspcap 0x528aaaaa
# ③ 0x100 跳板：adrp x8,键页 → str x8,[x8,#(1024+0)×8] → ldr w8,[x8,#(16+0)×8] → b 0x108（连 MOVK 一起换）；④ 0x10c 同理 x9、槽 1、b 0x114
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0x52838e48, 0x72a800e8, 0x1e270101, 0x52838e49, 0x72a800e9, 0xb9000909, 0x528aaaaa, 0x72a802aa, 0x1e270142,
        0x52838e4b, 0x72a800eb, 0x1100056b, 0x52838e4c, 0x72a8010c, 0xd65f03c0]
# 代码从 0x100 起；改写器要的模块骨架：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
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
EOF
$PY "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(tail -n +2 "$T/sites.tsv" | cut -f2,3 | tr '\t\n' ' ,')
ck "① 扫描器只出 0x100 aspcap / 0x10c aspcaps / 0x118 aspcap（实得：${got}）" '[ "$got" = "0x100 aspcap,0x10c aspcaps,0x118 aspcap," ]'
dis() { $PY - "$1" "$2" <<'EOF'
import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, a = sys.argv[1], int(sys.argv[2], 16)
key = next(int(l.split('\t')[1], 16) for l in open(d + '/main.fixups.tsv') if l.startswith('# KEY_PAGE_OFF\t'))
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
w, = struct.unpack_from('<I', b, a); assert w >> 26 == 0b000101, f'{a:#x} 不是 B：{w:#x}'
imm = w & 0x3ffffff; t = a + 4 * (imm - (1 << 26) if imm >> 25 else imm)
print(';'.join(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页').replace(f'#{a + 8:#x}', '#+8') for i in md.disasm(b[t:t + 16], t)))
EOF
}
for r in "C:$REW"; do
  nm=${r%%:*}; O=$T/out_$nm; mkdir -p "$O"
  ${r#*:} "$T/exefs/main" "$O" main "$T/sites.tsv" > "$T/rew_$nm.log" 2>&1; rc=$?; [ $rc = 0 ] || tail -5 "$T/rew_$nm.log"
  wt=$(tr '\t\n' ' ,' < "$O/main.widen.tsv" 2>/dev/null)
  ck "② $nm 改写器 0 缺口（rc=${rc}）、widen.tsv 三行（实得：${wt}）" '[ $rc = 0 ] && [ "$wt" = "0 0x100 aspcap 0x52838e48,1 0x10c aspcaps 0x52838e49,2 0x118 aspcap 0x528aaaaa," ]'
  t0=$(dis "$O" 0x100 2>&1); t1=$(dis "$O" 0x10c 2>&1)
  ck "③ $nm 0x100 跳板（实得：${t0}）" '[ "$t0" = "adrp x8, #键页;str x8, [x8, #0x2000];ldr w8, [x8, #0x80];b #+8" ]'
  ck "④ $nm 0x10c 跳板（实得：${t1}）" '[ "$t1" = "adrp x9, #键页;str x9, [x9, #0x2008];ldr w9, [x9, #0x88];b #+8" ]'
done
[ $bad = 0 ] && echo "✅ widen_aspcap_test 全过" || { echo "🔴 widen_aspcap_test 有不通项"; exit 1; }
