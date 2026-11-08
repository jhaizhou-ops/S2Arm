#!/bin/bash
# D1 采集入口（Mac）：先 runtime/run_mac.sh 跑一局，再把局目录归一化成 d1.json。
# 用法：bash graphics/nvn/tools/d1/capture.sh <款> <局目录> <秒>
# 需要 S2A_IN=<产物根快照>；可选 S2A_D1_DEVICE / S2A_D1_MODE / S2A_D1_METAL_API / S2A_D1_LABEL。
# 非 macOS 或跑局失败都保留真实退出码，不伪造读数（非 macOS 固定退出 2）。
set -eu
G=${1:?用法：capture.sh <款> <局目录> <秒>}
D=${2:?}
SEC=${3:?}
if [ "$(uname -s)" != "Darwin" ]; then
    printf '【黄】D1 采集需要在 macOS 上跑（当前 %s）；本脚本不生成读数，退出 2\n' "$(uname -s)" >&2
    exit 2
fi
: "${S2A_IN:?需要 S2A_IN=<产物根快照>}"
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
rc=0
bash "$ROOT/runtime/run_mac.sh" "$G" "$D" "$SEC" || rc=$?
python3 "$ROOT/graphics/nvn/tools/d1/capture.py" "$D" \
    --out "$D/d1.json" \
    --game "$G" \
    --device "${S2A_D1_DEVICE:-$(sysctl -n hw.model)}" \
    --mode "${S2A_D1_MODE:-direct}" \
    --metal-api "${S2A_D1_METAL_API:-4}" \
    --label "${S2A_D1_LABEL:-}" \
    --repo "$ROOT" \
    --commit auto || rc=$?
printf 'D1 采集完成：%s（run_mac.sh / capture.py 最后 rc=%s）\n' "$D/d1.json" "$rc" >&2
exit "$rc"
