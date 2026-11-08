#!/bin/bash
# 真实 EGL / GL → Metal 深度模板附件回归；不链接宿主 / GPU 后端 / Widen 替身。
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../../../.." && pwd)
. "$R/tools/toolchain.sh"
export LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:/opt/homebrew/opt/brotli/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
[ -x "$PY" ] || PY=python3
for tool in glslangValidator spirv-cross; do command -v "$tool" >/dev/null; done
GL_DS_BASELINE=0
OUT_DEFAULT="$R/build/gl-depth-stencil/current"
if [[ $# -eq 1 && "$1" == "--baseline" ]]; then
    GL_DS_BASELINE=1
    OUT_DEFAULT="$R/build/gl-depth-stencil/baseline-run"
    if [[ -z "${GL_DS_ARCHIVE:-}" || ! -f "$GL_DS_ARCHIVE" ]]; then
        echo "--baseline requires GL_DS_ARCHIVE pointing to the frozen old GL archive" >&2
        exit 2
    fi
    export S2A_WIDEN_DIRECT=0
fi
OUT=${GL_DS_OUT:-$OUT_DEFAULT}
mkdir -p "$OUT/cap" "$OUT/lib"
OUT=$(cd "$OUT" && pwd)
for source in ds.vert ds.frag; do
    key=$(shasum -a 256 "$H/$source" | cut -c1-16)
    cp "$H/$source" "$OUT/cap/$key.${source##*.}"
done
"$PY" "$R/translator/gl_shaders.py" "$OUT/cap" "$OUT/lib" > "$OUT/shaders.log" 2>&1 || { cat "$OUT/shaders.log"; exit 1; }
make -C "$R" -j "${GL_DS_JOBS:-1}" -f Makefile -f "$H/gpu_depth_stencil.mk" gl-depth-stencil-build \
    GL_DS_OUT="$OUT" GL_DS_ARCHIVE="${GL_DS_ARCHIVE:-}" GL_DS_BASELINE="$GL_DS_BASELINE" > "$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; exit 1; }
mkdir -p "$OUT/run/shaders"
RUN_LOG="$OUT/run/full.log"
if [[ "$GL_DS_BASELINE" == 1 ]]; then RUN_LOG="$OUT/run/baseline.log"; fi
if T_GPU_DIR="$H" S2A_GAME_DATA="$OUT" S2A_DOCS="$OUT/run" DM_MSL_DIR="$OUT/lib" \
    DM_MSL_FALLBACK="$OUT/run/shaders" DM_PSO_USER="$OUT/run/pso_user.tsv" \
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$OUT/t_gpu_depth_stencil" "$@" 2>&1 | tee "$RUN_LOG"; then
    :
else
    exit "$?"
fi
