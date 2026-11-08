#!/bin/bash
# 门禁覆盖：*.sh tests/macos_only_ok.tsv tests/macos_only_lint.py tests/macos_only_lint_test.py
# macOS 专有命令用法（cp -c / stat -f / sed -i ''）必须带退回或在 Darwin 判断里，只在 Mac 跑的存量脚本登记 tests/macos_only_ok.tsv（11-01：oneclick 交付拷贝 Linux 上 5 条不通）。
# 先跑检查器自己的单测（负对照：修前 oneclick 两行 → 报），再扫全仓库：bash tests/macos_only_lint_test.sh
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/macos_only_lint_test.py" > /dev/null 2>&1 || { python3 "$H/tests/macos_only_lint_test.py"; exit 1; }
python3 "$H/tests/macos_only_lint.py" "$H"
