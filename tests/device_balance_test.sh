#!/bin/bash
# 门禁覆盖：tools/devices.sh tools/devlock.sh
# 三台测试机负载均衡（11-06 jhz「测试机1和2和 Duo 都能用，做成负载均衡的吧」）：选机规则单测，占位名单 + 临时锁目录，不碰真机。
# 期望（按规则手写，不跑被测实现推）：负载 = 锁有活人持 + 活排队号 + 活占位；按（负载，没装这款容器，机号）取最小
#   ① 机号：any → 1 2 3；iphone → 1 2；duo → 3
#   ② 三台都闲、iphone → 1（机号最小）
#   ③ 测试机1 锁有活持有者 → iphone → 2；any → 2（2 与 3 都是 0，机号小）
#   ④ 都闲、测试机2 装着 com.t.g 的容器 → iphone + com.t.g → 2；负对照：不给包名 → 1
#   ⑤ 测试机2 有一个活排队号、测试机1 闲 → iphone → 1；排队号持有者已死 → 不算，iphone → 1 仍因机号；再让测试机1 持锁 → 2（死号不算负载）
#   ⑥ 占位：连选两次 iphone（第一次留下占位、没取锁）→ 1 然后 2；devlock 排号后占位撤掉 → 测试机1 负载回到 1（只算排队号）
#   ⑦ duo → 3；调度暂停 3 → duo 选不到（退 1）
#   ⑧ s2a_device iphone：导出 DEVNUM / DEVCLASS / DEVNAME 指向选中的那台
#   ⑨ 机型类没写（6 列名单，machine.local 的格式）：名字含 Duo 的认 duo，其余 iphone
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; PIDS=
trap 'for p in $PIDS; do kill $p 2> /dev/null; done; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_DEVICES_NO_LOCAL=1 S2A_MACHINE_NO_LOCAL=1 S2A_DEVICE_NO_USB_CHECK=1 S2A_TEST_ROOT=$T/lk S2A_SCHED_DIR=$T/sd; mkdir -p $T/lk $T/sd
. "$H/tools/devices.sh"
L1=$(s2a_device_field 1 lock); L2=$(s2a_device_field 2 lock)
clr() { rm -rf "$T"/lk/*.claim "$T"/lk/*.queue "$L1" "$L2" "$T"/sd/installed "$T"/sd/pause; }
hold() { mkdir -p "$1"; sleep 60 & PIDS="$PIDS $!"; echo $! > "$1/pid"; }
ck "① 机号 any「$(s2a_device_ids any | tr '\n' ' ')」iphone「$(s2a_device_ids iphone | tr '\n' ' ')」duo「$(s2a_device_ids duo | tr '\n' ' ')」" '[ "$(s2a_device_ids any | tr "\n" " ")" = "1 2 3 " ] && [ "$(s2a_device_ids iphone | tr "\n" " ")" = "1 2 " ] && [ "$(s2a_device_ids duo)" = 3 ]'
clr; r2=$(s2a_device_pick iphone)
ck "② 都闲 → iphone 选 ${r2}" '[ "$r2" = 1 ]'
clr; hold "$L1"; r3=$(s2a_device_pick iphone); clr; hold "$L1"; r3a=$(s2a_device_pick any)
ck "③ 测试机1 有人持锁 → iphone 选 ${r3}、any 选 ${r3a}" '[ "$r3" = 2 ] && [ "$r3a" = 2 ]'
clr; mkdir -p $T/sd/installed; : > $T/sd/installed/2_com.t.g; r4=$(s2a_device_pick iphone com.t.g); clr; mkdir -p $T/sd/installed; : > $T/sd/installed/2_com.t.g; r4n=$(s2a_device_pick iphone)
ck "④ 测试机2 装着容器 → 选 ${r4}；不给包名 → ${r4n}" '[ "$r4" = 2 ] && [ "$r4n" = 1 ]'
clr; mkdir -p "${L2%.lock}.queue"; sleep 60 & PIDS="$PIDS $!"; mkdir "${L2%.lock}.queue/0_1_$!"; mkdir "${L2%.lock}.queue/0_2_999999"
r5=$(s2a_device_pick iphone); l5=$(s2a_device_load 2); clr; mkdir -p "${L2%.lock}.queue"; mkdir "${L2%.lock}.queue/0_2_999999"; hold "$L1"; r5b=$(s2a_device_pick iphone)
ck "⑤ 测试机2 一个活号一个死号 → 负载 ${l5}、选 ${r5}；只剩死号且测试机1 持锁 → 选 ${r5b}" '[ "$l5" = 1 ] && [ "$r5" = 1 ] && [ "$r5b" = 2 ]'
clr; a6=$(s2a_device_pick iphone); b6=$(s2a_device_pick iphone); c6=$(s2a_device_load 1)
( DEVLOCK_DIR=$L1; DEVLOCK_QUEUE=${L1%.lock}.queue; . "$H/tools/devlock.sh" 2> /dev/null; DEVLOCK_DIR=$L1; DEVLOCK_QUEUE=${L1%.lock}.queue; devlock_ticket_take 单测 ) ; n6=$(ls "${L1%.lock}.claim" 2> /dev/null | wc -l | tr -d ' ')
ck "⑥ 连选两次 → ${a6} 然后 ${b6}（占位后测试机1 负载 ${c6}）；排号后占位剩 ${n6} 个" '[ "$a6" = 1 ] && [ "$b6" = 2 ] && [ "$c6" = 1 ] && [ "$n6" = 0 ]'
clr; r7=$(s2a_device_pick duo); mkdir -p $T/sd/pause; echo 单测 > $T/sd/pause/3; s2a_device_pick duo > /dev/null 2>&1; r7n=$?
ck "⑦ duo 选 ${r7}；Duo 暂停 → 选不到（退 ${r7n}）" '[ "$r7" = 3 ] && [ "$r7n" = 1 ]'
clr; hold "$L1"; s2a_device iphone 2> /dev/null; o8="$DEVNUM $DEVCLASS $DEVNAME"
ck "⑧ s2a_device iphone 导出「${o8}」" '[ "$o8" = "2 iphone 测试机2" ]'
o9=$(S2A_DEVICES="1|测试机1|a|b|$T/x1.lock|$T/b1
3|Duo|c|d|$T/x3.lock|$T/b3"; s2a_device_ids duo; s2a_device_ids iphone | tr '\n' ' ')
ck "⑨ 6 列名单按名字认类：duo + iphone →「$(echo $o9)」" '[ "$(echo $o9)" = "3 1" ]'
[ $bad = 0 ] && echo "device_balance 单测全过"; exit $bad
