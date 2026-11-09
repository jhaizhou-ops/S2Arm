#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：android/README.md android/*/README.md tools/readme_links.py tests/readme_links_test.sh
# android/ 下 README 不许引用仓库里没有的 Markdown 文件：bash tests/readme_links_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o=$(python3 "$H/tools/readme_links.py" "$H" 2>&1); r=$?
ck "本仓库：0 处悬空（$(tail -1 <<< "$o")）" '[ $r = 0 ]'
[ $r = 0 ] || echo "$o"
git init -q "$T/r"; mkdir -p "$T/r/android/sub" "$T/r/docs"; echo x > "$T/r/docs/real.md"; echo x > "$T/r/android/sub/near.md"
printf '[ok](near.md) [web](https://example.com/a.md) `docs/real.md`\n```\n[fence](gone-in-fence.md)\n```\n' > "$T/r/android/sub/README.md"
git -C "$T/r" add -A
o=$(python3 "$H/tools/readme_links.py" "$T/r" 2>&1); r=$?
ck "存在的引用、外链、代码块里的文字都不报" '[ $r = 0 ]'
printf '[dead](gone.md)\n`docs/secret/plan.md`\n' > "$T/r/android/README.md"; git -C "$T/r" add -A
o=$(python3 "$H/tools/readme_links.py" "$T/r" 2>&1); r=$?
ck "死链和行内路径都报红（rc=${r}）" '[ $r = 1 ] && grep -q "android/README.md: gone.md" <<< "$o" && grep -q "android/README.md: docs/secret/plan.md" <<< "$o"'
[ $bad = 0 ] && echo "readme_links 单测全过" || echo "readme_links 单测有不通"
exit $bad
