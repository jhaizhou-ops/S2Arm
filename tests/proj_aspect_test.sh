#!/bin/bash
# 镜头宽高比量具单测（tests/visual/proj_aspect.py，合成 GAL 录像，约 1 秒）：bash tests/proj_aspect_test.sh
# 录像里只有常量写入（SetBufferData 0x112），没有绘制 → 量具按写入次数挑主镜头。期望按矩阵手算（|P11| ÷ |P00|），不跑被测实现：
#   ① RE 引擎投影（10-21 怪猎 expD_t2 录像原样 16 个浮点：P00 −0.98472244、P11 2.1445067、z 列抖动 3.2e-7、w 位置 4.9）→ 2.1445067 ÷ 0.98472244 = 2.18
#   ①b 同一游戏 16:9 对照局（b_mhloop2 录像原样：P00 −1.2062848、P11 2.1445062，第 7 号浮点是 −1 不是 0——每组第 4 个放的是别的数据）→ 2.1445062 ÷ 1.2062848 = 1.78
#   ② 标准投影 P00 1.2063、P11 2.1445、w 行 (0,0,−1,0) → 1.78（旧形状照认）
#   ③ 只有杂数据：形状像投影但 P00 = 2e-4、P11 = 6000（视角不到 0.02°）→ 认不出，「主镜头宽高比 None」，退出码 1
# 旧代码反证：PA=<旧 proj_aspect.py> bash tests/proj_aspect_test.sh（旧版只认 P00 > 0、w 行第 4 个 = 0：① ①b 认不出；③报 3e7 量级的垃圾宽高比）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PA=${PA:-$H/tests/visual/proj_aspect.py}
PY=$(command -v python3); "$PY" -c "import numpy" 2> /dev/null || { echo "🔴 $PY 缺 numpy（tests/visual 量具要用）"; exit 1; }
"$PY" - "$T" <<'EOF'
import struct, sys
def rec(path, mats):
    b = bytearray(b'S2AGAL01' + bytes(4)) + struct.pack('<II', 0xFFFFFFFF, 0xFFFFFFFF) + struct.pack('<I', 0)
    for k, m in enumerate(mats):
        d = struct.pack('<16f', *m); b += struct.pack('<II', 0x112, 16 + len(d)) + struct.pack('<QiI', 100 + k, 0, len(d)) + d
    open(path, 'wb').write(b)
RE = [-9.8472244e-01, 0, -6.5256767e-12, 3.2584134e-07, 0, 2.1445067, 0, 0, 3.2086328e-07, 0, -2.0027161e-05, 1, 1.5722301e-06, -3.6456616, 9.9903874e-02, 4.9]
RE2 = [-1.2062848, 0, -6.5256767e-12, 3.2584134e-07, 0, 2.1445062, 0, -1, 3.9305743e-07, 0, -2.0027161e-05, 1, 1.9259815e-06, -3.6456594, 9.9903874e-02, 4.9]
STD = [1.2063, 0, 0, 0, 0, 2.1445, 0, 0, 0, 0, -1.0001, -0.10001, 0, 0, -1, 0]
JUNK = [2e-4, 0, 0, 0, 0, 6000, 0, 0, 0, 0, 0.5, 0, 0, 0, 1, 0]
rec(sys.argv[1] + '/re.rec', [RE]); rec(sys.argv[1] + '/re2.rec', [RE2]); rec(sys.argv[1] + '/std.rec', [STD]); rec(sys.argv[1] + '/junk.rec', [JUNK])
EOF
for n in re re2 std junk; do "$PY" "$PA" "$T/$n.rec" --target 2346/1080 > "$T/$n.txt" 2>&1; echo "rc=$?" >> "$T/$n.txt"; done
m() { sed -nE 's/^主镜头宽高比 ([^ ]+) .*/\1/p' "$T/$1.txt"; }
ck "① RE 引擎投影 → 2.18、退出码 0（实得 $(m re)）" '[ "$(m re)" = 2.18 ] && grep -q "^rc=0" "$T/re.txt"'
ck "①b RE 引擎 16:9 对照局投影 → 1.78、退出码 1（实得 $(m re2)）" '[ "$(m re2)" = 1.78 ] && grep -q "^rc=1" "$T/re2.txt"'
ck "② 标准投影 → 1.78、退出码 1（实得 $(m std)）" '[ "$(m std)" = 1.78 ] && grep -q "^rc=1" "$T/std.txt"'
ck "③ 杂数据 → None、退出码 1（实得 $(m junk)）" '[ "$(m junk)" = None ] && grep -q "^rc=1" "$T/junk.txt"'
[ $bad = 0 ] && echo "镜头宽高比量具 期望 4 项全通 → 全通" || { echo "镜头宽高比量具 期望 4 项全通 → 有不通"; exit 1; }
