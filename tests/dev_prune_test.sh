#!/bin/bash
# 门禁覆盖：tools/dev_prune.sh tools/dev_run.sh
# 腾测试机空间（11-06 jhz：「清理一下超过 24 小时以上的 S2Arm 的安装包吧……后续也是，如果安装遇到了空间问题，就删掉超过 24 小时的咱们的包」）：
#   假 devicectl + 占位名单 + 临时锁目录，不碰真机。期望（按规则手写，不跑被测实现推）：测试机2 上
#   io.s2arm.botw（永不卸）、io.s2arm.old（容器 48 小时没动）、io.s2arm-exp.recent（1 小时前动过）、io.s2arm.half（1 小时前，但 --first 点名）、
#   com.other.app（不是我方）、io.s2arm.unread（读不出容器时间）
#   ① --dry：列 half（点名先卸）、old；不列 botw / recent / other / unread；什么都没卸
#   ② 真卸：half、old 卸掉；botw / recent / other / unread 都还在；old 的存档（Documents/S2A/ryujinx/bis/user/save/a.sav）备份到 saves_backup 下、内容一致
#   ③ --need-mb：可用一开始就够 → 一款不卸
#   ⑤ 不设 S2A_PRUNE_KEEP（缺省空）→ botw 48 小时没动也列进会卸
#   （①–④ 显式 S2A_PRUNE_KEEP=2:io.s2arm.botw 测保护机制本身）
#   ④ 我方装机记录 2 小时前装过 old（作业 job.env DEV=2、BUNDLE=io.s2arm.old、out_x/install.log）→ 即使容器时间是 48 小时前也不卸
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1 S2A_DEVICE_NO_USB_CHECK=1 S2A_TEST_ROOT=$T/lk FAKE_DEV=$T/dev S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py"
export S2A_PRUNE_KEEP="2:io.s2arm.botw" DEVBATTERY_FAKE="80 1 1 0" S2A_SAVE_BACKUP_DIR=$T/bk S2A_PRUNE_ROOTS=$T/rec S2A_PRUNE_FREE_CMD="echo 1000" SW_DEVLOCK_HIST=$T/h.tsv SW_DEVLOCK_WD_LOG=$T/wd.log
mkdir -p $T/lk $T/rec; now=$(date +%s); h48=$((now - 48 * 3600)); h1=$((now - 3600))
export S2A_PRUNE_NEWEST="io.s2arm.botw=$h48,io.s2arm.old=$h48,io.s2arm-exp.recent=$h1,io.s2arm.half=$h1,com.other.app=$h48"
setup() { rm -rf $T/dev $T/bk; local D=$T/dev/00000000-0000-0000-0000-000000000002/apps
  for b in io.s2arm.botw io.s2arm.old io.s2arm-exp.recent io.s2arm.half com.other.app io.s2arm.unread; do mkdir -p $D/$b; echo "file:///x/$b/" > $D/$b/url; done
  mkdir -p $D/io.s2arm.old/Documents/S2A/ryujinx/bis/user/save; echo 存档 > $D/io.s2arm.old/Documents/S2A/ryujinx/bis/user/save/a.sav; }
left() { ls $T/dev/00000000-0000-0000-0000-000000000002/apps | tr '\n' ' '; }
setup; o1=$(bash $H/tools/dev_prune.sh 2 --dry --first io.s2arm.half 2>&1)
ck "① --dry 列 half、old（$(grep -o '会卸 [^（]*' <<< "$o1" | tr '\n' ' ')），一款没卸（剩 $(left)）" '[ "$(grep -o "会卸 [^（]*" <<< "$o1" | tr "\n" " ")" = "会卸 io.s2arm.half 会卸 io.s2arm.old " ] && [ "$(left)" = "io.s2arm.botw io.s2arm.half io.s2arm.old io.s2arm.unread com.other.app io.s2arm-exp.recent " ]'
setup; o2=$(bash $H/tools/dev_prune.sh 2 --first io.s2arm.half 2>&1); bk=$(ls -d $T/bk/2_io.s2arm.old_* 2> /dev/null | head -1)
ck "② 真卸 half、old，剩 $(left)；old 存档备份「$(cat $bk/bis/user/save/a.sav 2> /dev/null)」" '[ "$(left)" = "io.s2arm.botw io.s2arm.unread com.other.app io.s2arm-exp.recent " ] && [ "$(cat $bk/bis/user/save/a.sav 2> /dev/null)" = 存档 ] && grep -q "卸 2 款" <<< "$o2"'
setup; o3=$(S2A_PRUNE_FREE_CMD="echo 99999" bash $H/tools/dev_prune.sh 2 --need-mb 5000 2>&1)
ck "③ 可用已够 → 一款不卸（剩 $(left)）" 'grep -q "卸 0 款" <<< "$o3" && [ -d $T/dev/00000000-0000-0000-0000-000000000002/apps/io.s2arm.old ]'
setup; mkdir -p $T/rec/j1/out_x; printf 'DEV=2\nBUNDLE=io.s2arm.old\n' > $T/rec/j1/job.env; touch -t "$(date -v-2H +%Y%m%d%H%M)" $T/rec/j1/out_x/install.log
o4=$(bash $H/tools/dev_prune.sh 2 --dry 2>&1)
ck "④ 我方 2 小时前装过 old → 不列（$(grep -o '会卸 [^（]*' <<< "$o4" | tr '\n' ' ')）" '! grep -q "会卸 io.s2arm.old" <<< "$o4"'
setup; o5=$(env -u S2A_PRUNE_KEEP bash $H/tools/dev_prune.sh 2 --dry 2>&1)   # 真不设（不是设空），才测得到缺省值
ck "⑤ 缺省不保护任何包（11-06 晚 jhz「旷野之息可以删」）：不设 KEEP → 48 小时没动的 botw 也列（$(grep -o '会卸 [^（]*' <<< "$o5" | tr '\n' ' ')）" 'grep -q "会卸 io.s2arm.botw" <<< "$o5"'
[ $bad = 0 ] && echo "dev_prune 单测全过"; exit $bad
