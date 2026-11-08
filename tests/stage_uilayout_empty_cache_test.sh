#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/stage_uilayout.sh
# 合成生成器与只读现行根：非零且无覆盖文件不可缓存；成功空结果与部分成功保留缓存。
set -eu
command -v xxd >/dev/null || { echo "缺少阶段必需工具 xxd" >&2; exit 2; }
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/pack" "$T/repo/graphics/widen/scan" "$T/current/exefs" "$T/current/romfs" "$T/source/romfs/Layout"
cp "${STAGE:-$H/pack/stage_uilayout.sh}" "$T/repo/pack/stage_uilayout.sh"
mkdir -p "$T/repo/graphics/nvn/tools" && cp "$H/graphics/nvn/tools/romfs_list.py" "$T/repo/graphics/nvn/tools/"   # 覆盖包目录名带原版盘点身份（审计 #1534 P1-54）
cat > "$T/repo/pack/roots.sh" <<'SH'
root_cur() { printf '%s\n' "$TEST_CURRENT"; }
# Overlay application is covered separately by stage_uilayout_test.sh.
# Stop after cache generation, without Darwin clone commands or real assets.
root_stage_done() { return 0; }
SH
cat > "$T/repo/graphics/widen/scan/ui_lyt.py" <<'PY'
import os, pathlib, sys
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write('call\n')
out = pathlib.Path(sys.argv[2])
mode = os.environ['TEST_MODE']
if mode in ('partial', 'success'):
    out.mkdir(parents=True)
    (out / 'synthetic.txt').write_text('synthetic overlay')
elif mode == 'emptydir':
    out.mkdir(parents=True)
elif mode == 'metadata':
    out.mkdir(parents=True)
    (out / '.DS_Store').write_text('synthetic metadata')
print('synthetic generator ' + mode)
sys.exit(0 if mode in ('success', 'empty-success') else 1)
PY
printf 'synthetic encoder\n' > "$T/repo/graphics/widen/scan/yaz0enc.c"
head -c 96 /dev/zero > "$T/current/exefs/main"
printf 'src=%s\n' "$T/source" > "$T/current/seed.txt"
export TEST_CURRENT="$T/current" TEST_CALLS="$T/calls"
bad=0; checks=0
check() {
    checks=$((checks + 1))
    if "$@"; then echo "通 $checks"; else echo "不通 $checks: $*"; bad=1; fi
}
run() { TEST_MODE=$1 bash "$T/repo/pack/stage_uilayout.sh" synthetic > "$T/run.log" 2>&1; }
for mode in early emptydir metadata; do
    export S2A_WIDEN_DIR="$T/$mode"
    : > "$TEST_CALLS"
    run "$mode"
    check grep -q '【黄】' "$T/run.log"
    # Neither an empty failed cache nor an abandoned temporary directory may remain.
    count=$(find "$S2A_WIDEN_DIR" -type d -name 'ui_w*' | wc -l | tr -d ' ')
    check test "$count" = 0
    run success
    check test -d "$S2A_WIDEN_DIR/synthetic_00000000000000000000000000000000"
    check test "$(wc -l < "$TEST_CALLS" | tr -d ' ')" = 2
    check test "$(find "$S2A_WIDEN_DIR" -name synthetic.txt | wc -l | tr -d ' ')" = 1
    run early
    check test "$(wc -l < "$TEST_CALLS" | tr -d ' ')" = 2
done
for mode in empty-success partial; do
    export S2A_WIDEN_DIR="$T/$mode"
    : > "$TEST_CALLS"
    run "$mode"
    check test -d "$S2A_WIDEN_DIR/synthetic_00000000000000000000000000000000"
    check test "$(find "$S2A_WIDEN_DIR" -type d -name 'ui_w*' | wc -l | tr -d ' ')" = 1
    run early
    check test "$(wc -l < "$TEST_CALLS" | tr -d ' ')" = 1
done
printf 'stage_uilayout_empty_cache: %s assertions; failure=%s\n' "$checks" "$bad"
exit "$bad"
