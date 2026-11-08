#!/bin/bash
# S2Arm 设备锁补丁单测（不碰手机）：缺依赖 / 没选机当场退出 4（不在电量闸空等）、选机名单与日常手机拒绝。期望值按规则手写，不跑被测实现推算
set -u; H=$(cd "$(dirname "$0")/../tools" && pwd); T=$(mktemp -d); bad=0
export S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1
ok(){ echo "通 $1"; }; ng(){ echo "不通 $1"; bad=1; }
# 1. devbattery.sh 缺失：拷一份只有 devlock.sh 的目录，锁目录在过闸名单里 → 5 秒内退出 4、没取锁
mkdir $T/only; cp $H/devlock.sh $T/only/
t0=$SECONDS; ( SW_DEVBATTERY_LOCKS=$T/a.lock SW_DEVLOCK_DIR=$T/a.lock SW_DEVBATTERY_WAIT_S=60 bash -c "source $T/only/devlock.sh; devlock_acquire 单测; echo 不该走到这" ) > $T/o1 2>&1; r=$?
[ $r = 4 ] && [ $((SECONDS - t0)) -lt 30 ] && [ ! -d $T/a.lock ] && grep -q 'devbattery.sh' $T/o1 && ok "缺 devbattery.sh → 退出 4、$((SECONDS - t0)) 秒、没取锁" || ng "缺 devbattery.sh → rc=$r 用时 $((SECONDS - t0)) 秒：$(cat $T/o1)"
# 2. 没选测试机（SW_IOS_UDID 空）→ 不等锁直接退出 4（用时 < 30 秒，等锁上限 60 秒的一半；10-21 门禁墙钟判据普查：原判 ≤ 5 秒满载会误红）
t0=$SECONDS; ( unset SW_IOS_UDID DEVBATTERY_FAKE; DEVBATTERY_DIR=$T SW_DEVBATTERY_LOCKS=$T/b.lock SW_DEVLOCK_DIR=$T/b.lock SW_DEVBATTERY_WAIT_S=60 bash -c "source $H/devlock.sh; devlock_acquire 单测; echo 不该走到这" ) > $T/o2 2>&1; r=$?
[ $r = 4 ] && [ $((SECONDS - t0)) -lt 30 ] && [ ! -d $T/b.lock ] && ok "没选机 → 退出 4、$((SECONDS - t0)) 秒" || ng "没选机 → rc=$r 用时 $((SECONDS - t0)) 秒：$(cat $T/o2)"
# 3. 选机
( source $H/devices.sh; export S2A_DEVICE_NO_USB_CHECK=1
  s2a_device 00000000-0000000000000000 2>/dev/null && echo "不通 日常手机被选中" || echo "通 日常手机拒绝"
  s2a_device 00000000-DEADBEEF 2>/dev/null && echo "不通 名单外被选中" || echo "通 名单外拒绝"
  s2a_device 1 && [ "$SW_IOS_UDID" = 00000000-0000000000000001 ] && [ "$SW_DEVICE" = 00000000-0000-0000-0000-000000000001 ] && [ "$SW_DEVLOCK_DIR" = $HOME/sw-work/run/ios/device.lock ] && [ "$SW_DEVBATTERY_LOCKS" = "$SW_DEVLOCK_DIR" ] && echo "通 测试机1 → 本机锁 + UDID" || echo "不通 测试机1 导出不对"
  s2a_device 00000000-0000-0000-0000-000000000002 && [ "$SW_IOS_UDID" = 00000000-0000000000000002 ] && [ "$SW_DEVLOCK_DIR" = ${S2A_RUN_ROOT:-$HOME/.s2arm/run}/devq2/device2.lock ] && [ "$DEVNAME" = 测试机2 ] && echo "通 测试机2 按 CoreDevice 标识选中" || echo "不通 测试机2 导出不对"
  s2a_device_allowed 00000000-0000000000000002 && echo "通 白名单认测试机2 UDID" || echo "不通 白名单不认测试机2"
  s2a_device_allowed 00000000-0000000000000000 && echo "不通 白名单放过日常手机" || echo "通 白名单拒日常手机"
  s2a_device_allowed "" && echo "不通 白名单放过空串" || echo "通 白名单拒空串" ) > $T/o3
cat $T/o3; grep -q 不通 $T/o3 && bad=1
# 4. 选机核 USB：假 idevice_id 只列测试机1，选 2 → 拒（选错机器）
mkdir $T/bin; printf '#!/bin/sh\necho 00000000-0000000000000001\n' > $T/bin/idevice_id; chmod +x $T/bin/idevice_id
( PATH=$T/bin:$PATH; source $H/devices.sh; s2a_device 2 2>/dev/null ) && ng "测试机2 不在本机 USB 却被选中" || ok "测试机2 不在本机 USB → 拒"
( PATH=$T/bin:$PATH; source $H/devices.sh; s2a_device 1 2>/dev/null ) && ok "测试机1 在本机 USB → 选中" || ng "测试机1 在 USB 却被拒"
# 5. 端到端（假电量）：选测试机1 + 临时锁目录（覆盖成名单内）→ 取到、放掉
( source $H/devices.sh; S2A_DEVICE_NO_USB_CHECK=1 s2a_device 1; export SW_DEVLOCK_DIR=$T/c.lock SW_DEVLOCK_QUEUE=$T/c.queue SW_DEVBATTERY_LOCKS=$T/c.lock DEVBATTERY_DIR=$T DEVBATTERY_FAKE="80 0 1 0" SW_DEVLOCK_HIST=$T/h.tsv SW_DEVLOCK_WD_LOG=$T/wd.log
  source $H/devlock.sh; devlock_acquire 单测 30 2>/dev/null && [ "$(cat $T/c.lock/owner)" = 单测 ] && devlock_release && [ ! -d $T/c.lock ] ) && ok "选机 + 电量够 → 取锁、放锁" || ng "选机端到端失败"
[ $bad = 0 ] || { . "$(dirname "$0")/keep_scene.sh"; keep_scene devlock_s2a $T; }; rm -rf $T; [ $bad = 0 ] && echo "devlock_s2a 单测全过" || { echo "devlock_s2a 单测有不通"; exit 1; }
