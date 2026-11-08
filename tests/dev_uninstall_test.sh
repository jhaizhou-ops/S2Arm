#!/bin/bash
# 卸载实验 App 单测（假 devicectl，不碰手机，约 2 秒）：正式身份拒绝且不动；实验身份装着 → 卸掉；没装 → 绿；锁在别人手里 → 等不到报红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
export S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_TEST_ROOT=$T/lock S2A_DEVICE_NO_USB_CHECK=1 DEVBATTERY_FAKE="80 1 1 0" FAKE_DEV=$T/dev S2A_DEVICECTL="python3 $H/tests/fake_devicectl.py" S2A_PSO_SEED_DIR=$T/pso_seed SW_DEVLOCK_HIST=$T/h.tsv SW_DEVLOCK_WD_LOG=$T/wd.log
DV=$T/dev/00000000-0000-0000-0000-000000000002; mkdir -p $T/lock $DV/apps/io.s2arm-exp.witcher3/Documents $DV/apps/io.s2arm.witcher3/Documents
echo u > $DV/apps/io.s2arm-exp.witcher3/url; echo u > $DV/apps/io.s2arm.witcher3/url
o=$(bash $H/tools/dev_uninstall.sh 2 io.s2arm.witcher3 2>&1); r=$?
ck "正式身份 io.s2arm.witcher3 → 拒绝（退出 2）、机上没动（rc=${r}）" '[ $r = 2 ] && grep -q "只卸实验身份" <<< "$o" && [ -d $DV/apps/io.s2arm.witcher3 ]'
W=$DV/apps/io.s2arm-exp.witcher3/Documents/wire/0100A0B0C0D0E000; mkdir -p $W/pipelines; printf 'R\tab\n' > $W/pso_user.tsv; echo x > $W/pipelines/p.metalarchive
o=$(bash $H/tools/dev_uninstall.sh 2 io.s2arm-exp.witcher3 2>&1); r=$?
ck "实验身份装着 → 卸掉（rc=${r}）、正式身份那份还在、锁已放" '[ $r = 0 ] && grep -q "已卸载 测试机2 上的 io.s2arm-exp.witcher3" <<< "$o" && [ ! -d $DV/apps/io.s2arm-exp.witcher3 ] && [ -d $DV/apps/io.s2arm.witcher3 ] && [ ! -d $T/lock/device2.lock ]'
ck "卸前把 wire/<程序号>/pso_user.tsv 拉回 pso_seed/<程序号>/<包名>_<时间>_卸前.tsv、内容一致、只拉这张表" '[ "$(cat $T/pso_seed/0100A0B0C0D0E000/io.s2arm-exp.witcher3_*_卸前.tsv)" = "$(printf "R\tab")" ] && [ "$(ls -R $T/pso_seed | grep -c .tsv)" = 1 ]'
o=$(bash $H/tools/dev_uninstall.sh 2 io.s2arm-exp.witcher3 2>&1); r=$?
ck "再卸一次（本来没装）→ 绿、不调卸载（rc=${r}）" '[ $r = 0 ] && grep -q "没装 io.s2arm-exp.witcher3，不用卸" <<< "$o"'
mkdir -p $DV/apps/io.s2arm-exp.witcher3/Documents; echo u > $DV/apps/io.s2arm-exp.witcher3/url
o=$(bash $H/tools/dev_uninstall.sh 2 io.s2arm-exp.witcher3 2>&1); r=$?
ck "机上没有 wire/（没建过管线）→ 记「0 份」、照常卸掉、不报错（rc=${r}）" '[ $r = 0 ] && grep -q "卸前拉回管线种子来源：0 份" <<< "$o" && [ ! -d $DV/apps/io.s2arm-exp.witcher3 ]'
mkdir -p $DV/apps/io.s2arm-exp.witcher3; echo u > $DV/apps/io.s2arm-exp.witcher3/url
o=$(FAKE_APPS_GARBAGE=1 bash $H/tools/dev_uninstall.sh 2 io.s2arm-exp.witcher3 2>&1); r=$?
ck "已装列表 JSON 读不出 → 红退出 1、不当「没装」跳过（rc=${r}）、App 还在（审计 P1-50）" '[ $r = 1 ] && grep -q "查已装 App 失败" <<< "$o" && ! grep -q "没装" <<< "$o" && [ -d $DV/apps/io.s2arm-exp.witcher3 ]'
o=$(bash $H/tools/dev_uninstall.sh 9 io.s2arm-exp.witcher3 2>&1); r=$?   # 3 号 11-06 起是 Duo（名单内），名单外用 9
ck "名单外设备 9 → 红、不碰（rc=${r}）" '[ $r = 1 ] && grep -q "不在测试机名单" <<< "$o"'
o=$(bash $H/tools/dev_uninstall.sh 2 2>&1); r=$?; ck "少参数 → 用法、退出 2" '[ $r = 2 ] && grep -q 用法 <<< "$o"'
rm -rf $T; [ $bad = 0 ] && echo "dev_uninstall 单测全过" || { echo "dev_uninstall 单测有不通"; exit 1; }
