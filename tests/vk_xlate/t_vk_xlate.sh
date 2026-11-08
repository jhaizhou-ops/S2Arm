#!/bin/bash
# 乙的对拍单测（t_vk_xlate.m 文件头写了测什么、期望从哪来）：<vk_shaders.tsv> <SPIR-V 目录>...；缺省用哈迪斯快照（本机有才跑）
set -u
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../.." && pwd); . "$R/tools/toolchain.sh" > /dev/null || exit 2
make -s -C "$R/graphics/metal" "$R/build/gal/libspvc.a" > /dev/null || { echo "✗ t_vk_xlate：libspvc 编不过"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
clang -std=gnu11 -O1 -g -fobjc-arc -Wall -I"$R/graphics/third_party/spirv_cross" -o "$T/t" "$H/t_vk_xlate.m" "$R/graphics/metal/gal_vkx.m" "$R/build/gal/libspvc.a" -lc++ -framework Metal -framework Foundation \
  || { echo "✗ t_vk_xlate：编译失败"; exit 1; }
S=${1:-$HOME/.s2arm/run/s2arm/roots_priv/vulkan/hades_snap}
if [ $# -ge 2 ]; then "$T/t" "$@"; else "$T/t" "$S/shaders/direct/vk/vk_shaders.tsv" "$S/romfs"; fi
