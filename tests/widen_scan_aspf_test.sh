#!/bin/bash
# 宽屏第二层候选扫描：单独的 16:9 浮点常量 aspf（graphics/widen/scan/wide_scan.py，合成不压缩的原版 NSO，约 1 秒）：bash tests/widen_scan_aspf_test.sh
# 合成模块（三段都不压缩，text 0x1000 字节、ro 从内存 0x1000 起、data 从 0x2000 起；期望按字节手算，不跑被测实现）：
#   text 0x80 = 0x3fe38e39   代码段里（指令流 / 字面量池里的同值不是数据常量）     → 不出
#   ro   0x1010 = 0x3fe38e39 代码段之后、4 字节对齐                              → 出 0x1010 aspf 3fe38e39
#   ro   0x1022 = 0x3fe38e39 没对齐                                              → 不出
#   ro   0x1040 = 0x3fe38e3b（十进制 1.777778 舍入成的浮点）                     → 出 0x1040 aspf 3fe38e3b
#   ro   0x1200 / 0x1204 = 0x3fe38e39 两个挨着（连排的常量表，不是单独的镜头宽高比）  → 都不出
# 期望：候选表 aspf 行恰好 0x1010 / 0x1040 两行。旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_aspf_test.sh（旧扫描器没有 aspf，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/exefs"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/exefs/main" <<'EOF'
import struct, sys
text, ro, data = bytearray(0x1000), bytearray(0x1000), bytearray(0x1000)
struct.pack_into('<I', text, 0x80, 0x3fe38e39)
struct.pack_into('<I', ro, 0x10, 0x3fe38e39); struct.pack_into('<I', ro, 0x22, 0x3fe38e39); struct.pack_into('<I', ro, 0x40, 0x3fe38e3b); struct.pack_into('<II', ro, 0x200, 0x3fe38e39, 0x3fe38e39)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100   # 标志 0：三段都不压缩
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
open(sys.argv[1], 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(data))
EOF
"$PY" "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(awk -F'\t' '$3 == "aspf" { printf "%s %s,", $2, $4 }' "$T/sites.tsv")
if [ "$got" = "0x1010 3fe38e39,0x1040 3fe38e3b," ]; then echo "通 aspf 只出代码段之后对齐的两处（实得：${got}）"; echo "✓ widen_scan_aspf_test"; exit 0; fi
echo "不通 期望「0x1010 3fe38e39,0x1040 3fe38e3b,」，实得「${got}」"; cat "$T/scan.log"; echo "✗ widen_scan_aspf_test"; exit 1
