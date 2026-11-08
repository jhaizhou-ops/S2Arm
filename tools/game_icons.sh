#!/bin/bash
# 游戏图标重抽（10-20 jhz：App 图标缺省中文）：tools/game_icons.sh <款…>
# 按现行产物根的程序号，在游戏原始包目录（S2A_GAME_SRC，缺省 ~/Downloads）里按内容认包：每个 xci / nsp 单独读一遍控制元数据取程序号
#   （结果按「路径 大小 修改时间」缓存在 <S2A_ICONS>/.ids.tsv；文件名一概不看，10-20 总指挥定），程序号对上的就用（单独的更新包读不出程序号，不用），
# 用 nx_unpack --nacp-only 抽控制分区（图标语言：简体中文 → 美式英文 → 其余），只取 icon.jpg 放 <S2A_ICONS>/<款>.jpg（缺省 run/s2arm/icons）。
# 出包时 pack/ipa.sh 优先用它，没有再退回产物根 icon.jpg。不动产物根；图标不进仓库。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); source "$H/pack/roots.sh"; source "$H/pack/srcs.sh"   # 原始包按内容认：pack/srcs.sh（与追加内容阶段共用）
N=$SRC_N; K=$SRC_K; SRC=$SRC_DIR; OUT=${S2A_ICONS:-$HOME/.s2arm/run/s2arm/icons}; mkdir -p "$OUT"
[ -x "$N" ] || { echo "【红】没有 ${N}"; exit 1; }
rc=0
for g in "$@"; do
  cur=$(root_cur "$g"); tid=$(prog_id "$cur")
  [ -n "$tid" ] || { echo "【红】${g}：现行产物根取不到程序号"; rc=1; continue; }
  ids=$(src_ids) || { echo "【红】${g}：原件探测出错（见上一行，机器原因），图标没抽"; rc=1; continue; }
  fs=(); while IFS= read -r f; do fs+=("$f"); done < <(printf '%s\n' "$ids" | awk -F'\t' -v t="$tid" 'toupper($4) == t {print $1}')
  [ ${#fs[@]} -gt 0 ] || { echo "【红】${g}：${SRC} 下没找到程序号 ${tid} 的原始包"; rc=1; continue; }
  t=$(mktemp -d); "$N" "$K" "$t" --nacp-only --title-id="$tid" "${fs[@]}" > "$t/nacp.log" 2>&1
  if [ -s "$t/icon.jpg" ]; then cp "$t/icon.jpg" "$OUT/$g.jpg.tmp" && mv "$OUT/$g.jpg.tmp" "$OUT/$g.jpg" && echo "🟢 ${g}：图标 → $OUT/$g.jpg（原始包 ${#fs[@]} 个）"
  else echo "【红】${g}：没抽到图标（$(tail -1 "$t/nacp.log" | cut -c1-120)）"; rc=1; fi
  rm -rf "$t"
done
exit $rc
