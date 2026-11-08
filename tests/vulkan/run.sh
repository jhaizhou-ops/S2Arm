#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Offline Linux container shared by shader cases and Android Vulkan contracts.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
nr() { echo "Vulkan 测试环境未就绪：$*；请显式运行 bash tests/vulkan/prepare.sh" >&2; exit 75; }
source "$here/image.sh"
command -v python3 >/dev/null || nr "缺 python3"
command -v docker >/dev/null || nr "缺 docker"
s2a_vulkan_image "$here" || nr "镜像源身份不可读"
s2a_vulkan_engine
"${S2A_VULKAN_ENGINE[@]}" info >/dev/null 2>&1 || nr "Docker/colima 未运行"
label=$("${S2A_VULKAN_ENGINE[@]}" image inspect --format '{{index .Config.Labels "org.s2arm.vulkan.source"}}' "$S2A_VULKAN_IMAGE" 2>/dev/null) || nr "尚未准备 $S2A_VULKAN_IMAGE"
[ "$label" = "$S2A_VULKAN_SOURCE" ] || nr "镜像来源标签不匹配"
image=$("${S2A_VULKAN_ENGINE[@]}" image inspect --format '{{.Id}}' "$S2A_VULKAN_IMAGE" 2>/dev/null) || nr "镜像身份不可读"
case "$image" in sha256:*) ;; *) nr "镜像 ID 无效" ;; esac
# Linked worktrees have a .git file pointing outside the bind mount. Read only
# HEAD on the host; do not mount its git config, credential helpers or home.
head=$(git -C "$repo" rev-parse --verify HEAD) || { echo "cannot read source HEAD" >&2; exit 1; }
case "$head" in *[!0-9a-f]*|"") echo "invalid source HEAD" >&2; exit 1 ;; esac
[ "${#head}" = 40 ] || { echo "invalid source HEAD length" >&2; exit 1; }
# Use the inspected immutable image ID, not a mutable tag between inspect/run.
# 持久缓存目录挂到 /cache（shader_cases 编好的翻译器按输入摘要缓存，tests/shader_cases/run.py build_key；11-05 不稳定项 #12/#13）
cache=${S2A_VULKAN_CACHE:-$HOME/Library/Caches/s2a_vulkan}
mkdir -p "$cache" || nr "缓存目录 $cache 建不了"
"${S2A_VULKAN_ENGINE[@]}" run --platform linux/amd64 --rm --pull=never --network=none \
  --env "S2A_TEST_SOURCE_HEAD=$head" --env "S2A_VULKAN_IMAGE_ID=$image" --env S2A_VULKAN_CACHE=/cache \
  --user "$(id -u):$(id -g)" --mount "type=bind,source=$repo,target=/src" --mount "type=bind,source=$cache,target=/cache" \
  --workdir /src "$image" "$@"
rc=$?
case "$rc" in 125|126|127) nr "容器启动失败 rc=$rc" ;; *) exit "$rc" ;; esac
