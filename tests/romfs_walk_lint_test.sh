#!/bin/bash
# RomFS 只遍历一次的守卫单测（tools/romfs_walk_lint.py + graphics/nvn/tools/romfs_list.py，约 3 秒）：bash tests/romfs_walk_lint_test.sh
# 期望（按规则手写）：
#   ① 本仓库：除 romfs_list.py 外没有 RomFS 目录遍历（白名单逐条有理由、没有过期条目）
#   ② 坏写法夹具都报：Python os.walk(romfs) / 由含 romfs 的式子赋值的变量 / 递归 glob；shell 阶段交 RomFS 的工具里裸 os.walk；
#      find "$X/romfs"、cd "$X/romfs" && find .；内嵌 Python 段开头带 RomFS；C# 在提到 romfs 的文件里 Directory.EnumerateFiles
#   ③ 好写法夹具不报：romfs_list.walk / heads、os.walk(输出目录)、find 产物目录、du romfs.s2aidx、romfs_list.py has-ext
#   ④ 清单模块单测 tests/romfs_list_test.py 全过（与 os.walk / find / open().read(32) 逐项对拍）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o=$(python3 "$H/tools/romfs_walk_lint.py" "$H" 2>&1); r=$?
ck "① 本仓库 RomFS 目录遍历只在 romfs_list.py（命中：${o:0:400}）" '[ $r = 0 ] && [ -z "$o" ]'
mkdir -p "$T/r/pack" "$T/r/tools" "$T/r/svc" && cd "$T/r" && git init -q .
cat > pack/bad1.py <<'X'
import os
def a(root):
    for d, _, fs in os.walk(os.path.join(root, 'romfs')): pass
def b(root):
    rf = os.path.join(root, 'romfs')
    return sorted(os.listdir(rf))
def c(root):
    import glob
    return glob.glob(os.path.join(root, 'romfs', '**', 'x'), recursive=True)
X
cat > tools/recv.py <<'X'
import os, sys
for d, _, fs in os.walk(sys.argv[1]): pass
X
cat > pack/bad2.sh <<'X'
python3 "$R/tools/recv.py" "$W/romfs"
if [ -n "$(find "$W/romfs" -iname '*.pak' -print -quit)" ]; then :; fi
FL=$(cd "$OV/romfs" && find . -type f)
KR=$(python3 - "$CUR/romfs" <<'PY'
import os, sys
for d, ds, fs in os.walk(sys.argv[1]): pass
PY
)
X
cat > svc/Bad.cs <<'X'
// 预建 romfs 索引
foreach (string f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) { }
X
cat > pack/good1.py <<'X'
import os, romfs_list
def a(root, out):
    for d, _, fs in romfs_list.walk(os.path.join(root, 'romfs')): pass
    t = romfs_list.heads(os.path.join(root, 'romfs'))
    for d, _, fs in os.walk(out): pass
X
cat > pack/good2.sh <<'X'
find "$W/extract" -name '*.log' -print
echo "$(du -h "$CUR/romfs.s2aidx" | cut -f1)"
"$PY" "$R/graphics/nvn/tools/romfs_list.py" has-ext "$W/romfs" .pak
X
git add -A
o=$(python3 "$H/tools/romfs_walk_lint.py" "$T/r" 2>&1)
for want in "pack/bad1.py:3: a:walk" "pack/bad1.py:6: b:listdir" "pack/bad1.py:9: c:glob" "tools/recv.py:2: <module>:walk" "pack/bad2.sh:2: \$W/romfs" "pack/bad2.sh:3: \$OV/romfs" "pack/bad2.sh:6: 内嵌 Python" "svc/Bad.cs:2:"; do
  ck "② 坏写法报出：$want" 'grep -qF "$want" <<< "$o"'
done
ck "③ 好写法不报（命中：$(grep -E 'good[12]' <<< "$o" | head -3)）" '! grep -qE "good[12]" <<< "$o"'
cd "$H" || exit 1
o=$(python3 tests/romfs_list_test.py 2>&1); r=$?
ck "④ 清单模块单测（$(tail -1 <<< "$o")）" '[ $r = 0 ]'
[ $bad = 0 ] && echo "romfs_walk_lint 单测全过" || { echo "romfs_walk_lint 单测有不通"; exit 1; }
