#!/bin/bash
# 直连回放层（graphics/nvn/gfx：nvn 与 tex）里 Metal 4 专有符号的出现处数（不含 // 注释）。门禁棘轮用：只许减不许增，基线见 tools/mtl4_baseline.txt（#277 D3-1）
# 新代码碰 Metal 4 专有概念只经 nvn_mtl.m 的包装函数；往 Metal 3 两路的包装里搬掉一处，就同笔把基线改小。照 graphics/metal/tools/mtl4_count.sh
# 用法：bash graphics/nvn/tools/mtl4_count.sh [-v]（-v 按文件列）
cd "$(dirname "$0")/../gfx" || exit 2
files=$(ls nvn/*.m nvn/*.h nvn/*.inc nvn/*.c tex/*.m tex/*.h tex/*.c 2> /dev/null)
if [ "${1:-}" = -v ]; then
  for f in $files; do n=$(sed 's#//.*##' "$f" | grep -oE '(^|[^A-Za-z0-9_])MTL4[A-Za-z]*' | wc -l | tr -d ' '); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
fi
for f in $files; do sed 's#//.*##' "$f"; done | grep -oE '(^|[^A-Za-z0-9_])MTL4[A-Za-z]*' | wc -l | tr -d ' '
