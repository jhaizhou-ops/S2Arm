#!/bin/bash
# 宽屏第二层 seadasp（sead 透视投影读宽高比，10-30 参考 SavageWind 旷野之息原生移植 tools/patches.py persp_matrix）：扫描 + 改写成宿主门单测，合成 NSO，约 3 秒。
#   bash tests/widen_sead_test.sh。指令全部手写编码（不拷游戏字节），期望按 AArch64 编码与 graphics/widen/scan/wide_scan.py 规则手算，不跑被测实现：
#   代码段 0x100 起（模块偏移）：
#   0x100 ldr s1,[x0,#0x98] = 0xbd409801 / 0x104 fadd s1,s1,s1 / 0x108 ldp s2,s3,[x0,#0xac] = 0x2d558c02（tan、宽高比） / 0x10c ldp s4,s5,[x0,#0xb4] = 0x2d569404（偏移）
#     0x110–0x120 五条 str s?,[x1,#…] / 0x124 movz w8,#0xbf80,lsl#16（-1.0f） / 0x128 str w8,[x1,#0x38] / 0x12c ret      = 建矩阵函数（叶子，往 [X1] 写 6 次）
#   0x130 ldr s0,[x0,#0x98] / 0x134 ldr s1,[x0,#0xb0] = 0xbd40b001（宽高比） / 0x138 fmul / 0x13c ret             = 同族取值函数
#   0x140 ldr s0,[x0,#0x98] / 0x144 ldr s1,[x0,#0xac] = 0xbd40ac01（只读 tan） / 0x148 ret                       → 不出
#   0x900 同形状但带 bl（非叶子）、离建矩阵函数超过 0x600 字节                                                    → 不出
# ① 扫描器只出 2 行：0x108 seadasp、0x134 seadasp
# ② 改写器 0 缺口，widen.tsv = 0 0x108 seadasp 0x2d558c02 / 1 0x134 seadasp 0xbd40b001
# ③ 0x108 / 0x134 换成宿主门：原位是 B，门表 gates.tsv 两行种类 wide、号 0 / 1、原址 0x108 / 0x134
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }   # 出包同一入口
mkdir -p "$T/exefs" "$T/out"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0xbd409801, 0x1e212821, 0x2d558c02, 0x2d569404, 0xbd000021, 0xbd000822, 0xbd001423, 0xbd001824, 0xbd002825, 0x52b7f008, 0xb9003828, 0xd65f03c0,
        0xbd409800, 0xbd40b001, 0x1e210800, 0xd65f03c0,
        0xbd409800, 0xbd40ac01, 0xd65f03c0]
far = [0xbd409801, 0x2d558c02, 0x2d569404, 0x94000002, 0xbd000021, 0xbd000822, 0xbd001423, 0xbd001824, 0xbd002825, 0xbd003026, 0x52b7f008, 0xd65f03c0]
# 代码从 0x100 起；改写器要的模块骨架：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code); struct.pack_into('<%dI' % len(far), text, 0x900, *far)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 0x900 + 4 * len(far) - 0x100)
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
$PY "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(tail -n +2 "$T/sites.tsv" | cut -f2,3 | tr '\t\n' ' ,')
ck "① 扫描器只出 0x108 seadasp / 0x134 seadasp（实得：${got}）" '[ "$got" = "0x108 seadasp,0x134 seadasp," ]'
$PY "$H/tests/rewriter_exec.py" "$REW" "$T/exefs/main" "$T/out" main "$T/sites.tsv" > "$T/rew.log" 2>&1; rc=$?; [ $rc = 0 ] || tail -5 "$T/rew.log"
wt=$(tr '\t\n' ' ,' < "$T/out/main.widen.tsv" 2>/dev/null)
ck "② 改写器 0 缺口（rc=${rc}）、widen.tsv 两行（实得：${wt}）" '[ $rc = 0 ] && [ "$wt" = "0 0x108 seadasp 0x2d558c02,1 0x134 seadasp 0xbd40b001," ]'
gw=$(awk -F'\t' '$2 == "wide" { print $3 " " $4 }' "$T/out/main.gates.tsv" 2>/dev/null | sort | tr '\n' ',')
bb=$($PY -c "import struct,sys; b=open('$T/out/main.patched.bin','rb').read(); print(int(all(struct.unpack_from('<I',b,a)[0]>>26==0b000101 for a in (0x108,0x134))))" 2>/dev/null)
ck "③ 0x108 / 0x134 换成宿主门：原位是 B（${bb:-?}），门表 wide 行（号 原址）= 0 0x108 / 1 0x134（实得：${gw}）" '[ "${bb:-0}" = 1 ] && [ "$gw" = "0 0x108,1 0x134," ]'
[ $bad = 0 ] && echo "宽屏 seadasp 扫描 + 门 期望 3 项全通 → 全通" || { echo "宽屏 seadasp 扫描 + 门 期望 3 项全通 → 有不通"; exit 1; }
