#!/bin/bash
# 门禁覆盖：pack/shell/closure.py pack/shell_build.sh pack/stage_inputs/shell.tsv tests/test_shell_closure.py
# 壳输入闭包单测（pack/shell/closure.py：访问时间设旧 → 读入点名、表外报红、全量重读判核不了、建议表收目录，约 1 秒）：bash tests/shell_closure_test.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -B tests/test_shell_closure.py
