#!/bin/bash
# 宽屏第二层候选扫描：整数分辨率表 i32（graphics/widen/scan/wide_scan.py，合成不压缩的原版 NSO，约 1 秒）：bash tests/widen_scan_i32_test.sh
# 合成模块（三段都不压缩，text 0x1000 字节、ro 从内存 0x1000 起、data 从 0x2000 起；期望按字节手算，不跑被测实现）：
#   text 0x100 = 1280,720,1920,1080   代码段里                                         → 不出
#   ro   0x1010 = 1280,720,1920,1080  代码段之后、对齐、两对连排（丝之歌 SwitchPlatform 默认组）→ 出 0x1010 i32 1280,720,1920,1080
#   ro   0x1040 = 1024,576,1280,720   同上（掌机组）                                    → 出 0x1040 i32 1024,576,1280,720
#   ro   0x1080 = 1920,1080           单独一对（不是表）                                → 不出
#   ro   0x10c2 = 1280,720,1920,1080  没对齐                                            → 不出
# 期望：候选表 i32 行恰好 0x1010 / 0x1040。旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_i32_test.sh（旧扫描器没有 i32，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/exefs"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/exefs/main" <<'PYEOF'
import struct, sys
text, ro, data = bytearray(0x1000), bytearray(0x1000), bytearray(0x1000)
struct.pack_into('<4I', text, 0x100, 1280, 720, 1920, 1080)
struct.pack_into('<4I', ro, 0x10, 1280, 720, 1920, 1080); struct.pack_into('<4I', ro, 0x40, 1024, 576, 1280, 720)
struct.pack_into('<2I', ro, 0x80, 1920, 1080); struct.pack_into('<4I', ro, 0xc2, 1280, 720, 1920, 1080)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100   # 标志 0：三段都不压缩
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
open(sys.argv[1], 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(data))
PYEOF
"$PY" "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(awk -F'\t' '$3 == "i32" { printf "%s %s;", $2, $4 }' "$T/sites.tsv")
want="0x1010 1280,720,1920,1080;0x1040 1024,576,1280,720;"
if [ "$got" = "$want" ]; then echo "通 i32 只出代码段之后、对齐、连排两对以上的两张表（实得：${got}）"; echo "✓ widen_scan_i32_test"; exit 0; fi
echo "不通 期望「${want}」，实得「${got}」"; cat "$T/scan.log"; echo "✗ widen_scan_i32_test"; exit 1
