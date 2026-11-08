#!/bin/bash
# Mac 局默认存档单测（tools/mac_save.sh，runtime/run_mac.sh 调）：临时产物根 / 存档目录，约 1 秒
#   期望（按规则手写）：① 没显式给 S2A_SAVE_DIR → 按 exefs/main 0x40 起 16 字节的构建号找到 <款>_<构建号>，拷成局目录 save/ 副本、S2A_SAVE_DIR 指副本、system_time 带上；
#   ② 局里改副本，原件不变；③ 显式给了 S2A_SAVE_DIR → 照用、不拷；④ 没有这份存档 → 不带、不报错
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/in/exefs; { head -c 64 /dev/zero; printf '\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff'; head -c 32 /dev/zero; } > $T/in/exefs/main
BID=00112233445566778899aabbccddeeff; mkdir -p $T/saves/acnh_$BID/device; echo 原件 > $T/saves/acnh_$BID/device/a.bin; echo 1700000000 > $T/saves/acnh_$BID/system_time
run() { ( unset S2A_SAVE_DIR S2A_SYSTEM_TIME; [ -n "${EXPL:-}" ] && export S2A_SAVE_DIR=$EXPL; export S2A_SAVES=$T/saves; source $H/tools/mac_save.sh; mac_save_prep "$1" $T/in "$2" > "$2.out"; echo "${S2A_SAVE_DIR:-}|${S2A_SYSTEM_TIME:-}" ) ; }
o=$(run acnh $T/d1)
ck "① 缺省：S2A_SAVE_DIR 指局目录副本、内容同原件、system_time 带上（${o}）" '[ "$o" = "$T/d1/save|1700000000" ] && [ "$(cat $T/d1/save/device/a.bin)" = 原件 ]'
echo 局里改了 > $T/d1/save/device/a.bin
ck "② 改副本、原件不变" '[ "$(cat $T/saves/acnh_$BID/device/a.bin)" = 原件 ]'
o=$(EXPL=$T/mine run acnh $T/d2)
ck "③ 显式给了 S2A_SAVE_DIR → 照用、不拷（${o}）" '[ "${o%%|*}" = "$T/mine" ] && [ ! -e $T/d2/save ]'
o=$(run botw $T/d3)
ck "④ 没有该款存档 → 不带、不报错（${o}）" '[ "$o" = "|" ] && [ ! -e $T/d3/save ] && grep -q 不带存档 $T/d3.out'
# ⑤ 存档类型对不上游戏（10-27 动森设备存档被放成 account/）：产物根 control.nacp 账户 0、设备 >0 → account/ 存档报红、不起局（显式 / 缺省两条路）；device/ 照常
mkdir -p $T/in/ctl; python3 -c "import struct,sys; b=bytearray(0x4000); struct.pack_into('<4q',b,0x3080,0,0,4096,4096); open(sys.argv[1],'wb').write(b)" $T/in/ctl/control.nacp
mkdir -p $T/acc/account; echo x > $T/acc/account/main.dat
o=$(EXPL=$T/acc run acnh $T/d5); r5=$(grep -c '类型放错' $T/d5.out)
ck "⑤a 显式给 account/、游戏只用设备存档 → 报红（${o}）" '[ "$r5" = 1 ]'
o=$(run acnh $T/d6)
ck "⑤b 缺省找到 device/、游戏用设备存档 → 照常带上（${o}）" '[ "${o%%|*}" = "$T/d6/save" ] && ! grep -q 类型放错 $T/d6.out'
( unset S2A_SAVE_DIR; export S2A_SAVE_DIR=$T/acc; source $H/tools/mac_save.sh; mac_save_prep acnh $T/in $T/d7 > /dev/null ); r7=$?
ck "⑤c 类型放错时 mac_save_prep 返回非 0（run_mac 据此不起局）" '[ $r7 != 0 ]'
cp $T/in/ctl/control.nacp $T/nacp.ok; head -c 100 $T/nacp.ok > $T/in/ctl/control.nacp
o=$(EXPL=$T/acc run acnh $T/d8); r8=$(grep -c '读不出' $T/d8.out)
ck "⑤d control.nacp 截断读不出 → 报红、不放行（审计 P2-57；${o}）" '[ "$r8" = 1 ]'
cp $T/nacp.ok $T/in/ctl/control.nacp
rm -rf $T/in/ctl
# ⑥ 存档标了不能自动用（11-06 鬼灭社区档：游戏读不了、整局卡死）：有 不兼容.txt / 待核.txt → 缺省不带、不报错，说明原因
for f in 不兼容 待核; do echo 测试 > $T/saves/acnh_$BID/$f.txt; o=$(run acnh $T/d9$f); rm -f $T/saves/acnh_$BID/$f.txt
  ck "⑥ 有 $f.txt → 缺省不带存档（${o}）" '[ "$o" = "|" ] && [ ! -e $T/d9'$f'/save ] && grep -q "$f.txt" $T/d9'$f'.out'; done
ck "接线：runtime/run_mac.sh 调 mac_save_prep、mac_health.sh 不再直接给原件路径" 'grep -q "mac_save_prep" $H/runtime/run_mac.sh && ! grep -q "export S2A_SAVE_DIR=\$sa" $H/tools/mac_health.sh'
[ $bad = 0 ] && echo "mac_save 单测全过" || { echo "mac_save 单测有不通"; exit 1; }
