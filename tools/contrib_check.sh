#!/bin/bash
# 贡献者自检（协作循环第一层门禁，10-23 维护者 拍板）：在自己的 Apple Silicon Mac 上一条命令跑完、10 分钟内，结尾打一段可直接贴进 PR 的摘要。
#   bash tools/contrib_check.sh [--base <分支或提交>] [--host local|gate-host]
#   --host gate-host|auto（维护者机器；10-28 起 Spare-host 不跑门禁 / 自检，auto = gate-host）：步骤按门禁同一套分发派到 gate-host / Spare-host（维护方工具；auto = 跳过被独占预留的（维护方工具 --reserved），gate-host 空闲用 gate-host，否则 Spare-host 空闲用 Spare-host），本机不排负载队；缺省 local。
#   超时只算跑的时间：上限 = CONTRIB_TIMEOUT_S（缺省 900）+ 门禁负载排队上限 S2A_GATE_LOAD_WAIT_S（缺省 1800）——10-25 本机负载 50–80 时
#   门禁先排队、排满 900 秒被本脚本掐掉，0 绿 0 红，各线入队前自检全撞上。
#   维护者机器上（有列车目录 ~/.s2arm/run/s2arm/train）跑完写入队凭据 <列车目录>/checks/<提交全号>（tools/train.sh enqueue 认它）
# 跑什么：与列车同一张路由表（tools/gate_route.py）按改动选出的步骤（语法、单测、native / services / platforms 钩子、iOS 编译），
#   去掉 tools/contrib_layer2.tsv 登记的第二层里本机缺数据的（要我们的机器 / 测试 iPhone / 游戏文件 / 存档 / 金样录像 / gate-host 的步骤）；
#   本机数据齐（维护者机器）就跟列车跑同一份步骤（档位与第二层判定在 tools/gate_plan.sh，两边共用）。
# 第二层（金样逐帧、真机 A/B、九款回归）由维护者在列车里跑，本脚本不跑、在摘要里写明。
# 本机跑出红步时，摘要列出红的步；设 CONTRIB_BASE_RERUN=1 再把红的步在分叉点上跑一遍、按失败项比：与基线同红的、本机超时的（不重跑）列成机读的「未证」行
#   （交具备的宿主证），对不上的列「新红」；对照约让自检时间翻倍，缺省不做（#783 11-04 合入线定）。结论与退出码不变。
# 第一步跑 tools/doctor.sh（只读体检，要求从仓库现有文件读）；缺工具（Xcode / .NET / bash 5 / Python 3.12+ / Python 包）：给能照做的安装命令；依赖它的步骤记「缺工具没跑」，结论为「不完整」，退出非 0。
# 退出码：0 = 第一层全绿且没有缺跑；1 = 有红；75 = 环境未就绪（gate-host 不能派 / 门禁远端没跑成，不是红，重跑）；2 = 不完整（缺工具 / 工作树没提交 / 找不到基线 / 门禁列不出步骤或非 doc 档第一层 0 步 / 有步骤没出结论）；130 = 被中断。
set -u
# 超时（#591）：把仓库 tools/bin 放到 PATH 最前（perl 版 timeout，同 tools/toolchain.sh）。
_s2a_d=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || _s2a_d=; while [ -n "$_s2a_d" ] && [ ! -f "$_s2a_d/tools/_timeout.sh" ] && [ "$_s2a_d" != / ]; do _s2a_d=${_s2a_d%/*}; done; { [ -n "$_s2a_d" ] && [ -f "$_s2a_d/tools/_timeout.sh" ] && . "$_s2a_d/tools/_timeout.sh"; } || :
cd "$(git rev-parse --show-toplevel 2> /dev/null)" || { echo "请在 S2Arm 仓库里跑"; exit 2; }
# >>> contrib_gpu
# 自检起的本机门禁显卡步骤（维护方工具 prio）走并存档：让列车门禁先拿锁（LOWPRIO），与普查本机道（3 道）的 Mac 局同跑、不清空本机（MAXBUSY）。
#   11-04 维护者定：本机跑的显卡子项（pso_cache dsh gl vk shdist m3pack、tests/visual）都是对错检查，不测时序；独占只留给列车门禁。
#   代价：普查高峰时自检会慢一些，是有意的。单测 维护方工具「并存档」
export S2A_GATE_GPU_LOWPRIO=1 S2A_GATE_GPU_MAXBUSY=${S2A_CONTRIB_GPU_MAXBUSY:-3}
# <<< contrib_gpu
set_base() {
  case $1 in ''|-*) echo '参数错误：请使用 --base <分支或提交>，值不能为空或另一个选项' >&2; exit 2;; esac
  BASE=$1
}
BASE=; CHOST=${CONTRIB_HOST:-local}
while [ $# -gt 0 ]; do
  case $1 in
    --host) CHOST=${2:-}; shift; [ $# -gt 0 ] && shift;;   # 不带值时只移一个（shift 2 在只剩 1 个参数时失败、循环死转）
    --host=*) CHOST=${1#*=}; shift;;
    --base) set_base "${2:-}"; shift 2;;
    --base=*) set_base "${1#*=}"; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "认不得参数 $1"; exit 2;;
  esac
done
case $CHOST in local|gate-host|auto) ;; spare-host) echo "参数错误：自检不在 Spare-host 跑（10-28 Spare-host 退出门禁池），用 --host gate-host / auto"; exit 2;; *) echo "参数错误：--host 只认 local / gate-host / auto"; exit 2;; esac
T0=$SECONDS; OUT=build/contrib_check; mkdir -p "$OUT"
ITO=$PWD/tools/idle_timeout.sh   # 按无进展收门禁（基线工作树里跑时也用本检出这一份）
say() { echo "$*"; }

# ① 环境体检（tools/doctor.sh，只读；要求从仓库现有文件读）：缺的工具记下，依赖它的步骤跳过、结论「不完整」
DOC=$(bash tools/doctor.sh 2>&1); echo "$DOC" | grep -v '^缺：'
MISS=(); while IFS= read -r m; do [ -n "$m" ] && MISS+=("$m"); done < <(echo "$DOC" | sed -n 's/^缺：//p')
has_miss() { local m; for m in ${MISS[@]+"${MISS[@]}"}; do [ "$m" = "$1" ] && return 0; done; return 1; }
if has_miss "bash 5" || has_miss "Python 3.12+"; then echo; echo "🔴 缺 bash 5 / Python 3.12+：几乎每一步都要，先按上面的命令装好再跑（结论：不完整）"; exit 2; fi

# 被中断（收到信号 / 外层被停）：写明「中断」、非 0 退出，不往下算结论、不写入队凭据（10-27 交付线：步骤被停后照样判绿入队）
BW=; base_clean() { [ -n "$BW" ] || return 0; git worktree remove --force "$BW/t" > /dev/null 2>&1; rm -rf "$BW"; git worktree prune 2> /dev/null; BW=; }   # 红步与基线对照用的临时工作树（下面 ⑤b）
trap 'base_clean; echo; echo "🔴 自检被中断（收到信号）：结论不完整，不写入队凭据"; exit 130' INT TERM HUP

# ② 工作树必须干净（摘要要对得上一个提交）
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then say "🔴 工作树有未提交改动：先 git commit 再跑（PR 摘要要对应一个提交）"; exit 2; fi
REV=$(git rev-parse --short=9 HEAD)

# ③ 基线：上游 jhaizhou-ops/S2Arm 的 main（remote 名不限）；--base 可指定
if [ -z "$BASE" ]; then
  UP=$(git remote -v | awk '/jhaizhou-ops\/S2Arm(\.git)? \(fetch\)/ { print $1; exit }'); UP=${UP:-origin}
  timeout 60 git fetch -q "$UP" main 2> /dev/null || say "【黄】拉 $UP/main 失败，用本地已有的 $UP/main"
  BASE=$UP/main
fi
MB=$(git merge-base HEAD "$BASE" 2> /dev/null) || { say "🔴 找不到与 $BASE 的分叉点（--base 指一个上游 main 的提交）"; exit 2; }
CH=$(git -c core.quotepath=off diff --name-only "$MB" HEAD)
[ -n "$CH" ] || { say "🔴 相对 $BASE 没有改动"; exit 2; }
NCH=$(grep -c . < <(printf '%s\n' "$CH"))
source tools/gate_plan.sh   # 档位与第二层判定跟列车同一份（10-27：自检 13 步绿、列车 15 步红）
TIER=$(gate_tier "$CH")

# ④ 步骤清单：门禁按同一路由列出全部步骤，再分第一层 / 第二层 / 缺工具
#   doc 档也列并执行公开仓扫描；编译工具链不影响该平台无关步骤；
#   tool / full 档列不出来（门禁非 0 退出，如统一工具链不在本机）→ 留下门禁的原话、不跑、结论「不完整」（10-23 #58 复现：原先丢掉退出码与报错，0 步报绿）
rm -f "$OUT/gate.log" "$OUT/gate_list.err"   # 上一次的日志不许混进本次的绿 / 红计数
ALL=; LRC=0; LERR=
# 自检只跑合入前层（11-05 门禁精简：与列车合入前同口径；声明「门禁层：合入后」的重套件由守望在合入后全跑。原先不设层 = 全跑，自检比列车多跑一层）。
#   要连合入后层一起跑：显式 GATE_LAYER= （空）
export GATE_LAYER=${GATE_LAYER-pre}
ALL=$(GATE_LIST=1 GATE_SCAN_BASE="$MB" GATE_TIER=$TIER GATE_CHANGED="$(tr '\n' ' ' < <(printf '%s\n' "$CH"))" bash tools/gate.sh 2> "$OUT/gate_list.err"); LRC=$?
ALL=$(grep -v '^路由：' < <(printf '%s\n' "$ALL"))
if [ "$LRC" != 0 ]; then
  LERR=$(grep . "$OUT/gate_list.err" | tail -3 | tr '\n' ' '); LERR=${LERR% }
  say "🔴 门禁列步骤失败（GATE_LIST=1 bash tools/gate.sh 退出 ${LRC}）：${LERR:-没有报错输出}（全文 $OUT/gate_list.err）"
  ALL=
fi
L1=(); L2=(); SKIP=(); MACS=()   # MACS：本机没有苹果工具链、交 Mac 门禁证的步（不算缺工具、不算不完整，10-30 多宿主自检）
globhit() {   # globhit <表> <步骤名>：表里第一列（shell 通配）匹配步骤名 → 打印第二列
  local pat r; while IFS=$'\t' read -r pat r; do case $pat in \#*|'') continue;; esac; case $2 in $pat) echo "$r"; return 0;; esac; done < "$1"; return 1; }
while IFS= read -r st; do [ -n "$st" ] || continue
  # 先去掉能力标记再按同一规则分第二层；只有第一层 Apple 步计入缺工具。
  apple=
  case $st in *$'\t需苹果工具链') st=${st%$'\t需苹果工具链'}; apple=1;; esac
  if why=$(gate_layer2_why tools/contrib_layer2.tsv "$st"); then L2+=("${st}（${why}）"); continue; fi   # 本机数据齐的第二层照跑（同列车）
  [ -n "$apple" ] && { MACS+=("$st"); continue; }
  # 第二列可写多个工具（逗号分隔，缺其中任何一个就跳过，10-27：rewrite_* 同时要 Python 包与改写器固定依赖）
  if tools=$(globhit tools/contrib_tools.tsv "$st"); then mt=; IFS=, read -ra TL <<< "$tools"; for tool in "${TL[@]}"; do has_miss "$tool" && mt="$mt${mt:+、}$tool"; done
    [ -n "$mt" ] && { SKIP+=("${st}（缺 ${mt}）"); continue; }; fi
  L1+=("$st")
done < <(printf '%s\n' "$ALL")

# --list：只打第一层步骤清单（一行一步）就退出（单测 tests/gate_plan_same_test.sh 对拍列车清单用）
[ -n "${CONTRIB_LIST_ONLY:-}" ] && { printf '%s\n' ${L1[@]+"${L1[@]}"}; exit 0; }
# ⑤ 跑第一层：本机跑、只跑 L1（GATE_RERUN = 只跑这些步）；S2A_REPO 指本仓库（调度 / 列车脚本缺省认 ~/.s2arm/S2Arm，贡献者的克隆在别处）
RC=0; SUM="（尚无步骤结论）"
if [ ${#L1[@]} -gt 0 ]; then
  KEEP=$(printf '%s\t' "${L1[@]}"); KEEP=${KEEP%	}
  CTO=$(( ${CONTRIB_TIMEOUT_S:-900} + ${S2A_GATE_LOAD_WAIT_S:-1800} ))
  # CTO 是「无进展上限」不是墙钟（11-04）：门禁日志（$OUT 下）或本次远端日志目录还在长就不收；满核槽 / 令牌 / 显卡独占排队时门禁每 5 分钟打心跳。
  #   原先固定 timeout 2700 把排队算进去，自检整份 0 结论（一次成功线 18:3x、Switch2 线 19:2x 报）。硬上限 3 倍兜底
  # auto = gate-host（10-28 Spare-host 退出门禁池，不再在 gate-host / Spare-host 之间挑）：gate-host 被独占预留或盘不足（维护方工具 --reserved / --disk）→ 1 分钟内回「环境未就绪」退出 75，
  #   不退回本机、不换 Spare-host；gate-host 忙不算不就绪（门禁在 维护方工具 满核槽里排队）
  if [ "$CHOST" = auto ]; then CHOST=gate-host
    [ -n "${S2A_PRIVATE_TOOLS:-}" ] || { say "环境未就绪：--host gate-host|auto 是维护方设施，要设 S2A_PRIVATE_TOOLS"; exit 75; }
    d=$(timeout 30 bash "$S2A_PRIVATE_TOOLS/remote.sh" --host gate-host --reserved 2>&1) && { say "环境未就绪：gate-host ${d}（不换 Spare-host、不退回本机）"; exit 75; }
    d=$(timeout 30 bash "$S2A_PRIVATE_TOOLS/remote.sh" --host gate-host --disk 2>&1) || { say "环境未就绪：${d}（不换 Spare-host、不退回本机）"; exit 75; }
  fi
  say "第一层：$TIER 档，改 $NCH 个文件 → 跑 ${#L1[@]} 步（$([ "$CHOST" = local ] && echo 本机 || echo "派 ${CHOST}，本机不排负载队")）；日志 $OUT/gate.log"
  S2A_REPO=$PWD GATE_HOST=$CHOST GATE_SCAN_BASE="$MB" GATE_TIER=$TIER GATE_CHANGED="$(tr '\n' ' ' < <(printf '%s\n' "$CH"))" GATE_RERUN="$KEEP" GATE_REMOTE_NAME=contrib-$(basename "$PWD") \
    env $([ "$CHOST" != local ] && echo GATE_NO_LOADQ=1) bash "$ITO" "$CTO" $((CTO * 3)) "$OUT" "${S2A_REMOTE_LOGS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/remote}/contrib-$(basename "$PWD")" -- bash tools/gate.sh > "$OUT/gate.log" 2>&1; RC=$?
  grep '^工具链提示：' "$OUT/gate.log"   # 原始诊断可见，但不进入步骤计数
  grep -E '^(🟢|🔴) ' "$OUT/gate.log"
  SUM=$(tail -1 "$OUT/gate.log")
  [ $RC = 124 ] && SUM="超 ${CTO} 秒没跑完"
fi
# 任一档第一层一步没跑（列不出步骤 / 列出 0 步 / 全是第二层）不算绿：至少有公开仓扫描一步，0 步说明自检本身没生效
EMPTY=
if [ ${#L1[@]} -eq 0 ]; then
  if [ "$LRC" != 0 ]; then EMPTY="门禁列步骤失败（退出 ${LRC}）：${LERR:-没有报错输出}"
  elif [ -z "$(grep . < <(printf '%s\n' "$ALL"))" ]; then EMPTY="门禁列出 0 步（${TIER} 档至少应有公开仓扫描一步）"
  elif [ ${#MACS[@]} -gt 0 ] && [ ${#SKIP[@]} -eq 0 ]; then EMPTY=   # 本机能证的一步都不涉及、其余全待 Mac 证：结论按两段写，不算不完整
  else EMPTY="第一层 0 步（列出的步骤都归第二层或缺工具）"; fi
  [ -n "$EMPTY" ] && { SUM=$EMPTY; [ "$LRC" != 0 ] || say "🔴 ${EMPTY}：结论不完整，不能当第一层通过"; }
fi
GREEN=$(grep -c '^🟢 ' "$OUT/gate.log" 2> /dev/null); REDN=$(grep -c '^🔴 ' "$OUT/gate.log" 2> /dev/null)
# 有步骤没出结论不算绿（10-27 交付线：外层被停后派到 gate-host / Spare-host 的步骤陆续被杀，收尾「跑了 9 步；绿 0、红 0」照样 rc=0、cc_enqueue 推送入队）：
#   绿 + 红 < 应跑的第一层步数 → 不完整（退出 2，不当入队凭据）
NORES=
if [ ${#L1[@]} -gt 0 ] && [ $(( ${GREEN:-0} + ${REDN:-0} )) -lt ${#L1[@]} ]; then
  NORES="第一层应跑 ${#L1[@]} 步只出 $(( ${GREEN:-0} + ${REDN:-0} )) 个结论（步骤被中断或没跑完）"; say "🔴 ${NORES}：结论不完整，不能当第一层通过"; SUM=$NORES
fi
# 一个结论都没出（11-04 维护者：gate-host 门禁令牌漏掉一半后，两份自检各空跑 45 分钟，只报「只出 0 个结论」）：明说是环境没跑起来、不是本支红，带上门禁日志里最后的排队 / 远端行
if [ ${#L1[@]} -gt 0 ] && [ $(( ${GREEN:-0} + ${REDN:-0} )) = 0 ]; then
  say "🔴 环境未就绪：门禁一步结论都没出（远端没跑起来 / 被总时限收掉 / 卡在令牌或满核槽排队），不是本支红；环境好了重跑。门禁日志最后的排队 / 远端行："
  grep -aE '门禁令牌|remote：|满核槽|排队|环境未就绪' "$OUT/gate.log" 2> /dev/null | tail -3 | sed 's/^/    /'
  SUM="环境未就绪（${NORES}）"
fi
# 宿主项（10-30）：门禁结论里「待宿主证 / 已证宿主项」两类机读行（tools/gate.sh 收自各步）；已证的写成带本提交全号的「宿主证明」行，贴进 PR 后列车按提交核
HPEND=$(grep -a '^待宿主证	' "$OUT/gate.log" 2> /dev/null | cut -f2- | sort -u)
HPROOF=$(grep -a '^已证宿主项	' "$OUT/gate.log" 2> /dev/null | awk -F'\t' -v h="$(git rev-parse HEAD)" '{ print "宿主证明\t" $2 "\t" $3 "\t绿\t" h }' | sort -u)
# ⑤b 红步与基线对照（#783 11-03 合入线答 1；11-04 合入线定：缺省关、超时的步不重跑）：本机自检时不少单测因机器原因（缺 Xcode、gate-host 才有的环境）在 main 上本来就红，
#   「与基线一样红」只排除得了新冒出来的红：本支把一支本来就红的单测改坏了，两边照样一样红。所以分开写：
#   缺省只在摘要里列出本机红的步（不多跑）；设 CONTRIB_BASE_RERUN=1 才对照（自检时间约翻倍：11-04 Linux 实测 629 → 1258 秒）——
#   只把本机红的步在分叉点 MB 的临时工作树里再跑一遍（同一份改动清单、只跑这几步），按 tools/known_red.py 的失败特征（失败项 + 归一化后的错误原文）逐项比：
#   基线这一步也红、本支每一项失败基线都有 → 「未证」（与基线同红），红步取不出失败项明细时只比到整步，照样算未证；
#   本机跑到门禁时限的步（tools/gate.sh 打「（rc=124，超 N 秒）」）不在基线重跑（再跑一遍也要这么久），直接记「未证」、比到哪写「超时」；
#   未证的写成机读行（未证<TAB>步<TAB>逐项相同|只比到整步|超时<TAB>提交全号<TAB>基线全号），贴进 PR、交具备的宿主（gate-host）证；
#   基线这一步绿 / 基线没有这一步 / 没出结论 / 本支多出基线没有的失败项 → 「新红」。结论与退出码不变（有红照样红、不写进入队凭据）。
#   只在本机跑时对照（--host gate-host / auto 是维护者机器，红就是红）
red_names() { awk -v only="${2:-}" '/^🔴 / && (only == "" || index($0, only)) { n = ""; for (i = 2; i < NF; i++) { if ($i ~ /^[0-9]+$/ && $(i + 1) ~ /^秒/) break; n = n (n == "" ? "" : " ") $i } print n }' "$1"; }   # 红步的步名（🔴 后、「<数字> 秒」前；明细里也可能带「秒」，取第一处）；第二个参数 = 这一行还得带的字样
CMP=; BNOTE=
if [ "$CHOST" = local ] && [ "${REDN:-0}" -gt 0 ] && [ $RC != 0 ] && [ $RC != 75 ] && [ $RC != 124 ]; then
  if [ "${CONTRIB_BASE_RERUN:-0}" != 1 ]; then
    BNOTE="没对照（设 CONTRIB_BASE_RERUN=1 在分叉点只重跑这几步、分出新红与未证）：本机红 ${REDN} 步：$(red_names "$OUT/gate.log" | awk '{ printf "%s；", $0 }')"
  elif [ ! -f tools/known_red.py ]; then BNOTE="没对照（没有 tools/known_red.py）"
  else
    TOS=$(red_names "$OUT/gate.log" '（rc=124，超 ')   # 跑到门禁时限的步；没到上限、自己退 124 的照普通红步对照
    RST=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import known_red as k; to = set(sys.argv[2].splitlines()); print("\t".join(s for s in k.failures(sys.argv[1]) if s not in to))' "$OUT/gate.log" "$TOS" 2> "$OUT/base_gate.log") || RST=
    : > "$OUT/base_steps.txt"
    if [ -z "$RST$TOS" ]; then BNOTE="没对照（从 $OUT/gate.log 取不出红步）"
    elif [ -n "$RST" ] && { ! BW=$(mktemp -d "${TMPDIR:-/tmp}/contrib-base.XXXXXX") || ! git worktree add -q --detach "$BW/t" "$MB" > "$OUT/base_gate.log" 2>&1; }; then
      BNOTE="没对照（在分叉点建不了临时工作树，见 $OUT/base_gate.log）"; base_clean
    else
      : > "$OUT/base_gate.log"
      if [ -n "$RST" ]; then
        # 先取基线的步骤清单：请求的步有一个不在清单里，门禁整次不跑（tools/gate.sh「自检请求的步骤未在本次清单中」）；本支新加的单测基线上没有，剔掉、记「基线没有这一步」
        BLOG=$PWD/$OUT/base_gate.log   # 绝对路径：下面先 cd 进基线工作树
        if ! BL=$(cd "$BW/t" && S2A_REPO=$PWD GATE_LIST=1 GATE_HOST=local GATE_SCAN_BASE="$MB" GATE_TIER=$TIER GATE_CHANGED="$(tr '\n' ' ' < <(printf '%s\n' "$CH"))" bash tools/gate.sh 2> "$BLOG"); then
          BNOTE="没对照（分叉点上门禁列不出步骤，见 $OUT/base_gate.log）"
        else
          grep -v '^路由：' <<< "$BL" | cut -f1 > "$OUT/base_steps.txt"
          RB=$(tr '\t' '\n' < <(printf '%s\n' "$RST") | grep -Fxf "$OUT/base_steps.txt" | awk 'NR > 1 { printf "\t" } { printf "%s", $0 }')
          say "红步与基线对照：在分叉点 $(git rev-parse --short=9 "$MB") 的临时工作树里只重跑本机红、基线也有的 $(tr '\t' '\n' <<< "$RB" | grep -c .) 步（本机超时的 $(grep -c . <<< "$TOS") 步不重跑；CONTRIB_BASE_RERUN=1）"
          if [ -n "$RB" ]; then (cd "$BW/t" && S2A_REPO=$PWD GATE_HOST=local GATE_SCAN_BASE="$MB" GATE_TIER=$TIER GATE_CHANGED="$(tr '\n' ' ' < <(printf '%s\n' "$CH"))" GATE_RERUN="$RB" bash "$ITO" "$CTO" $((CTO * 3)) "$OUT" "${S2A_REMOTE_LOGS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/remote}/contrib-$(basename "$PWD")" -- bash tools/gate.sh) > "$OUT/base_gate.log" 2>&1; fi
        fi
      fi
      # 基线工作树的路径先换成本仓库的：同一项失败的错误原文才对得上（known_red 只归一化临时目录那一级，后面的路径保留）
      [ -n "$BNOTE" ] || CMP=$(python3 - "$OUT/gate.log" "$OUT/base_gate.log" "${BW:-/nonexistent}/t" "$PWD" "$OUT/base_steps.txt" "$TOS" <<'PY'
import os, re, sys, tempfile
sys.path.insert(0, 'tools'); import known_red as k
head_log, base_log, bt, top, steps, tos = sys.argv[1:7]
tos = set(tos.splitlines())
# known_red 的归一化是照 gate-host 上的日志定的；本机的环境红里还有每次都变的：合成仓库的提交短号（7–12 位、字母数字混排）、
#   磁盘剩余块数这类 6 位以上的大数——不换掉，同一项失败两边对不上、被当成新红（11-04 Linux 实跑：4 支红里 2 支这样误判）。16 位着色器键、小计数不动
VOL = [(re.compile(r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,12}\b'), '<v>'), (re.compile(r'\b[0-9]{6,}\b'), '<v>')]   # 同一个占位：全是数字的提交短号也换成一样的
def vol(x):
    for r_, t_ in VOL: x = r_.sub(t_, x)
    return x
listed = set(open(steps, encoding='utf-8').read().splitlines())
text = open(base_log, encoding='utf-8', errors='replace').read()
for p in sorted({bt, os.path.realpath(bt)}, key=len, reverse=True): text = text.replace(p, top)
with tempfile.NamedTemporaryFile('w', encoding='utf-8', suffix='.log', delete=False) as f: f.write(text)
try:
    head, base = ({st: [vol(x) for x in v] for st, v in k.failures(g).items()} for g in (head_log, f.name))
    green = {m.group(3) for m in map(k.STEP.match, text.splitlines()) if m and not m.group(1) and m.group(2) == '🟢'}
    # 基线这一步打了「待宿主证」机读行（tools/gate.sh 收自各步：待宿主证<TAB>类别<TAB>项<TAB>步）= 这一步没跑全却退 0（如安卓钩子遇 APK 准备持锁早退），
    #   不能当「基线这一步绿」把本支的红判成新红（#1553，#1546 撞上）：单列「缺」，进未证机读行
    pend = {}
    for ln in text.splitlines():
        f_ = ln.split('\t')
        if len(f_) >= 4 and f_[0] == '待宿主证': pend.setdefault(f_[3], f'待{f_[1]}证：{f_[2]}')
finally: os.unlink(f.name)
for st, sigs in head.items():
    if st in tos: print(f'超\t{st}\t超时')
    elif st in base:
        extra = [x for x in sigs if x not in base[st]]
        if extra: print(f'新\t{st}\t多出基线没有的失败项：{extra[0][:100]}' + ('…' if len(extra[0]) > 100 else '') + (f' 等 {len(extra)} 项' if len(extra) > 1 else ''))
        else: print(f'同\t{st}\t' + ('逐项相同' if sigs else '只比到整步'))
    elif st in pend: print(f'缺\t{st}\t基线没跑全（{pend[st]}）')
    elif st in green: print(f'新\t{st}\t基线这一步绿')
    elif st not in listed: print(f'新\t{st}\t基线没有这一步')
    else: print(f'新\t{st}\t基线没出这一步的结论')
PY
) || { CMP=; BNOTE="没对照（比对出错，见 $OUT/base_gate.log）"; }
      base_clean
    fi
  fi
fi
NNEW=$(grep -c '^新	' < <(printf '%s\n' "$CMP")); NSAME=$(grep -c '^同	' < <(printf '%s\n' "$CMP")); NTO=$(grep -c '^超	' < <(printf '%s\n' "$CMP")); NMISS=$(grep -c '^缺	' < <(printf '%s\n' "$CMP"))
NEWR=$(printf '%s\n' "$CMP" | grep '^新	' | awk -F'\t' '{ printf "%s（%s）；", $2, $3 }')
UNPROVEN=$(printf '%s\n' "$CMP" | grep -E '^(同|超|缺)	' | awk -F'\t' -v h="$(git rev-parse HEAD)" -v b="$(git rev-parse "$MB")" '{ print "未证\t" $2 "\t" $3 "\t" h "\t" b }')
if [ $RC = 75 ]; then VERD=环境未就绪; EXIT=75   # 门禁：远端没就绪、本机步无真红（tools/gate.sh）——不是红，重跑即可
elif [ $RC != 0 ]; then VERD=红; EXIT=1; elif [ -n "$EMPTY" ] || [ -n "$NORES" ] || [ ${#SKIP[@]} -gt 0 ]; then VERD=不完整; EXIT=2
elif [ ${#MACS[@]} -gt 0 ] || [ -n "$HPEND" ]; then VERD="本机已证绿，$([ ${#MACS[@]} -gt 0 ] && echo "待 Mac 证 ${#MACS[@]} 步")${HPEND:+$([ ${#MACS[@]} -gt 0 ] && echo "，")待宿主证 $(grep -c . <<< "$HPEND") 项}"; EXIT=0   # 两段结论：本机能证的全绿；苹果步交列车在 gate-host 上证（入队按此放行）
else VERD=绿; EXIT=0; fi

# Linux 按真实结果计数，不把已选择但没出结论的步骤写成「跑了」。
RAN=${#L1[@]}
[ "$(uname -s)" = Linux ] && RAN=$(( ${GREEN:-0} + ${REDN:-0} ))

# ⑥ PR 摘要
{
  echo "### 自检（tools/contrib_check.sh，第一层）"
  echo "- 提交：\`$REV\`（基线 \`$(git rev-parse --short=9 "$MB")\`，${BASE}）"
  echo "- 档位：${TIER}；改 $NCH 个文件"
  echo "- 第一层（本机已证）：应跑 $(( ${#L1[@]} + ${#SKIP[@]} )) 步、跑了 $RAN 步；绿 ${GREEN:-0}、红 ${REDN:-0}；耗时 $((SECONDS - T0)) 秒"
  [ ${#MACS[@]} -gt 0 ] && echo "- 待 Mac 证（本机无苹果工具链，交列车门禁在 gate-host 上跑）：$(printf '%s；' "${MACS[@]}")"
  [ -n "$HPEND" ] && echo "- 待宿主证（本机不具备，需在具备的宿主上证、把证明行贴进 PR）：$(awk -F'\t' '{ printf "%s：%s（%s）；", $1, $2, $3 }' <<< "$HPEND")"
  [ -n "$HPROOF" ] && { echo "- 宿主证明（本机已证，原样贴进 PR，列车按提交核）："; echo '```'; echo "$HPROOF"; echo '```'; }
  echo "- 门禁结论行：$SUM"
  [ -n "$BNOTE" ] && echo "- 红步与基线对照：$BNOTE"
  [ -n "$CMP" ] && echo "- 红步与基线对照（分叉点 \`$(git rev-parse --short=9 "$MB")\` 上只重跑本机红的步，日志 $OUT/base_gate.log）：新红 ${NNEW} 步、与基线同红 ${NSAME} 步$([ "$NTO" -gt 0 ] && echo "、本机超时没重跑 ${NTO} 步")$([ "$NMISS" -gt 0 ] && echo "、基线这一步没跑全 ${NMISS} 步")"
  [ -n "$NEWR" ] && echo "- 新红（基线上对不上：本 PR 引入的，或基线这一步跑法不同；要修或在 PR 里说明）：$NEWR"
  [ -n "$UNPROVEN" ] && { echo "- 本机红、未证 $((NSAME + NTO + NMISS)) 步（与基线同红 ${NSAME} 步：只排除了新红，看不出本来就红的单测里有没有被改坏；本机超时 ${NTO} 步：没在基线重跑；$([ "$NMISS" -gt 0 ] && echo "基线没跑全 ${NMISS} 步：基线那一步打了待宿主证（如安卓 APK 准备持锁早退），两边不可比；")下面原样贴进 PR，交具备的宿主证）："; echo '```'; echo "$UNPROVEN"; echo '```'; }
  [ ${#SKIP[@]} -gt 0 ] && echo "- 缺工具没跑：$(printf '%s；' "${SKIP[@]}")"
  echo "- 第二层（金样逐帧、真机 A/B、九款回归）由维护者在列车里跑：$([ ${#L2[@]} -gt 0 ] && printf '%s；' "${L2[@]}" || { [ "$LRC" != 0 ] && echo '门禁列步骤失败，不知道有哪些' || echo '本次改动没有第二层步骤'; })"
  echo "- 结论：**$VERD**"
} > "$OUT/summary.md"
echo; echo "===== 贴进 PR 的摘要（也在 $OUT/summary.md）====="; cat "$OUT/summary.md"
# 入队凭据（维护者机器上才有列车目录）：<提交全号> → 结论 / 档 / 基线全号 / 跑了几步 / 在哪跑 / 时刻；tools/train.sh enqueue 只认结论绿、且基线是待合提交祖先的
#   基线记分叉点 MB（本次自检实际对比的 main 提交），不记当时 origin/main 的头：自检十几分钟里 main 会前进，记头的话凭据永远「基线不在本支历史里」（10-25 merge349 / pushpak 绿了照样被拒）
CKD=${S2A_TRAIN_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/train}
[ -d "$CKD" ] && mkdir -p "$CKD/checks" && printf '结论	%s
档	%s
基线	%s
步数	%s
位置	%s
时刻	%s
结论行	%s
' "$VERD" "$TIER" "$MB" "${#L1[@]}" "$CHOST" "$(date '+%m-%d %T')" "$SUM" > "$CKD/checks/$(git rev-parse HEAD)"
[ ${#MISS[@]} -gt 0 ] && { echo; echo "缺的工具（安装命令见上面体检）：${MISS[*]}"; }
exit $EXIT
