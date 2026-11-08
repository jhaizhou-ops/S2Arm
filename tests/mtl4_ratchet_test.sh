#!/bin/bash
# Metal 4 棘轮快检（tools/mtl4_ratchet.py，约 1 秒；10-30 总指挥：gfx 钩子是慢步、入队预检不跑它，MTL4 超基线要等门禁 10 分钟、红还藏在结果段里）：bash tests/mtl4_ratchet_test.sh
# 门禁只看：graphics/metal/gal_* graphics/metal/tools/mtl4_* graphics/nvn/gfx/nvn/* graphics/nvn/gfx/tex/* graphics/nvn/tools/mtl4_* tools/mtl4_ratchet.py
#   ① 本树：渲染器 / 直连两份计数都不超基线（这一项就是入队前的拦截）
#   ② 判定本身（假仓库，期望手写）：基准上 graphics/nvn/gfx/nvn/a.m 有 1 处、基线 1；本支在函数 foo 里加 1 行 id<MTL4Buffer> → 退出 1、点名 a.m:<那行行号>（foo）；
#      再删掉基准原有那 1 处（净 1 处、不超）→ 退出 0；渲染器那份（graphics/metal/gal_x.m）不受影响、通
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o1=$(python3 "$H/tools/mtl4_ratchet.py" 2>&1); r1=$?
ck "① 本树两份计数不超基线（$(tr '\n' ' ' <<< "$o1")）" '[ $r1 = 0 ]'
mkdir -p "$T/tools" "$T/graphics/metal/tools" "$T/graphics/nvn/tools" "$T/graphics/nvn/gfx/nvn"
cp "$H/tools/mtl4_ratchet.py" "$T/tools/"; cp "$H/graphics/metal/tools/mtl4_count.sh" "$T/graphics/metal/tools/"; cp "$H/graphics/nvn/tools/mtl4_count.sh" "$T/graphics/nvn/tools/"
printf 'static void g(void) {\n    MTL4Thing *x = nil; // MTL4Comment\n}\n' > "$T/graphics/metal/gal_x.m"; echo 1 > "$T/graphics/metal/tools/mtl4_baseline.txt"
printf 'static int bar(int a) {\n    id<MTL4Old> o = nil;\n    return a;\n}\n\nstatic void foo(void) {\n    int k = 0;\n}\n' > "$T/graphics/nvn/gfx/nvn/a.m"; echo 1 > "$T/graphics/nvn/tools/mtl4_baseline.txt"
G() { git -C "$T" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
G init -q; G add -A; G commit -qm base; B=$(git -C "$T" rev-parse HEAD)
# 本支：foo 里第 8 行加一处（第 7 行 int k 之后）
printf 'static int bar(int a) {\n    id<MTL4Old> o = nil;\n    return a;\n}\n\nstatic void foo(void) {\n    int k = 0;\n    id<MTL4Buffer> b = nil;   // 新加\n}\n' > "$T/graphics/nvn/gfx/nvn/a.m"; G commit -qam add
o2=$(MTL4_BASE=$B python3 "$T/tools/mtl4_ratchet.py" 2>&1); r2=$?
ck "② 加一处 → 退出 1（rc=${r2}）、点名 a.m:8（foo）、渲染器那份通（$(tr '\n' ' ' <<< "$o2" | cut -c1-260)）" \
   '[ $r2 = 1 ] && grep -q "不通 直连.*2 > 基线 1；新增在 graphics/nvn/gfx/nvn/a.m:8（foo）id<MTL4Buffer> b = nil;" <<< "$o2" && grep -q "^通 渲染器.*1（基线 ≤ 1）" <<< "$o2"'
printf 'static int bar(int a) {\n    return a;\n}\n\nstatic void foo(void) {\n    int k = 0;\n    id<MTL4Buffer> b = nil;\n}\n' > "$T/graphics/nvn/gfx/nvn/a.m"; G commit -qam move
o3=$(MTL4_BASE=$B python3 "$T/tools/mtl4_ratchet.py" nvn 2>&1); r3=$?
ck "② 搬一处（净 1 处、不超基线）→ 退出 0（rc=${r3}，$(tr '\n' ' ' <<< "$o3")）" '[ $r3 = 0 ] && grep -q "^通 直连.*1（基线 ≤ 1）" <<< "$o3"'
[ $bad = 0 ] && echo "MTL4 棘轮快检：期望 3 项全通 → 全通" || { echo "MTL4 棘轮快检：期望 3 项全通 → 有不通"; exit 1; }
