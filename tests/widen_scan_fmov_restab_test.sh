#!/bin/bash
# 宽屏第二层候选扫描：movz 装浮点 + restab 档位表（graphics/widen/scan/wide_scan.py，合成平铺映像，约 1 秒）：bash tests/widen_scan_fmov_restab_test.sh
# 11-03 Pokopia（Switch 2）：主场景视口 = 缩放比 × 1920.0，1920.0 由 MOVZ Wd,#0x44f0,LSL#16 装浮点位；分辨率出自宽表紧跟高表的 u32 档位表
# 编码按 AArch64 手算，不跑被测实现：MOVZ Wd,#i,LSL#16 = 0x52a00000 | i<<5 | d；Xd 同形 0xd2a00000；1920.0f = 0x44f00000、1080.0f = 0x44870000
#   ① 0x00 movz w8,#0x44f0,lsl#16 / 0x04 nop / 0x08 movz w10,#0x4487,lsl#16 / 0x0c fmov s0,w8 / 0x10 fmov s1,w10 / ret → 0x0 movz、0x8 movzh
#      （FMOV Sd,Wn = 0x1e270000 | n<<5 | d：0x1e270100 / 0x1e270141）
#   ② 0x20 movz x8,#0x44f0,lsl#16（X 寄存器，无 MOVK 高）/ ret                      → 不出（X 写法归 f2w，要配 MOVK）
#   ③ 0x118 movz w9,#0x44f0,lsl#16 / fmov s0,w9 / ret（离 ① 的高超出 ±24 条，无配对）→ 不出
#   ③b 0x180 movz w8,#0x44f0,lsl#16 / movz w10,#0x4487,lsl#16 / ret（配对了但装完不当浮点用：多是预设表副本）→ 不出
#   ④ 0x200 档位表：宽 960,992,…,1920（每档 +32，31 档）,2560,3840 共 33 档，紧跟 33 个高（宽 × 9 / 16）→ 0x200 restab n=33
#   ⑤ 0x500 只有 3 档的表（1280,1600,1920 / 720,900,1080）→ 不出（不足 4 档）
# 期望恰好 3 行（扫描器按偏移排序）。旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_fmov_restab_test.sh（旧扫描器三行都没有，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/main" <<'PYEOF'
import struct, sys
NOP, RET = 0xd503201f, 0xd65f03c0
w = [0x52a89e08, NOP, 0x52a890ea, 0x1e270100, 0x1e270141, RET]   # ① 0x00–0x14
w += [NOP] * (0x20 // 4 - len(w))
w += [0xd2a89e08, RET]                           # ② 0x20
w += [NOP] * (0x118 // 4 - len(w))               # 拉开距离到 0x118
w += [0x52a89e09, 0x1e270120, RET]               # ③
w += [NOP] * (0x180 // 4 - len(w))
w += [0x52a89e08, 0x52a890ea, RET]               # ③b
w += [NOP] * (0x200 // 4 - len(w))
tw = list(range(960, 1921, 32)) + [2560, 3840]   # ④ 33 档
w += tw + [x * 9 // 16 for x in tw]
w += [0] * (0x500 // 4 - len(w))
w += [1280, 1600, 1920, 720, 900, 1080]          # ⑤
w += [0] * 16
open(sys.argv[1], 'wb').write(struct.pack(f'<{len(w)}I', *w))
PYEOF
"$PY" "$SCAN" "$T/main" --tsv "$T/sites.tsv" 2> "$T/scan.log" || { echo "不通 扫描器退出非 0"; cat "$T/scan.log"; echo "✗ widen_scan_fmov_restab_test"; exit 1; }
got=$(tail -n +2 "$T/sites.tsv" | cut -f2-3 | tr '\t\n' ' ,')
want="0x0 movz,0x8 movzh,0x200 restab,"
ev=$(awk -F'\t' '$3=="restab"{print $4}' "$T/sites.tsv")
if [ "$got" = "$want" ] && [ "$ev" = "n=33,960×540..3840×2160" ]; then echo "通 浮点宽高配对出 movz / movzh、X 写法与无配对不出、33 档表出 restab、3 档不出（实得：${got} ${ev}）"; echo "✓ widen_scan_fmov_restab_test"; exit 0; fi
echo "不通 期望「${want} n=33,960×540..3840×2160」，实得「${got} ${ev}」"; cat "$T/scan.log"; echo "✗ widen_scan_fmov_restab_test"; exit 1
