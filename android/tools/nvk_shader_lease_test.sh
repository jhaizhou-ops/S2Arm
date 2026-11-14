#!/usr/bin/env bash
# 程序借用（graphics/nvn/replay/rp_shader.h 的借用合同，实现 android/native/gfx_plat/nvk_shader.c）宿主单测。
# 链生产 nvk_shader.c，ASan 打开：夹具在「借用未归还 -> 收尾」这一交错上直接读收尾后的程序记录，
# 收尾若在借用归零前释放就是 heap-use-after-free（复核 P1-1）。
# 需要 NDK 29 的 Vulkan 头（与 nvk_shader_pool_test.py 同一条路）：用 android/tools/ndk_toolchain.sh 解析。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo/android/tools/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "NDK 29 missing (set ANDROID_NDK_HOME)" >&2; exit 2; }
tag=$(s2a_ndk_prebuilt_tag "$ndk") || exit 2
sysinc="$ndk/toolchains/llvm/prebuilt/$tag/sysroot/usr/include"
[ -f "$sysinc/vulkan/vulkan.h" ] || { echo "NDK 29 Vulkan headers missing" >&2; exit 2; }
out="$repo/build/nvk-shader-lease"; mkdir -p "$out"
"${PYTHON:-python3}" - "$repo" "$out" "${CC:-cc}" "$sysinc" <<'PYEOF'
import sys
from pathlib import Path
repo, out, cc, sysinc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
sys.path.insert(0, str(repo / 'android/tests'))
import host_link
native = repo / 'android/native'; gfx = repo / 'graphics/nvn'
inc = [repo/'runtime/include', native, native/'nvn', native/'direct', native/'gfx_plat',
       gfx, gfx/'replay', gfx/'gfx/nvn', gfx/'gfx/nvn/include', repo/'android/tests/vkhost']
# 显式给出 nvk_shader.c 那几个纯逻辑依赖（与 nvk_shader_pool_test.py 同一份清单）：host_link 就不会去拉
# vk_device.c（那要真 Vulkan loader），链接才能闭合。
libs = [repo/'runtime/src/direct_host.c']
libs += [native/'direct'/f for f in ('source_store.c','control.c','input_identity.c','texture_facts.c',
                                      'sha256.c','json.c','compile_request.c','compiler_bind.c')]
base = [cc, '-std=c11', '-O1', '-g', '-pthread', '-D_GNU_SOURCE', '-fsanitize=address',
        '-Wno-unused-parameter', '-Wno-unused-function', '-ffunction-sections', '-fdata-sections']
base += ['-I' + str(p) for p in inc]
base += ['-idirafter', str(sysinc)]        # libc 头优先取宿主，NDK 只补 vulkan/*
src = [repo/'android/tests/nvk_shader_prog_lease_test.c', native/'gfx_plat/nvk_shader.c', *libs]
exe = out / 't'
host_link.run(base + [str(p) for p in src] + ['-Wl,--gc-sections', '-lm', '-o', str(exe)],
              check=True, timeout=300, cwd=str(repo))
print('built', exe)
PYEOF
ASAN_OPTIONS=detect_leaks=0 "$out/t"
