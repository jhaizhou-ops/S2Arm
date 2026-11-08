#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
for tool in python3 cc c++ git glslc spirv-val dotnet; do
  command -v "$tool" >/dev/null || { echo "missing $tool in prepared Vulkan image" >&2; exit 2; }
done
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
icd=
for f in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
  [ -f "$f" ] && { icd=$f; break; }
done
[ -n "$icd" ] || { echo "missing Mesa lavapipe ICD" >&2; exit 2; }
layer=/usr/share/vulkan/explicit_layer.d
[ -f "$layer/VkLayer_khronos_validation.json" ] || { echo "missing Khronos validation layer" >&2; exit 2; }
export VK_DRIVER_FILES="$icd" S2A_LAVAPIPE_ICD="$icd" S2A_VK_LAYER_DIR="$layer"
export VK_LAYER_PATH="$layer" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_VALIDATE_SYNC=1
# run.sh's existing TSan path deliberately disables validation for that run.
case "${1:-}" in
  tests/shader_cases_test.sh) [ "$#" = 1 ] || exit 64 ;;
  android/tests/nvn_vk_real_teardown_test.sh) [ "$#" = 1 ] || { [ "$#" = 2 ] && [ "$2" = --neg ]; } || exit 64 ;;
  android/tests/vk/run.sh)
    [ "$#" -le 2 ] || exit 64
    if [ "${2:-}" = --tsan ]; then unset VK_INSTANCE_LAYERS VK_LAYER_VALIDATE_SYNC; fi ;;
  *) echo "unknown Vulkan test entry: ${1:-<missing>}" >&2; exit 64 ;;
esac
log=$(mktemp /tmp/s2arm-vulkan-log.XXXXXXXX)
trap 'rm -f "$log"' EXIT
set +e
bash "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
source /opt/s2arm-vulkan/result.sh
s2a_vulkan_result "$rc" "$log"
