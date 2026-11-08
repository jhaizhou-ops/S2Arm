#!/usr/bin/env bash
# 新 Vulkan 后端真机自测总入口：逐个跑，最后汇总；任一失败退出 1。
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
probes="nvn_vk_format_probe nvn_vk_sampler_probe nvn_vk_sampler_cache_probe nvn_vk_texcache_probe nvn_vk_texcache_retain_probe nvn_vk_texcache_tex_probe nvn_vk_texview_probe nvn_vk_session_probe nvn_vk_surface_probe nvn_vk_be_probe nvn_vk_pipeline_probe vk_interlock_probe vk_surface_probe"
fail=0
for p in $probes; do
    log=$(mktemp)
    if bash "$repo/android/tools/$p.sh" >"$log" 2>&1; then
        echo "PASS $p"
    else
        echo "FAIL $p"; tail -3 "$log"; fail=1
    fi
    rm -f "$log"
done
