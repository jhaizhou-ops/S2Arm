#!/bin/bash
# 门禁覆盖：tools/sysdialog.sh tools/screen_text.swift
# 测试机系统弹框分类单测（tools/sysdialog.sh）：注入假认字（S2A_OCR），期望类别与该点的按钮按规则手写；另编一次 screen_text.swift（真认字工具能编过）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1（实得：${R}）"; bad=$((bad + 1)); fi; }
printf 'png' > $T/s.png
cls() { printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$1" > $T/ocr.sh; chmod +x $T/ocr.sh; R=$(S2A_OCR=$T/ocr.sh bash "$H/tools/sysdialog.sh" "${2:-$T/s.png}"); }
cls '"软件更新" "“iOS 27.0.1”已经可以安装。" "现在安装" "稍后"'; ck "软件更新框 → 软件更新、点「稍后」" '[[ $R == 软件更新$'"'"'\t'"'"'点「稍后」* ]]'
cls '"允许“S2Arm”使用无线数据？" "关闭" "无线局域网与蜂窝网络"'; ck "无线数据框 → 无线数据、请 jhz 选「仅限无线局域网」（不再写点「不允许」）" '[[ $R == 无线数据$'"'"'\t'"'"'请\ jhz\ 选「仅限无线局域网」* ]]'
cls '"Software Update" "iOS 27.0.1 is available to install" "Later"'; ck "英文软件更新框 → 软件更新" '[[ $R == 软件更新* ]]'
cls '"“S2Arm”想访问你的通讯录" "好" "不允许"'; ck "别的系统框 → 其他系统框、看截图手动处理（不冒充无线数据 / 软件更新）" '[[ $R == 其他系统框$'"'"'\t'"'"'看截图\ s.png* ]]'
cls '""'; ck "截图认不出字 → 未识别、看截图" '[[ $R == 未识别$'"'"'\t'"'"'截图没认出字* ]]'
cls '"软件更新"' $T/none.png; ck "没截到图 → 未识别、到测试机上看（不调认字）" '[[ $R == 未识别$'"'"'\t'"'"'没截到图* ]]'
swiftc -O "$H/tools/screen_text.swift" -o $T/screen_text > $T/swiftc.log 2>&1; R=$(tail -2 $T/swiftc.log); ck "screen_text.swift 编得过" '[ -x $T/screen_text ]'
R=$($T/screen_text $T/s.png 2>&1; echo "rc=$?"); ck "认字工具读不出图 → 退出 2、不出假文字" '[[ $R == *rc=2 ]]'
echo "$([ $bad = 0 ] && echo ✓ || echo ✗) sysdialog：不通 $bad"; [ $bad = 0 ]
