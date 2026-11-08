#!/bin/bash
# 自动玩家缺省开关单测（tests/autoplay/ap_default.h）：同一份判定按「开发用 Mac 宿主」和「Mac 前端（S2A_MAC_FRONTEND=1）」各编一次，逐个环境变量组合核期望（期望按需求手写）
set -u
H=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'C'
#include "ap_default.h"
#include <stdio.h>
int main(int c, char **v) { const char *a = c > 1 && v[1][0] != '-' ? v[1] : NULL; printf("%d\n", s2a_autoplay_default(a)); return 0; }
C
clang -O1 -Wall -Werror -include "$H/autoplay/ap_default.h" -I"$H/autoplay" -o "$T/dev" "$T/t.c" || exit 1
clang -O1 -Wall -Werror -DS2A_MAC_FRONTEND=1 -include "$H/autoplay/ap_default.h" -I"$H/autoplay" -o "$T/front" "$T/t.c" || exit 1
bad=0
ck() { local got; got=$("$T/$1" "$2"); if [ "$got" = "$3" ]; then echo "通 $4（$1：期望 $3 → 真结果 ${got}）"; else echo "不通 $4（$1：期望 $3 → 真结果 ${got}）"; bad=1; fi; }
#   参数：构建 S2A_AUTOPLAY（- = 不设）期望 说明
ck front - 0 "Mac 前端：玩家从 App 起游戏、什么都不设 → 不开"
ck front 1 1 "Mac 前端：测试局显式 S2A_AUTOPLAY=1 → 开"
ck front 0 0 "Mac 前端：显式 0 → 不开"
ck dev - 1 "开发用 Mac 宿主：什么都不设 → 开（run_mac.sh / 真值局照旧）"
ck dev 0 0 "开发用 Mac 宿主：显式 0 → 不开"
ck dev 1 1 "开发用 Mac 宿主：显式 1 → 开"
[ $bad = 0 ] && echo "autoplay_default 单测全过" || { echo "autoplay_default 单测有不通"; exit 1; }
