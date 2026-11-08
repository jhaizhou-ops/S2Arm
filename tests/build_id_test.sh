#!/bin/bash
# 包号函数单测（pack/build_id.sh → pack/ipa_tail.py build_id）：期望值按一键出包原公式手算（cut 首段 + 对 .stage_pkg 文件 shasum），不经过被测函数；
#   着色器目标 / 画面模式 / Info.plist 写入在 tests/test_ipa_tail.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
. "$H/pack/build_id.sh"
PK='8cf4073a1 cur=/x/roots/botw@sh-1 vamm=alias sign=adhoc'; echo "$PK" > $T/.stage_pkg
exp=$(cut -d' ' -f1 $T/.stage_pkg)-$(shasum -a 256 < $T/.stage_pkg | cut -c1-8); got=$(s2a_build_id "$PK"); got2=$(s2a_build_id "$(cat $T/.stage_pkg)")
ck "包号 = 一键出包原公式（${exp}）：ipa.sh 传包键（${got}）、oneclick 读文件（${got2}）都一致" '[ "$got" = "$exp" ] && [ "$got2" = "$exp" ]'
ck "包号格式 <提交号>-<8 位十六进制>" '[[ $got =~ ^8cf4073a1-[0-9a-f]{8}$ ]]'
# 源码树干净才出（11-02 总指挥）：开发树有未提交改动 → 拒；发布快照（根有 engine.json）不判，哪怕有未跟踪的编译产物；开发树干净 → 放行。期望按规则手写
SD=$(sed -n '/^src_dirty() {/p' "$H/pack/ipa.sh"); E=$T/eg; mkdir -p $E/graphics; (cd $E && git init -q && echo a > graphics/a.c && git add -A && git -c user.name=t -c user.email=t@t commit -qm a)
d0=$(bash -c "$SD; src_dirty $E && echo 拒 || echo 放"); echo b >> $E/graphics/a.c; d1=$(bash -c "$SD; src_dirty $E && echo 拒 || echo 放")
git -C $E checkout -q -- graphics/a.c; mkdir -p $E/graphics/obj; echo o > $E/graphics/obj/x; echo '{}' > $E/engine.json; d2=$(bash -c "$SD; src_dirty $E && echo 拒 || echo 放")
ck "源码树检查：开发树干净→放（${d0}）、开发树改了没提交→拒（${d1}）、发布快照带编译产物→放（${d2}）；ipa.sh 用它把关" '[ -n "$SD" ] && [ "$d0" = 放 ] && [ "$d1" = 拒 ] && [ "$d2" = 放 ] && grep -qF '"'"'src_dirty "$R" && { echo "【红】本树构建相关目录有未提交改动'"'"' "$H/pack/ipa.sh"'
# 出包失败留证（10-23 用户体验线）：fail() 先把 build.log 拷进 $S2A_ROOTS/.failed/<款>_ipa_build.log 再清临时版本；make ios 报错取头一条 error 行
W=$T/w; mkdir -p $W/pkg; printf 'cc a.c\nsrc/a.c:3:10: fatal error: '"'"'platform/plat.h'"'"' file not found\n1 error generated.\nmake: *** [ios] Error 1\n' > $W/pkg/build.log
o=$(cd $T && G=xc3 TAG=t W=$W S2A_ROOTS=$T/roots bash -c "root_abort() { rm -rf \"\$W\"; }; $(sed -n '/^fail() {/,/^  echo .*exit 1; }$/p;/^errline()/p' $H/pack/ipa.sh)
fail \"make ios 失败（\$(errline \$W/pkg/build.log)）\"" 2>&1)
ck "失败报错带头一条 error 行、build.log 留在 .failed/xc3_ipa_build.log、临时版本已清（${o}）" 'grep -q "fatal error: .platforms/plat.h. file not found" <<< "$o" && grep -q "日志 $T/roots/.failed/xc3_ipa_build.log" <<< "$o" && grep -q "1 error generated" $T/roots/.failed/xc3_ipa_build.log && [ ! -d $W ]'
TAILCALL='"$H/ipa_tail.py" --work "$W"'
ck "ipa.sh 出包收尾调 pack/ipa_tail.py（包号 / 着色器目标 / 画面模式在那里写）" 'grep -qF "$TAILCALL" "$H/pack/ipa.sh"'
[ $bad = 0 ] && echo "build_id 单测全过" || exit 1
