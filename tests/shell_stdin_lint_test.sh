#!/bin/bash
# 门禁覆盖：tests/shell_stdin_lint.py tests/shell_stdin_lint_test.py tests/shell_lint_test.sh
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/shell_stdin_lint_test.py"
