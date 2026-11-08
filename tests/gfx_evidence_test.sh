#!/bin/bash
# 门禁只看：graphics/gate.sh
# gfx 门禁红项证据（evidence）单测：判红行打得早、后面跟一长串输出时，证据里也要看得到它（11-01 审计 P2-54：原先只给末 30 行）。期望按构造手写，约 0 秒
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
eval "$(awk '/^evidence\(\) \{/ { f = 1 } f { print } f && /done; }$/ { exit }' "$H/graphics/gate.sh")"
{ echo '✗ t_probe 第 3 帧不符'; for i in $(seq 1 40); do echo "进度 $i"; done; } > $T/a.log
REDLOGS=$T/a.log; o=$(evidence)
ck "判红行在第 1 行、后跟 40 行：证据里有它（带行号）" 'grep -Fq "1:✗ t_probe 第 3 帧不符" <<< "$o"'
ck "末 30 行照给：最后一行进度 40 在" 'grep -Fq "进度 40" <<< "$o"'
printf '进度 1\n进度 2\n' > $T/b.log; REDLOGS=$T/b.log; o=$(evidence)
ck "没有判红行：不打「判红行」标题，只给末尾" '! grep -Fq 判红行 <<< "$o" && grep -Fq "进度 2" <<< "$o"'
[ $bad = 0 ] && echo "gfx_evidence 单测全过" || { echo "gfx_evidence 单测有不通"; exit 1; }
