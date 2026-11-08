#!/bin/bash
# 真实 EGL / GL → Metal GPU 回归；不链接 t_gl_min 的后端或宽屏替身。
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../../../.." && pwd)
. "$R/tools/toolchain.sh"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
[ -x "$PY" ] || PY=python3
for tool in glslangValidator spirv-cross; do command -v "$tool" >/dev/null; done
OUT=${GL_GPU_OUT:-$R/build/gl-gpu-mip/current}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
mkdir -p "$OUT/cap" "$OUT/lib"
for source in gpu_mip.vert gpu_mip.frag gpu_cube.frag gpu_solid.frag; do
    key=$(shasum -a 256 "$H/$source" | cut -c1-16)
    cp "$H/$source" "$OUT/cap/$key.${source##*.}"
done
"$PY" "$R/translator/gl_shaders.py" "$OUT/cap" "$OUT/lib" >"$OUT/shaders.log" 2>&1
make -C "$R" -j "${GL_GPU_JOBS:-8}" -f Makefile -f "$H/gpu_mip.mk" gl-gpu-mip-build \
    GL_GPU_OUT="$OUT" GL_GPU_ARCHIVE="${GL_GPU_ARCHIVE:-}" >"$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; exit 1; }
mkdir -p "$OUT/run/shaders"
T_GPU_DIR="$H" S2A_GAME_DATA="$OUT" S2A_DOCS="$OUT/run" DM_MSL_DIR="$OUT/lib" \
    DM_MSL_FALLBACK="$OUT/run/shaders" DM_PSO_USER="$OUT/run/pso_user.tsv" \
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$OUT/t_gpu_mip"
