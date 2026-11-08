#!/bin/bash
# 换链窗口工具单测（translator/dmsh_chain_window.py）。10-30 起链号只随 ABI 变：只改翻译器 → --touches 不换链（退出 1）但列出改到的翻译文件；
#   改 ABI → 换链（退出 0）；合并只在头文件上冲突 → --resolve 写回合并后树上 dmsh_chain.py 算出的链号与 ABI；两边都改 ABI（链文件也冲突）→ --resolve 拒绝、头文件不动。
#   期望链号一律由 dmsh_chain.py（不是被测文件）算。用法：仓库根 bash tests/chain_window_test.sh（tools/gate.sh 自动收；改到 translator/dmsh_chain_window.py / dmsh_chain.py 时路由到它）
set -u; R=$(pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; bad=0
ok() { n=$((n+1)); if [ "$1" = "$2" ]; then echo "过  $3：期望 $1 → 真结果 $2"; else bad=$((bad+1)); echo "✗  $3：期望 $1 → 真结果 $2"; fi; }
git clone -q --shared "$R" "$T/r" && cd "$T/r" && git checkout -q "$(git -C "$R" rev-parse HEAD)" && git config user.email t@t && git config user.name t
cp "$R/translator/dmsh_chain_window.py" translator/   # 被测的是工作区这份
W="python3 translator/dmsh_chain_window.py"; C="python3 translator/dmsh_chain.py"; H=graphics/nvn/gfx/nvn/dmsh_chain.h
git add -A && git commit -qm base --allow-empty; base=$(git rev-parse HEAD); vbase=$($C)
abi() { sed -i '' "s/^ABI = [0-9]*/ABI = $1/" translator/dmsh_chain.py; }
# a：只改翻译器文件（不动 ABI）→ 不换链，--touches 照样列出改到的翻译文件
git checkout -qb a && echo "// a" >> graphics/tools/direct/dsh/batch/BuildXlate.cs && $C --header > /dev/null && git commit -qam a   # 翻译器指纹输入（S2A.Dsh.csproj DshXfpInput）里的文件；Build.cs 是编排、不在
out=$($W --touches "$base" a); rc=$?; ok 1 "$rc" "--touches 只改翻译器：退出码（不换链）"; ok "$vbase → $vbase" "$(echo "$out" | head -1)" "--touches 只改翻译器：前后链号不变"
ok graphics/tools/direct/dsh/batch/BuildXlate.cs "$(echo "$out" | sed -n 2p | tr -d ' ')" "--touches 列出改到的翻译文件"
# d：ABI 1 → 2 → 换链，后链号 = 该树上 dmsh_chain.py 算的值
git checkout -q "$base" && git checkout -qb d && abi 2 && $C --header > /dev/null && git commit -qam d; vd=$($C)
out=$($W --touches "$base" d); rc=$?; ok 0 "$rc" "--touches 改了 ABI：退出码（换链）"; ok "$vbase → $vd" "$(echo "$out" | head -1)" "--touches 改了 ABI：前后链号"
$W --touches d d > /dev/null; ok 1 $? "--touches 同一提交：不换链"
# f：非缺省选项写了头文件（只头文件与 d 冲突）→ --resolve 按合并后的树（ABI 2、缺省选项）重写
git checkout -q "$base" && git checkout -qb f && XLATE_REDUCED=0 $C --header > /dev/null && git commit -qam f
git checkout -q d && git merge -q f > /dev/null 2>&1; ok "$H" "$(git diff --name-only --diff-filter=U)" "合并只在头文件上冲突"
$W --resolve > /dev/null; ok 0 $? "--resolve 退出码"; vm=$($C)
ok "$vd" "$vm" "合并后的链号 = d 的链号（f 的选项不进缺省）"
ok "#define DMSH_CHAIN \"$vm\" #define DMSH_ABI 2" "$(grep '^#define' $H | tr '\n' ' ' | sed 's/ $//')" "--resolve 写回合并后的链号与 ABI"; ok "" "$(git diff --name-only --diff-filter=U)" "--resolve 后无冲突（已暂存）"
git merge --abort 2>/dev/null; git reset -q --hard d
# g：另一支把 ABI 改成 3 → dmsh_chain.py 也冲突 → --resolve 拒绝、头文件不动
git checkout -q "$base" && git checkout -qb g && abi 3 && $C --header > /dev/null && git commit -qam g
git checkout -q d && git merge -q g > /dev/null 2>&1; before=$(git show :3:$H 2>/dev/null | tail -1; cat $H | md5)
$W --resolve > /dev/null; ok 1 $? "ABI 两边都改（链文件也冲突）：--resolve 拒绝"; ok "$before" "$(git show :3:$H 2>/dev/null | tail -1; cat $H | md5)" "拒绝时头文件不动"
git merge --abort 2>/dev/null
echo "换链窗口单测：${n} 项，失败 ${bad} 项"; [ $bad = 0 ]
