#!/bin/bash
# 数据卷检查（11-02 jhz 的 2T 布局）：run/s2arm 下的大体量数据区整组放在另一块大盘（2T 数据卷，路径写在标记文件里），原路径留同名软链，工具与各线不用改路径。
#   本脚本只在 <运行区>/.data_vol 标记存在时生效（标记内容＝数据卷挂载点，切换时写；没有标记＝这台没用该布局，直接放行，贡献者 / mini 不受影响）：
#   ① 数据卷没挂载 → 红「数据卷没挂载」、退出 125（软链悬空本来也会让 mkdir -p / cp -c 报 No such file，这里给一句明白话）；
#   ② 登记的目录里有不是软链的（被同名真目录替换：rm -rf 软链后再 mkdir -p 会在内置盘悄悄建出来）→ 红、退出 125，不让往内置盘悄悄写。
#   用法：bash tools/data_vol_check.sh（入口脚本开头调一次，|| exit）。环境：S2A_RUN_ROOT / S2A_DATA_VOL_DIRS（空格分隔相对 s2arm 的目录，缺省见下）。
RUN=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm; M=$RUN/.data_vol
[ -f "$M" ] || exit 0
VOL=$(head -1 "$M")
DIRS=${S2A_DATA_VOL_DIRS:-"roots roots_priv cache census census_stage exp_tiyan native_repro zhilian merge_line fsline cold1030 cold1031 cold1102 wire-c sched/pkgstore sched/jobs"}
/sbin/mount | /usr/bin/grep -q " on $VOL " || { echo "🔴 数据卷 $VOL 没挂载：run/s2arm 下的大数据区在那块盘上，不会回落内置盘；插好盘再来（调用方按排队超时处理）" >&2; exit 125; }
bad=; for d in $DIRS; do p=$RUN/$d; [ -e "$p" ] || [ -L "$p" ] || continue; [ -L "$p" ] || bad="$bad $d"; done
[ -z "$bad" ] || { echo "🔴 数据区被内置盘的真目录替换：${bad}（应为指向 $VOL 的软链；多半是有人 rm -rf 软链后又 mkdir -p）；不往内置盘写，先查清再处理" >&2; exit 125; }
exit 0
