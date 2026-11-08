#!/bin/bash
# 门禁只看：tools/sched.sh tools/disk_guard.sh tools/oneshot.sh tools/remote.sh android/linux_ctest.sh tools/cost_log.sh tools/dev_run.sh tools/devbattery.sh tools/devices.sh tools/devlock.sh tools/machine.sh tools/push_pack.sh tools/sysdialog.sh tools/allgreen.py tools/board.py tools/clonedir.py tools/firstuse_scan.py tools/frame_gate.py tools/score_cells.py tools/game_fps.py tools/fps_truth.py tools/redline.py tools/diag_default.env tools/fps_truth.tsv tools/ab_noise.tsv pack/roots.sh tests/fake_devicectl.py tests/keep_scene.sh
# ssh 远端命令拼参数单测（#916 T120；不连真机器，约 30 秒）：bash tests/ssh_argv_test.sh
#   10-29 事故：「保留名单」经 ssh 主机 "命令 $列表" 传过去，远端 shell 按空格重新拆词，只有第一款被保护。
#   假 ssh（PATH 最前）：跟真 ssh 一样把主机名之后的参数用空格连成一条命令，交给「远端」shell 重新解析（本机 bash -c，HOME = 假远端家目录）。
#   驱动被改脚本里的真实函数 / 真实那一行，传入含空格、单双引号、$、通配符的参数，断言远端收到的参数个数与逐字内容与本机一致：
#   ① sched.sh rsh + rabs + rq：远端逐个收到原样参数
#   ② sched.sh 真派一局到「mini」（远端根、测试机锁目录含怪字符）：查忙 / 建目录 / 回收 / 记用 / 核清单 / 起局 / 删作业目录都落在原路径，不在拆出来的路径上建 / 删东西
#   ③ disk_guard.sh 远端根含怪字符：远端 gc 收到的 HOME / 根 / 水位原样   ④ oneshot.sh 读测试机系统版本 / 机型：远端 ideviceinfo 收到的 UDID 原样
#   ⑤ remote.sh fits：远端 du 在原路径下、收到原样的同步项   ⑥ linux_ctest.sh 仓库路径含怪字符：虚拟机里 cd 进原路径
#   负控：任一处改回直接拼 "$var"，对应用例红，红行点名 文件:行 和被拆开的参数。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
NASTY="a b'c\"d\$e*f"   # 空格、单引号、双引号、$、通配
NASTY2="a b'c\$e*f"     # ② 用：不含双引号（dev_run.sh 把作业目录路径原样写进 Python 源码，路径带双引号是它自己的问题，不在本单范围）
ok() { echo "通 $1"; }
red() { echo "不通 $1"; bad=1; }
ln_of() { grep -n -m1 -F -- "$2" "$H/$1" | cut -d: -f1; }   # 文件里含某段原文的第一行行号（红行点名用）
fn() { sed -n "/^$2() {/,/^}/p" "$H/$1" | awk 'NR == 1 && /}[^}]*$/ { print; exit } { print } /^}/ { exit }'; }   # 取脚本里的真实函数定义（单行 / 多行）
# argv_is <标签> <记录文件> <文件:行> 期望参数…：记录文件首行是参数个数，其后每行一个参数
argv_is() {
  local lab=$1 f=$2 at=$3; shift 3; local got=() l i=0 a
  [ -f "$f" ] || { red "$at 远端参数被拆开：${lab}：期望 $# 个［$(printf '«%s» ' "$@")］，远端按拆开后的参数跑、没走到收参处（出错或进错目录）"; return; }
  while IFS= read -r l; do got+=("$l"); done < <(tail -n +2 "$f")
  if [ "$(head -1 "$f")" = "$#" ]; then for a in "$@"; do [ "${got[$i]-}" = "$a" ] || break; i=$((i + 1)); done; fi
  [ $i = $# ] && [ "$(head -1 "$f")" = "$#" ] && { ok "${lab}：远端收到 $# 个参数、逐字一致"; return; }
  red "$at 远端参数被拆开：${lab}：期望 $# 个［$(printf '«%s» ' "$@")］，实收 $(head -1 "$f") 个［$(printf '«%s» ' ${got[@]+"${got[@]}"})］"
}
mkdir -p "$T/bin" "$T/rhome"; export RHOME=$T/rhome SSH_LOG=$T/ssh.log
cat > "$T/bin/ssh" << 'EOF'
#!/bin/bash
# 假 ssh：选项跳过，主机名之后的参数按真 ssh 的规矩用空格连成一条命令，交给「远端」shell 重新解析
while [ $# -gt 0 ]; do case $1 in -[bcDEeFIiJLlmOoPpQRSWw]) shift 2;; -*) shift;; *) break;; esac; done
shift; c="$*"; printf '%s\0' "$c" >> "$SSH_LOG"
cd "$RHOME" && HOME=$RHOME exec bash -c "$c"
EOF
cat > "$T/bin/argv" << 'EOF'
#!/bin/bash
{ echo "$#"; for a in "$@"; do printf '%s\n' "$a"; done; } > "$ARGV_OUT"
EOF
chmod +x "$T/bin/ssh" "$T/bin/argv"; export PATH=$T/bin:$PATH

# ① sched.sh 的 rsh / rabs / rq
(
  bad=0; eval "$(fn tools/sched.sh rsh)"; eval "$(fn tools/sched.sh rabs)"; eval "$(fn tools/sched.sh rq)"; MINI=fakemini
  export ARGV_OUT=$T/a1; rsh "argv $(rq "$NASTY" "x  y" '') $(rabs "r $NASTY")" 20
  argv_is "① sched.sh rsh + rq + rabs" "$T/a1" "tools/sched.sh:$(ln_of tools/sched.sh 'rabs() {')/$(ln_of tools/sched.sh 'rq() {')" "$NASTY" "x  y" "" "$RHOME/r $NASTY"
  ARGV_OUT=$T/a1b; rsh "argv $(rabs "r $NASTY/jobs/x")/pack" 20
  argv_is "① sched.sh rabs 后接 /后缀" "$T/a1b" "tools/sched.sh:$(ln_of tools/sched.sh 'rabs() {')" "$RHOME/r $NASTY/jobs/x/pack"
  [ $bad = 0 ]
) || bad=1

# ② sched.sh 真派一局到「mini」：远端根、测试机锁目录含怪字符
(
  bad=0; export S2A_TEST_ROOT="$T/lock $NASTY2" S2A_DEVICE_NO_USB_CHECK=1 DEVBATTERY_FAKE="80 1 1 0" FAKE_DEV=$T/dev S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py"
  export S2A_NO_FETCH=1 S2A_POLL_S=0.2 S2A_POLL_APPLY_S=0.2 SW_DEVLOCK_HIST=$T/h.tsv SW_DEVLOCK_WD_LOG=$T/wd.log S2A_ACT_S=1 MARK_AT=5
  export S2A_FILL_FORMAL=0 S2A_DUAL_SPLIT=0 S2A_BID_FORMAL=com.s2arm S2A_DEV2_HOST=mini S2A_PKG_NO_SMOKE=1 S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1
  printf '#!/bin/bash\ncp "$1" "$2"\n' > "$T/expid_pass"; chmod +x "$T/expid_pass"; export S2A_IPA_EXP_ID=$T/expid_pass   # 改签实验身份换原样拷贝桩（真改签要描述文件，sched_test 另测）
  RR="r $NASTY2"; export S2A_COST_TSV=$T/cost.tsv S2A_SCHED_DIR=$T/sched S2A_MINI=fakemini S2A_MINI_ROOT=$RR S2A_BOARD=$T/board/记分板.tsv
  mkdir -p "$S2A_TEST_ROOT" "$T/dev"; for c in ideviceinfo idevicediagnostics; do printf '#!/bin/sh\nexit 1\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
  # 假 rsync：fakemini:<相对路径> → 假远端家目录下的同一路径（只验 ssh 拼接；rsync 自己的远端路径传法不在本单范围）
  printf '#!/bin/bash\na=(); for x in "$@"; do case $x in fakemini:/*) a+=("${x#fakemini:}");; fakemini:*) a+=("$RHOME/${x#fakemini:}");; *) a+=("$x");; esac; done; exec /usr/bin/rsync "${a[@]}"\n' > "$T/bin/rsync"; chmod +x "$T/bin/rsync"
  P=$T/pkg; mkdir -p "$P/pack/romfs"; echo a > "$P/pack/romfs/a.bin"
  (cd "$P/pack" && printf 'romfs/a.bin\t2\t%s\n' "$(shasum -a 256 romfs/a.bin | cut -d' ' -f1)" > index.tsv && printf '{"version": 2, "index_sha256": "%s"}\n' "$(shasum -a 256 index.tsv | cut -d' ' -f1)" > manifest.json)
  w=$T/ipaw; mkdir -p "$w/Payload/X.app"; : > "$w/Payload/X.app/embedded.mobileprovision"; plutil -create xml1 "$w/Payload/X.app/Info.plist"; plutil -insert CFBundleIdentifier -string com.s2arm.acnh "$w/Payload/X.app/Info.plist"; (cd "$w" && zip -qr "$P/acnh.ipa" Payload)
  S="bash $H/tools/sched.sh"; $S pkg acnh "$P" c0ffee1 > /dev/null; MERGE_OWNER=测试 $S submit acnh --device=2 --act=1 引号局 > /dev/null
  : > "$SSH_LOG"; timeout 200 $S once > "$T/once.out" 2>&1
  top=$(ls -A "$RHOME" | grep -vxF "r $NASTY2" | grep -vxE 'Library|\..*')   # 远端家目录下工具自建的 Library / 点文件不算
  if grep -q RESULT=done "$T/sched/inbox/测试.log" 2> /dev/null && [ -f "$RHOME/$RR/packs/acnh/manifest.json" ] && [ -e "$RHOME/$RR/packs/.used_acnh" ] && [ -z "$(ls -A "$RHOME/$RR/jobs" 2> /dev/null)" ] && [ -z "$top" ]; then
    ok "② sched.sh 派局到 mini（远端根「${RR}」、锁目录含同样怪字符）：局跑完、资源包与 .used 落原路径、远端作业目录删净、没有拆出来的路径"
  else
    # 点名：远端收到的命令里原样出现了没转义的怪字符串（会被远端 shell 拆开）的那几条，回查 sched.sh 里发出它的 rsh 行
    while IFS= read -r -d '' c; do case $c in *"$NASTY2"*) v=$(sed 's/^export LANG=[^;]*; //' <<< "$c" | awk '{print $1}'); l=$(grep -n -F "rsh \"$v " "$H/tools/sched.sh" | head -1 | cut -d: -f1); [ "$v" = "[" ] && l=$(ln_of tools/sched.sh 'local chk=')   # 查锁那条是 rsh "$chk"
      red "tools/sched.sh:${l:-?} 远端参数被拆开：远端命令「${c:0:200}」里的 «${NASTY2}» 没转义";; esac; done < "$SSH_LOG"
    red "② sched.sh 派局到 mini（远端根「${RR}」）：done $(grep -c RESULT=done "$T/sched/inbox/测试.log" 2> /dev/null) 局；拆出来的路径「${top}」；残留作业目录「$(ls -A "$RHOME/$RR/jobs" 2> /dev/null)」；调度输出 $(tail -3 "$T/once.out" | tr '\n' ' ' | cut -c1-300)"
  fi
  [ $bad = 0 ]
) || bad=1

# ③ disk_guard.sh：远端根含怪字符，远端 gc 收到的 HOME / 根 / 水位原样
(
  bad=0; D=$T/dg; RR="$T/rr $NASTY"; mkdir -p "$D/tools" "$D/run" "$RR/gc/new"; cp "$H/tools/disk_guard.sh" "$D/tools/"; : > "$D/tools/machine.sh"
  printf '#!/bin/bash\n{ echo 4; printf "%%s\\n" "$HOME" "${S2A_GC_REMOTE_ROOT-}" "${S2A_GC_LOW_GB-}" "${S2A_GC_HIGH_GB-}"; } > %q\n' "$T/a3" > "$RR/gc/new/gc.sh"
  S2A_RUN=$D/run S2A_GUARD_RR=$RR S2A_REMOTE_HOSTS=fakemini S2A_DISK_WATCH=mini S2A_GUARD_FREE_LOCAL=999 S2A_GUARD_FREE_REMOTE=10 bash "$D/tools/disk_guard.sh" > "$T/dg.out" 2>&1
  for i in $(seq 1 50); do [ -s "$T/a3" ] && break; sleep 0.1; done
  argv_is "③ disk_guard.sh 远端 gc 的 HOME / 根 / 水位" "$T/a3" "tools/disk_guard.sh:$(ln_of tools/disk_guard.sh 'S2A_GUARD_RR:-')" "$RR/home" "$RR" 60 80
  [ $bad = 0 ]
) || bad=1

# ④ oneshot.sh 读测试机系统版本 / 机型：驱动真实那一行（远端 PATH 前插 /opt/homebrew/bin：桩用导出函数，函数先于 PATH 查找）
(
  bad=0; ideviceinfo() { { echo "$#"; for a in "$@"; do printf '%s\n' "$a"; done; } > "$ARGV_OUT"; echo 26.1; }; export -f ideviceinfo
  DEV=2 UD=$NASTY S2A_MINI=fakemini
  for k in ProductVersion ProductType; do
    l=$(grep -n "ideviceinfo -u .* -k $k\" 2>/dev/null" "$H/tools/oneshot.sh" | head -1); n=${l%%:*}
    export ARGV_OUT=$T/a4$k; eval "${l#*:}"
    argv_is "④ oneshot.sh 远端 ideviceinfo（${k}）" "$T/a4$k" "tools/oneshot.sh:$n" -u "$NASTY" -k "$k"
  done
  [ $bad = 0 ]
) || bad=1

# ⑤ remote.sh fits：远端 du 在原路径（远端根含怪字符）下、收到原样的同步项
(
  bad=0; eval "$(fn tools/remote.sh fits)"; hmin() { echo 0; }
  RR="nx $NASTY"; export S2A_REMOTE_ROOT=$RR T RR; SYNCP=("p $NASTY" "q r")
  mkdir -p "$RHOME/$RR/home/p $NASTY" "$RHOME/$RR/home/q r"
  du() { [ "$PWD" = "$RHOME/$RR/home" ] && { echo "$(( $# - 1 ))"; for a in "${@:2}"; do printf '%s\n' "$a"; done; } > "$T/a5"; command du "$@"; }; export -f du
  fits fakemini > /dev/null
  argv_is "⑤ remote.sh fits 远端 du 的同步项" "$T/a5" "tools/remote.sh:$(ln_of tools/remote.sh 'r=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$1"')" "p $NASTY" "q r"
  [ $bad = 0 ]
) || bad=1

# ⑥ linux_ctest.sh：仓库路径含怪字符，虚拟机里 cd 进原路径（假 colima：ssh -- 后的参数原样执行，同 limactl shell 逐个转义）
(
  bad=0; HM=$T/home; R="$HM/rep $NASTY"; mkdir -p "$R/android" "$T/b6"; cp "$H/android/linux_ctest.sh" "$R/android/"
  printf '#!/bin/sh\necho Darwin\n' > "$T/b6/uname"
  printf '#!/bin/bash\ncase $1 in status) exit 0;; ssh) shift; [ "$1" = -- ] && shift; exec "$@";; esac; exit 1\n' > "$T/b6/colima"
  printf '#!/bin/bash\n{ echo 1; printf "%%s\\n" "$PWD"; } > %q; exit 1\n' "$T/a6" > "$T/b6/cmake"
  for c in c++ cc; do printf '#!/bin/sh\nexit 0\n' > "$T/b6/$c"; done; chmod +x "$T/b6/"*
  HOME=$HM PATH=$T/b6:$PATH bash "$R/android/linux_ctest.sh" > "$T/lc.out" 2>&1
  argv_is "⑥ linux_ctest.sh 虚拟机里的仓库路径" "$T/a6" "android/linux_ctest.sh:$(ln_of android/linux_ctest.sh 'colima ssh -- bash -c')" "$R"
  [ $bad = 0 ]
) || bad=1

[ $bad = 0 ] && { echo "ssh_argv 单测全过"; exit 0; }
echo "ssh_argv 单测有不通"; exit 1
