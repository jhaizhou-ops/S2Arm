#!/usr/bin/env bash
# 首次使用准备下沉的三个纯逻辑模块（宿主，无 GPU）：
#   nvn_vk_prog_warm  跨会话程序清单：逐字段往返 / c1 合并不丢 / uses 去重 / 上限淘汰 / 坏文件整份拒绝 / 本局有效性过滤
#   nvn_vk_pipe_warm  跨会话管线配方：紧凑序列化 216 个字段变体 / 碰撞不去重 / 阶段位一致性 / 坏文件拒绝
#   nvn_vk_pipe_once  「同一配方只有一份」双检：4 线程并发只装一份、被丢弃的新建对象必须销毁
# 合同见 android/native/nvn/nvn_vk_{prog,pipe}_warm.h 与 nvn_vk_pipe_once.h。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc="${CC:-cc}"
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -pthread -D_GNU_SOURCE \
  -I "$android/native" -I "$android/native/nvn" -I "$android/native/direct" \
  -I "$repo/graphics/nvn/replay" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
  -o "$tmp/t_prog" "$android/tests/nvn_vk_prog_warm_test.c" "$android/native/nvn/nvn_vk_prog_warm.c" "$android/native/direct/sha256.c"
"$tmp/t_prog"
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -pthread -D_GNU_SOURCE \
  -I "$android/native" -I "$android/native/nvn" -I "$android/native/direct" \
  -I "$repo/graphics/nvn/replay" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
  -o "$tmp/t_pipe" "$android/tests/nvn_vk_pipe_warm_test.c" "$android/native/nvn/nvn_vk_pipe_warm.c"
"$tmp/t_pipe"
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -pthread -D_GNU_SOURCE \
  -I "$android/native/nvn" -o "$tmp/t_once" \
  "$android/tests/nvn_vk_pipe_once_test.c" "$android/native/nvn/nvn_vk_pipe_once.c"
"$tmp/t_once"
