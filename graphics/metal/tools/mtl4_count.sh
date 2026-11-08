#!/bin/bash
# Metal 4 专有接口在渲染器产品代码里的出现处数（不含 // 注释与 gal_be.h 对照表）。门禁棘轮用：只许减不许增，基线见 tools/mtl4_baseline.txt
# 用法：bash graphics/metal/tools/mtl4_count.sh [-v]（-v 按文件列）
cd "$(dirname "$0")/.." || exit 2
files=$(ls gal_*.m gal_*.h | grep -v '^gal_be.h$')
if [ "${1:-}" = -v ]; then
  for f in $files; do n=$(sed 's#//.*##' "$f" | grep -oE '(^|[^A-Za-z0-9_])MTL4[A-Za-z]*' | wc -l | tr -d ' '); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
fi
for f in $files; do sed 's#//.*##' "$f"; done | grep -oE '(^|[^A-Za-z0-9_])MTL4[A-Za-z]*' | wc -l | tr -d ' '
