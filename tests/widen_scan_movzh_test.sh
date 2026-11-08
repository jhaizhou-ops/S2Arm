#!/bin/bash
# 宽屏第二层候选扫描：movzh 显示高度（graphics/widen/scan/wide_scan.py _main_part，合成平铺映像，约 1 秒）：bash tests/widen_scan_movzh_test.sh
# 11-02 窄屏加高（智慧的再现 Duo：游戏按 1280×720 渲染、核心认不出 3D 投影竖向加不了）：宽度 MOVZ 配对的那条纯 MOVZ #高 也登记成候选，宿主按屏高填值。
# 编码按 AArch64 手算，不跑被测实现：MOVZ Wd,#i = 0x52800000 | i<<5 | d；MOVK Xd,#i,LSL#32 = 0xf2c00000 | i<<5 | d；RET = 0xd65f03c0
#   ① 0x00 movz w8,#1280 / 0x04 movz w9,#720 / ret            → 0x0 movz、0x4 movzh
#   ② 0x0c movz x8,#1920 / 0x10 movk x8,#1080,lsl#32 / ret    → 0xc movz + 0x10 i2h（高是 MOVK 打包：不单列 movzh，11-04 起单列 i2h，证据 = MOVK 字 + MOVZ 字）
#   ③ 0x118 movz w9,#720 / nop / ret（前面 64 条 nop，离 ① ② 的宽超出 ±16 条配对窗口）→ 不出
# 期望恰好 4 行。旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_movzh_test.sh（旧扫描器没有 0x4 movzh，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/main" <<'PYEOF'
import struct, sys
NOP, RET = 0xd503201f, 0xd65f03c0
w = [0x5280a008, 0x52805a09, RET]                 # ①
w += [0xd280f008, 0xf2c08708, RET]                # ② movz x8,#1920 / movk x8,#1080,lsl#32
w += [NOP] * 64                                   # 拉开距离：配对窗口 ±16 条
w += [0x52805a09, NOP, RET]                       # ③
open(sys.argv[1], 'wb').write(struct.pack(f'<{len(w)}I', *w))
PYEOF
"$PY" "$SCAN" "$T/main" --tsv "$T/sites.tsv" 2> "$T/scan.log" || { echo "不通 扫描器退出非 0"; cat "$T/scan.log"; echo "✗ widen_scan_movzh_test"; exit 1; }
got=$(tail -n +2 "$T/sites.tsv" | cut -f2-4 | tr '\t\n' ' ,')
want="0x0 movz 5280a008,0x4 movzh 52805a09,0xc movz d280f008,0x10 i2h f2c08708 d280f008,"
if [ "$got" = "$want" ]; then echo "通 movzh 只出 ① 的配对高、② MOVK 打包出 i2h 不出 movzh、③ 无配对不出（实得：${got}）"; echo "✓ widen_scan_movzh_test"; exit 0; fi
echo "不通 期望「${want}」，实得「${got}」"; cat "$T/scan.log"; echo "✗ widen_scan_movzh_test"; exit 1
