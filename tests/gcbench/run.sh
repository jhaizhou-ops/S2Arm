#!/bin/bash
# 门禁手动：要联网：依赖 build.sh --restore 先恢复 NuGet（离线跑报 NETSDK1004），之后才能扫描
# Offline one-command scan; build.sh --restore must have been run explicitly once.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
bash "$ROOT/tests/gcbench/build.sh"
OUT=${S2A_GCBENCH_BUILD:-$ROOT/build/195-gcbench/aot}
exec python3 "$ROOT/tests/gcbench/scan.py" --exe "$OUT/publish/GcBench" "$@"
