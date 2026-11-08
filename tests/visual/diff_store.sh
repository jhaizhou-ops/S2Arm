#!/bin/bash
# 门禁手动：辅助脚本，把对拍录像按内容寻址存进 ~/.s2arm/gate_data/diffrec（要传录像与款），本身不是单测
# 对拍录像入库（内容寻址，只增不改）：tests/visual/diff_store.sh <gal.rec> <款>  → 打印库里的文件名 <款>_<sha256 前 16 位>.rec
# 库：${S2A_DIFF_RECS:-~/.s2arm/gate_data/diffrec}（tools/shared_paths.tsv 登记；放在 run/ 之外，清盘与 safe_rm.sh 碰不到）。门禁清单 tests/visual/diff_list.tsv 按文件名引用、随代码走列车：
#   新录像先入库（不影响任何人——没有清单行引用它），再在分支里改清单；同名文件已在就核长度、不覆盖。
set -u
SRC=${1:?gal.rec}; G=${2:?款}; DR=${S2A_DIFF_RECS:-$HOME/.s2arm/gate_data/diffrec}; mkdir -p "$DR"
H=$(shasum -a 256 "$SRC" | cut -c1-16); N=${G}_$H.rec
if [ -f "$DR/$N" ]; then
  [ "$(stat -f %z "$DR/$N")" = "$(stat -f %z "$SRC")" ] || { echo "🔴 库里 $N 长度与源不同（不覆盖）" >&2; exit 1; }
else
  cp -c "$SRC" "$DR/$N.tmp.$$" && chmod a-w "$DR/$N.tmp.$$" && mv "$DR/$N.tmp.$$" "$DR/$N" || { rm -f "$DR/$N.tmp.$$"; echo "🔴 入库失败" >&2; exit 1; }
fi
echo "$N"
