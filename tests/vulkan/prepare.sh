#!/usr/bin/env bash
# 门禁手动：要联网：显式在线准备 Vulkan 测试镜像，按设计绝不被门禁或单测调用
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Explicit online preparation ONLY; never called by a gate or test.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/image.sh"
s2a_vulkan_image "$here"
s2a_vulkan_engine
command -v docker >/dev/null || { echo "需要已配置的 Docker（macOS: colima context）；不自动安装" >&2; exit 75; }
"${S2A_VULKAN_ENGINE[@]}" info >/dev/null 2>&1 || { echo "Docker 环境未就绪；不自动启动/创建虚拟机" >&2; exit 75; }
"${S2A_VULKAN_ENGINE[@]}" build --platform linux/amd64 --label "org.s2arm.vulkan.source=$S2A_VULKAN_SOURCE" \
  --tag "$S2A_VULKAN_IMAGE" "$here"
"${S2A_VULKAN_ENGINE[@]}" image inspect --format '{{.Id}}' "$S2A_VULKAN_IMAGE"
echo "prepared $S2A_VULKAN_IMAGE"
