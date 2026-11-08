#!/usr/bin/env bash
# 生成 android/native/nvn/nvn_bc_spv.h：把 graphics/nvn/third_party/granite/decode/
# 下四个 compute 着色器编成 SPIR-V 并内嵌为 uint32 数组（上游提交见该目录 README）。
# 用法：bash tools/gen_nvn_bc_spv.sh [glslc]
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
glslc=${1:-$(command -v glslc || true)}
[ -n "$glslc" ] || { echo "【红】找不到 glslc" >&2; exit 2; }
src="$repo/graphics/nvn/third_party/granite/decode"
out="$repo/android/native/nvn/nvn_bc_spv.h"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/s2a-bc-spv.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

{
  echo "// 自动生成（tools/gen_nvn_bc_spv.sh：glslc --target-env=vulkan1.1）：BC1–BC7 compute 解压着"
  echo "// 色器，源码 graphics/nvn/third_party/granite/decode/（Granite，MIT，钉版见该目录 README）。"
  echo "#pragma once"
  echo "#include <stdint.h>"
} > "$out"

for s in s3tc rgtc bc6 bc7; do
  "$glslc" --target-env=vulkan1.1 -I"$src" "$src/$s.comp" -o "$tmp/$s.spv"
  {
    echo
    echo "static const uint32_t nvn_bc_${s}_comp[] = {"
    od -An -v -t u4 "$tmp/$s.spv" | awk '{ for (i = 1; i <= NF; i++) printf "0x%08xu, ", $i; print "" }' | sed 's/, $/,/'
    echo "};"
  } >> "$out"
done
echo "written $out"
