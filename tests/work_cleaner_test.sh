#!/bin/bash
# 门禁预算：900
# 门禁层：合入后
# 门禁覆盖：tools/ops/work_cleaner.sh tools/ops/guard_lib.sh
# 工作盘清理器（tools/ops/work_cleaner.sh）单测（合入运维线 11-04 起，11-05 收进仓库）：bash tests/work_cleaner_test.sh [--no-neg]
#   跑的是 tools/ops/work_cleaner.sh 本体（WC 覆盖）；删除走替身（只许删本测试临时目录里的东西，运行区 safe_rm.sh 有本机盘路径、不进仓库）；临时 WORK 在 $TMPDIR 下。
#   每个用例新建一套：layout.env（单位 KB：S2A_WC_UNIT_KB=1）、假缓存 / 假批次 / 假产物根、假 packq / 调度目录、调度 refs 桩、GUARD_DIR / GUARD_STATUS。
#   负控：把 work_cleaner.sh 里某条判据改成「不成立」（函数开头插 return 1 / 删一行），对应用例必须红。
set -u
H=$(cd "$(dirname "$0")" && pwd); WC=${WC:-$H/../tools/ops/work_cleaner.sh}; export S2A_GUARD_LIB=${S2A_GUARD_LIB:-$H/../tools/ops/guard_lib.sh}
TOP=$(mktemp -d "${TMPDIR:-/tmp}/wct.XXXXXX"); TOP=$(cd "$TOP" && pwd -P); PIDS=
RMS=$TOP/rm_stub.sh; printf '#!/bin/bash\ncase $1 in "%s"/*) rm -rf -- "$1";; *) echo "替身拒删 $1" >&2; exit 3;; esac\n' "$TOP" > "$RMS"   # 删除替身：只许删本测试临时目录里的
cleanup() { for p in $PIDS; do kill "$p" 2> /dev/null; done; chmod -R u+w "$TOP" 2> /dev/null; rm -rf "$TOP"; }; trap cleanup EXIT
bg() { "$@" > /dev/null 2>&1 & PIDS="$PIDS $!"; LAST=$!; }   # 起一个辅助进程（sleep 等），记 pid 收尾杀
old() { find "$1" -exec touch -h -t "$(date -v-"${2:-600}"M +%Y%m%d%H%M.%S)" {} + 2> /dev/null; }   # 整棵树改成 N 分钟前
PYH=/opt/homebrew/bin/python3; [ -x "$PYH" ] || PYH=$(command -v python3)
hold() { local i; bg "$PYH" -c 'import time; time.sleep(120)' "$@"
  for i in $(seq 100); do ps -axEww -o command= -p "$LAST" 2> /dev/null | grep -qF -- "$*" && return 0; sleep 0.1; done; echo "    × 持有者 10 秒没进进程表：$*"; F=1; }   # 等它真进进程表（11-05 固定等 0.5 秒，本机编 dotnet 时 c_pqx_cap 偶发把被持有的条目删掉）   # 辅助进程：macOS 系统自带程序（/bin/sleep 等）的环境在 ps -E 里看不到，用 Homebrew python 当持有者；参数会出现在命令行
blob() { mkdir -p "$(dirname "$1")"; dd if=/dev/urandom of="$1" bs=1k count="$2" 2> /dev/null; }
mk() {   # 新建一套环境 → ${B}（用例根）${W}（WORK）
  B=$(mktemp -d "$TOP/c.XXXX"); W=$B/work; mkdir -p "$W"/cache/direct "$W"/cache/unpack "$W"/census "$W"/roots "$B"/g/locks "$B"/g/ops_bg "$B"/pq/run "$B"/pq/req "$B"/sd/queue "$B"/sd/run "$B"/sd/jobs
  printf '# 状态\n其它行\n' > "$B/status.md"; date +%s > "$B/gc_done"; export WORK_GC_STAMP=$B/gc_done   # 本机 gc 时间戳（guard_stale）指本例临时文件，缺省刚跑完
  cat > "$B/layout.env" <<EOT
WORK=$W
WORK_LINE_KEEP_H=${LKH:-0}
WORK_FLOOR_GB=${FLOOR:-1}
WORK_XLATE_DIRS="$W/cache/direct $W/census_dcache"
WORK_XLATE_CAP_GB=${XCAP:-100000}
WORK_UNPACK_DIR=$W/cache/unpack
WORK_UNPACK_CAP_GB=${UCAP:-100000}
WORK_CENSUS_DIRS=$W/census
WORK_ROOTS_DIR=$W/roots
WORK_ROOTS_CAP_GB=${RCAP:-}
WORK_MISC="${MISCV:-}"
WORK_FREE_TARGET_GB=${FT:-}
WORK_TITLES_TSV=$B/titles.tsv
EOT
  printf '# 款名表\n0100000000000A03\tgamec\n' > "$B/titles.tsv"
  mkdir -p "$W/census_dcache"
  printf '#!/bin/bash\n[ "$1" = refs ] && cat "$S2A_SCHED_DIR/refs.txt" 2> /dev/null; exit 0\n' > "$B/sched_ok.sh"
  printf '#!/bin/bash\nexit 1\n' > "$B/sched_bad.sh"; SCHED=$B/sched_ok.sh; TOTAL=100000000
}
mk2() { sed -i '' -e "s#^WORK_MISC=.*#WORK_MISC=\"${MISCV:-}\"#" -e "s#^WORK_FREE_TARGET_GB=.*#WORK_FREE_TARGET_GB=${FT:-}#" "$B/layout.env"; }
run() {   # run [--n 轮数]：跑 N 轮 --once，返回最后一轮退出码
  local n=1 i rc=0; [ "${1:-}" = --n ] && { n=$2; shift 2; }
  for i in $(seq "$n"); do
    env S2A_LAYOUT_ENV="$B/layout.env" S2A_WC_UNIT_KB=1 GUARD_DIR="$B/g" GUARD_STATUS="$B/status.md" S2A_WC_RM="$RMS" S2A_SAFE_RM_LOG="$B/rm.log" WORK_EVIDENCE_DIR="$B/ev" \
      S2A_PACKQ_DIR="$B/pq" S2A_SCHED_DIR="$B/sd" S2A_WC_SCHED_SH="$SCHED" WCT_TOTAL="$TOTAL" WCT_W="$W" \
      S2A_WC_FREE_CMD='echo $(( WCT_TOTAL - $(du -sk "$WCT_W" | cut -f1) ))' ${PSX:+S2A_WC_PS="$PSX"} bash "$WC" --once "$@" > "$B/out.txt" 2>&1; rc=$?; done
  return $rc; }
F=0; fails=
ok() { [ -e "$1" ] || { echo "    × 应留没留：${1#$B/}"; F=1; }; }
gone() { [ -e "$1" ] && { echo "    × 应删没删：${1#$B/}"; F=1; }; return 0; }
tsv() { local f=$1; shift; mkdir -p "$(dirname "$f")"; printf '键\t名称\t版本\t机器\t源GB\t款\t结论\n' > "$f"; for r in "$@"; do printf '%s\t名\t1\tlocal\t1\tt\t%s\n' "${r%%:*}" "${r#*:}" >> "$f"; done; }
ID1=0100000000000A01; ID2=0100000000000A02; ID3=0100000000000A03; ID4=0100000000000A04; ID5=0100000000000A05
livebatch() { hold census.sh "$1"; }   # livebatch <批目录>：让这一批算「在跑」（清理器 batch_live 按进程表认 census.sh <批目录>）
keepq() { printf '%s\n' "$@" > "$W/cache/unpack/.keep"; mkdir -p "$W/census/bk"; printf '%s\n' "$@" > "$W/census/bk/queue.tsv"; livebatch "$W/census/bk"; }   # keepq <程序号…>：写进 .keep，并让它们在一个在跑批的队列里（.keep 只认在跑批队列里的款）
ucache() { mkdir -p "$W/cache/unpack/$1"; blob "$W/cache/unpack/$1/romfs.bin" "${3:-4}"; echo "${2:-4}" > "$W/cache/unpack/$1.size"; }
# ---------------- 用例 ----------------
c_roots() {   # 产物根：现行 + pkg 留，中间版本（含没持有者的 .tmp）删，2 小时内动过的留
  mk; R=$W/roots; mkdir -p "$R/g1@c2" "$R/g1@pkg-a" "$R/g1@ex-1" "$R/g1@dl-2.tmp" "$R/g1@pkg-b.tmp" "$R/g1@rx-young"; ln -s g1@c2 "$R/g1@现行"
  echo x > "$R/g1@ex-1/f"; old "$R/g1@ex-1"; old "$R/g1@dl-2.tmp"; old "$R/g1@pkg-b.tmp"; old "$R/g1@c2"; old "$R/g1@pkg-a"; run
  ok "$R/g1@c2"; ok "$R/g1@pkg-a"; ok "$R/g1@rx-young"; [ -L "$R/g1@现行" ] || { echo "    × 现行软链没了"; F=1; }
  gone "$R/g1@ex-1"; gone "$R/g1@dl-2.tmp"; gone "$R/g1@pkg-b.tmp"; }
c_roots_cap() {   # 产物根上限（整款 LRU）：5 款各 100，上限 250。最旧 ID1 钉住（按程序号）、次旧 ID2 待跑 → 留；ID3（简称 gamec 经款名表）、ID4 整款删（现行 + 其它版本 + 现行链接）；ID5 一小时内动过 → 留
  RCAP=250; mk; R=$W/roots; local i=0 id n
  for id in $ID1 $ID2 $ID3 $ID4 $ID5; do i=$((i + 1)); n=t$(echo "$id" | tr A-F a-f); [ "$id" = "$ID3" ] && n=gamec
    blob "$R/$n@c1/f" 100; ln -s "$n@c1" "$R/$n@现行"; done
  mkdir -p "$R/gamec@pkg-x"; old "$R/gamec@pkg-x" 900
  old "$R/t$(echo $ID1 | tr A-F a-f)@c1" 500; old "$R/t$(echo $ID2 | tr A-F a-f)@c1" 400; old "$R/gamec@c1" 300; old "$R/t$(echo $ID4 | tr A-F a-f)@c1" 200; old "$R/t$(echo $ID5 | tr A-F a-f)@c1" 60
  echo "$ID1" > "$W/pins"; mkdir -p "$W/census/b1/running"; touch "$W/census/b1/running/$ID2"; livebatch "$W/census/b1"; run; unset RCAP
  ok "$R/t$(echo $ID1 | tr A-F a-f)@c1"; ok "$R/t$(echo $ID2 | tr A-F a-f)@c1"; ok "$R/t$(echo $ID5 | tr A-F a-f)@c1"
  gone "$R/gamec@c1"; gone "$R/gamec@pkg-x"; gone "$R/t$(echo $ID4 | tr A-F a-f)@c1"
  { [ -L "$R/gamec@现行" ] || [ -L "$R/t$(echo $ID4 | tr A-F a-f)@现行" ]; } && { echo "    × 整款删后现行链接还在"; F=1; }; return 0; }
c_line_keep() {   # 各线目录在用不靠登记（11-06 总指挥：Switch2 线 ns2_zelda 下在用的 run_v34.sh / up_venv / up_src 被删三次）：线目录 L 上限 0，
  #   期望（按规则手写）：new 1 分钟前新建 → 留；new3h 3 小时前动过 → 留（只有「各线目录 24 小时」这条保得住，原 2 小时窗口保不住）；held 30 小时没动、但有进程开着里面的文件 → 留；old 30 小时没动、没人用 → 删（负对照）
  mk; local n; L=$W/linek; for n in new new3h held old; do blob "$L/$n/f" 10; done; old "$L/new" 1; old "$L/new3h" 180; old "$L/held" 1800; old "$L/old" 1800
  bg bash -c "exec 3< '$L/held/f'; exec sleep 120"; sleep 0.5
  MISCV="$L=0"; LKH=24 mk2; sed -i '' 's/^WORK_LINE_KEEP_H=.*/WORK_LINE_KEEP_H=24/' "$B/layout.env"; run; unset MISCV
  ok "$L/new/f"; ok "$L/new3h/f"; ok "$L/held/f"; gone "$L/old"; return 0; }
c_misc_cap() {   # 各线目录上限 LRU：线目录 L 下 4 条各约 100，上限 250。最旧 a 被调度 refs 引用、次旧 b 有活 .pin → 留；删 c；d 30 分钟内动过 → 留，仍超上限记黄
  mk; local n; L=$W/linex; for n in a b c d; do blob "$L/$n/f" 100; done; old "$L/a" 500; old "$L/b" 400; old "$L/c" 300; old "$L/d" 10
  echo "$L/a/pkg" > "$B/sd/refs.txt"; bg sleep 120; printf '%s %s\n' "$LAST" "$(ps -o lstart= -p $LAST | awk '{$1 = $1} 1')" > "$L/b/.pin.v1.$LAST"; old "$L/b" 400
  MISCV="$L=250"; mk2; run; unset MISCV
  ok "$L/a"; ok "$L/b"; gone "$L/c"; ok "$L/d"; grep -q "linex 删到不在用的都删完仍超上限" "$B/g/ops_bg/work_cleaner.log" || { echo "    × 没记黄"; F=1; }; return 0; }
c_privroot() {   # 各线私有根整款回收（11-05 总指挥：roots_priv 下 .romfs_store 没人管）：闲置 6 小时；树 L 下 5 款，版本 romfs 是指向只读存储的软链。
  #   g1 400 分钟没动 → 版本、现行链接、只读存储全删；g2 钉住表带原因 → 留；g3 钉住表没写原因 → 照删、记黄；g4 有活 .pin → 留；g5 60 分钟前动过 → 留
  #   另一棵树 l2 根上打了 .keep、同样 400 分钟没动 → 整棵留（11-07：整棵 .keep 原先不认，mk8fix / nmsrec 打了 .keep 照样进删除名单）
  mk; local L=$W/roots_priv/l1 g; echo "WORK_PRIVROOT_IDLE_H=6" >> "$B/layout.env"
  for g in g1 g2 g3 g4 g5; do mkdir -p "$L/$g@a"; blob "$L/.romfs_store/$g/a-1/f" 5; ln -s "../.romfs_store/$g/a-1" "$L/$g@a/romfs"; ln -s "$g@a" "$L/$g@现行"; done
  bg sleep 120; printf '%s %s\n' "$LAST" "$(ps -o lstart= -p $LAST | awk '{$1 = $1} 1')" > "$L/.pin.g4@a.$LAST"
  printf '%s\t%s\n' "$L/g2" "jhz 手测包要用" > "$W/pins"; printf '%s\n' "$L/g3" >> "$W/pins"
  local K=$W/roots_priv/l2; mkdir -p "$K/k1@a"; blob "$K/k1@a/f" 5; ln -s "k1@a" "$K/k1@现行"; : > "$K/.keep"; old "$K" 400
  #   g6 同样 400 分钟没动，但活进程命令行提到的作业目录 job6 里 pack 软链到 g6@a/pack（11-07 卡顿线 tl3_off 排准入时根被删）→ 留；
  #   负对照 g7：作业目录 job7 也软链到它，但没有活进程提到 job7 → 照删
  local g; for g in g6 g7; do mkdir -p "$L/$g@a/pack"; blob "$L/$g@a/pack/f" 5; mkdir -p "$W/st/job${g#g}"; ln -s "$L/$g@a/pack" "$W/st/job${g#g}/pack"; done
  bg bash -c 'sleep 120; :' x "$W/st/job6"
  old "$L" 400; old "$L/g5@a" 60; chmod -R a-w "$L/.romfs_store"/*/a-1
  run
  ok "$L/g6@a/pack/f"; gone "$L/g7@a"
  gone "$L/g1@a"; gone "$L/.romfs_store/g1"; [ -L "$L/g1@现行" ] && { echo "    × g1 现行链接还在"; F=1; }
  ok "$K/k1@a/f"; ok "$L/g2@a"; ok "$L/.romfs_store/g2/a-1/f"; gone "$L/g3@a"; gone "$L/.romfs_store/g3"; ok "$L/g4@a"; ok "$L/.romfs_store/g4/a-1"; ok "$L/g5@a"; ok "$L/.romfs_store/g5/a-1"
  grep -q "钉住表里 $L/g3 没写原因" "$B/g/ops_bg/work_cleaner.log" || { echo "    × 没原因的钉没记黄"; F=1; }
  chmod -R u+w "$L" 2> /dev/null; return 0; }
c_idle_dir() {   # 按闲置整条回收（11-05 逐帧录像 frame_rec=24 小时）：a 30 小时没动 → 删；b 同样旧但钉住表带原因 → 留；c 深层文件 1 小时前动过 → 留；
  #   d 断了的软链 → 删；e 指向本例临时目录外真目录的软链（内置盘那份）→ 不碰
  mk; local L=$W/frec x; echo "WORK_IDLE_DIRS=\"$L=24\"" >> "$B/layout.env"
  for x in a b c; do blob "$L/$x/r1/rec/f1/mem.bin" 5; done; old "$L" 1800; touch "$L/c/r1/rec/f1/mem.bin"
  mkdir -p "$B/int/e"; ln -s "$B/int/nope" "$L/d"; ln -s "$B/int/e" "$L/e"; printf '%s\t%s\n' "$L/b" "满屏线手测对照要用" > "$W/pins"
  blob "$L/f/f5800/m.bin" 5; blob "$L/f/f9000/m.bin" 5; old "$L/f" 1800; printf '%s\t%s\n' "$L/f/f5800" "能耗线回放对照（钉子目录，父目录整条闲置也不删）" >> "$W/pins"
  run
  gone "$L/a"; ok "$L/b/r1/rec/f1/mem.bin"; ok "$L/c/r1/rec/f1/mem.bin"; ok "$L/f/f5800/m.bin"; [ -L "$L/d" ] && { echo "    × 断链没删"; F=1; }; [ -L "$L/e" ] || { echo "    × 好软链被删"; F=1; }; ok "$B/int/e"; return 0; }
c_writers() {   # 绕过准入在写（11-06）：假 lsof 列一个 2G 写开着的工作盘文件，写它的进程不在账上 → 状态页【红】点名目录与进程；账上有它的父进程 → 撤红
  mk; local A=$B/acct; mkdir -p "$A"; bg sleep 120; local P=$LAST
  printf '#!/bin/bash\necho "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"\necho "sleep %s jhz 3w REG 1,1 2147483648 1 %s/exp_x/run1/big.bin"\n' "$P" "$W" > "$B/lsofw.sh"
  S2A_DISK_DIR=$A S2A_WC_LSOF_W="bash $B/lsofw.sh" run
  grep -q '^\*\*【红】看守 绕过准入 .*exp_x/run1（sleep '"$P"'）' "$B/status.md" || { echo "    × 不在账上没报红点名"; F=1; }
  printf '{"pid": %s, "lstart": "x", "gb": 1}' $$ > "$A/use.1"; S2A_DISK_DIR=$A S2A_WC_LSOF_W="bash $B/lsofw.sh" run
  grep -q '绕过准入' "$B/status.md" && { echo "    × 祖先在账上仍报红"; F=1; }; return 0; }
c_tianyan() {   # 天眼死工位回收（11-06）：每轮调 tianyan_lane.py sweep（替身），它打的「[天眼回收]」行进清理器日志；替身失败 → 记黄、本轮照常收尾
  mk; printf '#!/usr/bin/env python3\nimport os\nprint("[天眼回收] 证据根 " + os.environ.get("S2A_EVIDENCE_DIR", "无"))\nprint("[天眼回收] 删了 1 个工位")\n' > "$B/tl_ok.py"
  printf '#!/usr/bin/env python3\nimport sys\nprint("ssh 连不上")\nsys.exit(3)\n' > "$B/tl_bad.py"
  S2A_WC_TIANYAN_LANE=$B/tl_ok.py run
  grep -q '\[天眼回收\] 删了 1 个工位' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 回收行没进日志"; F=1; }
  grep -q "\[天眼回收\] 证据根 $W/evidence" "$B/g/ops_bg/work_cleaner.log" || { echo "    × 证据根没指到工作盘 evidence/"; F=1; }
  S2A_WC_TIANYAN_LANE=$B/tl_bad.py run
  grep -q '【黄】天眼回收 rc=3：ssh 连不上' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 替身失败没记黄"; F=1; }
  grep -q '本轮 候选' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 本轮没收尾"; F=1; }; return 0; }
c_idle_glob() {   # 左边写通配（11-06：exp_*、ns2_zelda/dev*_job）：两个 exp_ 目录、一个 dev*_job 目录下各有旧条目 → 都删；不匹配通配的 other/ 旧条目不碰
  mk; local x; echo "WORK_IDLE_DIRS=\"$W/exp_*=6 $W/ns2/dev*_job=6\"" >> "$B/layout.env"
  for x in exp_a/r1 exp_b/r2 ns2/dev3_job/out_1 other/r3; do blob "$W/$x/f" 2; done; old "$W" 600
  run
  gone "$W/exp_a/r1"; gone "$W/exp_b/r2"; gone "$W/ns2/dev3_job/out_1"; ok "$W/other/r3/f"; ok "$W/exp_a"; return 0; }
c_gc_stale() {   # 本机 gc 过期报红（11-05：内置盘 gc 10-30 后 6 天没跑没人知道）：时间戳 3 小时前 → 状态页顶部【红】看守 本机gc过期；刚跑完 → 红行撤掉
  mk; echo $(( $(date +%s) - 10800 )) > "$B/gc_done"; run
  grep -q '^\*\*【红】看守 本机gc过期 ' "$B/status.md" || { echo "    × 3 小时没跑没报红"; F=1; }
  date +%s > "$B/gc_done"; run
  grep -q '本机gc过期' "$B/status.md" && { echo "    × 跑过了红行没撤"; F=1; }; return 0; }
c_root_tmp() {   # 产物根半成品（11-05 18:0x：ns2_zelda/*/roots 下 5 个出包中途失败留下的 <款>@<键>.tmp 共约 130G 没人管，保底删完仍 172 < 220）：
  #   不进上限表、不分线：.root_pid 进程已死且 300 分钟没动 → 删；.root_pid 进程活着 → 留；刚动过 → 留；不带 .tmp 的正式根 → 不碰；第 4 层的半成品也删
  mk; local L=$W/l9/roots; sleep 30 & local lp=$!
  blob "$L/g@k1.tmp/f" 5; echo 999999 > "$L/g@k1.tmp/.root_pid"; old "$L/g@k1.tmp" 300
  blob "$L/g@k2.tmp/f" 5; echo "$lp $(ps -o lstart= -p "$lp")" > "$L/g@k2.tmp/.root_pid"; old "$L/g@k2.tmp" 300
  blob "$L/g@k3.tmp/f" 5
  blob "$L/g@k4/f" 5; old "$L/g@k4" 300
  blob "$W/a/b/roots/g@k5.tmp/f" 5; old "$W/a/b/roots/g@k5.tmp" 300
  mk2; run; kill "$lp" 2> /dev/null; wait "$lp" 2> /dev/null
  gone "$L/g@k1.tmp"; ok "$L/g@k2.tmp"; ok "$L/g@k3.tmp"; ok "$L/g@k4"; gone "$W/a/b/roots/g@k5.tmp"; return 0; }
c_pin_scope() {   # 按程序号钉只管解包 / 产物根 / 直连缓存（11-05 13:3x：winline_power 下以钉住款程序号命名的做完包 32G 永远删不掉）：
  #   线目录 L 上限 150，条目 ${ID1}（钉住表里的程序号）与 x 各约 100、都旧 → ${ID1} 照删（最旧）；同号的直连缓存仍留（钉住表原意）
  mk; local L=$W/winx X1=$W/cache/direct; blob "$L/$ID1/f" 100; blob "$L/x/f" 100; old "$L/$ID1" 500; old "$L/x" 300
  blob "$X1/$ID1/store/a.e" 10; old "$X1/$ID1" 500; echo "$ID1" > "$W/pins"
  MISCV="$L=150"; mk2; run; unset MISCV
  gone "$L/$ID1"; ok "$L/x"; ok "$X1/$ID1"; }
c_no_misc_lru() {   # 没写上限的线目录不按最久没用删（11-05 总指挥 / jhz「根修删除规则」：出好待上机的产物根被余量目标删掉两次）：
  #   盘低于保底、WORK_FREE_TARGET_GB 还写着 2000（旧表，高于剩余）、线目录 L1 没写上限 → 条目一个不删
  mk; L1=$W/l1; blob "$L1/x/f" 100; blob "$L1/z/f" 100; old "$L1/x" 300; old "$L1/z" 300
  MISCV="$L1"; FT=2000; mk2; FLOOR=1000; mk_floor; run; unset MISCV FT FLOOR
  ok "$L1/x"; ok "$L1/z"; return 0; }
c_evidence() {   # 证据归档（11-04）：各线目录条目删前，日志 / 读数 / 截图拷进 WORK_EVIDENCE_DIR（保留相对路径、内容一致），二进制与 romfs 下的不拷；条目照删
  mk; L1=$W/l1; E=$B/ev; export WORK_EVIDENCE_DIR=$E; local x=$L1/out_1104121251
  mkdir -p "$x/r/logs" "$x/romfs"; echo "host log 行" > "$x/r/logs/host.log"; printf 'a\tb\n' > "$x/frames.tsv"; blob "$x/shot.png" 3; blob "$x/big.bin" 100; echo '{}' > "$x/romfs/a.json"
  old "$x" 300; MISCV="$L1=1"; mk2; run; unset MISCV WORK_EVIDENCE_DIR
  local a; a=$(ls -d "$E"/*/l1/out_1104121251 2> /dev/null | head -1)
  gone "$x"; [ -n "$a" ] || { echo "    × 没有归档目录"; F=1; return 0; }
  cmp -s "$a/r/logs/host.log" <(echo "host log 行") || { echo "    × host.log 没归档或内容不对"; F=1; }
  [ -f "$a/frames.tsv" ] && [ -f "$a/shot.png" ] || { echo "    × 读数 / 截图没归档"; F=1; }
  [ -e "$a/big.bin" ] && { echo "    × 二进制不该归档"; F=1; }; [ -e "$a/romfs/a.json" ] && { echo "    × romfs 下不该归档"; F=1; }; return 0; }
c_ctx_retry() {   # 偶发取不到进程当前目录（负载高时 lsof 取空）：首次取空、第二次正常 → 重试后照常删，不再整轮不动手（11-04 c_evidence 偶发红）
  mk; L1=$W/l1; blob "$L1/x/f" 100; old "$L1/x" 300; MISCV="$L1=1"; mk2
  printf '#!/bin/bash\nf=%s/lsof_n; n=$(cat "$f" 2> /dev/null || echo 0); echo $((n + 1)) > "$f"; [ "$n" = 0 ] && exit 1; echo n/\n' "$B" > "$B/lsof_flaky.sh"
  S2A_WC_LSOF="bash $B/lsof_flaky.sh" run; unset MISCV; gone "$L1/x"; return 0; }
c_beat() {   # 长轮心跳：WORK_BEAT_S=0 时每删一项都写一行「本轮进行中」到看守日志（看守按日志更新时间判卡住）
  UCAP=1; mk; U=$W/cache/unpack; ucache "$ID3-01" 100; ucache "$ID3-02" 100; old "$U/$ID3-01" 300; old "$U/$ID3-02" 200
  WORK_BEAT_S=0 run; unset UCAP; grep -q "本轮进行中：已删 1 项" "$B/g/ops_bg/guard_work_cleaner.log" || { echo "    × 没写心跳"; F=1; }; return 0; }
c_roots_ref() {   # 产物根在用：调度 refs、.pin 活钉、.tmp 持有者活着、进程环境提到、packq 同款共享根单 → 都不删
  mk; R=$W/roots; for v in c1 ex-ref ex-pin ex-ps ex-tmp.tmp; do mkdir -p "$R/g2@$v"; done; ln -s g2@c1 "$R/g2@现行"
  mkdir -p "$R/g3@c1" "$R/g3@ex-1"; ln -s g3@c1 "$R/g3@现行"
  echo "/x/roots/g2@ex-ref/pack" > "$B/sd/refs.txt"
  bg sleep 120; echo "$LAST $(ps -o lstart= -p "$LAST")" > "$R/.pin.g2@ex-pin.$LAST"
  bg sleep 120; echo "$LAST $(ps -o lstart= -p "$LAST")" > "$R/g2@ex-tmp.tmp/.root_pid"
  WCT_USE="$R/g2@ex-ps/rom" hold   # 只在环境里提到
  printf '{"id":"j1","game":"g3","roots":"shared"}\n' > "$B/pq/run/j1.json"
  old "$R"; run
  for v in ex-ref ex-pin ex-ps ex-tmp.tmp; do ok "$R/g2@$v"; done; ok "$R/g3@ex-1"; }
c_roots_unk() {   # 调度 refs 取不到 → 产物根一个不删
  mk; R=$W/roots; mkdir -p "$R/g1@c2" "$R/g1@ex-1"; ln -s g1@c2 "$R/g1@现行"; old "$R"; SCHED=$B/sched_bad.sh; run
  ok "$R/g1@ex-1"; grep -q '核不了' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写「核不了」"; F=1; }; }
c_jobs() {   # 局 work：已判只留 r/logs；未判、running、.留证、有进程当前目录在里面的不动
  mk; C=$W/census/c1; tsv "$C/总表.tsv" K1:通过 K2:未判 K3:失败 K4:通过 K5:通过 K6:通过; mkdir -p "$C/running"; touch "$C/running/K3"
  for k in K1 K2 K3 K4 K5 K6; do blob "$C/work/$k/a.bin" 4; blob "$C/work/$k/r/结果.tsv" 1; blob "$C/work/$k/r/logs/x.log" 1; done; touch "$C/work/K4/.留证"
  echo "CENSUS_KEEP_KEYS 能耗线复现" > "$C/work/K6/.保留"   # 11-06：普查点名保留的款（包与产物根）不能被删成只剩 r/logs
  : > "$C/work/K1/.tmp_x"; : > "$C/work/K1/r/.part"; ln -s /nonexist "$C/work/K1/dead"   # 点文件、断链也要删（11-04 补：原用例没有，负控去掉 .[!.]* / -L 照样绿）
  old "$C"; bg sh -c "cd '$C/work/K5' && exec sleep 120"; livebatch "$C"; sleep 0.3   # 批次在跑（11-06 起收批后的批另有规则，见 c_jobs_closed）
  #   删除换成不设防的 rm（只测清理器自己的判断）：safe_rm 也拒删 r/、r/logs，会替清理器挡住「留 r/logs」被改坏（11-04 负控 c_jobs 绿着失效的根因）
  printf '#!/bin/bash\nrm -rf -- "$1"\n' > "$B/rm_plain.sh"; local RMS=$B/rm_plain.sh; run
  ok "$C/work/K1/r/logs/x.log"; gone "$C/work/K1/a.bin"; gone "$C/work/K1/r/结果.tsv"; gone "$C/work/K1/.tmp_x"; gone "$C/work/K1/r/.part"
  [ -L "$C/work/K1/dead" ] && { echo "    × 断链没删"; F=1; }
  for k in K2 K3 K4 K5 K6; do ok "$C/work/$k/a.bin"; done; }
c_jobs_closed() {   # 收批后（11-06 总指挥清盘复盘：中途停 / 重起留下的「未判」款 work/*/p 一直留着）：批次没有 census.sh 在跑 →
  #   未判款也只留 r/logs；running 里的款不动；.保留 不动；.留证 在批次最后改动（批次.log）不到 48 小时不动、满 48 小时照删。
  #   负对照：同样的未判款放在在跑批（c_jobs 的 K2）不动
  mk; C=$W/census/c7; D=$W/census/c8; tsv "$C/总表.tsv" K1:未判; tsv "$D/总表.tsv" K1:未判; mkdir -p "$C/running"; touch "$C/running/K3"
  for k in K1 K2 K3 K4 K6; do blob "$C/work/$k/a.bin" 4; blob "$C/work/$k/r/logs/x.log" 1; done; blob "$D/work/K7/a.bin" 4; blob "$D/work/K7/r/logs/x.log" 1
  touch "$C/work/K4/.留证" "$D/work/K7/.留证"; echo 点名留包 > "$C/work/K6/.保留"; echo x > "$C/批次.log"; echo x > "$D/批次.log"
  old "$C/work"; old "$D"; touch -t "$(date -v-50H +%Y%m%d%H%M)" "$D/批次.log"
  printf '#!/bin/bash\nrm -rf -- "$1"\n' > "$B/rm_plain.sh"; local RMS=$B/rm_plain.sh; run
  gone "$C/work/K1/a.bin"; gone "$C/work/K2/a.bin"; ok "$C/work/K1/r/logs/x.log"; ok "$C/work/K3/a.bin"; ok "$C/work/K4/a.bin"; ok "$C/work/K6/a.bin"
  gone "$D/work/K7/a.bin"; ok "$D/work/K7/r/logs/x.log"; }
c_unreg() {   # 没登记的顶层目录（11-06 清盘复盘：33 个实验目录不在任何规则里）：WORK 下 zz_old 闲置 80 小时 → 整条删；zz_new 1 小时前动过 → 留；
  #   keepme（WORK_UNREG_KEEP 点名）80 小时 → 留；zz_pin 80 小时但钉住表写了原因 → 留；census / roots 等已知区不归这条（里面的旧文件不被整删）
  mk; for d in zz_old zz_new keepme zz_pin; do blob "$W/$d/f.bin" 4; done; blob "$W/census/oldlog.txt" 1
  old "$W/zz_old" 4800; old "$W/keepme" 4800; old "$W/zz_pin" 4800; old "$W/census" 4800; old "$W/zz_new" 60
  printf '%s\t实验长留（单测）\n' "$W/zz_pin" > "$W/pins"
  WORK_UNREG_KEEP=keepme run
  gone "$W/zz_old"; ok "$W/zz_new/f.bin"; ok "$W/keepme/f.bin"; ok "$W/zz_pin/f.bin"; ok "$W/census/oldlog.txt"; }
c_jobs_skip() {   # 跳过表：WORK_JOBS_SKIP 里的批次（c9）已判款也不动；同盘别的批次（c1）照删
  mk; for b in c1 c9; do tsv "$W/census/$b/总表.tsv" K1:通过; blob "$W/census/$b/work/K1/a.bin" 4; blob "$W/census/$b/work/K1/r/logs/x.log" 1; done
  echo 'WORK_JOBS_SKIP="c8 c9"' >> "$B/layout.env"; old "$W/census"; run
  gone "$W/census/c1/work/K1/a.bin"; ok "$W/census/c9/work/K1/a.bin"; }
c_unpack_judged() {   # 解包缓存：已判删（连 .size）；待跑（running）/ .keep / 未判 / 30 分钟内动过 不删
  mk; U=$W/cache/unpack; C=$W/census/c1; tsv "$C/总表.tsv" "$ID1:通过" "$ID2:失败" "$ID4:通过" "$ID5:通过"; mkdir -p "$C/running"; touch "$C/running/$ID2"; livebatch "$C"
  ucache "$ID1-aa"; ucache "$ID2-aa"; ucache "$ID3-aa"; ucache "$ID4-aa"; ucache "$ID5-aa"; keepq "$ID4"
  old "$U/$ID1-aa"; old "$U/$ID2-aa"; old "$U/$ID3-aa"; old "$U/$ID4-aa"; run
  gone "$U/$ID1-aa"; gone "$U/$ID1-aa.size"; ok "$U/$ID2-aa"; ok "$U/$ID3-aa"; ok "$U/$ID4-aa"; ok "$U/$ID5-aa"; }
c_unpack_cap() {   # 解包缓存上限 LRU：合计 400 > 上限 300，删最久没用的一份；最旧那份进程在用 → 跳过、删次旧
  UCAP=300; mk; U=$W/cache/unpack; for i in 1 2 3 4; do ucache "$ID3-0$i" 100; done
  old "$U/$ID3-01" 400; old "$U/$ID3-02" 300; old "$U/$ID3-03" 200; old "$U/$ID3-04" 100
  hold "x/unpack/$ID3-01"; run; unset UCAP   # 持有者只在命令行里提到条目名
  ok "$U/$ID3-01"; gone "$U/$ID3-02"; ok "$U/$ID3-03"; ok "$U/$ID3-04"; }
c_xlate_cap() {   # 翻译缓存上限 LRU（两个目录共用一个上限）：最旧那款有活的 work.stage.<pid> → 留，删次旧；回到上限内即停
  XCAP=450; mk; X1=$W/cache/direct; X2=$W/census_dcache
  blob "$X1/$ID1/store/a.e" 200; blob "$X2/$ID2/store/a.e" 200; blob "$X1/$ID3/store/a.e" 200
  bg sleep 120; touch "$X1/$ID1/work.stage.$LAST"
  old "$X1/$ID1" 300; old "$X2/$ID2" 200; old "$X1/$ID3" 100; run; unset XCAP
  ok "$X1/$ID1"; gone "$X2/$ID2"; ok "$X1/$ID3"; }
c_pin() {   # WORK_PINS 里的程序号：超上限也不删
  XCAP=250; mk; X1=$W/cache/direct; blob "$X1/$ID1/store/a.e" 200; blob "$X1/$ID2/store/a.e" 200; old "$X1/$ID1" 300; old "$X1/$ID2" 100
  echo "$ID1" > "$W/pins"; run; unset XCAP; ok "$X1/$ID1"; gone "$X1/$ID2"; }
c_pin_sub() {   # 钉住表钉的是条目下的子路径（11-06 frame_rec/t040074a01bf12000/f5800 被按父目录删）：超上限也不整删父条目；负对照：没钉的同类旧条目照删
  XCAP=250; mk; X1=$W/cache/direct; blob "$X1/$ID1/store/a.e" 200; blob "$X1/$ID2/store/a.e" 200; old "$X1/$ID1" 300; old "$X1/$ID2" 100
  echo "$X1/$ID1/store" > "$W/pins"; run; unset XCAP; ok "$X1/$ID1/store/a.e"; gone "$X1/$ID2"; }
c_floor() {   # 保底：上限都没超，但工作盘剩余 < 保底 → 先删解包缓存最久没用的，回到保底即停；翻译缓存不动
  mk; U=$W/cache/unpack; X1=$W/cache/direct; for i in 1 2 3; do ucache "$ID3-0$i" 100 100; done; blob "$X1/$ID1/store/a.e" 100
  old "$U/$ID3-01" 400; old "$U/$ID3-02" 300; old "$U/$ID3-03" 200; old "$X1/$ID1" 500
  FLOOR=1000; mk_floor; WORK_FLOOR_MARGIN_GB=0 run; unset FLOOR
  gone "$U/$ID3-01"; gone "$U/$ID3-02"; ok "$U/$ID3-03"; ok "$X1/$ID1"
  a=$(( TOTAL - $(du -sk "$W" | cut -f1) )); [ $a -ge 1000 ] || { echo "    × 删完剩 ${a}，没回到保底 1000"; F=1; }; }
mk_floor() { sed -i '' "s/^WORK_FLOOR_GB=.*/WORK_FLOOR_GB=$FLOOR/" "$B/layout.env"; TOTAL=$(( $(du -sk "$W" | cut -f1) + FLOOR - 150 )); }   # 剩余 = 保底 - 150：删 1 份（约 104）不够、删 2 份够
c_floor_tick() {   # 两轮之间的保底快查（11-04 23:1x）：首轮余量够、不删；轮后写入把余量压到保底以下 → 不等下一轮（间隔 300 秒），几秒内删最久没用的一份、回到保底即停
  mk; U=$W/cache/unpack; ucache "$ID3-01" 100 100; ucache "$ID3-02" 100 100; old "$U/$ID3-01" 400; old "$U/$ID3-02" 300
  FLOOR=1000; mk_floor; unset FLOOR; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1100 ))
  env S2A_LAYOUT_ENV="$B/layout.env" S2A_WC_UNIT_KB=1 GUARD_DIR="$B/g" GUARD_STATUS="$B/status.md" S2A_WC_RM="$RMS" S2A_SAFE_RM_LOG="$B/rm.log" WORK_EVIDENCE_DIR="$B/ev" \
    S2A_PACKQ_DIR="$B/pq" S2A_SCHED_DIR="$B/sd" S2A_WC_SCHED_SH="$SCHED" WCT_TOTAL="$TOTAL" WCT_W="$W" WORK_FLOOR_MARGIN_GB=0 WORK_CLEAN_INTERVAL_S=300 WORK_FLOOR_TICK_S=1 \
    S2A_WC_FREE_CMD='echo $(( WCT_TOTAL - $(du -sk "$WCT_W" | cut -f1) ))' bash "$WC" > "$B/out.txt" 2>&1 & local p=$!; PIDS="$PIDS $p"
  local i; for i in $(seq 1 60); do grep -aq '本轮 候选' "$B/g/ops_bg/work_cleaner.log" 2> /dev/null && break; sleep 0.5; done
  ok "$U/$ID3-01"; blob "$W/fill/x" 200
  for i in $(seq 1 20); do [ -e "$U/$ID3-01" ] || break; sleep 0.5; done; sleep 1; kill $p 2> /dev/null; pkill -P $p 2> /dev/null
  gone "$U/$ID3-01"; ok "$U/$ID3-02"; grep -aq '保底快查：工作盘' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没有「保底快查」"; F=1; }; }
c_floor_long() {   # 主轮很慢（调度 refs 桩卡 15 秒）时，后台保底快查照样在几秒内删到保底（11-05 01:4x 长轮期间保底一次没跑）
  mk; U=$W/cache/unpack; ucache "$ID3-01" 100 100; ucache "$ID3-02" 100 100; old "$U/$ID3-01" 400; old "$U/$ID3-02" 300
  FLOOR=1000; mk_floor; unset FLOOR; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1100 ))
  printf '#!/bin/bash\ntouch %s/sched_in\nsleep 15\n[ "$1" = refs ] && cat "$S2A_SCHED_DIR/refs.txt" 2> /dev/null; exit 0\n' "$B" > "$B/sched_slow.sh"; chmod +x "$B/sched_slow.sh"
  : > "$B/g/ops_bg/work_cleaner.log"
  env S2A_LAYOUT_ENV="$B/layout.env" S2A_WC_UNIT_KB=1 GUARD_DIR="$B/g" GUARD_STATUS="$B/status.md" S2A_WC_RM="$RMS" S2A_SAFE_RM_LOG="$B/rm.log" WORK_EVIDENCE_DIR="$B/ev" \
    S2A_PACKQ_DIR="$B/pq" S2A_SCHED_DIR="$B/sd" S2A_WC_SCHED_SH="$B/sched_slow.sh" WCT_TOTAL="$TOTAL" WCT_W="$W" WORK_FLOOR_MARGIN_GB=0 WORK_CLEAN_INTERVAL_S=300 WORK_FLOOR_TICK_S=1 \
    S2A_WC_FREE_CMD='echo $(( WCT_TOTAL - $(du -sk "$WCT_W" | cut -f1) ))' bash "$WC" > "$B/out.txt" 2>&1 & local p=$!; PIDS="$PIDS $p"
  # 等主轮确实卡进调度桩（桩开头 touch sched_in）再写满，不按固定秒数（11-07 守望：mini 负载高、主轮开头的上下文变慢，固定 2 秒时主轮还没卡住就看到写满、
  #   自己删到保底，负控「关掉后台快查」也绿 → 没测住）。卡住之后只有后台快查能删
  local w; for w in $(seq 1 100); do [ -e "$B/sched_in" ] && break; sleep 0.1; done
  ok "$U/$ID3-01"; blob "$W/fill/x" 200   # 开头余量够（主轮开头不删）；主轮卡在调度桩里时写入把余量压到保底下
  local i; for i in $(seq 1 16); do { [ -e "$U/$ID3-01" ] && [ -e "$U/$ID3-02" ]; } || break; sleep 0.5; done
  local rd; rd=$(grep -ac '本轮 候选' "$B/g/ops_bg/work_cleaner.log"); kill $p 2> /dev/null; sleep 0.3; pkill -P $p 2> /dev/null
  # 判「后台快查在长轮期间删到保底」：两份解包至少删掉一份、日志有保底快查行（不钉死删哪份：全套跑时 -01 的目录修改时刻偶尔被前面的步骤刷新，
  #   保底按最久没用挑到 -02 也是对的）
  { [ ! -e "$U/$ID3-01" ] || [ ! -e "$U/$ID3-02" ]; } || { echo "    × 长轮期间后台快查没删到保底（两份解包都还在）"; F=1; }
  grep -q '保底快查：工作盘 .* → ' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没有保底快查行"; F=1; }
  [ "$rd" = 0 ] || { echo "    × 主轮已结束（${rd} 轮），没测到「长轮期间」"; F=1; }
  sleep 1.5; pgrep -f "$B/layout.env" > /dev/null && { echo "    × 主进程收掉后后台快查还活着"; F=1; }; return 0; }
c_redact() {   # 进程表落盘前遮掉口令类环境变量的值（11-05：ps -E 记下了明文 GH_TOKEN）；路径类照留，目录权限 700
  mk; bg env GH_TOKEN=ghp_wctSECRETvalue123 MY_API_KEY=k9secret "$PYH" -c 'import time; time.sleep(120)' "$W/cache/unpack/x"; sleep 0.5; run
  local f=$B/g/ops_bg/.work_cleaner.d/ps.txt
  grep -aq 'GH_TOKEN=<已遮>' "$f" || { echo "    × 进程表里没有遮掉的 GH_TOKEN"; F=1; }
  grep -aq 'ghp_wctSECRETvalue123\|k9secret' "$f" && { echo "    × 进程表里还有明文口令"; F=1; }
  grep -aqF "$W/cache/unpack/x" "$f" || { echo "    × 路径参数被误遮"; F=1; }
  [ "$(stat -f %Lp "$B/g/ops_bg/.work_cleaner.d")" = 700 ] || { echo "    × 目录权限不是 700"; F=1; }; }
c_ps_unk() {   # 进程表取不到 → 本轮一个都不删（已判的解包缓存也不删）
  mk; U=$W/cache/unpack; tsv "$W/census/c1/总表.tsv" "$ID1:通过"; ucache "$ID1-aa"; old "$U/$ID1-aa"; PSX=false; run; unset PSX
  ok "$U/$ID1-aa"; grep -q '核不了，本轮一个都不删' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写「核不了，本轮一个都不删」"; F=1; }; }
c_single() {   # 单实例：同名看守活着 → 退出码 4，不删
  mk; U=$W/cache/unpack; tsv "$W/census/c1/总表.tsv" "$ID1:通过"; ucache "$ID1-aa"; old "$U/$ID1-aa"
  bg sleep 120; echo "$LAST" > "$B/g/locks/guard_work_cleaner.pid"; run; rc=$?
  [ $rc = 4 ] || { echo "    × 退出码 ${rc}，应为 4"; F=1; }; ok "$U/$ID1-aa"; }
c_idle_red() {   # 空转报红：核不了连续 2 轮不红、第 3 轮运维线.md 顶部出【红】；恢复处理后撤红
  mk; U=$W/cache/unpack; tsv "$W/census/c1/总表.tsv" "$ID1:通过"; ucache "$ID1-aa"; old "$U/$ID1-aa"; PSX=false
  run --n 2; grep -q '【红】看守 work_cleaner 空转' "$B/status.md" && { echo "    × 2 轮就红了"; F=1; }
  run; unset PSX; head -1 "$B/status.md" | grep -q '^\*\*【红】看守 work_cleaner 空转' || { echo "    × 3 轮没报红：$(head -1 "$B/status.md")"; F=1; }
  run; grep -q '【红】看守 work_cleaner' "$B/status.md" && { echo "    × 恢复处理后没撤红"; F=1; }; gone "$U/$ID1-aa"; }
c_floor_red() {   # 保底删不动（待跑款的解包且有进程在用）连续 3 轮 → 报红
  mk; U=$W/cache/unpack; ucache "$ID3-01" 100 100; keepq "$ID3"; old "$U/$ID3-01"; hold "$U/$ID3-01"; FLOOR=1000; mk_floor; run --n 3; unset FLOOR
  ok "$U/$ID3-01"; grep -q '【红】看守 work_cleaner 空转' "$B/status.md" || { echo "    × 保底删不动 3 轮没报红"; F=1; }; }
c_no_layout() {   # 上限表不在 → 退出码 2
  mk; rm -f "$B/layout.env"; run; rc=$?; [ $rc = 2 ] || { echo "    × 退出码 ${rc}，应为 2"; F=1; }; }
c_dry() {   # --dry 只列不删
  mk; U=$W/cache/unpack; tsv "$W/census/c1/总表.tsv" "$ID1:通过"; ucache "$ID1-aa"; old "$U/$ID1-aa"; run --dry
  ok "$U/$ID1-aa"; grep -q "会删 .*$ID1-aa" "$B/out.txt" || { echo "    × --dry 没列出会删"; F=1; }; }
c_family() {   # 保底第 ③ 类按款整族删：已判、不在待跑 / .keep 的款按 LRU 整族删（产物根 + @现行 + bake / aoc），够了就停；直连缓存不在族里
  #   ID1（最旧）产物根 / bake / aoc 都删、直连缓存留；ID4（较新，删完 ID1 已达标）留；ID2 产物根被进程提到 → 整款留；ID3 在 .keep → 留；ID5 没判 → 留
  mk; R=$W/roots; U=$W/cache/unpack; local id n
  tsv "$W/census/b1/总表.tsv" "$ID1:通过" "$ID2:通过" "$ID3:通过" "$ID4:通过"
  for id in $ID1 $ID2 $ID3 $ID4 $ID5; do n=t$(echo "$id" | tr A-F a-f); blob "$R/$n@c1/f" 100; ln -s "$n@c1" "$R/$n@现行"
    blob "$W/cache/bake/${n#t}-x/f" 20; blob "$W/cache/aoc/$n-k/aoc.tsv" 20; blob "$W/cache/direct/$id/f" 20; done
  keepq "$ID3"; old "$W" 900; old "$R/t$(echo $ID1 | tr A-F a-f)@c1" 1200
  hold "$R/t$(echo $ID2 | tr A-F a-f)@c1"
  sed -i '' "s/^WORK_FLOOR_GB=.*/WORK_FLOOR_GB=1000/" "$B/layout.env"; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1000 - 100 )); WORK_FLOOR_MARGIN_GB=0 run
  local l1 l4; l1=t$(echo $ID1 | tr A-F a-f); l4=t$(echo $ID4 | tr A-F a-f)
  gone "$R/$l1@c1"; [ -L "$R/$l1@现行" ] && { echo "    × ID1 现行链接没删"; F=1; }
  gone "$W/cache/bake/${l1#t}-x"; gone "$W/cache/aoc/$l1-k"; ok "$W/cache/direct/$ID1"; ok "$W/cache/bake/${l4#t}-x"; ok "$W/cache/aoc/$l4-k"
  ok "$R/$l4@c1"; ok "$R/t$(echo $ID2 | tr A-F a-f)@c1"; ok "$R/t$(echo $ID3 | tr A-F a-f)@c1"; ok "$R/t$(echo $ID5 | tr A-F a-f)@c1"
  grep -raq "整族删 ${ID1}（已判、不在待跑，工作盘低于保底" "$B" || { echo "    × 日志没有「整族删 ${ID1}」"; F=1; }; }
c_floor_order() {   # 保底按重建代价（11-05）：解包删够了就不碰直连缓存，也不动整族；ID3 解包（未判、最旧）、ID1 解包（已判）删，ID1 产物根 / 直连、ID6 直连都留
  mk; R=$W/roots; U=$W/cache/unpack; X1=$W/cache/direct; local l1; l1=t$(echo $ID1 | tr A-F a-f)
  tsv "$W/census/b1/总表.tsv" "$ID1:通过"
  ucache "$ID3-01" 100 100; blob "$U/$ID1-aa/romfs.bin" 100; blob "$R/$l1@c1/f" 100; blob "$X1/$ID1/f" 100; blob "$X1/0100000000000A06/f" 100
  old "$W" 900; old "$X1" 2000; old "$U/$ID3-01" 1500; old "$U/$ID1-aa" 1400
  FLOOR=1000; mk_floor; WORK_FLOOR_MARGIN_GB=0 run; unset FLOOR
  gone "$U/$ID3-01"; gone "$U/$ID1-aa"; ok "$X1/$ID1"; ok "$X1/0100000000000A06"; ok "$R/$l1@c1"; }
c_floor_pend() {   # 保底第 ③b 类（11-05 09:5x：钉住表 + .keep 把 166G 解包保在上限 120 之上，保底删完前三类仍低于底线）：
  #   ID3 在 .keep、ID1 在钉住表，解包都没人用 → 删（各 100，剩余 = 保底 - 150，删两份够）；ID4 在 .keep 但有进程提到 → 留；ID6 直连缓存 → 不动
  mk; U=$W/cache/unpack; X1=$W/cache/direct
  ucache "$ID3-01" 100 100; ucache "$ID1-aa" 100 100; ucache "$ID4-bb" 100 100; blob "$X1/0100000000000A06/f" 100
  keepq "$ID3" "$ID4"; echo "$ID1" > "$W/pins"; old "$W" 900; old "$X1" 2000; hold "$U/$ID4-bb"
  FLOOR=1000; mk_floor; WORK_FLOOR_MARGIN_GB=0 run; unset FLOOR
  gone "$U/$ID3-01"; gone "$U/$ID1-aa"; ok "$U/$ID4-bb"; ok "$X1/0100000000000A06"
  grep -raq "保底（待跑或钉住款解包）：$ID3-01" "$B" || { echo "    × ID3（.keep 款）的解包不是在 ③b 删的（前面的类没认待跑）"; F=1; }; }
c_pqx_cap() {   # packq 抽取上限（11-05：6 条因调度 refs 里有同名款被各线目录规则保住，381G / 40 删不动）：上限 150、三条各 100；
  #   最旧 a 的款名出现在调度 refs 里但没进程在用 → 照删；次旧 b 被进程命令行提到 → 留；删 a 后 200 仍超 → 删 c… c 是最新、30 分钟内动过 → 留（记黄）
  mk; P=$W/cache/packq_extract; blob "$P/t0100000000000a07/f" 100; blob "$P/t0100000000000a08/f" 100; blob "$P/t0100000000000a09/f" 100
  old "$P/t0100000000000a07" 500; old "$P/t0100000000000a08" 400; old "$P/t0100000000000a09" 10; echo "t0100000000000a07 排队中" > "$B/sd/refs.txt"
  hold "x/packq_extract/t0100000000000a08"; echo "WORK_PQX_CAP_GB=150" >> "$B/layout.env"; run
  gone "$P/t0100000000000a07"; ok "$P/t0100000000000a08"; ok "$P/t0100000000000a09"; }
c_floor_pqx() {   # 保底第 ⓪ 类：packq 播种抽取中间目录（11-05 382G 无规则）先于解包和直连删；在用的留：
  #   p1、p2 旧抽取（未判款）、p3 被进程命令行提到；ID3 解包（未判、旧）；直连 ID1；需腾约 150 → 删 p1、p2，p3 / 解包 / 直连都留
  mk; P=$W/cache/packq_extract; U=$W/cache/unpack; X1=$W/cache/direct
  blob "$P/t0100000000000a07/exefs/main" 100; blob "$P/nx_unpack_ncz_1_ab.nca" 100; blob "$P/t0100000000000a08/exefs/main" 100; ucache "$ID3-01" 100 100; blob "$X1/$ID1/f" 100
  old "$W" 900; old "$P/t0100000000000a07" 1500; old "$P/nx_unpack_ncz_1_ab.nca" 1400; old "$P/t0100000000000a08" 1300; old "$U/$ID3-01" 1200; old "$X1" 2000
  hold "x/packq_extract/t0100000000000a08"
  sed -i '' "s/^WORK_FLOOR_GB=.*/WORK_FLOOR_GB=1000/" "$B/layout.env"; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1000 - 150 )); WORK_FLOOR_MARGIN_GB=0 run
  gone "$P/t0100000000000a07"; gone "$P/nx_unpack_ncz_1_ab.nca"; ok "$P/t0100000000000a08"; ok "$U/$ID3-01"; ok "$X1/$ID1"; }
c_pqx_run() {   # packq 在出单的款，抽取目录不删（11-06 旷野之息单自己重抽后推远端刷新 20 分钟、本机没进程提到抽取目录，保底删掉，拉回后 uilayout 回读原版报红）：
  #   a07 / a08 都旧、没进程提到；packq run/ 有 a08 的单 → 保底需腾约 150：删 a07，a08 留；另一轮上限 50：a07 删、a08 留（记黄）
  mk; P=$W/cache/packq_extract; blob "$P/t0100000000000a07/exefs/main" 100; blob "$P/t0100000000000a08/exefs/main" 100
  old "$W" 900; old "$P/t0100000000000a07" 1500; old "$P/t0100000000000a08" 1600; printf '{"id":"q8","game":"t0100000000000a08","roots":"shared"}\n' > "$B/pq/run/q8.json"
  sed -i '' "s/^WORK_FLOOR_GB=.*/WORK_FLOOR_GB=1000/" "$B/layout.env"; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1000 - 150 )); WORK_FLOOR_MARGIN_GB=0 run
  gone "$P/t0100000000000a07"; ok "$P/t0100000000000a08"
  mk; P=$W/cache/packq_extract; blob "$P/t0100000000000a07/f" 100; blob "$P/t0100000000000a08/f" 100; old "$P/t0100000000000a07" 500; old "$P/t0100000000000a08" 600
  printf '{"id":"q8","game":"t0100000000000a08","roots":"priv:x"}\n' > "$B/pq/run/q8.json"; echo "WORK_PQX_CAP_GB=50" >> "$B/layout.env"; run
  gone "$P/t0100000000000a07"; ok "$P/t0100000000000a08"
  # ③ 私有根指定原件的抽取目录 <款>@<私有根名>（11-06 packq submit --src）：run/ 有 a08 的单 → a08@v143 留；没单的 a07@v1 删
  mk; P=$W/cache/packq_extract; blob "$P/t0100000000000a07@v1/f" 100; blob "$P/t0100000000000a08@v143/f" 100; old "$P/t0100000000000a07@v1" 500; old "$P/t0100000000000a08@v143" 600
  printf '{"id":"q8","game":"t0100000000000a08","roots":"priv:v143"}\n' > "$B/pq/run/q8.json"; echo "WORK_PQX_CAP_GB=50" >> "$B/layout.env"; run
  gone "$P/t0100000000000a07@v1"; ok "$P/t0100000000000a08@v143"; }
c_pq_unreadable() {   # packq run/ 读不了（11-06 #58 moongrant：glob 遇到读不了的目录返回空列表、不报错，「读不了就不删」被绕过）：
  #   ① 抽取上限 50、a07 / a08 各 100、都旧、没进程提到；run/ 权限 000 → 两条都留（日志写 run/ 读不了）
  #   ② 产物根：g1 现行 c2、中间版本 ex-1 旧（平常会删）；run/ 权限 000 → ex-1 留、日志写「核不了」
  mk; P=$W/cache/packq_extract; blob "$P/t0100000000000a07/f" 100; blob "$P/t0100000000000a08/f" 100; old "$P/t0100000000000a07" 500; old "$P/t0100000000000a08" 600
  echo "WORK_PQX_CAP_GB=50" >> "$B/layout.env"; chmod 000 "$B/pq/run"; run; chmod 755 "$B/pq/run"
  ok "$P/t0100000000000a07"; ok "$P/t0100000000000a08"; grep -q 'packq run/ 读不了' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写「packq run/ 读不了」"; F=1; }
  mk; R=$W/roots; mkdir -p "$R/g1@c2" "$R/g1@ex-1"; ln -s g1@c2 "$R/g1@现行"; old "$R/g1@ex-1"; old "$R/g1@c2"; chmod 000 "$B/pq/run"; run; chmod 755 "$B/pq/run"
  ok "$R/g1@ex-1"; grep -q '核不了' "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写「核不了」"; F=1; }; }
c_family_pq() {   # 整族删不动 packq 在出 / 在等的款（11-06 小小梦魇3：手测单在出时保底整族删了它刚播的根，拉回后「没有现行产物根」）：
  #   ID1 / ID4 都已判、都不在待跑、都旧；packq run/ 有 ID1 的单、req/ 有 ID4 的单（正式款名 party → titles.tsv 换程序号）→ 两款都留；
  #   run/ 读不了 → 本轮整族删一个都不做（日志写读不了）
  mk; R=$W/roots; local id n
  tsv "$W/census/b1/总表.tsv" "$ID1:通过" "$ID4:通过"
  for id in $ID1 $ID4; do n=t$(echo "$id" | tr A-F a-f); blob "$R/$n@c1/f" 100; ln -s "$n@c1" "$R/$n@现行"; done
  old "$W" 900; old "$R/t$(echo $ID1 | tr A-F a-f)@c1" 1200; old "$R/t$(echo $ID4 | tr A-F a-f)@c1" 1100
  printf '{"id":"j1","game":"t%s","roots":"shared"}\n' "$(echo $ID1 | tr A-F a-f)" > "$B/pq/run/j1.json"
  printf '# 注释\n%s\tparty\n' "$ID4" > "$B/titles.tsv"; printf '{"id":"j4","game":"party","roots":"shared"}\n' > "$B/pq/req/j4.json"
  sed -i '' "s/^WORK_FLOOR_GB=.*/WORK_FLOOR_GB=1000/" "$B/layout.env"; echo "WORK_TITLES_TSV=$B/titles.tsv" >> "$B/layout.env"
  TOTAL=$(( $(du -sk "$W" | cut -f1) + 1000 - 100 )); WORK_FLOOR_MARGIN_GB=0 run
  ok "$R/t$(echo $ID1 | tr A-F a-f)@c1"; ok "$R/t$(echo $ID4 | tr A-F a-f)@c1"
  grep -q "留款 ${ID1}（packq 有该款单在出 / 在等）" "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写 ID1 留款原因"; F=1; }
  rm -f "$B/pq/run/j1.json" "$B/pq/req/j4.json"; chmod 000 "$B/pq/run"; TOTAL=$(( $(du -sk "$W" | cut -f1) + 1000 - 100 )); WORK_FLOOR_MARGIN_GB=0 run; chmod 755 "$B/pq/run"
  ok "$R/t$(echo $ID1 | tr A-F a-f)@c1"; grep -q "整族删本轮不做：packq run/ req/ 读不了" "$B/g/ops_bg/work_cleaner.log" || { echo "    × 日志没写整族删读不了"; F=1; }; }
c_key_birth() {   # 「最新那份」按创建时间判（11-05 03:49：旧键正在被删、修改时间变「刚刚」，快查把最新键当旧键删了）：
  #   ID2 在 .keep；a 先建（500 分钟前）、b 后建（100 分钟前）；之后 a 里有文件刚被改 → 仍是 a 旧、b 新；上限 50 → a 删、b 留
  UCAP=50; mk; U=$W/cache/unpack; ucache "$ID2-a" 100 100; old "$U/$ID2-a" 500; sleep 1; ucache "$ID2-b" 100 100; old "$U/$ID2-b" 100; keepq "$ID2"
  touch -t "$(date -v-40M +%Y%m%d%H%M.%S)" "$U/$ID2-a/romfs.bin"; run; unset UCAP; gone "$U/$ID2-a"; ok "$U/$ID2-b"; }
c_pin_old_key() {   # 钉住表按程序号钉的款，解包只保最新那份（11-05：钉住表 18 款把旧版本解包整款钉住）：ID1 在钉住表，旧键 a、新键 b；上限 50 → a 删、b 留
  UCAP=50; mk; U=$W/cache/unpack; ucache "$ID1-a" 100 100; ucache "$ID1-b" 100 100; echo "$ID1" > "$W/pins"; old "$U/$ID1-a" 500; old "$U/$ID1-b" 100
  run; unset UCAP; gone "$U/$ID1-a"; ok "$U/$ID1-b"; }
c_dead_batch() {   # 死批残条不算待跑（11-05：15 个早没进程的批还挂 running / packed / hold，把解包钉住 330G / 上限 120）：
  #   b9 没有 census.sh 进程、running 里有 ID1 → ID1（已判）解包删；b8 有活进程、running 里有 ID4 → ID4（已判）解包留
  mk; U=$W/cache/unpack; tsv "$W/census/b1/总表.tsv" "$ID1:通过" "$ID4:通过"
  mkdir -p "$W/census/b9/running" "$W/census/b8/running"; touch "$W/census/b9/running/$ID1" "$W/census/b8/running/$ID4"; livebatch "$W/census/b8"
  ucache "$ID1-aa"; ucache "$ID4-aa"; old "$U/$ID1-aa"; old "$U/$ID4-aa"; run
  gone "$U/$ID1-aa"; ok "$U/$ID4-aa"; }
c_keep_stale() {   # .keep 过期条目不算待跑（11-06 06:5x 总指挥：.keep 21 款里 16 款不在任何在跑批队列里，仍整族钉住）：
  #   ID1、ID4 都已判、都在 .keep；ID4 在在跑批 bk 的队列里 → 解包留；ID1 不在任何在跑批队列里 → 解包删
  mk; U=$W/cache/unpack; tsv "$W/census/b1/总表.tsv" "$ID1:通过" "$ID4:通过"; keepq "$ID4"; printf '%s\n%s\n' "$ID1" "$ID4" > "$U/.keep"
  ucache "$ID1-aa"; ucache "$ID4-aa"; old "$U/$ID1-aa"; old "$U/$ID4-aa"; run
  gone "$U/$ID1-aa"; ok "$U/$ID4-aa"; }
c_old_key() {   # 待跑款只保最新那份解包（11-05：同款旧版本解包整款保住，王国之泪两份各 16G 等约 74G）：ID2 在 .keep，旧键 a（500 分钟前）、新键 b（100 分钟前）；
  #   解包上限 50、两份各 100 → 旧键 a 删；删完仍超上限，新键 b 是该款最新那份 → 留（记黄）
  UCAP=50; mk; U=$W/cache/unpack; ucache "$ID2-a" 100 100; ucache "$ID2-b" 100 100; keepq "$ID2"; old "$U/$ID2-a" 500; old "$U/$ID2-b" 100
  run; unset UCAP; gone "$U/$ID2-a"; ok "$U/$ID2-b"; }
CASES="c_tianyan c_writers c_idle_glob c_idle_dir c_gc_stale c_privroot c_root_tmp c_pin_scope c_floor_pend c_pin_sub c_pqx_cap c_floor_pqx c_pqx_run c_pq_unreadable c_family_pq c_key_birth c_pin_old_key c_line_keep c_dead_batch c_keep_stale c_jobs_closed c_unreg c_old_key c_floor_order c_no_misc_lru c_family c_evidence c_ctx_retry c_roots c_beat c_roots_cap c_misc_cap c_roots_ref c_roots_unk c_jobs c_jobs_skip c_unpack_judged c_unpack_cap c_xlate_cap c_pin c_floor c_floor_tick c_floor_long c_redact c_ps_unk c_single c_idle_red c_floor_red c_no_layout c_dry"
one() { F=0; "$1"; for p in $PIDS; do kill "$p" 2> /dev/null; done; PIDS=; return $F; }   # 每个用例收尾杀掉它的辅助进程（别让上一例的进程环境把下一例的同名条目判成在用）
n=0; bad=0; for c in $CASES; do n=$((n + 1)); if one "$c"; then echo "  ✓ $c"; else echo "  ✗ ${c}（日志 $B/g/ops_bg/work_cleaner.log；收尾会删，最后几行如下）"; tail -8 "$B/g/ops_bg/work_cleaner.log" 2> /dev/null | sed 's/^/      | /'; bad=$((bad + 1)); fails="$fails $c"; fi; done
echo "用例 ${n} 个，红 ${bad}${fails:+：${fails}}（实现 ${WC}；删除 ${RMS##*/}）"
# ---------------- 负控：改坏一条判据，对应用例必须红 ----------------
#   fn~<函数名>~<用例>：函数开头插 return 1（判据永远不成立）；sub~<原文>=><替换>~<用例>：原文只许命中 1 处（分隔用 ~：原文里有 ||）
NEG='fn~pinned~c_pin
sub~    tianyan_sweep; writers_check=>    writers_check~c_tianyan
sub~S2A_EVIDENCE_DIR=${S2A_EVIDENCE_DIR:-$WORK/evidence} timeout=>timeout~c_tianyan
sub~  [ $rc = 0 ] || say "【黄】天眼回收=>  true || say "【黄】天眼回收~c_tianyan
sub~"$T/pins.txt" && { echo "钉住（钉住表钉了它下面的子路径）"=>false && { echo "x"~c_pin_sub
sub~return (x in w) || index(x, t) == 1=>return (x in w)~c_idle_dir
fn~ref_ps~c_unpack_cap
fn~ref_cwd~c_jobs
fn~stage_live~c_xlate_cap
fn~recent~c_unpack_judged
fn~root_ref~c_roots_ref
fn~root_pin~c_roots_ref
fn~root_tmp~c_roots_ref
fn~root_young~c_roots
fn~root_tid~c_roots_cap
sub~  NDEL=$((NDEL + 1)); [=>  NDEL=$((NDEL + 1)); false && [~c_beat
fn~misc_ctx~c_misc_cap
sub~"$1" "$b" "$T/sref.txt" "$T/mrefs.txt" 2> /dev/null && { echo "被调度 refs / packq 单 / 调度作业引用"; return 0; }=>"$1" "$b" /dev/null 2> /dev/null && { echo x; return 0; }~c_misc_cap
sub~    [ -n "$q" ] && [ "$(lstart "$q")"=>    false && [ "$(lstart "$q")"~c_misc_cap
sub~[ -z "$k" ] && [ -n "$id" ] && { grep -qxF "$id" "$T/pins.txt" && k="钉住表"; [ -z "$k" ] && pending "$id" && k="待跑 / 手测 / .keep"; }=>:~c_roots_cap
sub~    rule_roots; rule_roots_cap; rule_jobs;=>    rule_roots; rule_jobs;~c_roots_cap
sub~    roottmp   # 主轮=>    :   # 主轮~c_root_tmp
fn~rule_family~c_family
fn~pin_why~c_privroot
sub~writers_check; guard_stale 本机gc=>writers_check; : 本机gc~c_gc_stale
sub~rule_misc; rule_idle; rule_unreg; rule_xlate=>rule_misc; rule_unreg; rule_xlate~c_idle_dir
sub~for d in ${e%=*}; do=>for d in "${e%=*}"; do~c_idle_glob
sub~tianyan_sweep; writers_check; guard_stale=>tianyan_sweep; guard_stale~c_writers
sub~    anc "$pid" | grep -qxF=>    false | grep -qxF~c_writers
sub~[ $((now - ${n:-0})) -ge $((h * 3600)) ] || continue=>:~c_idle_dir
sub~k=$(pin_why "$x" || live_use "$x" || line_recent "$x")=>k=$(live_use "$x" || line_recent "$x")~c_idle_dir
sub~[ -e "$x" ] || { CAND=$((CAND + 1)); del "$x" "${d##*/} 断了的软链=>true || { CAND=$((CAND + 1)); del "$x" "${d##*/} 断了的软链~c_idle_dir
fn~pr_keep~c_privroot
sub~[ $((now - t)) -ge $((PRIDLE * 3600)) ] || continue=>:~c_privroot
sub~if (r != "") {print=>if (1) {print~c_privroot
sub~[ $DRY = 1 ] || chmod -R u+w "$tr/.romfs_store/$g" 2> /dev/null;=>:;~c_privroot
sub~    rule_privroot   # 私有产物根排最前=>    :   # 私有产物根排最前~c_privroot
sub~[ -e "$tr/.keep" ] && { say=>false && { say~c_privroot
sub~  for i in 1 2 3; do ${S2A_WC_LSOF=>  for i in 1; do ${S2A_WC_LSOF~c_ctx_retry
sub~  local l=$T/ev.txt d f n=0; evidence "$1" > "$l"; [ -s "$l" ] || return 0=>  return 0~c_evidence
sub~ "$WORK/cache/bake/$lk"-* "$WORK/cache/aoc/t$lk"-*=> ~c_family
fn~judged~c_unpack_judged
fn~pending~c_unpack_judged
fn~over_cap~c_unpack_cap
sub~  [ -z "$CTX_WHY" ]=>  true~c_ps_unk
sub~[ -n "$why" ] && { say "核不了，不删 ${d}（${why}）"; continue; }=>:~c_roots_unk
sub~grep -qxF "$g" "$T/ract.txt" && {=>false && {~c_roots_ref
sub~[ -e "$b/running/$k" ] && continue;=>:;~c_jobs
sub~[ -e "$w/.留证" ] && [ $aged = 0 ] && continue; [ -e "$w/.保留" ]=>: ; [ -e "$w/.保留" ]~c_jobs
fn~rule_unreg~c_unreg
sub~  root_tmp "$1" || in_use "$1" || root_young "$1" || line_recent "$1"; }=>  root_tmp "$1" || in_use "$1" || root_young "$1"; }~c_line_keep
fn~ref_open~c_line_keep
sub~grep -qxF "$k" "$T/bj.txt" || [ $closed = 1 ] || continue=>grep -qxF "$k" "$T/bj.txt" || continue~c_jobs_closed
sub~[ -e "$w/.留证" ] && [ $aged = 0 ] && continue=>[ -e "$w/.留证" ] && continue~c_jobs_closed
sub~[ -e "$w/.保留" ] && continue   #=>:   #~c_jobs
sub~[ -e "$x" ] || [ -L "$x" ] || continue; case $x in "$w"/r|"$w"/r/logs) continue;; esac; del=>[ -e "$x" ] || [ -L "$x" ] || continue; del~c_jobs
sub~      for x in "$w"/* "$w"/.[!.]* "$w"/r/* "$w"/r/.[!.]*; do [ -e "$x" ] || [ -L "$x" ] || continue; case $x in "$w"/r|"$w"/r/logs) continue;; esac; del=>      for x in "$w"/* "$w"/r/*; do [ -e "$x" ] || [ -L "$x" ] || continue; case $x in "$w"/r|"$w"/r/logs) continue;; esac; del~c_jobs
sub~      for x in "$w"/* "$w"/.[!.]* "$w"/r/* "$w"/r/.[!.]*; do [ -e "$x" ] || [ -L "$x" ] || continue; case $x in "$w"/r|"$w"/r/logs) continue;; esac; del=>      for x in "$w"/* "$w"/.[!.]* "$w"/r/* "$w"/r/.[!.]*; do [ -e "$x" ] || continue; case $x in "$w"/r|"$w"/r/logs) continue;; esac; del~c_jobs
sub~[ $DRY = 1 ] || guard_single work_cleaner=>:~c_single
sub~guard_round work_cleaner "$CAND" "$DONE"=>: "$CAND" "$DONE"~c_idle_red
sub~[ $DRY = 1 ] || { [ "$(free_u)" -lt "$FLOOR" ] && rule_floor; }=>:~c_floor
sub~i=$(gid "$1"); if pending "$i"; then=>i=$(gid "$1"); if false; then~c_floor_pend
fn~pqx_keep~c_pqx_run
sub~    grep -qxF "$k" "$T/fam_pq.txt" && {=>    false && {~c_family_pq
sub~{ say "【黄】整族删本轮不做：packq run/ req/ 读不了"; return 0; }=>{ true; }~c_family_pq
sub~b=${b%%@*}   #=>:   #~c_pqx_run
sub~os.listdir(d) if=>(os.listdir(d) if os.access(d, os.R_OK) else []) if~c_pq_unreadable
sub~os.listdir(dd) if=>(os.listdir(dd) if os.access(dd, os.R_OK) else []) if~c_pq_unreadable
sub~  pqx_run; for d in "$PQX"=>  for d in "$PQX"~c_pqx_run
sub~  [ "$(free_u)" -lt "$tgt" ] && rule_family "$tgt" fam_parts=>  false && rule_family "$tgt" fam_parts~c_family
sub~  floor_pass "$T/fl_u.txt" 解包 "$tgt"=>  :~c_floor_order
sub~    batch_live "$n" && { ls "$b/running"=>    { ls "$b/running"~c_dead_batch
sub~ | grep -xF -f "$T/liveq.txt" >>=> >>~c_keep_stale
fn~batch_live~c_dead_batch
fn~ulatest~c_old_key
sub~  floor_pass "$T/fl_q.txt" packq抽取 "$tgt"=>  :~c_floor_pqx
sub~rule_unpack; rule_pqx; rule_misc;=>rule_unpack; rule_misc;~c_pqx_cap
sub~n=$(stat -f %B "$x" 2> /dev/null)=>n=$(newest "$x")~c_key_birth
sub~  case $1 in "$UD"/*) ulatest "$i" "$1" || return 1;; esac=>  :~c_pin_old_key
fn~ulatest~c_pin_old_key
sub~ulatest "$i" "$1" && { echo=>true && { echo~c_old_key
sub~    case " ${WORK_JOBS_SKIP:-} " in *" ${b##*/} "*) continue;; esac=>    :~c_jobs_skip
sub~(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|PRIVATE_KEY)=>(NOMATCHXYZ)~c_redact
sub~MAINP=$$; if [ $ONCE = 0 ] && [ $DRY = 0 ]; then floor_loop & FLP=$!;=>MAINP=$$; if false; then floor_loop & FLP=$!;~c_floor_long'
if [ "${1:-}" != --no-neg ]; then
  nn=0; nbad=0; nfail=; ORIG=$WC; MUT=$TOP/wc_neg.sh
  while IFS='~' read -r kind pat cs; do [ -n "$kind" ] || continue; nn=$((nn + 1))
    if ! python3 - "$ORIG" "$MUT" "$kind" "$pat" <<'PY'
import re, sys
src, dst, kind, pat = sys.argv[1:5]; s = open(src, encoding='utf-8').read()
if kind == 'fn':
    rx = re.compile('^' + re.escape(pat) + r'\(\) \{', re.M); n = len(rx.findall(s)); s = rx.sub(pat + '() { return 1;', s)
else:
    a, b = pat.split('=>', 1); n = s.count(a); s = s.replace(a, b)
if n != 1: sys.exit(f'负控原文命中 {n} 处（应为 1）：{pat[:60]}')
open(dst, 'w', encoding='utf-8').write(s)
PY
    then nbad=$((nbad + 1)); nfail="$nfail ${kind}:${pat:0:30}"; continue; fi
    if WC=$MUT one "$cs" > /dev/null 2>&1; then echo "  ✗ 负控 ${kind} ${pat:0:50} → ${cs} 仍绿（这条判据没被测住）"; nbad=$((nbad + 1)); nfail="$nfail ${cs}"; else echo "  ✓ 负控 ${kind} ${pat:0:40} → ${cs} 红"; fi
  done <<< "$NEG"
  echo "负控 ${nn} 条，没测住 ${nbad}${nfail:+：${nfail}}"
  bad=$((bad + nbad))
fi
[ $bad = 0 ]
