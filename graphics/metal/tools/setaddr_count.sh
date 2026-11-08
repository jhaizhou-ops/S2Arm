#!/bin/bash
# gal 层直接调参数表 setAddress 的**行数**（去掉 // 注释后再数；一行多次也只算一行，避免拆行/并行的噪声）。
# 门禁棘轮用，对应 #114（M3-7 参数绑定）：目标是把这些调用全部收进 gal_be_bind 入口，收一处就把基线减一，
# 基线见 tools/setaddr_baseline.txt。**只许减不许增。**
# 用法：bash graphics/metal/tools/setaddr_count.sh [-v]（-v 按文件列）
cd "$(dirname "$0")/.." || exit 2
files=$(ls gal_*.m 2>/dev/null)
if [ "${1:-}" = -v ]; then
  for f in $files; do n=$(sed 's#//.*##' "$f" | grep -c 'setAddress:'); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn
fi
for f in $files; do sed 's#//.*##' "$f"; done | grep -c 'setAddress:'
