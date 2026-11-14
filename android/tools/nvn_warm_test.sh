#!/usr/bin/env bash
# 首次使用准备下沉：预热调度（nvn_warm.c）的时序合同（宿主，确定性，无 GPU）。
#   ① 先程序、后管线：程序清单（含在途重试）走完才取管线；
#   ② 在途重试：build 返回 1 的条目会被重试并最终发布，不丢；
#   ③ 计数：失败条目计入 failed、不阻塞其它条目；
#   ④ Stop 有界：stop 很快返回、两个 owner 的清单都落盘、后台静默被调用；
#   ⑤ 开关：debug.s2a.nvk_warm=0 时不起线程（进程内开关不变，单独一次进程跑）。
# 蓝本：graphics/nvn/gfx/nvn/nvn_mtl.m warm_start / pso_pend（后台清单预热、首帧不等）。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -pthread -D_GNU_SOURCE \
  -I "$android/native" -I "$android/native/nvn" \
  -I "$repo/graphics/nvn/replay" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" \
  -o "$tmp/t" "$android/tests/nvn_warm_test.c" "$android/native/nvn/nvn_warm.c"
"$tmp/t"
NVK_WARM_OFF=1 "$tmp/t"
