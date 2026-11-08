#!/bin/bash
# 工作树换分支安全阀（10-25 总指挥 / jhz「一改动一工作树，换分支前查有没有进程在用」；10-24 夜三次在后台入队 / 出包正用的树里切分支，测成错的内容、包成两个提交的混合）：
#   tools/wt.sh busy [<工作树>]               在用这棵树的进程（当前目录在树里，或命令行带树的路径）；退出 0 = 有人在用，1 = 空闲
#   tools/wt.sh switch <分支> [<工作树>] [-b]  空闲才 git checkout（-b = 新建分支）；有人在用 → 列出进程、拒绝、退出 2
# 只做这一个检查，不加别的流程。<工作树> 缺省当前目录所在的工作树
set -u
tree() { git -C "${1:-.}" rev-parse --show-toplevel 2> /dev/null; }
busy() {   # busy <树> → 打「pid 命令」，有就退出 0
  local t=$1 me=$$ pp=$PPID found=1 p
  for p in $( { lsof -a -d cwd -Fp +D "$t" 2> /dev/null | sed -n 's/^p//p'; pgrep -f -- "$t/" 2> /dev/null; pgrep -f -- "$t\$" 2> /dev/null; } | sort -un); do
    [ "$p" = "$me" ] || [ "$p" = "$pp" ] && continue
    ps -o command= -p "$p" 2> /dev/null | grep -q "tools/wt.sh" && continue   # 本工具自己（子 shell）
    echo "$p $(ps -o command= -p "$p" 2> /dev/null | cut -c1-160)"; found=0
  done; return $found; }
case ${1:-} in
  busy) t=$(tree "${2:-.}") || { echo "【红】${2:-.} 不在 git 工作树里"; exit 2; }; busy "$t" && exit 0 || { echo "空闲：$t"; exit 1; };;
  switch)
    b=${2:?分支}; t=$(tree "${3:-.}") || { echo "【红】${3:-.} 不在 git 工作树里"; exit 2; }
    if out=$(busy "$t"); then echo "【红】$t 有进程在用，不换分支（换了会让它们读到另一个提交的文件）："; echo "$out" | sed 's/^/  /'; echo "  另开一棵：git worktree add <新目录> $b"; exit 2; fi
    if [ "${4:-}" = -b ]; then git -C "$t" checkout -q -b "$b"; else git -C "$t" checkout -q "$b"; fi && echo "已切到 ${b}（${t}）";;
  *) echo "用法：tools/wt.sh busy [<工作树>] | switch <分支> [<工作树>] [-b]"; exit 2;;
esac
