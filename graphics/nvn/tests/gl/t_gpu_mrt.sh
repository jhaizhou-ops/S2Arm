#!/bin/bash
# 真实 EGL / OpenGL → Metal MRT 回归，不链接 GL 后端或宽屏替身。
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../../../.." && pwd)
NV=$R/graphics/nvn
. "$R/tools/toolchain.sh"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
[ -x "$PY" ] || PY=python3
for tool in glslangValidator spirv-cross; do command -v "$tool" >/dev/null; done

OUT=${GL_MRT_OUT:-$R/build/gl-gpu-mrt/current}
mkdir -p "$OUT/cap" "$OUT/lib"
OUT=$(cd "$OUT" && pwd)
for source in mrt.vert mrt.frag tri.vert tri.frag; do
    key=$(shasum -a 256 "$H/$source" | cut -c1-16)
    cp "$H/$source" "$OUT/cap/$key.${source##*.}"
done
"$PY" "$NV/../../translator/gl_shaders.py" "$OUT/cap" "$OUT/lib" >"$OUT/shaders.log" 2>&1 || { cat "$OUT/shaders.log"; exit 1; }
make -C "$R" -j "${GL_MRT_JOBS:-1}" -f Makefile -f "$H/gpu_mrt.mk" gl-gpu-mrt-build \
    GL_MRT_OUT="$OUT" GL_MRT_ARCHIVE="${GL_MRT_ARCHIVE:-}" >"$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; exit 1; }
mkdir -p "$OUT/run/shaders"
T_GPU_DIR=$H S2A_GAME_DATA=$OUT S2A_DOCS=$OUT/run DM_MSL_DIR=$OUT/lib \
    DM_MSL_FALLBACK=$OUT/run/shaders DM_PSO_USER=$OUT/run/pso_user.tsv \
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$OUT/t_gpu_mrt"
