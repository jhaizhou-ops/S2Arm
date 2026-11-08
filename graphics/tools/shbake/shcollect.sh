#!/bin/bash
# 运行时着色器缓存收集器（画面·着色器线首局根治 C①：每局遇到包里没有的代码，自动收回、并入下一版包）：
#   bash graphics/tools/shbake/shcollect.sh <款> [<局目录 | 缓存目录>…]
#   不给目录 = 扫调度作业里该款的局（$S2A_SCHED_DIR/jobs/*/out_*/，job.env GAME=<款>）；局目录下的 shcache_rt/（四个缓存文件）由真机执行器 tools/dev_run.sh 收局拉回，拉不全的读不了、跳过。
#   候选缓存里有「现行包着色器缓存 + 已收的各份」都没有的程序（S2A.ShBake guest-new：口径一致按代码 + 特化状态比，否则只比客体代码）→ 收进
#   $S2A_SHCOLLECT/<款>/<程序号>/<内容指纹>/（APFS 克隆）；已收的某份的代码全被新收这份包含 → 删掉那份（同一批代码只留一份）。
#   出包 pack/stage_shaders.sh 先调本脚本，再把收集目录里的每份作 --ref-guest 交给烘焙，各份指纹进着色器缓存键。
#   只在本机用，不分发（内容是游戏的着色器代码）。
set -u
G=${1:?款}; shift; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../.." && pwd)
COL=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}; SD=${S2A_SCHED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}
SB=${S2A_SHBAKE:-$R/build/shbake/S2A.ShBake}
# 不在这里编 S2A.ShBake（九款刷新并行时同一工程并发编会互踩 obj/）：现有二进制不认 guest-new（旧版 / 没编过）→ 本次不收、退出 0，shader_pack.sh 编好后下次刷新再收
"$SB" guest-new /nonexistent 2>&1 | grep -q '没有 shared.toc' || { echo "【黄】shcollect：$SB 不认 guest-new（没编或旧版），本次不收"; exit 0; }
# 现行包的着色器缓存（基准）：调用方可用 S2A_SHCOLLECT_BASE=<产物根> 指定，缺省取现行产物根
if [ -n "${S2A_SHCOLLECT_BASE:-}" ]; then BASE=$S2A_SHCOLLECT_BASE; else source "$R/pack/roots.sh"; BASE=$(root_cur "$G"); fi
# 程序号取现行包 shaders/shcache/<程序号>/（拉回的 shcache_rt/ 下不分程序号）
TID=$(ls "$BASE/shaders/shcache" 2> /dev/null | head -1); [ -n "$TID" ] || { echo "【黄】shcollect：$G 现行包没有 shaders/shcache/<程序号>/，本次不收"; exit 0; }
# 候选：每个 <目录>/shcache_rt/ 或直接给的缓存目录（含 shared.toc）
CANDS=()
add_from() { local d=$1 t; if [ -f "$d/shared.toc" ]; then CANDS+=("$d"); return; fi
  [ -f "$d/shcache_rt/shared.toc" ] && CANDS+=("$d/shcache_rt"); }
if [ $# -gt 0 ]; then for d in "$@"; do add_from "$d"; done
else for e in "$SD"/jobs/*/job.env; do [ -f "$e" ] || continue; [ "$(sed -n 's/^GAME=//p' "$e" | head -1)" = "$G" ] || continue
  # 实验包（实验身份 io.s2arm-exp.<款>，sched submit --pkg）的局不收（10-22 测试出包线：塞尔达社区缓存 A/B 的 on 局把社区缓存翻出的 8899 支代码经这里收进了正式包）：
  #   实验包里是什么代码由做实验的线定，不能自动进正式包；要收就显式把局目录作参数给本脚本
  case "$(sed -n 's/^BUNDLE=//p' "$e" | head -1)" in io.s2arm-exp.*) continue;; esac
  for o in "$(dirname "$e")"/out_*/; do [ -d "$o" ] && add_from "${o%/}"; done; done; fi
[ "${S2A_SHCOLLECT_LIST:-0}" = 1 ] && { for c in ${CANDS[@]+"${CANDS[@]}"}; do echo "$c"; done; exit 0; }   # 只列候选、不收（单测用）
n_new=0 n_skip=0 n_drop=0 n_cpfail=0
for c in ${CANDS[@]+"${CANDS[@]}"}; do
  tid=$TID; D=$COL/$G/$tid
  have=("$BASE/shaders/shcache/$tid")
  for k in "$D"/*/; do [ -f "$k/shared.toc" ] && have+=("${k%/}"); done
  # 这局用的包本身干不干净（10-22 测试出包线：受污染的正式包跑出的局把社区缓存代码二次带回收集目录）：运行时缓存 = 这局装的包的缓存 + 真跑出来的新代码，
  #   收集器整份存、整份作 --ref-guest 烘；这局装的包里只要有「现行包 + 已收各份」之外的程序（实验包 / 受污染包），整份就会把它们带进来 → 这局不收。
  #   作业的包快照（jobs/<局>.job 的 PKG）已被 gc 删 → 改核局目录里的 pkg_shcache/；两样都没有、核不了 → 也不收（报黄）；显式给的缓存目录（不在作业里）照旧
  case $c in "$SD"/jobs/*/out_*/shcache_rt)
    jf=${c%/out_*/shcache_rt}.job; pk=$( [ -f "$jf" ] && ( . "$jf" 2> /dev/null; echo "${PKG:-}" ) )
    pc=$pk/pack/shaders/shcache/$tid
    # 包快照被 gc 删了就用局目录里执行器同时克隆的包缓存（tools/dev_run.sh 写 out_*/pkg_shcache/，10-23 起）
    [ -n "$pk" ] && [ -f "$pc/shared.toc" ] || pc=${c%/shcache_rt}/pkg_shcache
    [ -f "$pc/shared.toc" ] || { echo "【黄】shcollect：${c} 的包快照找不到（${pk:-作业里没有 PKG}）、局目录也没有 pkg_shcache/，核不了包干不干净，不收"; n_skip=$((n_skip + 1)); continue; }
    r0=$("$SB" guest-new --code "$pc" ${have[@]+"${have[@]}"} 2>&1) || { echo "【黄】shcollect：读不了包缓存 ${pc}（${r0}），不收 ${c}"; n_skip=$((n_skip + 1)); continue; }   # --code：只比客体代码（着色器线 10-22：口径一致时缺省连特化状态比，翻译器缺省状态一变，干净旧包会被误判）。10-28 前出错处理写在注释里被吞
    [ "$(echo "$r0" | sed -n 's/^新 \([0-9]*\) 总.*/\1/p')" = 0 ] || { echo "shcollect：$G 不收 ${c}：这局装的包里有现行包与已收各份之外的程序（${r0}；实验包 / 受污染包）"; n_skip=$((n_skip + 1)); continue; };;
  esac
  r=$("$SB" guest-new "$c" ${have[@]+"${have[@]}"} 2>&1) || { echo "【黄】shcollect：读不了 ${c}（${r}），跳过"; continue; }
  nw=$(echo "$r" | sed -n 's/^新 \([0-9]*\) 总.*/\1/p'); [ -n "$nw" ] || { echo "【黄】shcollect：${c} 输出不认识（${r}），跳过"; continue; }
  [ "$nw" -gt 0 ] || { n_skip=$((n_skip + 1)); continue; }
  fp=$(cat "$c"/shared.toc "$c"/shared.data "$c"/guest.toc "$c"/guest.data | shasum -a 256 | cut -c1-16)
  # 四个文件 + from.txt 全写成才替换旧的同指纹目录（审计 #806 第 3 条：原先不看 cp 退出码，卷满 / 源中途不可读时照样 rm -rf 旧的完整一份、拿半份或空目录顶上，
  #   下一轮 36 行只看 shared.toc 在不在就算进 have）；有一步失败 → 删临时目录、旧的原样留着、报红，末行计数、退出 1
  ef=; mkdir -p "$D/.tmp_$fp" || ef=mkdir
  for f in shared.toc shared.data guest.toc guest.data; do [ -z "$ef" ] || break; cp -c "$c/$f" "$D/.tmp_$fp/$f" 2> /dev/null || cp "$c/$f" "$D/.tmp_$fp/$f" || ef=$f; done
  [ -n "$ef" ] || echo "$c" > "$D/.tmp_$fp/from.txt" || ef=from.txt
  if [ -n "$ef" ]; then rm -rf "$D/.tmp_$fp"; n_cpfail=$((n_cpfail + 1)); echo "【红】shcollect：$G $tid 拷 ${ef} 失败（来自 ${c}），不收，旧的 $D/$fp 原样保留"; continue; fi
  rm -rf "$D/$fp"; mv "$D/.tmp_$fp" "$D/$fp"; n_new=$((n_new + 1))
  echo "shcollect：$G $tid 收回 ${fp}（${r}；来自 ${c}）"
  # 已收的各份：代码全被这份包含的删掉
  for k in "$D"/*/; do k=${k%/}; [ "$k" = "$D/$fp" ] && continue; [ -f "$k/shared.toc" ] || continue
    s=$("$SB" guest-new "$k" "$D/$fp" 2>/dev/null) && [ "${s%% 总*}" = "新 0" ] && { rm -rf "$k"; n_drop=$((n_drop + 1)); echo "shcollect：$G $tid 删 $(basename "$k")（全被 $fp 包含）"; }; done
done
# 出包 pack/stages/shaders.sh 只看末行（| tail -1）：拷失败的计数写进末行、带【红】
echo "$([ $n_cpfail = 0 ] || echo "【红】")shcollect：$G 候选 ${#CANDS[@]} 份，新收 ${n_new}、没有新代码 ${n_skip}、被包含删掉 ${n_drop}$([ $n_cpfail = 0 ] || echo "、拷贝失败 ${n_cpfail}（旧的保留）")；现有 $(ls -d "$COL/$G"/*/*/ 2> /dev/null | wc -l | tr -d ' ') 份（$COL/${G}）"
[ $n_cpfail = 0 ]
