#!/bin/bash
# 真机现场一把锁单测（tools/dev_scene.sh；假设备 + 临时锁目录，不碰手机，约 10 秒）：
#   命令在锁内跑、拿得到 SW_DEVICE；同机两个现场按锁排队、时间不重叠；现场里再取锁（嵌套，如 dev_run / xcui）立即通过；命令退出码原样返回；用法错 2；名单外设备 1
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1 S2A_TEST_ROOT=$T/lock S2A_DEVICE_NO_USB_CHECK=1 DEVBATTERY_FAKE="80 1 1 0" FAKE_DEV=$T/dev \
  S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py" SW_DEVLOCK_HIST=$T/h.tsv SW_DEVLOCK_WD_LOG=$T/wd.log
mkdir -p $T/lock $T/dev
S=$H/tools/dev_scene.sh
o=$(bash $S 2 测锁内 -- bash -c 'echo "dev=$SW_DEVICE held=${SW_DEVLOCK_HELD:-} pid=$(cat "$SW_DEVLOCK_DIR/pid")"' 2>&1); r=$?
ck "命令在锁内跑：拿得到 SW_DEVICE、持锁 pid 就是本现场（rc=${r}）" '[ $r = 0 ] && grep -q "dev=" <<< "$o" && h=$(sed -n "s/.*held=\([0-9]*\) pid=\([0-9]*\).*/\1 \2/p" <<< "$o") && [ -n "${h% *}" ] && [ "${h% *}" = "${h#* }" ]'
ck "现场结束放锁" '[ ! -s "$T/lock/$(ls $T/lock | grep "\.lock$" | head -1)/pid" ]'
# 同机两个现场：各自在锁内记起止时刻（毫秒），后起的必须等先起的放锁
rec() { python3 -c 'import time,sys; open(sys.argv[1],"a").write(f"{sys.argv[2]} {time.time():.3f}\n")' $T/t.log "$1"; }
export -f rec; export T
bash $S 2 现场A -- bash -c 'rec A0; sleep 2; rec A1' > /dev/null 2>&1 & sleep 0.3
bash $S 2 现场B -- bash -c 'rec B0; sleep 1; rec B1' > /dev/null 2>&1; wait
ck "同机两个现场排队：B 在 A 放锁之后才进现场（$(tr '\n' ' ' < $T/t.log)）" 'python3 -c "
import sys; d={l.split()[0]:float(l.split()[1]) for l in open(\"$T/t.log\")}; sys.exit(0 if d[\"B0\"] >= d[\"A1\"] else 1)"'
o=$(bash $S 2 测嵌套 -- bash -c 'source '"$H"'/tools/devlock.sh && devlock_acquire 里面的工具 30 && echo 嵌套取到' 2>&1); r=$?
ck "现场里再取锁（dev_run / xcui 那样）立即通过、不自己等自己（rc=${r}）" '[ $r = 0 ] && grep -q 嵌套取到 <<< "$o"'
bash $S 2 测退出码 -- bash -c 'exit 7' > /dev/null 2>&1; r=$?; ck "命令退出码原样返回（rc=${r}）" '[ $r = 7 ]'
bash $S 2 少命令 > /dev/null 2>&1; r=$?; ck "少命令 → 用法、退出 2（rc=${r}）" '[ $r = 2 ]'
bash $S 9 名单外 -- true > /dev/null 2>&1; r=$?; ck "名单外设备 → 退出 1、不跑命令（rc=${r}）" '[ $r = 1 ]'
[ $bad = 0 ] && echo "dev_scene 单测全过" || { echo "dev_scene 单测有不通"; exit 1; }
