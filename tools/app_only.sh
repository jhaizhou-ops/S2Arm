#!/bin/bash
# 只换 App 程序快道（10-23 总指挥：运行时改动合入后 ≤30 分钟出第一对真机读数，不等整包重烘）：tools/app_only.sh <款> [--register]
#   ① 读该款登记包（<调度目录>/pkgs/<款>.env：COMMIT、PKG 快照）；基底产物根 = <共享产物根>/<款>@pkg-<COMMIT>（没有 → 退出 2，走正常出包）
#   ② 按产物键判本提交改没改包里的预编产物：本树对基底根逐阶段算键（pack/stage_keys.sh）——改写 / 界面布局 / 追加内容 / RomFS 索引要全等；
#      着色器只比代码段（键里第一个「-」之前：游戏输入 + 翻译器闭包 + GAL 翻译代码 + 烘焙脚本），后面的收集数据段（-rg / -sp / -pu / -sc …）沿用登记包的
#      任一不等 → 退出 3、列出变了的段（这次改动会改预编产物，走正常出包）
#   ③ 只出程序：S2A_APP_ONLY_FROM=<基底根> pack/ipa.sh <款> → 新 ipa（改写产物取自基底根，编程序 / 签名 / 打 ipa，几十秒）
#   ④ 新包目录 = 克隆登记包快照（资源包、状态表、存档、语言 / 地区原样）+ 换 ipa；--register：tools/sched.sh pkg 登记（照常冒烟后转正，冒烟只推 ipa）
#   只许 origin/main 上的提交登记（分支代码不进正式包）；不加 --register 只出包目录，打印路径
# 退出码：0 出成；1 出错；2 没有基底；3 产物键变了（不适用快道）
set -u
G=${1:?款}; REG=0; [ "${2:-}" = --register ] && REG=1
R=$(cd "$(dirname "$0")/.." && pwd); C=$(git -C "$R" rev-parse --short=9 HEAD) || exit 1
SD=${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}; RT=${S2A_ROOTS_SHARED:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots}
OUTR=${S2A_APP_ONLY_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/apponly}; t0=$SECONDS
BC=$(. "$SD/pkgs/$G.env" 2> /dev/null; echo "${COMMIT:-}"); BP=$(. "$SD/pkgs/$G.env" 2> /dev/null; echo "${PKG:-}")
[ -n "$BC" ] && [ -d "$BP" ] || { echo "【黄】$G 没有登记包（$SD/pkgs/$G.env），走正常出包"; exit 2; }
B=$(cd -P "$RT/$G@pkg-$BC" 2> /dev/null && pwd) || { echo "【黄】$G 登记包 $BC 的产物根 $RT/$G@pkg-$BC 不在了，走正常出包"; exit 2; }
[ -f "$BP/$G.ipa" ] && [ -d "$BP/pack" ] || { echo "【红】$G 登记包快照 $BP 不完整（缺 ipa 或 pack/）"; exit 1; }
if [ $REG = 1 ]; then   # 不联网：origin/main 由本机列车合入时更新，本机已是最新（11-02 jhz）
  git -C "$R" merge-base --is-ancestor HEAD origin/main 2> /dev/null || { echo "【红】$C 不在 origin/main 上：只出程序可以出，但不许登记成正式包（去掉 --register）"; exit 1; }; fi
# ② 产物键
KS=$(${S2A_APP_ONLY_KEYS:-bash "$R/pack/stage_keys.sh"} "$G" "$B") || { echo "【红】${G} 算阶段键失败"; exit 1; }   # S2A_APP_ONLY_KEYS / _IPA：单测换桩（10-28 前出错处理写在注释里被吞）
diff=; while IFS=$'\t' read -r s k b; do
  if [ "$s" = shaders ]; then [ "${k%%-*}" = "${b%%-*}" ] || diff="$diff 着色器（代码段 ${k:0:12} ≠ 登记包 ${b:0:12}）"
  else [ "$k" = "$b" ] || diff="$diff ${s}（${k:0:12} ≠ 登记包 ${b:0:12}）"; fi
done < <(printf '%s\n' "$KS")
[ -n "$KS" ] || diff=" 一个阶段键都没算出来"
[ -z "$diff" ] || { echo "【黄】$G 本提交 $C 相对登记包 $BC 改了预编产物：${diff# }——不适用只换程序，走正常出包"; exit 3; }
# ③ 只出程序
O=$OUTR/$G-$C; rm -rf "$O.tmp"; mkdir -p "$O.tmp/ipa_out" || exit 1
S2A_PACK_PRIO=${S2A_PACK_PRIO:-1} S2A_APP_ONLY_FROM=$B S2A_APP_ONLY_OUT=$O.tmp/ipa_out ${S2A_APP_ONLY_IPA:-bash "$R/pack/ipa.sh"} "$G" > "$O.tmp/ipa.log" 2>&1 \
  || { echo "【红】$G 只出程序失败：$(grep '【红】' "$O.tmp/ipa.log" | tail -1 | cut -c1-200)（$O.tmp/ipa.log）"; exit 1; }
# ④ 克隆登记包快照、换 ipa
cp -cR "$BP" "$O.tmp/pkg" && cp "$O.tmp/ipa_out/$G.ipa" "$O.tmp/pkg/$G.ipa" && cp "$O.tmp/ipa_out/timing.tsv" "$O.tmp/pkg/timing.tsv" || { echo "【红】$G 组新包失败"; exit 1; }
printf '%s\n' "只换程序：程序 ${C}，资源包 / 归档 / 改写产物沿用登记包 ${BC}（$(basename "$B")）" > "$O.tmp/pkg/app_only.txt"
rm -rf "$O"; mv "$O.tmp" "$O"
ls -dt "$OUTR/$G"-* 2> /dev/null | grep -v '\.tmp$' | tail -n +3 | while read -r d; do rm -rf "$d"; done   # 每款只留最近两份（登记时 sched.sh pkg 另存快照，这里删了不影响已登记的）
echo "🟢 $G 只换程序包 $O/pkg（$((SECONDS - t0)) 秒）：程序 $C + 登记包 $BC 的资源与归档；$(grep '只出程序' "$O/ipa.log" | tail -1 | cut -c1-120)"
[ $REG = 1 ] || exit 0
S2A_PKG_NOTE="只换程序（资源沿用 ${BC}）" bash "$R/tools/sched.sh" pkg "$G" "$O/pkg" "$C"
