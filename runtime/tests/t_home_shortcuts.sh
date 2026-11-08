#!/bin/bash
# 主屏长按快捷操作单测（ios/shortcuts.json → runtime/build.mk 写进 Info.plist → ios/app.m home_shortcut 处理）：bash runtime/tests/t_home_shortcuts.sh
# 期望值手写（不跑被测实现）：三项 类型 / 标题 = dev.s2arm.save 存档管理、dev.s2arm.diag 导出诊断包、dev.s2arm.settings 设置
# ① 用 build.mk 同一条 plutil 命令写进空 Info.plist，读回三项按序对上；② json 里每个类型在 app.m 都有处理分支、app.m 处理的类型都在 json 里（两边不漂）；
# ③ build.mk 确实有这条写入（防止被删了单测还绿）
set -u; H=$(cd "$(dirname "$0")/../.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/home_sc.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; bad=1; fi; }
cd "$H"
/usr/bin/plutil -create xml1 "$T/Info.plist"
cmd=$(sed -n 's/^.*\(\/usr\/bin\/plutil -insert UIApplicationShortcutItems -json "\$\$(cat ios\/shortcuts.json)"\).*$/\1/p' runtime/build.mk | head -1)
ck "③ build.mk 写入 UIApplicationShortcutItems" '[ -n "$cmd" ]'
/usr/bin/plutil -insert UIApplicationShortcutItems -json "$(cat ios/shortcuts.json)" "$T/Info.plist" 2> "$T/err"
got=$(python3 -c 'import plistlib,sys; print("|".join(i["UIApplicationShortcutItemType"]+"="+i["UIApplicationShortcutItemTitle"] for i in plistlib.load(open(sys.argv[1],"rb"))["UIApplicationShortcutItems"]))' "$T/Info.plist" 2>> "$T/err")
ck "① Info.plist 三项按序（实为 ${got:-空}）" '[ "$got" = "dev.s2arm.save=存档管理|dev.s2arm.diag=导出诊断包|dev.s2arm.settings=设置" ]'
js=$(python3 -c 'import json; print(" ".join(sorted(i["UIApplicationShortcutItemType"] for i in json.load(open("ios/shortcuts.json")))))')
am=$(sed -n '/^static void home_shortcut/,/^}/p' ios/app.m | grep -o '@"dev\.s2arm\.[a-z]*"' | tr -d '@"' | sort -u | tr '\n' ' ' | sed 's/ $//')
ck "② json 类型（${js}）与 app.m 处理分支（${am}）一致" '[ "$js" = "$am" ]'
ck "② 冷启动 / 运行中两个入口都接到 home_shortcut" 'grep -q "options.shortcutItem) home_shortcut(options.shortcutItem.type, YES" ios/app.m && grep -q "performActionForShortcutItem" ios/app.m'
[ $bad = 0 ] && echo "主屏快捷操作单测全过" || { cat "$T/err"; exit 1; }
