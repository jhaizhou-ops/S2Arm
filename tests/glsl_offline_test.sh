#!/bin/bash
# GLSL 离线链：真实 glslang / SPIRV-Cross / Metal，不下载工具；缺工具报红。
# 门禁覆盖：graphics/tools/glsl/* graphics/tools/spirv_msl.py translator/vk_shaders.py translator/gl_shaders.py translator/mbundle.py tests/glsl/* tests/glsl_offline_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}   # 钉版解释器（gl_shaders.py 读 NSO 用 lz4），同其它工具单测
exec "$PY" "$R/tests/glsl_offline_test.py"
