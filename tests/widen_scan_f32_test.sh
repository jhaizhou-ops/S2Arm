#!/bin/bash
# 宽屏第二层候选扫描：f32 分辨率表只认代码段之后（graphics/widen/scan/wide_scan.py，审计 #829 F-scan-f32-text；合成不压缩的原版 NSO，约 1 秒）：bash tests/widen_scan_f32_test.sh
# 门禁覆盖：graphics/widen/scan/wide_scan.py
# 合成模块（同 widen_scan_aspf_test：text 0x1000 字节、ro 从内存 0x1000 起；期望按字节手算）：
#   text 0x200 = (1920.0, 1080.0),(1280.0, 720.0)  代码段里（指令流 / 字面量池凑巧）→ 不出
#   ro   0x1100 = (1920.0, 1080.0),(1280.0, 720.0) 代码段之后、紧挨另一档 16:9   → 出 0x1100 f32
# 旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_f32_test.sh（旧扫描器对整段映像 find，0x200 也出，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/exefs"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/exefs/main" <<'PYEOF'
import struct, sys
text, ro, data = bytearray(0x1000), bytearray(0x1000), bytearray(0x1000)
struct.pack_into('<ffff', text, 0x200, 1920.0, 1080.0, 1280.0, 720.0)
struct.pack_into('<ffff', ro, 0x100, 1920.0, 1080.0, 1280.0, 720.0)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
open(sys.argv[1], 'wb').write(bytes(h) + bytes(text) + bytes(ro) + bytes(data))
PYEOF
"$PY" "$SCAN" "$T/exefs" --tsv "$T/sites.tsv" 2> "$T/scan.log"
got=$(awk -F'\t' '$3 == "f32" { printf "%s,", $2 }' "$T/sites.tsv")
if [ "$got" = "0x1100," ]; then echo "通 f32 只出代码段之后的 0x1100（实得：${got}）"; echo "✓ widen_scan_f32_test"; exit 0; fi
echo "不通 期望「0x1100,」，实得「${got}」"; cat "$T/scan.log"; echo "✗ widen_scan_f32_test"; exit 1
