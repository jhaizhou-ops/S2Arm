#!/bin/bash
# 门禁覆盖：tools/train.sh
# 列车日志只写合法 UTF-8（11-06）：train.sh 的 u8() / t() / inbox() 写入口滤掉非法字节，约 1 秒：bash tests/train_log_utf8_test.sh
# 期望（按规则手写，不跑被测实现推）：
#   ① u8 输入「门禁 绿 全量清<半个「单」字的前两个字节>；ok」→ 输出是合法 UTF-8，且「门禁 绿 全量清」「；ok」都在
#   ② 合法输入原样返回
#   ③ t() 与 inbox() 都经 u8（源码里写入口调用了它）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
eval "$(/usr/bin/grep -a '^u8() ' "$H/tools/train.sh")"
in=$(printf '门禁 绿 全量清\xe5\x8d；ok')
o=$(u8 "$in")
v=$(printf '%s' "$o" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8"); print("合法")' 2>/dev/null)
ck "① 截半的汉字被滤掉，前后文都在（${o}）" '[ "$v" = 合法 ] && [ "$o" = "门禁 绿 全量清；ok" ]'
ck "② 合法输入原样" '[ "$(u8 "已合入 x → main 中文🟢")" = "已合入 x → main 中文🟢" ]'
ck "③ t() 与 inbox() 写入口经 u8" '/usr/bin/grep -aq "^t() .*u8 " "$H/tools/train.sh" && /usr/bin/grep -aq "^inbox() { set -- \"\$1\" \"\$(u8 " "$H/tools/train.sh"'
[ $bad = 0 ] && echo "train_log_utf8 单测全过"; exit $bad
