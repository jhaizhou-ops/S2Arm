#!/bin/bash
# 宽屏第二层候选扫描：aspdiv 的除法形状（graphics/widen/scan/wide_scan.py _div_shape，合成平铺映像，约 1 秒）：bash tests/widen_scan_rectasp_test.sh
# 编码按 AArch64 手算，不跑被测实现：FSUB = 0x1e203800 | m<<16 | n<<5 | d；FDIV = 0x1e201800 | …；STR St,[Xn,#imm] = 0xbd000000 | (imm/4)<<10 | n<<5 | t；
#   LDP Wt,Wt2,[Xn,#imm] = 0x29400000 | (imm/4)<<15 | t2<<10 | n<<5 | t；SCVTF Sd,Wn = 0x1e220000 | n<<5 | d；FMOV Sd,Wn = 0x1e270000 | n<<5 | d；MOVZ Wd,#i,LSL#16 = 0x52a00000 | i<<5 | d
# 每块 6 字，除法在块内第 4 字（偏移 0x18·块号 + 0xc）：
#   ① 0x0c 视口矩形：fsub s1,s3,s1 / fsub s0,s0,s2 / fdiv s0,s1,s0 / str s0,[x9,#0xb0]（马车8 main 0x3cd314）           → 出
#   ② 0x24 同上但 str s0,[x9,#0xa8]（10-26 起写回偏移不限）                                                          → 出
#   ③ 0x3c 第一条 fsub 写 s4（fdiv 的源 s1 不是它算的）                                                              → 不出
#   ④ 0x54 str s5,[x9,#0xb0]（存的不是 fdiv 的结果，也不是 s0 + ret）                                                 → 不出
#   ⑤ 0x6c 矩形 getter：fdiv s0,s1,s0 后一条 ret（塞尔达 sead 视锥 getAspect 那种）                                  → 出
#   ⑥ 0x84 整数宽高相除：ldp w8,w9,[x0,#0x10] / scvtf s0,w8 / scvtf s1,w9 / fdiv s0,s0,s1（异度3 main 0xeb73ac）      → 出
#   ⑦ 0x9c 同上但 ldp w9,w8（先取的是高，不是宽）                                                                    → 不出
#   ⑧ 0xb4 宽 ÷ 常量高：movz w8,#0x4434,lsl#16（720.0f）/ fmov s1,w8 / scvtf s0,w9 / fdiv s0,s0,s1（银河 2 main 0x2fe4a0）→ 出
#   ⑨ 0xcc 同上但 360.0f（0x43b4，多半是角度）                                                                       → 不出
#   ⑩ 0xe4 同上但立即数 0x7fc0（拼出 NaN）；⑪ 0xfc 立即数 0x7f80（拼出 Inf）——潜水员戴夫 main 里有这种 MOVZ，旧扫描器 int(NaN) 抛错整款出包停 → 不出、不崩
#   ⑫ 0x114 存好的宽高相除 getter：ldp s0,s1,[x8,#8] / fdiv s0,s0,s1 / ret（奥德赛 main 0x9cf340）                    → 出
#   ⑬ 0x12c 同上但 ldp s1,s0（先取的是高）；⑭ 0x144 同上但 fdiv s1,s0,s1（结果不在 s0，不是 getter 的返回值）          → 不出
#   ⑮ 0x17c 矩形半宽 ÷ 半高（12 字一块，接在 ⑭ 后）：fsub s0,s0,s2 / fneg s2,s0 / fcmp s0,#0.0 / fcsel s0,s0,s2,gt / fmov s2,#0.5 / fmul s8,s0,s2 /
#       fsub s0,s1,s3 / fneg s1,s0 / fcmp s0,#0.0 / fcsel s0,s0,s1,gt / fmul s9,s0,s2 / fdiv s3,s8,s9（奥德赛 3CA12DFA main 0xa63d5c 同形；
#       fcmp s0,#0.0 的低 5 位是 8，不能当成写 s8）→ 出
#   ⑯ 0x1ac 同上但 fmov s2,#1.0（不是减半）→ 不出
# 期望：恰好 ① ② ⑤ ⑥ ⑧ ⑫ ⑮ 七行。旧代码反证：SCAN=<旧 wide_scan.py> bash tests/widen_scan_rectasp_test.sh（旧扫描器只认 ①，红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; SCAN=${SCAN:-$H/graphics/widen/scan/wide_scan.py}
"$PY" - "$T/main" <<'PYEOF'
import struct, sys
NOP, RET = 0xd503201f, 0xd65f03c0
rect = lambda f1, st: [NOP, f1, 0x1e223800, 0x1e201820, st, RET]
w = rect(0x1e213861, 0xbd00b120) + rect(0x1e213861, 0xbd00a920) + rect(0x1e213864, 0xbd00b120) + rect(0x1e213861, 0xbd00b125)
w += [NOP, 0x1e213861, 0x1e223800, 0x1e201820, RET, NOP]                       # ⑤
w += [0x29422408, 0x1e220100, 0x1e220121, 0x1e211800, RET, NOP]                # ⑥ ldp w8,w9,[x0,#0x10]
w += [0x29422009, 0x1e220100, 0x1e220121, 0x1e211800, RET, NOP]                # ⑦ ldp w9,w8,[x0,#0x10]
w += [0x52a88688, 0x1e270101, 0x1e220120, 0x1e211800, RET, NOP]                # ⑧ 720.0f
w += [0x52a87688, 0x1e270101, 0x1e220120, 0x1e211800, RET, NOP]                # ⑨ 360.0f
w += [0x52aff808, 0x1e270101, 0x1e220120, 0x1e211800, RET, NOP]                # ⑩ NaN
w += [0x52aff008, 0x1e270101, 0x1e220120, 0x1e211800, RET, NOP]                # ⑪ Inf
w += [NOP, NOP, 0x2d410500, 0x1e211800, RET, NOP]                              # ⑫ ldp s0,s1,[x8,#8] / fdiv s0,s0,s1 / ret
w += [NOP, NOP, 0x2d410101, 0x1e211800, RET, NOP]                              # ⑬ ldp s1,s0,[x8,#8]
w += [NOP, NOP, 0x2d410500, 0x1e211801, RET, NOP]                              # ⑭ fdiv s1,s0,s1
half = lambda k: [0x1e223800, 0x1e214002, 0x1e202008, 0x1e22cc00, k, 0x1e220808, 0x1e233820, 0x1e214001, 0x1e202008, 0x1e21cc00, 0x1e220809, 0x1e291903]
w += half(0x1e2c1002) + half(0x1e2e1002)                                         # ⑮ fmov s2,#0.5；⑯ fmov s2,#1.0
open(sys.argv[1], 'wb').write(struct.pack(f'<{len(w)}I', *w))
PYEOF
"$PY" "$SCAN" "$T/main" --tsv "$T/sites.tsv" 2> "$T/scan.log" || { echo "不通 扫描器退出非 0"; cat "$T/scan.log"; echo "✗ widen_scan_rectasp_test"; exit 1; }
got=$(tail -n +2 "$T/sites.tsv" | cut -f2-4 | tr '\t\n' ' ,')
want="0xc aspdiv 1e201820,0x24 aspdiv 1e201820,0x6c aspdiv 1e201820,0x84 aspdiv 1e211800,0xb4 aspdiv 1e211800,0x114 aspdiv 1e211800,0x17c aspdiv 1e291903,"
if [ "$got" = "$want" ]; then echo "通 aspdiv 除法形状只出 ① ② ⑤ ⑥ ⑧ ⑫ ⑮（实得：${got}）"; echo "✓ widen_scan_rectasp_test"; exit 0; fi
echo "不通 期望「${want}」，实得「${got}」"; cat "$T/scan.log"; echo "✗ widen_scan_rectasp_test"; exit 1
