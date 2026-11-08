#!/bin/bash
# 门禁只看：pack/shell/closure.py pack/stage_inputs/shell.tsv pack/*.py tools/*.py
# 壳输入表 Python import 闭包（pack/shell/closure.py pyimports，不出壳的静态核对，约 1 秒）：bash tests/shell_pyimports_test.sh
# 起因（11-06 总指挥）：列车没有出壳这一步，#1586 让 pack/ship_ext.py 在模块顶层 import 新增的 tools/module_order.py、
#   没登记进 pack/stage_inputs/shell.tsv 就合进了 main，全线出壳红。这里在列车上就把这类漏登记拦下。
# 期望（按规则手写，不跑被测实现推）：临时 git 仓库，表里「入」pack/a.py
#   ① a.py 顶层 sys.path.insert 到 tools 后 import x（tools/x.py 没登记）→ 红，点名 tools/x.py
#   ② 表里加「入 tools/x.py」→ 绿
#   ③ x.py 顶层再 import y（tools/y.py 没登记）→ 红，点名 tools/y.py（递归）
#   ④ 函数里的延迟 import z（tools/z.py 没登记）→ 不算（出壳不一定走到），绿
#   ⑤ 「from pkg import m」：仓库根有目录包 pkg/m.py（已登记），pack/ 下另有同名 pkg.py（没登记）→ 按仓库根解析到 pkg/m.py，绿
#   ⑥ 真仓库：当前表下 0 个漏登记
set -u
H=$(cd "$(dirname "$0")/.." && pwd); C=$H/pack/shell/closure.py; T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/r; mkdir -p "$R/pack/stage_inputs" "$R/tools" "$R/pkg"; git -C "$R" init -q
printf 'import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))\nimport x\n' > "$R/pack/a.py"
printf 'V = 1\n' > "$R/tools/x.py"; printf 'W = 1\n' > "$R/tools/y.py"; printf 'Z = 1\n' > "$R/tools/z.py"; printf 'M = 1\n' > "$R/pkg/m.py"; printf 'P = 1\n' > "$R/pack/pkg.py"
printf '入\tpack/a.py\n' > "$R/pack/stage_inputs/shell.tsv"
git -C "$R" add -A
o1=$(python3 "$C" pyimports "$R" 2>&1); r1=$?
ck "① 顶层 import 没登记的 tools/x.py → 红（rc=${r1}）" '[ $r1 = 1 ] && grep -q "tools/x.py" <<< "$o1"'
printf '入\tpack/a.py\n入\ttools/x.py\n' > "$R/pack/stage_inputs/shell.tsv"
o2=$(python3 "$C" pyimports "$R" 2>&1); r2=$?
ck "② 登记后 → 绿（rc=${r2}）" '[ $r2 = 0 ]'
printf 'import y\nV = 1\n' > "$R/tools/x.py"
o3=$(python3 "$C" pyimports "$R" 2>&1); r3=$?
ck "③ 递归：x 顶层 import 没登记的 y → 红点名 tools/y.py（rc=${r3}）" '[ $r3 = 1 ] && grep -q "tools/y.py" <<< "$o3" && ! grep -q "tools/x.py" <<< "$o3"'
printf 'V = 1\ndef f():\n    import z\n    return z\n' > "$R/tools/x.py"
o4=$(python3 "$C" pyimports "$R" 2>&1); r4=$?
ck "④ 函数里的延迟 import 不算 → 绿（rc=${r4}）" '[ $r4 = 0 ]'
printf 'import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))\nimport x\nfrom pkg import m\n' > "$R/pack/a.py"
printf '入\tpack/a.py\n入\ttools/x.py\n入\tpkg/m.py\n' > "$R/pack/stage_inputs/shell.tsv"
o5=$(python3 "$C" pyimports "$R" 2>&1); r5=$?
ck "⑤ from pkg import m 按仓库根目录包解析，不误认同目录 pack/pkg.py → 绿（rc=${r5}：${o5}）" '[ $r5 = 0 ]'
o6=$(python3 "$C" pyimports "$H" 2>&1); r6=$?
ck "⑥ 真仓库当前表：${o6}" '[ $r6 = 0 ]'
[ $bad = 0 ] && echo "shell_pyimports 单测全过"; exit $bad
