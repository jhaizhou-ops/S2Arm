#!/bin/bash
# 测试出包线的运行产物保留规则（10-19 总指挥：本机 20 分钟掉 13 GB）：tools/gc.sh [--dry] [--versions]（只剪被取代的版本，见 versions()）
#   调度局目录 sched/jobs：每款保留最近 10 个绿局 + 最近 10 个红局（红局留现场），其余删；超过 12 小时的（没被引用、没 .keep）整个删（10-25）；局目录里的包副本（*.ipa、pso.metallib）收局即删（sched.sh 已做）
#   Mac 健康表 health/：保留最近 10 次
#   产物根 roots/：每款只留现行 + 上一版（pack/roots.sh 提交时也按此剪）；没有现行的散版本不动（报一行）
#   调度包快照 sched/pkgstore：每款只留登记中的那一份（sched.sh pkg 已做），这里再兜一次底
#   M0 / 判据录局 m0/：最近 3 批 + 旧批红局现场（细则见下）
# 只删本线建的确切目录；APFS 克隆共享块，删版本只释放该版本独有的字节（改写产物、ipa 等），释放量以 df 前后差为准。
set -u
S=${S2A_RUN:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm}; DRY=0; VER=0; for a in "$@"; do case $a in --dry) DRY=1;; --versions) VER=1;; esac; done
# 数据所在卷（11-06 总指挥亲手清 S2A_2T 95 → 507 GB 后复盘）：运行区在内置盘，roots / sched/jobs / sched/pkgstore 等是软链到工作盘 S2A_2T 的目录。
#   原先 df 一律看 "$S"（内置盘，常年 200 GB+），「按盘余量回收」从没触发；find 起点是软链时不跟（find 缺省 -P），「超龄局目录整删」等规则扫到 0 个。
#   余量看数据真正所在的卷 DV（roots 的真实路径；没有 roots 的单测 / 远端 = ${S}）；find 起点一律 -H（只跟起点软链，不跟树里的链）
DV=$(cd -P "$S/roots" 2> /dev/null && pwd -P || echo "$S")
# 删除函数在 pack/roots.sh：仓库里在 ../pack/；常驻调度的冻结副本（sched/auto/tools_<提交>/，只有 tools/）里同目录另存一份 roots.sh。
#   10-20 夜查实：冻结副本里 source 不到它，_root_rm 未定义，gc 一直什么都没删、只报 command not found
H=$(cd "$(dirname "$0")/.." && pwd); RS=$H/pack/roots.sh; [ -f "$RS" ] || RS=$(dirname "$0")/roots.sh
source "$RS" 2>/dev/null; type _root_rm > /dev/null 2>&1 || { echo "【红】gc：取不到删除函数（${RS}），本次不删"; exit 1; }
# 同一运行目录同时只跑一份（10-22 两份 gc 并发、互相截断 gc_last.log）：锁 $S/.gc.lock（mkdir + pid 存活检查，持有者死了收回）；拿不到打一行、退出 0
LKD=$S/.gc.lock; mkdir -p "$S"
#   建不了锁又不存在（盘写满）= 不是别人持有：不加锁照跑（满盘正是最要 gc 的时候）；锁里还没写 pid 的、1 分钟内新建的算对方刚拿到
#   锁里记「pid 起始时间」（10-25 mini：gc_last.log 一直「另一份 gc 在跑（pid 16822）」，16822 早被别的进程复用、gc 一直被跳过）：pid 活着且起始时间对得上才算对方在跑
lk_start() { ps -o lstart= -p "$1" 2> /dev/null | awk '{$1 = $1} 1'; }
if ! mkdir "$LKD" 2> /dev/null && [ -d "$LKD" ]; then
  read -r p pst < "$LKD/pid" 2> /dev/null
  #   旧格式锁（只有 pid、没有起始时间，10-25 修之前写的）：60 分钟没动就当残留接管（pid 可能早被复用，mini 的 16822 就是这样）
  if { [ -n "$p" ] && kill -0 "$p" 2> /dev/null && { { [ -z "${pst:-}" ] && [ -n "$(find "$LKD" -maxdepth 0 -mmin -60)" ]; } || { [ -n "${pst:-}" ] && [ "$(lk_start "$p")" = "$pst" ]; }; }; } || { [ -z "$p" ] && [ -n "$(find "$LKD" -maxdepth 0 -mmin -1)" ]; }; then echo "gc：另一份 gc 在跑（pid ${p:-?}），本次跳过"; exit 0; fi
  rm -rf "$LKD"; mkdir "$LKD" 2> /dev/null || { echo "gc：另一份 gc 在跑（刚拿到锁），本次跳过"; exit 0; }
fi
echo "$$ $(lk_start $$)" > "$LKD/pid" 2> /dev/null
GL=$(mktemp); trap 'rm -f "$GL"; [ "$(cut -d" " -f1 "$LKD/pid" 2> /dev/null)" = $$ ] && rm -rf "$LKD"' EXIT   # 只收自己的锁（满盘没加上锁时不碰别人后来拿的）
# 硬保护（10-21 总指挥：不依赖各线记得放 .keep）：milestones/（验收证据，10-20 删过 M0 验收批）、jhz_saves/、jhz_review/ 下一律不删；
#   调度局目录被记分板「局目录」列或 milestones 里任何文件引用的不删。命中只打「受保护，不删」
# 输入 / 工具依赖 / 门禁数据：不可再生或重建很贵，按路径一律不删（本机 prot 与远端回收共用这一张；10-27 mini 远端 gc 删了 saves/ 和 deps/rewriter-deps，
#   所有派到 mini 的门禁红在 make_pack_rewriter_test）。门禁数据那几项同 bin/safe_rm.sh 的拒删表。toolchain、假家目录的 .secrets 不在 run/s2arm 下，gc 不扫
KEEP_DIRS="saves saves_bak saves_backup jhz_saves jhz_review milestones deps bin openfonts replay visual gate_data apreg diffrec"
PROT=$(for k in $KEEP_DIRS; do printf '%s ' "$S/$k"; done); BOARD=${S2A_BOARD:-run/记分板.tsv}
REFJ=$( { cut -f11 "$BOARD" 2>/dev/null; LC_ALL=C grep -rhoa '[~/][^[:space:]"'"'"']*sched/jobs/[A-Za-z0-9_]*' "$S/milestones" 2>/dev/null; } | sed "s|^~/|$HOME/|" | sed -n "s|^\($S/sched/jobs/[A-Za-z0-9_]*\).*|\1|p" | sort -u)
# seed.txt 的 src= 指向的原版解包目录按路径保护（10-28 事故：清盘清单把 xc3 的原版解包目录当副本删了，出包卡在找不到 romfs）。
#   本机与远端共用：扫产物根的 seed.txt，被引用的 src 及其祖先目录不删。本机按 $S 下的 roots / roots_priv + SSD；远端加扫 rpack 根
#   S2A_ROOTS_SSD：另加扫描的产物根目录（给了才扫；11-05 起不再缺省外接 SSD 的 work 目录——SSD 已从 Air 挪给天眼，写死的盘路径会静默漏扫 / 扫空）
_ssd=${S2A_ROOTS_SSD:-}
if [ -n "${S2A_GC_REMOTE_ROOT:-}" ]; then
  SEEDSRC=$(S2A_ROOTS="$S/roots:$S/roots_priv:${S2A_GC_REMOTE_ROOT}/home/rpack/roots" python3 "$H/tools/seed_refs.py" 2>/dev/null)
else
  SEEDSRC=$(S2A_ROOTS="$S/roots:$S/roots_priv${_ssd:+:$_ssd}" python3 "$H/tools/seed_refs.py" 2>/dev/null)
fi
unset _ssd
# 存档按路径保护、不看修改时间（10-27 mini 远端 gc 把 saves/ 整个删了：存档是 rsync -a 拷的，保留了 10-2x 的修改时间，「最后使用」判成很久没用；
#   同类坑 10-26 gc-slims-job-save-before-push）：saves/、saves_bak/、任何一层叫 save / saves 的目录、带 .keep 的目录，本机与远端都不删
prot_seed() { [ -z "${SEEDSRC:-}" ] && return 1   # 命中：候选等于某 src 或是它的祖先（某 src 在候选下面）
  local p="${1%/}" s; while IFS= read -r s; do [ -n "$s" ] || continue
    [ "$s" = "$p" ] && return 0; case "$s/" in "$p"/*) return 0;; esac; done < <(printf '%s\n' "${SEEDSRC}"); return 1; }
prot() { local p; for p in $PROT; do case "$1/" in "$p"/*) return 0;; esac; done
  case "$1/" in */save/*|*/saves/*) return 0;; esac; [ -e "$1/.keep" ] && return 0; prot_seed "$1" && return 0; grep -qxF "$1" < <(printf '%s\n' "$REFJ"); }
del() { prot "$1" && { echo "受保护，不删 $1"; return 0; }; if [ $DRY = 1 ]; then echo "会删 $1"; else _root_rm "$1" && { echo "删 $1"; echo "$1" >> "$GL"; } || echo "【红】gc：删不掉 $1"; fi; }   # 逐项打出删了什么（10-21：只报可用空间差，别的进程同时在写时差值为负，看不出删没删）
a0=$(df -k "$DV" | awk 'NR==2{print $4}'); n=0
# RomFS 共享存储（pack/roots.sh）：删掉 .tmp / 旧版本后，没有版本再指向的身份一并删（冻结副本里的旧 roots.sh 没有这个函数就跳过）
romfs_sweep() { [ $DRY = 1 ] || ! type root_romfs_sweep > /dev/null 2>&1 || S2A_ROOTS=$1 root_romfs_sweep 2>&1; }
# 被取代的版本（产物根 / 包快照 / 远端 rpack 常驻根）：每款只留现行 + 上一版。平常 gc 在原位置跑；tools/gc.sh --versions 只跑这一段就退出
#   （10-29 总指挥：常态回收挂进运维线 15 分钟巡检，三台都跑；不扫目录、只按版本名剪，几秒）
versions() {
# 产物根里被打断的出包留下的 <款>@<版本>.tmp（root_begin 建、root_commit / root_abort 收；进程被杀就留下）：持有者已死且 2 小时没动就删（10-20 一个就占 1.7 GB 独有字节）。
#   持有者（.root_pid，roots.sh root_tmp_live）还活着的不删，不管多久没动（10-23 社区数据 / texscale 两包排烘焙道 2 小时 10 分钟，.tmp 被按时间删掉、出包中途失败）；
#   没有持有者记录的（旧格式）按时间兜底
find -H "$S/roots" "$S/roots_priv" -mindepth 1 -maxdepth 2 -type d -name '*.tmp' -mmin +120 2>/dev/null | while read -r d; do
  if type root_tmp_live > /dev/null 2>&1 && root_tmp_live "$d"; then echo "在用，不删 ${d}（持有者 $(cut -d' ' -f1 "$d/.root_pid") 还活着）"; else del "$d"; fi; done
# 产物根回收目录（pack/roots.sh _root_trash：被取代的整根挪进 .trash/<名>.<pid>.<随机> 后台删）：删的进程被打断留下的残余——名字里的 pid 已不在就删
for d in "$S/roots"/.trash/* "$S/roots_priv"/*/.trash/*; do [ -e "$d" ] || continue; p=${d%.*}; p=${p##*.}
  case $p in ''|*[!0-9]*) del "$d";; *) kill -0 "$p" 2> /dev/null && echo "在删，跳过 ${d}（pid ${p} 还活着）" || del "$d";; esac; done
# 产物根：每款现行 + 上一版
for cur in "$S/roots"/*@现行; do
  [ -L "$cur" ] || continue; g=$(basename "$cur"); g=${g%@现行}; c=$(basename "$(readlink "$cur")")
  ls -dt "$S/roots/$g"@* 2>/dev/null | grep -v -e '@现行$' -e '\.tmp$' | while read -r d; do [ "$(basename "$d")" = "$c" ] || echo "$d"; done | tail -n +2 | while read -r d; do { type _root_pinned > /dev/null 2>&1 && S2A_ROOTS=$S/roots _root_pinned "$d"; } && { echo "钉住，不删 ${d}（有进程正把它当输入，pack/roots.sh _root_pin）"; continue; }; del "$d"; done
done
romfs_sweep "$S/roots"
# 包快照：只留各款登记中的 + 排队 / 在跑作业引用的（按 source 出的路径比；10-20 grep 作业文件原文对不上 %q 转义的「无」，删了排队作业的快照）
#   每款在该款的登记锁（sched/pkgs/.<款>.glock，sched.sh glock 同一把）里删：锁内重取登记与引用，删前不会和同款新包登记 / 派发撞上（10-21 动森快照被删）
source "$(dirname "$0")/plock.sh"
# 按款遍历 pkgstore 里实际有快照的款（11-06：原先只遍历 pkgs/*.env 有登记的款，登记撤掉 / 从没转正的款快照永远轮不到，88 份无引用快照钉着旧块）
for g in $( { for f in "$S/sched/pkgs"/*.env; do [ -f "$f" ] && basename "$f" .env; done; for o in "$S/sched/pkgstore"/*/; do [ -d "$o" ] || continue; o=${o%/}; o=${o##*/}; echo "${o%%-*}"; done; } | sort -u); do f=$S/sched/pkgs/$g.env
  PLOCK_POLL_S=0.2 plock_take "$S/sched/pkgs/.$g.glock" 60 || { echo "gc：$g 的登记锁 60 秒没拿到，本次不清它的快照"; continue; }   # 与 sched.sh glock 同一把内核文件锁（审计 P1-27）
  L_PID=$PLOCK_PID
  keep=$( [ -f "$f" ] && . "$f" && echo "$PKG"); REFD=$(S2A_SCHED_DIR=$S/sched bash "$(dirname "$0")/sched.sh" refs)   # 值是 printf %q 写的（路径里的「无」会被转义），要 source 取，不能 sed
  # 每款留：现行登记包 + sched.sh refs（在排 / 在跑作业引用的、等冒烟的候选、每台测试机上各应用身份现装的）+ 其余里最近的 1 个旧包（10-21 总指挥定）；其余删
  n=0; ls -dt "$S/sched/pkgstore/$g"-* 2> /dev/null | while read -r o; do [ -d "$o" ] || continue
    [ "$o" = "$keep" ] || grep -qxF "$o" < <(printf '%s\n' "$REFD") && continue
    n=$((n + 1)); [ $n -le "$([ -n "$keep" ] && echo 1 || echo 0)" ] || del "$o"; done   # 有登记的款多留 1 个旧包作回退；没登记的款无引用即删
  plock_release "$L_PID"; done
# 远端 rpack 常驻根 <远端根>/home/rpack/roots：每款现行 + 上一版（10-29 总指挥：被取代的版本常态回收，不等盘低；原先只在 rpack 下次给这款推根时清，
#   mini 上巫师3 的 rx / ex 两版各 du 71 GB 堆着）。.tmp（刷新写到一半的）不碰；在跑的远端命令登记了 rpack/roots/<款>@ 的整款不动
if [ -n "${S2A_GC_REMOTE_ROOT:-}" ] && [ -d "$S2A_GC_REMOTE_ROOT/home/rpack/roots" ]; then RPR=$S2A_GC_REMOTE_ROOT/home/rpack/roots
  for cur in "$RPR"/*@现行; do
    [ -L "$cur" ] || continue; g=$(basename "$cur"); g=${g%@现行}; c=$(basename "$(readlink "$cur")")
    for f in "$S2A_GC_REMOTE_ROOT"/wt/*.pid; do p=$(cat "$f" 2> /dev/null); [ -n "$p" ] && kill -0 "$p" 2> /dev/null && grep -q "rpack/roots/$g@" "${f%.pid}.uses" 2> /dev/null && { echo "在用，不剪 rpack ${g}（在跑的远端命令登记了它）"; continue 2; }; done
    ls -dt "$RPR/$g"@* 2>/dev/null | grep -v -e '@现行$' -e '\.tmp$' | while read -r d; do [ "$(basename "$d")" = "$c" ] || echo "$d"; done | tail -n +2 | while read -r d; do del "$d"; done
  done
  romfs_sweep "$RPR"
fi
# 本机直连缓存按容量预算淘汰（11-02 出包线，jhz「存储换时间」：缓存放 2T，超预算才删最久没用的，不按天数删）：cache/direct 下全部款合计超
#   S2A_DIRECT_CACHE_BUDGET_GB（缺省 300；11-02 时 67 款合计 108 GB、2T 剩 703 GB）时，按仓条目修改时间从旧到新删（出库整理只刷新用到的条目、不删）；
#   进程命令行里出现 cache/direct/<程序号> 的款在出包，整款不动。远端另按空闲时长整款淘汰（下一段）
if [ -z "${S2A_GC_REMOTE_ROOT:-}" ] && [ -d "$S/cache/direct" ]; then
  DIU=$(ps -axo command= 2> /dev/null | grep -o 'cache/direct/[0-9A-Fa-f]\{16\}' | sed 's|.*/||' | sort -u | tr '\n' ',')
  python3 "$H/tools/direct_cache_lru.py" "$S/cache/direct" --budget-gb "${S2A_DIRECT_CACHE_BUDGET_GB:-300}" --in-use "$DIU" $([ $DRY = 1 ] && echo --dry) \
    || echo "【红】gc：直连缓存预算淘汰失败（tools/direct_cache_lru.py）"
fi
# 远端按款空闲淘汰（10-29 出包线：三机分工后解包 / 出包集中本机，远端只放当前派到这台的款；Air 上 13 款直连缓存 du 190 GB、mini 上 4 款 rpack 常驻根 du 208 GB
#   全是做完的款在堆）：不等盘低，每轮都把空闲超过 S2A_GC_REMOTE_EVICT_H（缺省 6）小时的按款整份删——
#   直连缓存 cache/direct/<程序号>（前 3 层没有文件在空闲期内改过）、rpack 常驻根 rpack/roots/<款>@*（该款各版前 2 层都没改过，连 @现行 一起）。
#   在跑的远端命令（wt/<名>.pid 活着）在 <名>.uses 里登记了的不动；S2A_GC_REMOTE_EVICT_H=0 关。都可再生：本机有原件与共享根，下次派到这台时重推 / 重编
if [ -n "${S2A_GC_REMOTE_ROOT:-}" ] && [ "${S2A_GC_REMOTE_EVICT_H:-6}" != 0 ]; then EM=$(( ${S2A_GC_REMOTE_EVICT_H:-6} * 60 ))   # 0 = 关（单测测别的规则时用）
  ruses() { local f p; for f in "$S2A_GC_REMOTE_ROOT"/wt/*.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2> /dev/null); [ -n "$p" ] && kill -0 "$p" 2> /dev/null && cat "${f%.pid}.uses" 2> /dev/null; done; }
  RU=$(ruses)
  for d in "$S/cache/direct"/*/; do d=${d%/}; [ -d "$d" ] || continue; t=$(basename "$d")
    [ -n "$(find "$d" -maxdepth 3 -mmin -"$EM" -print -quit 2> /dev/null)" ] && continue
    grep -q "cache/direct/$t" <<< "$RU" && { echo "在用，不淘汰直连缓存 ${t}"; continue; }
    del "$d"; done
  # 普查远端款目录 census/<批次>/work/<键>（tools/census/census.sh 把解包目录同步过来就地出包 + 起局；「局后清」只在远端命令正常收尾时跑，
  #   批次被停 / 命令被杀时留下，10-29 Air 积了 40 GB）：前 4 层空闲超过 S2A_GC_REMOTE_CENSUS_H（缺省 1）小时、在跑命令没登记的删；整批空闲超 24 小时的整批删
  CM=$(( ${S2A_GC_REMOTE_CENSUS_H:-1} * 60 ))
  # 先判整批（删了款目录会刷新批次目录的修改时间）
  for d in "$S"/census/*/; do d=${d%/}; [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 4 -mmin -1440 -print -quit 2> /dev/null)" ] && continue
    grep -q "census/$(basename "$d")/" <<< "$RU" && continue
    [ -n "$(find "$d" -maxdepth 4 -name .留证 -print -quit 2> /dev/null)" ] && continue
    del "$d"; done
  for d in "$S"/census/*/work/*/; do d=${d%/}; [ -d "$d" ] || continue; k=$(basename "$d"); b=$(basename "$(dirname "$(dirname "$d")")")
    [ -n "$(find "$d" -maxdepth 4 -mmin -"$CM" -print -quit 2> /dev/null)" ] && continue
    grep -q "census/$b/work/$k/" <<< "$RU" && continue
    [ -n "$(find "$d" -maxdepth 3 -name .留证 -print -quit 2> /dev/null)" ] && continue   # 普查留证款（10-30 泛化线）：保留到批次收尾
    del "$d"; done
  if [ -d "$S2A_GC_REMOTE_ROOT/home/rpack/roots" ]; then
    for g in $(ls "$S2A_GC_REMOTE_ROOT/home/rpack/roots" | sed -n 's/^\([^.][^@]*\)@.*/\1/p' | sort -u); do
      [ -n "$(find "$S2A_GC_REMOTE_ROOT/home/rpack/roots/$g"@* -maxdepth 2 -mmin -"$EM" -print -quit 2> /dev/null)" ] && continue
      grep -q "rpack/roots/$g@" <<< "$RU" && { echo "在用，不淘汰 rpack ${g}"; continue; }
      L="$S2A_GC_REMOTE_ROOT/home/rpack/roots/$g@现行"; [ -L "$L" ] && { [ $DRY = 1 ] && echo "会删 $L" || { rm -f "$L" && echo "删 $L"; }; }   # 软链先删（版本目录删后它悬空，_root_rm 判不存在会跳过）
      for d in "$S2A_GC_REMOTE_ROOT/home/rpack/roots/$g"@*; do [ -L "$d" ] || del "$d"; done; done
    romfs_sweep "$S2A_GC_REMOTE_ROOT/home/rpack/roots"
  fi
fi
}
# 全机解包缓存 cache/unpack/<程序号>-<键>（pack/stages/unpack.sh，11-02 jhz：解包结果共用）：每个程序号只留最近用过的 1 份；
#   总量超 S2A_UNPACK_CACHE_GB（缺省 300）从最久没用的删起（大小读旁边的 .size，没有就 du）。解包目录 / 产物根是克隆，删缓存只释放没人在用的独有字节
#   在用按进程判（同直连缓存）：进程命令行里出现条目名 <程序号>-<键> 的不动（unpack.sh 正从它克隆）；cache/unpack/.keep 里列的程序号（一行一个，
#   运维线写入待跑 / 手测队列 / 待复判款）不动。11-02 22:5x 主 2T 掉到 67 GB：这段原先只在全量 gc 里，常规回收只跑 --versions 到不了，88 条只增不减，
#   所以抽成函数、--versions 也跑（只读 .size，几秒）
unpack_cap() {
  local UCD=${S2A_UNPACK_CACHE:-$S/cache/unpack} t d sz ucap usum busy keep
  [ -d "$UCD" ] && [ "$UCD" != off ] || return 0
  busy=$(ps -axo command= 2> /dev/null | grep -o '[0-9A-F]\{16\}-[0-9a-f]\{1,\}' | sort -u)
  keep=$(cat "$UCD/.keep" 2> /dev/null)
  idle() { local n=${1##*/}; ! grep -qxF "$n" < <(printf '%s\n' "$busy") && ! grep -qxF "${n%%-*}" < <(printf '%s\n' "$keep"); }
  for t in $(ls "$UCD" 2> /dev/null | sed -n 's/^\([0-9A-F]\{16\}\)-[0-9a-f]*$/\1/p' | sort -u); do
    ls -dt "$UCD/$t"-*/ 2> /dev/null | grep -v '\.tmp\.' | tail -n +2 | while read -r d; do d=${d%/}; idle "$d" && { del "$d"; [ $DRY = 1 ] || rm -f "$d.size"; }; done; done
  for d in "$UCD"/*.tmp.*; do [ -d "$d" ] || continue; kill -0 "${d##*.tmp.}" 2> /dev/null || del "$d"; done   # 写到一半的半成品 <条目>.tmp.<pid>：写入进程不在了就清（体验线 11-02）
  ucap=$(( ${S2A_UNPACK_CACHE_GB:-300} * 1048576 )); usum=0
  ls -dt "$UCD"/*/ 2> /dev/null | grep -v '\.tmp\.' | while read -r d; do d=${d%/}; sz=$(cat "$d.size" 2> /dev/null || du -sk "$d" | cut -f1); usum=$((usum + ${sz:-0}))
    [ $usum -gt $ucap ] && idle "$d" && { del "$d"; [ $DRY = 1 ] || rm -f "$d.size"; }; done
}
[ "$VER" = 1 ] && { versions; unpack_cap; a1=$(df -k "$DV" | awk 'NR==2{print $4}'); echo "gc --versions：剪掉被取代的版本 $(wc -l < "$GL" | tr -d ' ') 项，可用 $((a0 / 1048576)) → $((a1 / 1048576)) GB"; exit 0; }
# 调度局目录：按款、按红绿分组，各留最近 10 个
if [ -d "$S/sched/jobs" ]; then
  for g in $(ls "$S/sched/jobs" | sed -n 's/^\([a-z0-9]*\)_[0-9]*_[12]$/\1/p' | sort -u); do
    for kind in done red; do
      ls -dt "$S/sched/jobs/${g}_"*_[12] 2>/dev/null | while read -r j; do
        r=$(grep -h '^RESULT=' "$j/r.txt" 2>/dev/null | tail -1); case "$r" in RESULT=done*) k=done;; *) k=red;; esac
        [ "$k" = "$kind" ] && echo "$j"; done | tail -n +11 | while read -r j; do [ -e "$j/.keep" ] && continue; del "$j"; done   # 作业文件 <局>.job 不删（几百字节，记分板按它认 OWNER）   # 带 .keep（实验局结论未回收）不删
    done
  done
fi
# 局目录瘦身（10-23 总指挥：盘剩 105 GB，jobs 103 GB；读数已进记分板 / 看板的局删可再生大文件，留 host.log / frames.tsv / 截图等小证据）：
#   拉回的着色器缓存 shcache_rt/（收集器每次出包重扫、已收的另存 shcollect/）、帧抓取 framecap.bin、Vulkan 管线缓存、xctrace 导出 12 小时前的删；GAL 录像 gal.rec 24 小时前的删；
#   收局残留的 push.tar / *.ipa 直接删。10-24 补（盘 82 GB、jobs 59 GB）：pkg_shcache/（收集器拿它核对同局 shcache_rt，后者 12 小时后已删）、
#   作业目录推送用的存档副本 save/（原件在 saves/ 与包快照）同 12 小时。截图里收局截图 screen/end.png 48 小时（10-24 总指挥定）；
#   MARK 截图 screen/mark.png 与 shots*/ 是判画面 / 核 MARK 的证据，不动。
#   记分板引用的局照样瘦身（整局保护只管不删局目录）；实验局 .keep（sched.sh 自动写「结论回收后 unkeep」、各线常忘了回收，
#   10-23 积到 391 个 / 44 GB）超过 24 小时也瘦身；其余 .keep（验收证据）与里程碑引用的不动。S2A_GC_SLIM_AGE_H 覆盖 12（单测用）
# 局的年龄（10-26 运维线：怪猎 / 八方2 / 动森存档在推送前被删、游戏缺档起局崩）：只认「已收局」（r.txt 有 RESULT=）、从写下结论（r.txt 的 mtime）算起，
#   不看各文件自己的 mtime——存档 / ipa / push.tar 是 cp -c 克隆进局目录的、带着原件的旧时刻，刚交单还没推就被当成几天前的。没收局的局两段瘦身一律不碰（打 -1）
jage() { grep -q '^RESULT=' "$1/r.txt" 2> /dev/null || { echo -1; return; }; echo $(( (now - $(stat -f %m "$1/r.txt")) / 3600 )); }
if [ -d "$S/sched/jobs" ]; then SA=${S2A_GC_SLIM_AGE_H:-12}; now=$(date +%s)
  for j in "$S/sched/jobs"/*/; do j=${j%/}
    if [ -e "$j/.keep" ]; then grep -q '的实验局' "$j/.keep" 2> /dev/null && [ $(( (now - $(stat -f %m "$j/.keep")) / 3600 )) -ge 24 ] || continue; fi
    case "$j/" in "$S/milestones"/*) continue;; esac
    ja=$(jage "$j"); [ "$ja" -ge 0 ] || continue
    find "$j" -type f \( -path '*/shcache_rt/*' -o -path '*/pkg_shcache/*' -o -path '*/screen/end.png' -o -name framecap.bin -o -name vulkan_nxgal_bin.data -o -name 'x_metal*.xml' -o -name gal.rec -o -name push.tar -o -name '*.ipa' \) -size +1M 2> /dev/null | while read -r f; do
      a=$ja; case "$f" in */gal.rec) [ $a -ge $((SA * 2)) ] || continue;; */screen/end.png) [ $a -ge $((SA * 4)) ] || continue;; */push.tar|*.ipa) ;; *) [ $a -ge $SA ] || continue;; esac
      if [ $DRY = 1 ]; then echo "会瘦身 $f"; else rm -f "$f" && echo "$f" >> "$GL"; fi; done
  done
fi
# 局目录 12 小时瘦身到白名单（10-24 总指挥：盘 100 GB、jobs 48 GB；记分板能复算就行；当天再缩 24 → 12 小时，jobs 独占仍 27 GB）：超过 12 小时的局，大于 256 KB 的文件只留
#   frames.tsv、host.log、shots_ap/ap_mark.png（记分板 / 核 MARK 的证据；同局有 ap_mark.png 时 screen/mark.png 是同一时刻的重复证据、也删，
#   10-24 总指挥批：每局约 3 MB、千余局约 3 GB；没有 ap_mark.png 的局 screen/mark.png 照留），其余（pkg_shcache、shcache_rt、收局 / 过程截图、
#   save 副本、r.index、推送清单、gal.rec、framecap.bin、ipa、logarchive …）一律删；小文件（结论行 r.txt、job.env、pw*.plist、timing.tsv 等）不动。
#   保护同上：非实验局的 .keep 整局不动、实验局 .keep 超过 24 小时照瘦；milestones 不在 jobs 下。S2A_GC_WL_AGE_H 覆盖 12（单测用）
if [ -d "$S/sched/jobs" ]; then WA=${S2A_GC_WL_AGE_H:-12}; now=$(date +%s)
  for j in "$S/sched/jobs"/*/; do j=${j%/}
    if [ -e "$j/.keep" ]; then grep -q '的实验局' "$j/.keep" 2> /dev/null && [ $(( (now - $(stat -f %m "$j/.keep")) / 3600 )) -ge 24 ] || continue; fi
    [ "$(jage "$j")" -ge "$WA" ] || continue   # 收局满 12 小时（局的年龄，见 jage）；局里的文件不再各看各的 mtime
    find "$j" -type f -size +256k ! -name frames.tsv ! -name host.log ! -path '*/shots_ap/ap_mark.png' ! -path '*/save/*' 2> /dev/null | while read -r f; do   # save/：存档按路径保护（10-27）
      case $f in */screen/mark.png) [ -s "${f%/screen/mark.png}/shots_ap/ap_mark.png" ] || continue;; esac
      if [ $DRY = 1 ]; then echo "会瘦身 $f"; else rm -f "$f" && echo "$f" >> "$GL"; fi; done
  done
fi
# 健康表：留最近 10 次
[ -d "$S/health" ] && ls -dt "$S/health"/*/ 2>/dev/null | tail -n +11 | while read -r d; do del "${d%/}"; done
versions
# 着色器实验区 shpack/（帧率能耗线；10-20 总指挥授权纳入，本机 20 分钟掉 11 GB）：目录按名字第一段分组（acnh_* / cold_* / island_trace* / mk8d_* …），
#   每组只留最新 3 个（= 现行 + 上一版 + 一份对照；root_* 只留最新 1 个），30 分钟内改过的一律不动（在用）；散文件（*.log / *.out / *.tsv）6 小时前的删。实验包请放在命名可识别的目录里
if [ -d "$S/shpack" ]; then
  now=$(date +%s)
  for grp in $(ls -1 "$S/shpack" | while read -r n; do [ -d "$S/shpack/$n" ] && echo "${n%%[_0-9]*}"; done | sort -u); do
    keep=3; [ "$grp" = root ] && keep=1
    ls -dt "$S/shpack/$grp"*/ 2>/dev/null | tail -n +$((keep + 1)) | while read -r d; do d=${d%/}
      [ $((now - $(stat -f %m "$d"))) -lt 1800 ] || del "$d"; done
  done
  find -H "$S/shpack" -maxdepth 1 -type f \( -name '*.log' -o -name '*.out' -o -name '*.tsv' \) -mmin +360 | while read -r f; do del "$f"; done
fi
# 各工作树的 C# 构建缓存 ~/.s2arm/s2arm-wt/*/build/cs/<平台>-<内容哈希>/：每份约 0.4 GB、代码一变就新建一份、旧的从不删（10-20 一夜攒了 150 多份约 60 GB）。
#   每棵树每个平台（osx-arm64 / ios-arm64 …）只留最新 2 份，30 分钟内改过的不动（可能正在编）；可重建的缓存，删了下次编时重生成
WTR=${S2A_WT_ROOT:-$HOME/.s2arm/s2arm-wt}
for cs in "$WTR"/*/build/cs "$S"/gate_ios/*/src/build/cs "$S/gate_ios_src/build/cs"; do [ -d "$cs" ] || continue   # 门禁 iOS 编译的源码镜像（tools/gate_ios.sh）：镜像本身 rsync --delete 只一份，会攒的是它里面按 C# 键的库
  for plat in $(ls -1 "$cs" 2>/dev/null | sed -n 's/^\(.*\)-[0-9a-f]\{16\}\(\.tmp\)\{0,1\}$/\1/p' | sort -u); do
    ls -dt "$cs/$plat"-* 2>/dev/null | tail -n +3 | while read -r d; do [ -n "$(find "$d" -maxdepth 0 -mmin -30)" ] || del "$d"; done
  done
done
# 整机级构建缓存 cache/nxaot/<平台>-<键>/（services/nxaot.sh，各树共用）每平台留最新 3 份；cache/vpx、cache/opus、cache/dav1d/<平台>-<版本>-<脚本哈希>/ 每平台留 2 份；30 分钟内改过的不动
# 宽屏门禁缓存 cache/widen_gate（画幅线 10-24：rec/ 只是 replay/gal 下 .rec.zst 的解压缓存，缺了门禁按 .zst 自动重解，全部 12 GB 约 6 秒；lib/<键>/ 是离线库）：
#   rec/ 下 2 小时没动的录像删；lib/ 只留最近 2 个键，30 分钟内动过的不动（在途门禁可能在用）。画幅线会把门禁改成流式解压不落盘，届时 rec/ 自然为空
WGC=${S2A_WIDEN_GATE_CACHE:-$S/cache/widen_gate}
[ -d "$WGC/rec" ] && find "$WGC/rec" -type f -mmin +120 2> /dev/null | while read -r f; do del "$f"; done
[ -d "$WGC/lib" ] && ls -dt "$WGC/lib"/*/ 2> /dev/null | tail -n +3 | while read -r d; do d=${d%/}; [ -n "$(find "$d" -maxdepth 1 -mmin -30 | head -1)" ] || del "$d"; done
# 着色器翻译缓存 cache/bake/<程序号>-<键>（graphics/tools/shader_pack.sh 自己每程序号留 3 份，10-24 积到 38 GB、每份 1.8–3.2 GB）：每程序号只留最近 2 份；
#   1 小时内动过的不动（在途烘焙命中时克隆它）。键随翻译器 / 环境变化，旧键基本不会再命中
BCC=${S2A_BAKE_CACHE:-$S/cache/bake}
[ -d "$BCC" ] && [ "$BCC" != off ] && for t in $(ls "$BCC" 2> /dev/null | sed -n 's/^\([0-9a-fA-F]\{16\}\)-.*/\1/p' | sort -u); do
  ls -dt "$BCC/$t"-*/ 2> /dev/null | tail -n +3 | while read -r d; do d=${d%/}; [ -n "$(find "$d" -maxdepth 0 -mmin -60)" ] || del "$d"; done; done
# 追加内容缓存 cache/aoc/<款>-<键>：每款留最近 2 份（产物根是克隆，删缓存只释放没有根在用的独有字节）
[ -d "$S/cache/aoc" ] && for g in $(ls "$S/cache/aoc" | grep -v '\.tmp\.' | sed 's/-[0-9a-f]*$//' | sort -u); do ls -dt "$S/cache/aoc/$g"-* 2>/dev/null | grep -v '\.tmp\.' | tail -n +3 | while read -r d; do del "$d"; done; done
unpack_cap   # 全机解包缓存（定义在 --versions 分支前）
# 门禁 iOS 编译的按树镜像 + 构建目录 gate_ios/<树号>/（tools/gate_ios.sh，每次用时 touch）：6 小时没用的删，正在用（src.lock 在）的不动；
#   10-21 之前的全机一份 gate_ios_src / gate_ios_build：24 小时里没有任何文件被改过（没有旧版本脚本在用了）就整个删
# 10-21 晚总指挥：改留「最近 2 小时用过的」且最多 8 份（按最久没用先删）——每个分支门禁一份约 1 GB，6 小时窗口下 33 份 22.6 GB；隔两小时再跑冷编约 1.5 分钟
[ -d "$S/gate_ios" ] && ls -dt "$S/gate_ios"/*/ 2> /dev/null | while read -r d; do d=${d%/}; n=$((${n:-0} + 1)); [ -d "$d/src.lock" ] && continue
  [ $n -gt 8 ] || [ -n "$(find "$d" -maxdepth 0 -mmin +120)" ] && del "$d"; done   # 10-21 改 6 小时（近 6 小时新写 36 GB）
for gd in "$S/gate_ios_src" "$S/gate_ios_build"; do [ -d "$gd" ] && [ -z "$(find "$gd" -mmin -1440 -print -quit 2>/dev/null)" ] && [ ! -d "$gd.lock" ] && del "$gd"; done
# nxaot 编到一半被杀留下的 <平台>-<键>.tmp：本键的锁（.lock-<平台>-<键>）没有活持有者、且 2 小时没动 → 删（services/nxaot.sh 自己不清，10-21 起清理全归这里）
[ -d "$S/cache/nxaot" ] && find -H "$S/cache/nxaot" -mindepth 1 -maxdepth 1 -type d -name '*.tmp' -mmin +120 | while read -r d; do k=$(basename "${d%.tmp}")
  p=$(cat "$S/cache/nxaot/.lock-$k/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null || del "$d"; done
# nxaot 成品（取用即 touch，目录时间 = 最近使用）：24 小时没用的删；每平台超过 10 份时删最久没用的；30 分钟内用过的一律不动
#   （10-21 原生层线：按「每平台留 2–3 份」淘汰时五六条线的键轮流互删、反复满核重编，还删过别人刚拿到路径没链接完的那份）
[ -d "$S/cache/nxaot" ] && for plat in osx-arm64 ios-arm64; do n=0
  ls -dt "$S/cache/nxaot/$plat"-* 2>/dev/null | grep -v '\.tmp$' | while read -r d; do n=$((n + 1))
    [ -n "$(find "$d" -maxdepth 0 -mmin -30)" ] && continue
    { [ $n -gt 10 ] || [ -z "$(find "$d" -maxdepth 0 -mmin -1440)" ]; } && del "$d"; done; done
# 预编壳缓存 cache/shell/<壳编号>/（pack/ipa.sh 按提交出一次、每次用时 touch；11-04 全外置，每份约 106 MB、每个提交一份）：
#   24 小时没用的删、超过 6 份删最久没用的；30 分钟内用过的不动（在途出包在组装）；出到一半的 .tmp.<编号>.<pid> 2 小时没动删
SHC=${S2A_SHELL_CACHE:-$S/cache/shell}
[ -d "$SHC" ] && { find "$SHC" -mindepth 1 -maxdepth 1 -name '.tmp.*' -mmin +120 | while read -r d; do del "$d"; done
  n=0; ls -dt "$SHC"/*/ 2> /dev/null | while read -r d; do d=${d%/}; n=$((n + 1)); [ -n "$(find "$d" -maxdepth 0 -mmin -30)" ] && continue
    { [ $n -gt 6 ] || [ -z "$(find "$d" -maxdepth 0 -mmin -1440)" ]; } && del "$d"; done
  # 壳旁的工具链记录 .<壳编号>.toolchain（pack/ipa.sh，审计 #1534 P1-107）：壳目录删了就一并删
  for f in "$SHC"/.*.toolchain; do [ -f "$f" ] || continue; _tf=${f##*/}; _tf=${_tf#.}; [ -d "$SHC/${_tf%.toolchain}" ] || del "$f"; done; }
for c in "$S/cache/vpx:2" "$S/cache/opus:2" "$S/cache/dav1d:2"; do d0=${c%:*}; keep=${c##*:}; [ -d "$d0" ] || continue
  for plat in osx-arm64 ios-arm64; do ls -dt "$d0/$plat"-* 2>/dev/null | grep -v '\.tmp$' | tail -n +$((keep + 1)) | while read -r d; do [ -n "$(find "$d" -maxdepth 0 -mmin -30)" ] || del "$d"; done; done
done
# —— 10-21 总指挥：磁盘 441 → 245 GB（夜里约 40 GB/时；近 6 小时新写：roots 65 / roots_priv 46 / gate_ios 36 / sched 30 / cache 22 GB）扩 gc 范围，规则写进开工公约 三之二 ——
#   闲 = 目录前几层 N 分钟内没有文件改动；有进程当前目录在里面的不删；带 .keep 的不删
idle() { [ -z "$(find "$1" -maxdepth "${3:-3}" -mmin -"$2" -print -quit 2>/dev/null)" ]; }
CWDS=$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
# 命令行引用也算在用（10-27 总指挥：Air 手动 gc 删了着色器线 ssh 直起的远端普查 dcensus_r/out——它不经 remote.sh 登记，当前目录也不在里面，
#   但 direct_lib.sh / dcensus.sh 的参数里带着这个路径）：进程命令行里出现「<目录>/」或以「<目录>」结尾的参数 = 在用
CMDS=$(ps -A -ww -o command= 2>/dev/null)
inuse() { printf '%s\n' "$CWDS" | awk -v d="$1" 'index($0 "/", d "/") == 1 { f = 1 } END { exit !f }' && return 0
  printf '%s\n' "$CMDS" | awk -v d="$1" 'index($0 " ", d "/") || index($0 " ", d " ") { f = 1 } END { exit !f }'; }
# 调度局目录超龄回收（10-25 盘满事故：jobs 堆到约 4800 个局目录；读数已进记分板，局目录只是现场）：最后改动超过 S2A_GC_JOB_AGE_H（缺省 12）小时、
#   没被记分板 / 里程碑引用（prot）、没带 .keep、没有进程当前目录在里面 → 整个删；上面「每款留最近 10 绿 10 红」只管 12 小时内的
if [ -d "$S/sched/jobs" ]; then JA=${S2A_GC_JOB_AGE_H:-12}
  find -H "$S/sched/jobs" -mindepth 1 -maxdepth 1 -type d -mmin +$((JA * 60)) 2> /dev/null | while read -r j; do
    [ -e "$j/.keep" ] && continue; inuse "$j" && continue; idle "$j" $((JA * 60)) 2 || continue; del "$j"; done
fi
# 分支私有产物根 roots_priv/<名>/（pack/roots.sh：分支树不许改共享现行，用私有根）：6 小时没改动的整个删（原 24 小时）；
#   还在用的私有根里每款只留现行 + 上一版（同共享根；原先只整目录删，一棵树连出几版各占 10 GB 级）
if [ -d "$S/roots_priv" ]; then
  for d in "$S/roots_priv"/*/; do d=${d%/}; [ -d "$d" ] || continue; [ -e "$d/.keep" ] && continue; inuse "$d" && continue   # -d：空目录时通配不展开，原先把字面量「roots_priv/*」记成删了一项
    if idle "$d" 360 2; then
      # 11-01 两次私有根（mx84ce 08:03、mx2f9f 09:05）被整删：S2A_ROOTS 在局的环境变量里、不在命令行，上面 inuse 看不到；这里补三道，每次决定写一行带原因
      #   ① 任一进程的环境 / 命令行含该根  ② 出包队列在出 / 在等的单提到 priv:<名>  ③ 删除走 bin/safe_rm.sh（自带在用闸 + 删除日志；远端没有就退回 del）
      PENVS=$(ps -A -ww -E -o command= 2> /dev/null)
      if printf '%s\n' "$PENVS" | grep -qF -- "$d"; then echo "私有根留 ${d}（有进程的环境或命令行引用它）"; continue; fi
      if grep -qsF -- "priv:$(basename "$d")" "$S"/packq/run/*.json "$S"/packq/req/*.json; then echo "私有根留 ${d}（出包队列有在出 / 在等的单用它）"; continue; fi
      if [ -x "$S/bin/safe_rm.sh" ] && [ $DRY != 1 ] && ! prot "$d"; then
        if bash "$S/bin/safe_rm.sh" "$d" > /dev/null 2>&1; then echo "删 ${d}（私有根 6 小时没动，无进程 / 单子引用；走 safe_rm）"; echo "$d" >> "$GL"; else echo "私有根留 ${d}（safe_rm 拒删，见 safe_rm.log）"; fi
      else echo "私有根 6 小时没动 $d → $([ $DRY = 1 ] && echo 干跑 || echo 走 del)"; del "$d"; fi
      continue; fi
    for cur in "$d"/*@现行; do [ -L "$cur" ] || continue; g=$(basename "$cur"); g=${g%@现行}; c=$(basename "$(readlink "$cur")")
      ls -dt "$d/$g"@* 2>/dev/null | grep -v -e '@现行$' -e '\.tmp$' | while read -r v; do [ "$(basename "$v")" = "$c" ] || echo "$v"; done | tail -n +2 | while read -r v; do { type _root_pinned > /dev/null 2>&1 && S2A_ROOTS=$d _root_pinned "$v"; } && continue; idle "$v" 30 1 && del "$v"; done
    done
    romfs_sweep "$d"
  done
fi
# 本机逐帧录像（11-05 总指挥：run/s2arm/frame_rec 改为指向 2T 的软链，此前录在内置盘的留在 frame_rec.local/<款>；2T 上由工作盘清理器 WORK_IDLE_DIRS 按同一条规则收）：
#   整款 S2A_GC_FREC_IDLE_H（缺省 24）小时没改动（看到最深层，录像在 <款>/<局>/rec/<帧>/ 下）、没有进程在用、钉住表（S2A_GC_PINS，缺省上限表的 WORK_PINS / $S2A_WORK/pins）
#   没写「<路径>\t<原因>」→ 整款删；2T 上指回来的软链随后由清理器当断链删。钉住没写原因的不认（同清理器）
FL=$S/frame_rec.local
if [ -d "$FL" ]; then FH=${S2A_GC_FREC_IDLE_H:-24}; FP=${S2A_GC_PINS:-$( . "${S2A_LAYOUT_ENV:-$S/env/layout.env}" 2> /dev/null; echo "${WORK_PINS:-${S2A_WORK:-}/pins}")}; F2=$(cd -P "$S/frame_rec" 2> /dev/null && pwd)
  for d in "$FL"/*/; do d=${d%/}; [ -d "$d" ] || continue; b=${d##*/}
    why=$(awk -F'\t' -v a="$d" -v b="$S/frame_rec/$b" -v c="$F2/$b" '$0 !~ /^#/ && ($1 == a || $1 == b || $1 == c) {r = $2; gsub(/[ \t]/, "", r); if (r != "") {print $2; exit}}' "$FP" 2> /dev/null)
    [ -n "$why" ] && { echo "录像留 ${d}（钉住：${why}）"; continue; }
    inuse "$d" && { echo "录像留 ${d}（在用）"; continue; }; idle "$d" $((FH * 60)) 9 || continue; del "$d"; done
fi
# 各线私有包 / 试验区：wip/<线>/（新约定）与现有的 *_wip、widen1021、gfxsh 下的每一项，6 小时没动删（带 .keep 的项或整区不动）
for z in "$S"/wip/* "$S"/*_wip "$S/widen1021" "$S/gfxsh"; do [ -d "$z" ] || continue; [ -e "$z/.keep" ] && continue
  for c in "$z"/*; do [ -e "$c" ] || continue; [ -e "$c/.keep" ] && continue; inuse "$c" && continue; idle "$c" 360 3 && del "$c"; done
done
# 工作树 ~/.s2arm/s2arm-wt/<名>/（. 开头的是列车临时树，不动）：已合进 origin/main（HEAD 是它的祖先）、干净（git status 空）、2 小时没动 → git worktree remove；
#   留着的树里 build/（可重建）6 小时没动 → 删 build/
#   只管测试出包线自己的树（名字 test-* 开头）和树根放了 .gc_ok 的（别的线自愿交给 gc）：10-23 查实本规则按「已合入 + 干净 + 2 小时没动」
#   把别的线的工作树（gfxsh-* / coresmain / exp-d3 …）连同它们的 build/ 一起删了，违反「只删自己建的确切路径」
#   10-29 总指挥（本机一个半小时掉 80 GB，大头是各线子 Agent 留在 ~/.s2arm/wt 的工作树与构建产物，画面线手清 36 棵 wirec_*）：工作树按「已并入 main 且久没改动」
#     自动回收、不靠各线自觉——别的线的树也收，但只收「已合入 origin/main + 干净 + 没进程在用 + 没 .keep + S2A_GC_WT_IDLE_H（缺省 6）小时没动」的整棵树
#     （内容都在 main 上，删了不丢）；别的线没合入的树一律不碰、它的 build/ 也不碰。扫的目录：S2A_WT_ROOT + S2A_GC_WT_OTHERS（正式运行缺省 ~/.s2arm/wt；
#     单测覆盖了 S2A_WT_ROOT 而没给 S2A_GC_WT_OTHERS 时不扫别处，绝不碰真工作树）
GR=${S2A_REPO:-$HOME/.s2arm/S2Arm}
# 工作树能不能回收的唯一判定（11-05 总指挥：瓦力欧音频修复 crash/audio-aux-readpos 从没提交，分支头 = main 旧提交，工作树 aux_rd 被当成「已合入、干净」删掉）：
#   wt_gcable <树> <闲分钟>：三条全满足打 0，否则打不删的原因、返回 1——
#   ① git status 跑成功且为空（--untracked-files=all：未跟踪源文件算脏；.gitignore 排除的构建产物不算）；status 出错按「核不了」不删（原先 2>/dev/null 把出错当干净）
#   ② HEAD 在 origin/main 里，且分支（游离头看本树 HEAD）的 reflog 里有自己的提交（commit / rebase / cherry-pick / merge）；只是从 main 建出、从没提交过的不算已合入
#   ③ 整棵树（全深度，原先只看 1–2 层）<闲分钟> 内没有改动
#   11-07 启动器线定因（出壳闭包判黄 10713/10715）：③ 原先排在最后，① 的 git status 先跑——出壳中途的树（pack/shell_build.sh 已把全部仓库文件访问时间设旧，
#     状态时间随之全变）被 git status 整树重读，闭包把这次重读算成「出壳读到」。改为 ③ 先判（只看修改时间，不读内容），正在出壳 / 编译的树当场跳过；
#     git status 再带 core.trustctime=false：只看修改时间 / 大小 / inode，状态时间变了不重读内容（同 shell_build.sh 子进程的设法）
wt_gcable() { local w=$1 st rc h br own m
  [ -z "$(find "$w" -mmin -"$2" -print -quit 2> /dev/null)" ] || { echo "$2 分钟内有改动"; return 1; }
  st=$(git -c core.trustctime=false -C "$w" status --porcelain --untracked-files=all -- . ':!.gc_ok' 2>&1); rc=$?
  [ $rc = 0 ] || { echo "git status 出错，核不了（${st:0:80}）"; return 1; }
  [ -z "$st" ] || { echo "有未提交改动或未跟踪文件"; return 1; }
  h=$(git -C "$w" rev-parse -q --verify HEAD) || { echo "取不到 HEAD"; return 1; }
  m=$(git -C "$w" rev-parse -q --verify origin/main) && git -C "$w" merge-base --is-ancestor "$h" "$m" 2> /dev/null || { echo "HEAD 不在 origin/main 里"; return 1; }   # 按树自己所属仓库的 origin/main
  br=$(git -C "$w" symbolic-ref -q --short HEAD)
  own=$(git -C "$w" reflog show --format=%gs "${br:+refs/heads/}${br:-HEAD}" 2> /dev/null | grep -m1 -E '^(commit|rebase|cherry-pick|merge|pull)')
  [ -n "$own" ] || { echo "分支 ${br:-（游离头）}上没有自己的提交（头是 main 上的提交，从没提交过不算已合入）"; return 1; }
  echo "${br:-（游离头）} ${h:0:9}"; return 0; }
WTLOG=${S2A_GC_WT_LOG:-$S/gc_worktrees.log}   # 删工作树常驻记录：时刻 / 路径 / 分支 / 头提交（GL 是临时文件，删完就没了）
WTD=$WTR; if [ -n "${S2A_GC_WT_OTHERS+x}" ]; then WTD="$WTD $S2A_GC_WT_OTHERS"; elif [ -z "${S2A_WT_ROOT:-}" ]; then WTD="$WTD $HOME/.s2arm/wt"; fi
if OM=$(git -C "$GR" rev-parse -q --verify origin/main); then
  for wd in $WTD; do [ -d "$wd" ] || continue
  for w in "$wd"/*/; do w=${w%/}; [ -e "$w/.git" ] || continue; [ -e "$w/.keep" ] && continue; inuse "$w" && continue
    own=; case $(basename "$w") in test-*) own=1;; *) [ -e "$w/.gc_ok" ] && own=1;; esac   # 自己的 / 自愿的：2 小时；别的线的：S2A_GC_WT_IDLE_H 小时
    im=$([ -n "$own" ] && echo 120 || echo $(( ${S2A_GC_WT_IDLE_H:-24} * 60 )))   # 别的线的树 24 小时（11-05 总指挥，原 6）
    if why=$(wt_gcable "$w" "$im"); then
      if [ $DRY = 1 ]; then echo "会删 ${w}（工作树：已合入、干净、$((im / 60)) 小时没动；${why}）"
      else printf '%s\t%s\t%s\n' "$(date '+%m-%d %T')" "$w" "$why" >> "$WTLOG"; git -C "$GR" worktree remove $([ -e "$w/.gc_ok" ] && echo --force) "$w" > /dev/null 2>&1 && { echo "删 ${w}（工作树：已合入、干净、$((im / 60)) 小时没动；${why}）"; echo "$w" >> "$GL"; } || echo "【红】gc：工作树删不掉 $w"; fi
    elif [ -n "$own" ] && [ -d "$w/build" ] && idle "$w/build" 360 3; then del "$w/build"; fi   # 别的线没合入的树连 build/ 也不碰
  done
  done
fi
# M0 / 判据录局 m0/<批>/<局>/：只留最近 3 批；更早的批只留红局现场（没到 MARK 或有 CRASH），绿局删；
#   旧批里留下的红局删逐键截图 ap_p*.png（探测 / MARK / 卡住截图、轨迹、日志留）；没有宿主在用的输入快照 <批>/in 一律删（停掉的批次不会自己清）。
#   批目录里放 .keep（验收批）就整批不动；里程碑证据另存 ~/.s2arm/run/s2arm/milestones/（不在 gc 范围）。
#   旧判据回归集在 apreg/（只留存），不在这里删
if [ -d "$S/m0" ]; then
  for b in "$S/m0"/*/; do b=${b%/}; [ -d "$b/in" ] && ! pgrep -f "$b/in" > /dev/null && del "$b/in"; done
  # 按创建时间排（删 in/ 会刷新批次目录的修改时间，按 -t 排会把老批当新批；10-20 因此删掉了 M0 验收批 x9）；带 .keep 的批（验收证据）永远不动
  for b in "$S/m0"/*/; do b=${b%/}; echo "$(stat -f %B "$b") $b"; done | sort -rn | awk '{print $2}' | tail -n +4 | while read -r b; do [ -e "$b/.keep" ] && continue
    for r in "$b"/*/; do r=${r%/}; [ -f "$r/host.log" ] || continue
      if grep -aq 'S2A 标记 MARK' "$r/host.log" && ! grep -aq CRASH "$r/host.log"; then del "$r"; else for p in "$r"/ap_p[0-9]*.png; do [ -f "$p" ] && del "$p"; done; fi
    done
    [ -z "$(find "$b" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ] && del "$b"
  done
fi
# 按盘余量回收（10-22 总指挥：两小时掉 34 GB，按常规保留规则只删得动 1 个根）：剩余 < S2A_GC_LOW_GB（缺省 100）就回收到 S2A_GC_HIGH_GB（缺省 120），缺口一次算定
#   （10-27 jhz 15:4x：300 GB 是那次大清理的目标，日常 ≥ 100 GB 就够；原 160 / 180 → 当日上午 300 / 320 → 100 / 120）：
#   ① sched/pkgstore 里没登记、也没被排队 / 在跑作业 / 候选引用（sched.sh refs 硬引用，不算「机上装着」：10-23 总指挥）的包快照（多是克隆，腾得少，但不用重编）；
#   ② 着色器中间缓存 gal_air_cache / gal_dl_cache 按修改时间从旧到新删到补够缺口（见下方「着色器中间缓存」段，记账按 APFS 独占大小）。
#      管线归档缓存 gal_pso_cache 不再参与（10-23 画面·着色器线实测：条目全和产物根共享，独占 0，删了腾不出空间、只让下次出包重编）。
#   ③ 工作树（10-27 出包运维线：~/.s2arm/wt + s2arm-wt 积到 519 个，删 367 个干净已推的回收约 100 GB）：S2A_GC_WT_DIRS 下的 git 工作树，
#      无未提交 / 未跟踪改动、HEAD 在 origin 任一分支上、没有进程 cwd 或命令行引用、24 小时内没改动的，最旧的先删（git worktree remove），
#      df 回到 HIGH 就停；launcher-main（jhz 屏幕上的启动器）、airmeas（Air 量数）、.train（列车落地树）不动
#   ⑤ 作废链号的直连库 cache/direct/*/{mac,ios}/b-<旧链号>（10-28，见下方本段；排在 ③ 之前跑：丢的只是下次出库的预填编译缓存，比删工作树代价小）
#   ④ devicectl 装包增量缓存（10-27：AppInstallationBinaryDeltas 按包身份存、从不自动清，删 1 天前的 19 个包回 30 GB）：S2A_GC_CDDELTA 下修改时间超过 1 天的包目录；删了只让下次装同一身份走全量传输
#   S2A_GC_FREE_GB 覆盖读到的剩余、S2A_GC_NEED_KB 覆盖缺口（单测用）
FREE=${S2A_GC_FREE_GB:-$(df -g "$DV" | awk 'NR==2{print $4}')}; LOW=${S2A_GC_LOW_GB:-100}; HIGH=${S2A_GC_HIGH_GB:-120}
if [ "$FREE" -lt "$LOW" ]; then
  NEED=${S2A_GC_NEED_KB:-$(( (HIGH - FREE) << 20 ))}; echo "gc：盘剩 ${FREE} GB < ${LOW} GB，回收到 ${HIGH} GB（缺口 $((NEED >> 20)) GB）"
  if [ -d "$S/sched/pkgstore" ]; then
    KEEP=$( { S2A_REFS_HARD=1 S2A_SCHED_DIR=$S/sched bash "$(dirname "$0")/sched.sh" refs 2> /dev/null; for f in "$S"/sched/pkgs/*.env; do [ -f "$f" ] && ( . "$f"; echo "$PKG" ); done; } | sort -u)
    for p in "$S"/sched/pkgstore/*/; do p=${p%/}; grep -qxF "$p" < <(printf '%s\n' "$KEEP") || del "$p"; done
  fi
  CDD=${S2A_GC_CDDELTA:-$HOME/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas}
  [ -d "$CDD" ] && find "$CDD" -mindepth 1 -maxdepth 1 -type d -mtime +1 | while read -r p; do
    if [ $DRY = 1 ]; then echo "会删装包增量缓存 $p"; else rm -rf -- "$p" && echo "装包增量缓存 ${p##*/}" >> "$GL"; fi; done
  hi() { [ -n "${S2A_GC_FREE_GB:-}" ] && return 1; [ "$(df -g "$DV" | awk 'NR==2{print $4}')" -ge "$HIGH" ]; }   # 单测给了假剩余时不按 df 停
  # ⑤ 作废链号的直连库（10-28 出包运维线：本机盘剩 83 GB，上面几项只删得动 1 项）：cache/direct/<程序号>/{mac,ios}/b-<链号>/ 按翻译链号分目录（graphics/tools/direct/direct_lib.sh），
  #    链号一换，旧目录宿主再也不加载，只剩下次出库给 dmsh_build 预填编译缓存的用处，原先没有任何规则管（6 种链号里 5 种已作废，共 30 份）。
  #    保留 = 当前 main 链号（本机：仓库 origin/main 的 dmsh_chain.h；远端：<远端根>/S2Arm.git 里最新的 refs/s2a/om/*；都取不到用本树文件）
  #      + 在跑的出包进程（命令行第一、二个词是 refresh.sh / stage_direct.sh / direct_lib.sh）的工作树链号：命令行里每个绝对路径和进程当前目录都往上找 dmsh_chain.h，找到的全留
  #      + 远端在跑命令（wt/<名>.pid 活着）的工作树链号。取不到 main 链号、或有出包进程一个工作树都认不出 = 拿不准，本段整段不删
  #    S2A_GC_PS = 列进程的命令（输出「进程号 命令行」，单测只列自己起的假进程，免得撞上本机 / mini 真在跑的出包）
#    整款不动：该程序号下有活的 <work|mac|ios>.stage.<进程号>（direct_lib.sh 正在出这款，出库中会读同款全部 b-* 预填）；单个目录或它下面一层 30 分钟内改过的不动。
  #    其余按目录修改时间从旧到新删，按 privsize 独占字节记账，补够缺口或 df 回到 HIGH 就停（10-28 本机实测作废的 29 份 du 508 GB、独占合计只 2.7 GB：多是和现行链 / 产物根共享的克隆，
  #    只在旧目录之间共享的块单看哪份都不算独占，真腾出量以 df 为准）；prot（KEEP_DIRS / seed_refs / .keep）照常。S2A_GC_OLDCHAIN=0 关掉本段
  DH=graphics/nvn/gfx/nvn/dmsh_chain.h
  hc() { sed -n 's/^#define DMSH_CHAIN "\([0-9a-f]\{12\}\)".*/\1/p' | head -1; }   # 标准输入是头文件文本，打链号
  tc() { local p=$1; while [ "${#p}" -gt 1 ]; do [ -f "$p/$DH" ] && { hc < "$p/$DH"; return; }; p=$(dirname "$p"); done; }   # 路径往上找工作树根，打它的链号
  if [ "${S2A_GC_OLDCHAIN:-1}" != 0 ] && [ -d "$S/cache/direct" ]; then
    RG=${S2A_GC_REMOTE_ROOT:-}; CM=
    if [ -n "$RG" ]; then om=$(git -C "$RG/S2Arm.git" for-each-ref --sort=-committerdate --count=1 --format='%(objectname)' refs/s2a/om 2> /dev/null)
      [ -n "$om" ] && CM=$(git -C "$RG/S2Arm.git" show "$om:$DH" 2> /dev/null | hc)
    else CM=$(git -C "$GR" show "origin/main:$DH" 2> /dev/null | hc); fi
    [ -n "$CM" ] || { [ -f "$H/$DH" ] && CM=$(hc < "$H/$DH"); }
    UC=; UNK=
    for p in $(${S2A_GC_PS:-ps -A -ww -o pid=,command=} 2> /dev/null | awk '{ for (i = 2; i <= 3 && i <= NF; i++) if ($i ~ /(^|\/)(refresh|stage_direct|direct_lib)\.sh$/) { print $1; next } }'); do
      [ "$p" = $$ ] && continue; read -r -a A <<< "$(ps -ww -o command= -p "$p" 2> /dev/null)"; c=
      w=$(lsof -a -p "$p" -d cwd -Fn 2> /dev/null | sed -n 's/^n//p' | head -1)
      for a in "$w" ${A[@]+"${A[@]}"}; do case $a in /*) x=$(tc "$a"); [ -n "$x" ] && c="$c $x";; esac; done
      if [ -n "$c" ]; then UC="$UC$c"; elif kill -0 "$p" 2> /dev/null; then UNK="$UNK $p"; fi   # 列完已退出的不算拿不准
    done
    [ -n "$RG" ] && for f in "$RG"/wt/*.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2> /dev/null); [ -n "$p" ] && kill -0 "$p" 2> /dev/null || continue
      [ -f "${f%.pid}/$DH" ] && UC="$UC $(hc < "${f%.pid}/$DH")"; done
    if [ -z "$CM" ]; then echo "gc：取不到当前 main 的直连链号，作废链号的直连库本次不删"
    elif [ -n "$UNK" ]; then echo "gc：在跑的出包进程${UNK} 认不出工作树（链号拿不准），作废链号的直连库本次不删"
    else KC=$(printf '%s\n' "$CM" $UC | sort -u | tr '\n' ' '); echo "gc：作废链号的直连库：保留链号 ${KC}（当前 main ${CM}）"
      python3 - "$(dirname "$0")" "$S/cache/direct" "$KC" <<'PY' | { got=0; k=0; acc=; fin=; why=; while IFS=$'\t' read -r t sz p x; do
import os, re, sys, time
sys.path.insert(0, sys.argv[1])
try:   # 先在 tools/ 上实测一次：导入成功不等于能用（没有 getattrlist 的系统导入照过、调用才抛，#619 审计）
    from privsize import tree; tree(sys.argv[1]); acc = '独占'; size = lambda d: tree(d)[0]
except Exception:   # 远端冻结副本只带 tools/*.sh、或系统没有 getattrlist：退回 st_blocks（克隆共享的会高估、少删），输出里标明
    acc = 'du（无 privsize，偏大）'
    size = lambda d: sum(os.lstat(os.path.join(r, f)).st_blocks * 512 for r, _, fs in os.walk(d) for f in fs)
root, keep, now = sys.argv[2], set(sys.argv[3].split()), time.time()
def out(*a): print('\t'.join(map(str, a)), flush=True)
def alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True
def recent(d):   # 目录本身或它下面一层 30 分钟内改过
    if now - os.lstat(d).st_mtime < 1800: return True
    with os.scandir(d) as it:
        for e in it:
            try:
                if now - e.stat(follow_symlinks=False).st_mtime < 1800: return True
            except OSError: pass
    return False
cands = []
try:
    out('acc', acc)
    for t in sorted(os.listdir(root)):
        td = os.path.join(root, t)
        if os.path.islink(td) or not os.path.isdir(td): continue
        old = [os.path.join(td, pl, b) for pl in ('mac', 'ios') if os.path.isdir(os.path.join(td, pl)) and not os.path.islink(os.path.join(td, pl))
               for b in sorted(os.listdir(os.path.join(td, pl))) if b.startswith('b-') and b[2:] not in keep]
        old = [d for d in old if os.path.isdir(d) and not os.path.islink(d)]
        if not old: continue
        live = [m.group(1) for m in (re.fullmatch(r'(?:work|mac|ios)\.stage\.(\d+)', n) for n in os.listdir(td)) if m and alive(int(m.group(1)))]
        if live: out('busy', 0, td, live[0]); continue
        for d in old:
            try:
                if recent(d): out('new', 0, d)
                else: cands.append((os.lstat(d).st_mtime, d))
            except OSError: pass
    for m, d in sorted(cands): out('old', size(d), d)
    out('end')
except BrokenPipeError: os._exit(0)
except Exception as e:   # 扫描中途出错：报给 shell 端打红，不许落成「删 0 份」（#619 审计）
    out('err', 0, repr(e)[:200]); sys.exit(1)
PY
        case $t in
          acc) acc=$sz; continue;;
          end) fin=1; continue;;
          err) why=$p; continue;;
          busy) echo "在用，不删 ${p}（direct_lib.sh 进程 ${x} 在出这款）"; continue;;
          new) echo "在用，不删 ${p}（30 分钟内改过）"; continue;;
        esac
        { { [ "${acc#du}" = "$acc" ] && [ "$got" -ge $((NEED << 10)) ]; } || hi; } && { fin=1; break; }   # 补够了主动收手也算扫完；du 记账（远端无 privsize）会把克隆共享的算成腾出、删一份就收手（同原症状）：只按 df 停
        prot "$p" && { echo "受保护，不删 $p"; continue; }
        del "$p"; { [ $DRY = 1 ] || [ ! -e "$p" ]; } && { got=$((got + sz)); k=$((k + 1)); }
      done; [ -n "$fin" ] || echo "【红】gc：作废链号的直连库扫描中途失败（${why:-扫描进程没交完就退出}），已$([ $DRY = 1 ] && echo 列 || echo 删) ${k} 份、清单不全"
      [ -n "$fin" ] && echo "gc：作废链号的直连库$([ $DRY = 1 ] && echo 会删 || echo 删) ${k} 份，${acc} $(awk -v b="$got" 'BEGIN { printf "%.1f", b / 2^30 }') GB（缺口 $((NEED >> 20)) GB）"; }
    fi
  fi
  USED=$( { lsof -d cwd -Fn 2> /dev/null | sed -n 's/^n//p'; ps -axo command; } | grep -oE '/[^ ]*/(wt|s2arm-wt)/[^/ ]+' | sort -u)
  for d in ${S2A_GC_WT_DIRS:-$HOME/.s2arm/wt $HOME/.s2arm/s2arm-wt}; do [ -d "$d" ] || continue
    for w in "$d"/*/; do w=${w%/}; [ -e "$w/.git" ] || continue; echo "$(stat -f %m "$w") $w"; done; done | sort -n | while read -r _ w; do
    hi && break
    case ${w##*/} in launcher-main|airmeas|.train) continue;; esac
    grep -qxF "$w" < <(printf '%s\n' "$USED") && continue
    why=$(wt_gcable "$w" 1440) || continue
    if [ $DRY = 1 ]; then echo "会删工作树 ${w}（${why}）"; else printf '%s\t%s\t%s\n' "$(date '+%m-%d %T')" "$w" "$why" >> "$WTLOG"; git -C "$w" worktree remove "$w" 2> /dev/null && echo "工作树 $w" >> "$GL" && echo "删工作树 ${w}（${why}）"; fi   # 不 --force：git 自己再挡一道脏树
  done
fi
# 着色器中间缓存（10-23 画面·着色器线交规则）：gal_air_cache（.air，链接 metallib 的中间产物，产物根里不留）与 gal_dl_cache（链接版函数体），删了只是重编。
#   常规：修改时间超过 S2A_GC_CACHE_H（缺省 72）小时的删；air 的 ios/ 下不在 u?? 合编子目录里的逐支条目超过 6 小时就删（合编上线后基本不再命中，只有合编失败退回逐支时才用）；
#   盘紧（上面算了 NEED）：再按修改时间从旧到新删到补够缺口，1 小时内动过的不动。删除量按 APFS 独占大小记（tools/privsize.py），不按 st_blocks。
#   没有 getattrlist 时 import 照过、调用才抛（与作废链那一段同一类）：先对 gc.sh 实测一次，失败退回 st_blocks×512。
#   这是分配块，和 du -k 同一口径，不是表观大小（BSD du -A、GNU du --apparent-size）。稀疏文件的洞不占块，按表观大小会把缺口提前算满、少删。
#   并发：烘焙中照清（10-24 总指挥：盘 63 GB、九款排着重烘，重烘道几乎不空，原「有活持有者整段跳过」等于从不清）。graphics/cache-touch（44bb288a）起命中刷新条目时间、
#   克隆失败退回现编：在用的条目 1 小时内必被刷新、上面的「1 小时内动过的不动」护住它；万一判存在与克隆之间被删也只是重编，不抛异常
AIRC=${GAL_AIR_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/gal_air_cache}; DLC=${GAL_DL_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/gal_dl_cache}
if [ -d "$AIRC" ] || [ -d "$DLC" ]; then
  python3 - "$(dirname "$0")" "$AIRC" "$DLC" "${NEED:-0}" "$DRY" "$GL" "${S2A_GC_CACHE_H:-72}" <<'PY'
import os, re, sys, time
sys.path.insert(0, sys.argv[1])
try:   # 先实测一次：导入成功不等于能用（没有 getattrlist 的系统导入照过、调用才抛；作废链那段已探 tree()，这里原先只探导入）
    from privsize import private_size; private_size(os.path.join(sys.argv[1], 'gc.sh')); ACC = '独占'
except Exception:   # 远端 gc 只带了 tools/*.sh（remote.sh），或系统没有 getattrlist：退回 st_blocks（克隆共享的会高估、少删），输出里标明
    private_size = lambda p: os.lstat(p).st_blocks * 512; ACC = 'du（无 privsize，偏大）'
air, dl, need, dry, gl, hold_h = sys.argv[2], sys.argv[3], int(sys.argv[4]) * 1024, sys.argv[5] == '1', sys.argv[6], float(sys.argv[7]); now = time.time()
fs = []   # (修改时间, 路径, 规则)
for c in (air, dl):
    for root, ds, names in os.walk(c):
        rel = os.path.relpath(root, c).split(os.sep)
        unity = any(re.fullmatch(r'u..', x) for x in rel)
        for f in names:
            p = os.path.join(root, f)
            try: m = os.lstat(p).st_mtime
            except OSError: continue
            age = now - m
            if age < 3600: continue
            rule = 'old' if age >= hold_h * 3600 else 'perbranch' if c == air and rel[0] == 'ios' and not unity and age >= 6 * 3600 else 'lru'
            fs.append((m, p, rule))
fs.sort(); got = n = 0; by = {}
for m, p, rule in fs:
    if rule == 'lru' and got >= need: continue
    sz = private_size(p) or 0
    if not dry:
        try: os.remove(p)
        except OSError: continue
    got += sz; n += 1; by[rule] = by.get(rule, 0) + 1
if not dry and n: open(gl, 'a').write(f'着色器中间缓存 {n} 条\n')
print(f'gc：着色器中间缓存{"会删" if dry else "删"} {n} 条（超过 {hold_h:g} 小时 {by.get("old", 0)}、逐支旧条目 {by.get("perbranch", 0)}、补缺口 {by.get("lru", 0)}），{ACC} {got / 2**30:.1f} GB' + (f'（缺口 {need / 2**30:.1f} GB）' if need else ''))
PY
fi
# 远端假家目录（tools/remote.sh 起的 gc 带 S2A_GC_REMOTE_ROOT=<远端根>，HOME=<远端根>/home）：这里的东西全是本机的同步镜像或远端局的派生物，本质是缓存。
#   10-25 mini 盘剩 18 GB、gc 删 0 项：占地的是各线在 run/s2arm 顶层自建的目录（gj_play）和 roots/<款>@现行 的同步镜像——前者没有规则管，后者按「现行」永不回收；
#   大头互为 APFS 克隆，按 du 估缺口会失真。规则：盘剩 < LOW 时，把上面各条规则不管的目录按「最后使用」从旧到新逐个删，每删一个重读 df，到 HIGH 停。
#   回收单位：带 .s2a_sync 标记的同步目录整个算一个（remote.sh 每次用到就 touch 标记，标记时间 = 最后使用）；不含同步目录的目录整个算一个（最后使用 = 前三层最新的修改时间）；
#     含同步目录的往下拆。sched / cache / gate_ios / health / m0 / shpack / wip 有自己的规则，受保护目录不动。
#   不删：S2A_GC_REMOTE_IDLE_MIN（缺省 60）分钟内用过的；在跑的远端命令（<远端根>/wt/<名>.pid 活着）在 <名>.uses 里登记的同步目录和 --env 路径；有进程当前目录在里面的。
#   删完还不够：打一行「盘上 gc 管不到的大头」（远端根以外，如 mini 自己的 ~/.s2arm/data、run），remote.sh 拒跑时带上这一行
RR0=${S2A_GC_REMOTE_ROOT:-}
fr() { if [ -n "${S2A_GC_FREE_CMD:-}" ]; then bash -c "$S2A_GC_FREE_CMD"; else df -g "$DV" | awk 'NR==2{print $4}'; fi; }   # S2A_GC_FREE_CMD 单测用
if [ -n "$RR0" ] && [ -d "$S" ] && [ "$(fr)" -lt "$LOW" ]; then
  uses_now() { for f in "$RR0"/wt/*.pid; do [ -f "$f" ] || continue; p=$(cat "$f" 2> /dev/null); [ -n "$p" ] && kill -0 "$p" 2> /dev/null || continue
    [ -f "${f%.pid}.uses" ] && grep -v '^/*$' "${f%.pid}.uses" | sed "s|^|$HOME/|"; done; }   # 空行不算（不然整个家目录都算在用）
  USES=$(uses_now)
  # 删前重核（10-29 画面线 sewant_PB：mini 盘剩 54 GB，remote.sh 先后台起本 gc、再 rsync 同步 botw 根 155 秒；rsync -t 保留旧修改时间、
  #   标记 .s2a_sync 与 .uses 登记都在同步之后才写，正在写的根被当成「很久没用」边写边删，同步报传完、romfs 却没了）：
  #   清单是开头列的，删到它时可能已被别的作业用上——每删一项前重读在跑命令的登记、重拍进程快照，里面（≤ 6 层）的 .s2a_sync 在空闲期内碰过也不删
  IDLEM=${S2A_GC_REMOTE_IDLE_MIN:-60}
  fresh() { [ -n "$(find "$1" -maxdepth 6 -name .s2a_sync -mmin -"$IDLEM" -print -quit 2> /dev/null)" ]; }
  echo "gc：远端假家目录按最后使用回收（盘剩 $(fr) GB < ${LOW} GB，回收到 ${HIGH} GB；在跑命令登记的路径 $(grep -c . < <(printf '%s\n' "$USES")) 条）"
  KEEP_DIRS=$KEEP_DIRS python3 - "$S" "${S2A_GC_REMOTE_IDLE_MIN:-60}" <<'PY' | while IFS=$'\t' read -r age d; do
import os, sys, time
S, idle = sys.argv[1], float(sys.argv[2]) * 60; now = time.time()
SKIP = {'sched', 'cache', 'gate_ios', 'gate_ios_src', 'gate_ios_build', 'health', 'm0', 'shpack', 'wip', 'remote', 'train'} | set(os.environ.get('KEEP_DIRS', '').split())   # KEEP_DIRS：同本机 prot（输入 / 工具依赖 / 门禁数据）
KEEP_NAMES = {'save', 'saves', 'systemdata'}   # 存档按路径保护（10-27：rsync -a 保留旧修改时间，按最后使用判成很久没用、整个 saves/ 被删）；
#   系统归档同理（10-29 总指挥：systemdata/ 是起局必需的种子数据，不是缓存）。带 .s2a_sync 的同步镜像仍整份算一个单位——本机有原件，下次用到重新同步
def protected(c): return os.path.basename(c) in KEEP_NAMES or os.path.exists(os.path.join(c, '.keep'))
def mt(p):
    try: return os.lstat(p).st_mtime
    except OSError: return 0
def has_sync(d, depth=6):
    for root, ds, fs in os.walk(d):
        if '.s2a_sync' in fs and root != d: return True
        if root[len(d):].count(os.sep) >= depth: ds[:] = []
    return False
def has_keep(d, depth=4):   # 里面有存档 / .keep 的目录不整块删，往下拆、只删拆出来的别的部分
    for root, ds, fs in os.walk(d):
        if root != d and (os.path.basename(root) in KEEP_NAMES or '.keep' in fs): return True
        if root[len(d):].count(os.sep) >= depth: ds[:] = []
    return False
def last_use(d):
    if os.path.isfile(os.path.join(d, '.s2a_sync')): return mt(os.path.join(d, '.s2a_sync'))
    t = mt(d)
    for root, ds, fs in os.walk(d):
        for n in ds + fs: t = max(t, mt(os.path.join(root, n)))
        if root[len(d):].count(os.sep) >= 2: ds[:] = []
    return t
units = []
def walk(d):
    for n in sorted(os.listdir(d)):
        c = os.path.join(d, n)
        if n.startswith('.') or os.path.islink(c) or not os.path.isdir(c) or protected(c): continue
        if not os.path.isfile(os.path.join(c, '.s2a_sync')) and (has_sync(c) or has_keep(c)): walk(c)
        else: units.append((last_use(c), c))
for n in sorted(os.listdir(S)):   # 顶层目录是分类（roots / roots_priv / wire-c …），回收单位至少往下拆一层：10-25 Air 上 roots/ 整块算一个单位，
    c = os.path.join(S, n)        #   里面 mk8d@现行 一小时内写过，24 GB 的 acnh@现行 镜像就跟着永远「新」、删不掉
    if n in SKIP or n.startswith('.') or os.path.islink(c) or not os.path.isdir(c) or protected(c): continue
    if os.path.isfile(os.path.join(c, '.s2a_sync')): units.append((last_use(c), c))
    else: walk(c)
for t, c in sorted(units):
    if now - t >= idle: print(f'{int((now - t) / 60)}\t{c}')
PY
    [ "$(fr)" -ge "$HIGH" ] && break
    fresh "$d" && { echo "刚用过，不删 ${d}（列清单后有同步碰过它）"; continue; }
    USES=$(uses_now); CWDS=$(lsof -a -d cwd -Fn 2> /dev/null | sed -n 's/^n//p'); CMDS=$(ps -A -ww -o command= 2> /dev/null)
    awk -v d="$d" 'NF && (index($0 "/", d "/") == 1 || index(d "/", $0 "/") == 1) { f = 1 } END { exit !f }' < <(printf '%s\n' "$USES") && { echo "在用，不删 ${d}（在跑的远端命令登记了它）"; continue; }
    inuse "$d" && { echo "在用，不删 ${d}（有进程当前目录在里面，或命令行引用它）"; continue; }
    # 回收量按 df 前后量，不按 du（10-29 mini 实测：rpack 两版巫师3 根 du 各 71 GB、独占各 0 GB——互为克隆，单删一份回 0；喷3 直连缓存 du 70 GB，
    #   和喷3 产物根共用块，删了只回 5 GB）：克隆共享的块要等最后一个引用也删了才回，所以每删一项都重读 df、记这一项实回多少
    g0=$(fr); del "$d"; g1=$(fr); echo "  ${age} 分钟没用；盘剩 ${g1} GB（这项实回 $((g1 - g0)) GB）"
  done
  if [ "$(fr)" -lt "$HIGH" ]; then
    echo "gc：盘上 gc 管不到的大头：$(for x in "$(dirname "$RR0")"/*; do [ "$x" = "$RR0" ] || [ ! -d "$x" ] || echo "$(timeout 120 du -sg "$x" 2> /dev/null | cut -f1) $x"; done | sort -rn | head -5 | awk '$1 > 0 {printf "%s %s GB；", $2, $1}')"
  fi
fi
a1=$(df -k "$DV" | awk 'NR==2{print $4}')
echo "gc：$([ $DRY = 1 ] && echo 干跑 || echo "删 $(wc -l < "$GL" | tr -d ' ') 项，可用空间差 $(( (a1 - a0) / 1024 )) MB（同时有别的进程在写时可为负）")（可用 $((a0 / 1048576)) → $((a1 / 1048576)) GB）"
[ $DRY = 1 ] || date +%s > "$S/gc_done"   # 真跑完的时刻（11-05：tools/disk_guard.sh 按它每小时起一轮；清理器 guard_stale 超 2 小时报红）
