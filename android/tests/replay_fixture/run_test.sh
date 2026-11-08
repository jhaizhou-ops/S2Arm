#!/usr/bin/env bash
# S2RF 夹具宿主自检：不依赖 Metal / 真机 / Vulkan，一台能跑 cc 的机器就够。
#   bash android/tests/replay_fixture/run_test.sh
# 做什么：编 rfx.c + 工具 + 单测 → 跑 t_rfx（含样例解析）→ rfx_gen 重出样例到临时目录 →
#   与提交的 samples/ 逐字节比（证明生成器与金样一致、可重现）。
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../../.." && pwd)
CC=${CC:-cc}
CF="-std=c11 -Wall -Wextra -Werror -O1 -I$D -I$R/graphics/nvn/gfx/nvn -I$R/graphics/nvn/gfx/nvn/include"
out=$(mktemp -d "${TMPDIR:-/tmp}/rfx-build.XXXXXX")
trap 'rm -rf "$out"' EXIT

$CC $CF -o "$out/rfx_cmp" "$D/rfx_cmp.c" "$D/rfx.c"
$CC $CF -o "$out/t_rfx" "$D/t_rfx.c" "$D/rfx.c"
$CC $CF -o "$out/rfx_gen" "$D/rfx_gen.c" "$D/rfx.c" "$R/graphics/nvn/gfx/nvn/nvn_tex.c"

"$out/t_rfx" "$D/samples"
mkdir -p "$out/gen"
"$out/rfx_gen" "$out/gen"
for f in "$D"/samples/*.rfx; do
    n=$(basename "$f")
    cmp -s "$f" "$out/gen/$n" || { echo "【红】金样 $n 与生成器输出不一致"; exit 1; }
done
echo "✓ run_test：单测绿、样例可重现（与提交的 samples/ 逐字节一致）"
