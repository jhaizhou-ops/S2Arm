#!/bin/bash
# 门禁覆盖：tools/thanks_list.py
# README 联合开发者名单补新人（tools/thanks_list.py）单测：bash tests/thanks_list_test.sh，约 1 秒，不联网（--events 给假数据）
#   期望按规则手写：现有 a、b；事件 c(03)、b(01)、d(02)、bot[bot]、类型 Bot 的 e、维护方 jhaizhou-ops、c 再来一次(04)、大小写不同的 A
#   → 只补 d、c（按首次时间：d 02 < c 03），已有的 a、b 顺序不动；中英两份都改、结尾标点不变；再跑一遍要补 0 人（幂等）；
#   改写表里的账号（fucknima）显示打码、链接原账号，再跑不重复补
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/tools"; cp "$H/tools/thanks_list.py" "$T/tools/"
printf '# x\n- **联合开发者**：感谢（按首次贡献时间）：[@a](https://github.com/a), [@b](https://github.com/b)。\n- **别的**：x\n' > "$T/README.zh-CN.md"
printf '# x\n- **Co-developers**: thanks (in order): [@a](https://github.com/a), [@b](https://github.com/b).\n- **Other**: x\n' > "$T/README.md"
cat > "$T/ev.json" <<'J'
[{"login":"c","created_at":"2026-01-03T00:00:00Z","type":"User"},{"login":"b","created_at":"2026-01-01T00:00:00Z","type":"User"},
 {"login":"d","created_at":"2026-01-02T00:00:00Z","type":"User"},{"login":"bot[bot]","created_at":"2026-01-01T00:00:00Z","type":"Bot"},
 {"login":"e","created_at":"2026-01-01T00:00:00Z","type":"Bot"},{"login":"jhaizhou-ops","created_at":"2026-01-01T00:00:00Z","type":"User"},
 {"login":"c","created_at":"2026-01-04T00:00:00Z","type":"User"},{"login":"A","created_at":"2026-01-01T00:00:00Z","type":"User"}]
J
o=$(python3 "$T/tools/thanks_list.py" --events "$T/ev.json"); r=$?
ck "只列不写：要补 d、c（rc=${r}：${o}）" '[ $r = 0 ] && [[ "$o" == *"要补 2 人：d, c"* ]] && ! grep -q "@d" "$T/README.md"'
o=$(python3 "$T/tools/thanks_list.py" --events "$T/ev.json" --write); r=$?
ck "写入：中文行 = a、b、d、c 且以「。」结尾（rc=${r}）" '[ $r = 0 ] && grep -qF "[@a](https://github.com/a), [@b](https://github.com/b), [@d](https://github.com/d), [@c](https://github.com/c)。" "$T/README.zh-CN.md"'
ck "写入：英文行同序、以「.」结尾，别的行不动" 'grep -qF "[@b](https://github.com/b), [@d](https://github.com/d), [@c](https://github.com/c)." "$T/README.md" && grep -qx -- "- \*\*Other\*\*: x" "$T/README.md"'
o=$(python3 "$T/tools/thanks_list.py" --events "$T/ev.json"); ck "幂等：再跑要补 0 人（${o}）" '[[ "$o" == *"要补 0 人"* ]]'
# 显示名改写表：表里的账号照样列出、显示文字打码（星号转义）、链接保留原账号；再跑按链接认人、不重复补
printf '[{"login":"fucknima","created_at":"2026-01-05T00:00:00Z","type":"User"}]' > "$T/ev2.json"
python3 "$T/tools/thanks_list.py" --events "$T/ev2.json" --write > /dev/null
ck "改写表：显示 f 加 7 个转义星号、链接原账号，中英都有" 'grep -qF "[@c](https://github.com/c), [@f\\*\\*\\*\\*\\*\\*\\*](https://github.com/fucknima)。" "$T/README.zh-CN.md" && grep -qF "(https://github.com/fucknima)." "$T/README.md" && ! grep -q "\[@fucknima\]" "$T/README.md"'
o=$(python3 "$T/tools/thanks_list.py" --events "$T/ev2.json"); ck "改写过的人按链接认出、再跑要补 0 人（${o}）" '[[ "$o" == *"要补 0 人"* ]]'
printf '# x\n- **Co-developers**: thanks: [@a](https://github.com/a).\n' > "$T/README.md"
o=$(python3 "$T/tools/thanks_list.py" --events "$T/ev.json" 2>&1); r=$?
ck "中英现有名单不一致 → 退 1、点名（rc=${r}）" '[ $r = 1 ] && [[ "$o" == *不一致* ]]'
[ $bad = 0 ] && echo "thanks_list 单测全过" || { echo "thanks_list 单测有不通"; exit 1; }
