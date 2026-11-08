#!/bin/bash
# 门禁覆盖：tools/gate_plan.sh
# tools/gate_plan.sh gate_tier 大文件列表单测（11-04 合入运维线）：文件列表经管道喂 grep，不走 here-string。
#   期望按规则手写：4000 个 tools/ 路径（约 120 KB）→ tool；再加 1 个 runtime/ 路径 → full；4000 个 docs/*.md → doc。
#   每次判档限 20 秒（卡死即红）。here-string 的两种坏法都依赖环境：管道死等要 macOS 内存紧、管道扩不到 64K；
#   临时文件失败要 /tmp 也写不了（TMPDIR 不可写时 bash 会退回 /tmp），单测里造不出来，所以 ①–④ 对旧写法也是绿的；
#   ⑤ 直接盯机制：gate_tier 函数体里不许有 <<<（旧写法在 ⑤ 红）。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); bad=0
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
T=$(mktemp -d "${TMPDIR:-/tmp}/t_gate_tier_big.XXXXXX"); trap 'rm -rf "$T"' EXIT
TOOLS=$(for i in $(seq 1 4000); do echo "tools/some/long/path/component_$i.sh"; done)
DOCS=$(for i in $(seq 1 4000); do echo "docs/some/long/path/page_$i.md"; done)
tier() {
    [ -n "$T" ] || return 1
    printf '%s' "$1" > "$T/files" || return
    TMPDIR=$T/nope timeout 20 bash -c 'source "$1/tools/gate_plan.sh" && files=$(cat "$2") && gate_tier "$files"' _ "$H" "$T/files" 2> /dev/null
}
chk "① 4000 个 tools/ 路径（$(printf '%s' "$TOOLS" | wc -c | tr -d ' ') 字节）→ tool" tool "$(tier "$TOOLS")"
chk "② 再加 1 个 runtime/ 路径 → full" full "$(tier "$TOOLS"$'\n'"runtime/src/a.c")"
chk "③ 4000 个 docs/*.md → doc" doc "$(tier "$DOCS")"
chk "④ 小列表照旧：docs/a.md + tools/b.sh → tool" tool "$(tier $'docs/a.md\ntools/b.sh')"
body=$(sed -n '/^gate_tier() {/,/^}/p' "$H/tools/gate_plan.sh")
chk "⑤ gate_tier 函数体不用 here-string（<<<）" 0 "$(grep -c '<<<' <<< "$body")"
[ $bad = 0 ] && echo "gate_tier 大文件列表单测全绿" || { echo "gate_tier 大文件列表单测有红"; exit 1; }
