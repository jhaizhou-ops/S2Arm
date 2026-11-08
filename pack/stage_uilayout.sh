#!/bin/bash
# 出包·宽屏界面布局阶段：pack/stage_uilayout.sh <款> [屏幕宽 W，缺省 2346 = iPhone 17 Pro Max 横屏 1080 高对应的宽]
# 把画幅线出的布局覆盖包 ~/.s2arm/run/s2arm/widen/<款>_<main 构建号>/ui_w<W>_<工具版本>/romfs/ 下的文件覆盖进新版本产物根 romfs/ 同路径（只替换这些文件）：
#   nn::ui2d .bflyt 里加宽后不拉伸的整画布底（纯色、所有层真平铺）加宽到屏幕宽（画幅线 graphics/widen/scan/ui_lyt.py）。
# 覆盖包一律从原版 romfs 生成（现行产物根 seed.txt 记的游戏数据目录 /romfs）：现行产物根 romfs 里可能已含上一版覆盖，拿它当输入会在旧改动上再改。
# 工具版本 = ui_lyt.py + yaz0enc.c 内容哈希、原版 Layout / UI / Pack 的盘点身份，都进覆盖包目录名：工具或原版变了就重新生成，不复用旧覆盖包。生成先写 .tmp 再改名，目录在 = 生成完整。
# 上一版改过、这一版不改了的文件（现行 ui_overlay.tsv 有、新覆盖包没有）在新产物根里恢复成原版文件。
# 覆盖前先删目标再克隆：产物根 romfs 是从原版克隆来的，直接写可能顺着克隆源 / 软链写坏原版。只许替换原版 romfs 里已有的文件，多出来的打黄跳过（宽屏不挡出包）。
# 阶段键 = W + 工具版本 + 覆盖文件内容哈希；与现行 .stage_uilayout 相同就跳过。
set -u
G=${1:?款}; WD=${2:-2346}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -f "$CUR/exefs/main" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
[ -d "$CUR/romfs" ] || { echo "🟢 $G 现行产物根没有 romfs/，跳过（界面不加宽）"; exit 0; }
SRC=$(sed -n 's/^src=//p' "$CUR/seed.txt" 2>/dev/null | head -1); ORIG=$SRC/romfs
[ -n "$SRC" ] && [ -d "$ORIG" ] || { echo "【红】$G 找不到原版 romfs（现行 seed.txt 的 src=${SRC:-无}）：覆盖包只从原版生成"; exit 1; }
GEN=$R/graphics/widen/scan/ui_lyt.py
TV=$(cat "$GEN" "$R/graphics/widen/scan/yaz0enc.c" 2>/dev/null | shasum -a 256 | cut -c1-12)
# 原版身份（审计 #1534 P1-54）：生成器读的原版 Layout / UI / Pack 的盘点身份（graphics/nvn/tools/romfs_list.py：相对路径 + 大小 + 修改时间纳秒，只 lstat）进覆盖包目录名。
#   原先只按构建号 + 屏宽 + 工具版本：重解包 / 只换数据的更新让原版 romfs 变了而构建号没变，目录还在就照盖上一份覆盖。阶段键仍按覆盖文件内容算，重生成出来一样的不出新版本
SI=$(/usr/bin/python3 -c 'import hashlib, os, sys; sys.path.insert(0, sys.argv[1]); import romfs_list
h = hashlib.sha256()
for d in ("Layout", "UI", "Pack"):
    p = os.path.join(sys.argv[2], d)
    if os.path.isdir(p):
        i = romfs_list.scan(p).identity
        if i is None: sys.exit(1)
        h.update(f"{d} {i}\n".encode())
print(h.hexdigest()[:12])' "$R/graphics/nvn/tools" "$ORIG") || { echo "【红】$G 盘点不了原版 romfs 的 Layout / UI / Pack（${ORIG}）"; exit 1; }
BID=$(xxd -s 0x40 -l 16 -p "$CUR/exefs/main"); OV=${S2A_WIDEN_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/widen}/${G}_$BID/ui_w${WD}_${TV}_$SI
has=0; for d in Layout UI Pack; do [ -d "$ORIG/$d" ] && has=1; done
if [ ! -d "$OV" ] && [ $has = 1 ] && [ -f "$GEN" ]; then
  T=$OV.tmp.$$; rm -rf "$T"; mkdir -p "$T"
  # 生成有报错（解不开 / 改坏的包）只打黄：报错的包不覆盖、其余照常（宽屏是画质项，不挡出包；10-28 王国之泪带字典 zstd 全报错，整款出不了包）
  failed=0
  /usr/bin/python3 "$GEN" "$ORIG" "$T/romfs" "$WD" > "$T/gen.log" 2>&1 || failed=1
  if [ "$failed" = 1 ] && [ -z "$(find "$T/romfs" -type f ! -name '.DS_Store' -print -quit 2>/dev/null)" ]; then
    # 失败且没有可用覆盖不代表完整的空结果：不发布缓存，下次同工具仍可重试。
    echo "【黄】$G 布局覆盖包生成失败且无覆盖文件，下次重试（$(tail -1 "$T/gen.log")）"
    rm -rf "$T"
  else
    [ "$failed" = 0 ] || echo "【黄】$G 布局覆盖包生成有报错，报错的包不加宽、其余照常（$(tail -1 "$T/gen.log")；明细 $OV/gen.log）"
    mv "$T" "$OV" 2> /dev/null || rm -rf "$T"
  fi
fi
FL=; [ -d "$OV/romfs" ] && FL=$(cd "$OV/romfs" && find . -type f ! -name '.DS_Store' | sed 's#^\./##' | LC_ALL=C sort)
PREV=$(grep -v '^$' "$CUR/ui_overlay.tsv" 2>/dev/null)
[ -n "$FL" ] || [ -n "$PREV" ] || { echo "🟢 $G 没有要加宽的布局（覆盖包 ${OV}），现行也没有旧覆盖，跳过"; exit 0; }
K=$(printf 'w%s %s %s' "$WD" "$TV" "$([ -n "$FL" ] && cd "$OV/romfs" && printf '%s\n' "$FL" | while read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -c1-16)" | shasum -a 256 | cut -c1-16)
root_stage_done "$CUR" uilayout "$K" && { echo "🟢 $G 现行已是布局覆盖 ${K}，跳过"; exit 0; }
# 本阶段要改 RomFS：现行的 romfs 是指向共享存储的只读软链（pack/roots.sh），ROOT_OWN_ROMFS=1 开工拿一份自己的真目录（APFS 克隆），提交时收成新身份
TAG=$(root_tag "$G" "ui-w$WD-${K:0:8}"); W=$(ROOT_OWN_ROMFS=1 root_begin "$G" "$TAG") || exit 1
# 只许替换、上一版清单都对着这次要提交的工作树 W 核（root_begin 从此刻的现行克隆）：开头记下的 $CUR 只是起跑时的现行，生成覆盖包要几分钟，
#   期间并行的改写 / 追加内容等阶段提交，旧版本按「只留现行 + 上一版」被删（pack/roots.sh root_commit），$CUR/romfs 整个不在。
#   10-26 斯普拉遁3 普查：28 个覆盖文件全判成「原版没有」（报的正是排序后的前三个），现行已换成改写阶段的 rw-…-spin
PREV=$(grep -v '^$' "$W/ui_overlay.tsv" 2>/dev/null)
miss=$(printf '%s\n%s\n' "$FL" "$PREV" | grep -v '^$' | while read -r f; do [ -f "$ORIG/$f" ] && [ -f "$W/romfs/$f" ] || echo "$f"; done)
# 宽屏是画质项，不挡出包（10-26 总指挥）：原版 / 这次的产物根里没有的文件打黄、不覆盖也不恢复（只许替换），其余照做
if [ -n "$miss" ]; then
  echo "【黄】$G 宽屏布局：原版 romfs 没有 $(printf '%s\n' "$miss" | wc -l | tr -d ' ') 个覆盖 / 上一版清单里的文件，跳过：$(echo "$miss" | head -3 | tr '\n' ' ')"
  FL=$(printf '%s\n' "$FL" | grep -v '^$' | grep -vxF -- "$miss"); PREV=$(printf '%s\n' "$PREV" | grep -v '^$' | grep -vxF -- "$miss")
fi
# 上一版覆盖过、这一版不覆盖的文件：恢复成原版
RST=$(printf '%s\n' "$PREV" | grep -v '^$' | while read -r f; do printf '%s\n' "$FL" | grep -qxF -- "$f" || echo "$f"; done)
n=0; m=0
while read -r f; do [ -n "$f" ] || continue; rm -f "$W/romfs/$f" && _root_cp "$ORIG/$f" "$W/romfs/$f" || { root_abort "$G" "$TAG"; echo "【红】恢复原版 $f 失败"; exit 1; }; m=$((m + 1)); done <<< "$RST"
while read -r f; do [ -n "$f" ] || continue; rm -f "$W/romfs/$f" && _root_cp "$OV/romfs/$f" "$W/romfs/$f" || { root_abort "$G" "$TAG"; echo "【红】覆盖 $f 失败"; exit 1; }; n=$((n + 1)); done < <(printf '%s\n' "$FL")
# romfs 变了，RomFS 索引要重出
# 旧索引 romfs.s2aidx 同一次提交里删掉（10-21 帧率能耗线实证：只删 .stage_romfsidx 时，本阶段提交到索引阶段重出之间的几分钟里现行根「索引记 868 字节、文件已是 871 字节」，
#   这期间起的 Mac 局读该文件空指针崩）。没有索引时宿主按目录现建（慢但对），索引阶段随后重出
printf '%s' "$FL" > "$W/ui_overlay.tsv"; [ -n "$FL" ] && echo >> "$W/ui_overlay.tsv"; echo "$K" > "$W/.stage_uilayout"; rm -f "$W/.stage_romfsidx" "$W/romfs.s2aidx"
# 与改写 / 系统数据并行：本阶段只写这些（.stage_romfsidx 在 W 里已删 = 重放成删）
ROOT_REPLAY='romfs ui_overlay.tsv .stage_uilayout .stage_romfsidx romfs.s2aidx' root_commit "$G" "$TAG" || exit 1
echo "🟢 $G 宽屏界面布局：覆盖 $n 个文件、恢复原版 $m 个（屏幕宽 ${WD}，来源 ${OV}），现行 → $(basename "$(root_cur "$G")")"
