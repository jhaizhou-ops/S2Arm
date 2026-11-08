#!/bin/bash
# 把 compat/tree 的未入补丁改动生成一个新补丁：patches/<生成时刻 YYYYMMDD-HHMM>-<名字>.patch，追加进 series，并在改动清单追加一行。
# 用法：patch_new.sh <名字> <理由（一句话）> [路径…]
#   名字：英文短横线，如 nvdrv-zero-alloc；路径：只收这些路径的改动（相对 compat/tree，缺省收全部）
# 生成后自动跑 verify.sh；提交时 tree 改动、补丁、series、清单放同一笔。
set -euo pipefail
NAME=${1:?"用法：patch_new.sh <名字> <理由> [路径…]"}; WHY=${2:?"要写理由"}; shift 2
[[ "$NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "名字只用小写字母、数字、点、短横线：$NAME" >&2; exit 2; }
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel); cd "$ROOT"
P=compat/patches; L=compat/改动清单.md
mkdir -p "$P"; touch "$P/series"
read -r EXPECT CUR < <(bash compat/verify.sh --trees || true)
[ -n "${EXPECT:-}" ] && [ -n "${CUR:-}" ] || { echo "verify.sh --trees 没给出树（先修好已有补丁）" >&2; exit 2; }
# 补丁名用生成时刻作前缀（10-28 总指挥梳理步 10）：原先按「最大号 + 1」编号，两支并行各自生成都拿到同一个号，合入时撞号要列车续号（train_renumber.py）；
#   时刻前缀两支不会撞，series 与改动清单都是末尾追加、.gitattributes 设 merge=union，并发合入不再冲突。补丁顺序以 series 为准，与名字无关
F="$(date +%Y%m%d-%H%M)-$NAME.patch"
[ -e "$P/$F" ] && { echo "同名补丁已存在：${P}/${F}（同一分钟内同名生成两次？改名或等一分钟）" >&2; exit 2; }
git diff-tree -p --binary --full-index --no-renames "$EXPECT" "$CUR" -- "$@" > "$P/$F"
[ -s "$P/$F" ] || { rm -f "$P/$F"; echo "没有可生成补丁的改动（树内源码已等于上游 + 补丁）" >&2; exit 1; }
FILES=$(git diff-tree -r --name-only --no-renames "$EXPECT" "$CUR" -- "$@" | sed 's|^src/||' | awk 'NR > 1 { printf "、" } { printf "%s", $0 }')   # 不用 paste -sd：BSD paste 把分隔符当逐字节轮换的列表，多字节「、」会被拆成三个半字符轮流插入
echo "$F" >> "$P/series"
[ -f "$L" ] || { echo "缺 $L" >&2; exit 2; }
printf '| %s | %s | %s |\n' "$F" "$FILES" "$WHY" >> "$L"
echo "已生成 $P/${F}（$(grep -c '^diff --git' "$P/$F") 个文件）"
bash compat/verify.sh
