#!/bin/bash
# metal-tt 查询缓存后缀入口单测（tools/tt_env.sh，约 1 秒）：bash tests/tt_env_test.sh
# 门禁只看：tools/tt_env.sh
# 期望按基础设施线 10-29 约定手写（不跑实现推）：后缀 = s2a-tt-<版本>，只留 [A-Za-z0-9._-]、截 80 字节；版本 = metal-tt 真实路径里 MetalToolchain-v<数字和点>（不带挂载随机后缀），
#   取不到退到 metal-tt -version 首行 AIR-TT 版本，都取不到【红】、非 0、不给空后缀。路径用不存在的 /nonexistent/…（realpath 原样），两种调用口径（tt_suffix 打印 / tt_env_run 给子进程）逐条同值：
#   ① cryptex 路径、挂载后缀以字母开头 → s2a-tt-v27.1.266.1；② 挂载后缀以数字开头（.1abcde）→ s2a-tt-v17.6.109.0（不把 .1 吃进版本）
#   ③ 没有挂载后缀 → s2a-tt-v27.1.266.1；④ 路径无版本、-version 答「AIR-TT 32023.921」→ s2a-tt-32023.921；⑤ 版本带别的字符（AIR-TT 1.0+b/x）→ s2a-tt-1.0_b_x
#   ⑥ 版本 200 字符 → 截到 80 字节；⑦ 都取不到 → 两种口径都非 0、标准错误有【红】、标准输出空 / 命令不执行
#   ⑧ tt_env_run 只给子进程带后缀（子进程读到 s2a-tt-v27.1.266.1，调用方 shell 里没设）；后缀取不到时不执行命令、返回 1
#   ⑨ 规则全仓只一份（审计 P2-27）：tools/ 下写版本正则（MetalToolchain-(v）的文件只有 tt_env.sh，没有 Python 副本
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/tt_env_test.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
. "$H/tools/tt_env.sh"
both() { local a b; a=$(tt_suffix "$1" 2> /dev/null); b=$(TT_PATH=$1 tt_env_run bash -c 'printf %s "$DIRHELPER_USER_DIR_SUFFIX"' 2> /dev/null); [ "$a" = "$b" ] && printf '%s' "$a" || printf 'print=%s/run=%s' "$a" "$b"; }
C=/nonexistent/com.apple.MobileAsset.MetalToolchain
r=$(both "$C-v27.1.266.1.hA5OXX/Metal.xctoolchain/usr/bin/metal-tt"); ck "① 挂载后缀字母开头：$r" '[ "$r" = s2a-tt-v27.1.266.1 ]'
r=$(both "$C-v17.6.109.0.1abcde/Metal.xctoolchain/usr/bin/metal-tt"); ck "② 挂载后缀数字开头：$r" '[ "$r" = s2a-tt-v17.6.109.0 ]'
r=$(both "/nonexistent/MetalToolchain-v27.1.266.1/usr/bin/metal-tt"); ck "③ 没有挂载后缀：$r" '[ "$r" = s2a-tt-v27.1.266.1 ]'
fake() { printf '#!/bin/bash\n[ "$1" = -version ] && printf %%s\\\\n %q\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
fake tt4 'AIR-TT 32023.921'; r=$(both "$T/tt4"); ck "④ 路径无版本、退到 -version：$r" '[ "$r" = s2a-tt-32023.921 ]'
fake tt5 'AIR-TT 1.0+b/x'; r=$(both "$T/tt5"); ck "⑤ 版本里的别的字符换成 _：$r" '[ "$r" = s2a-tt-1.0_b_x ]'
L=$(printf 'a%.0s' $(seq 1 200)); fake tt6 "AIR-TT $L"; r=$(both "$T/tt6"); ck "⑥ 截到 80 字节（实得 ${#r} 字节）" '[ "$r" = "s2a-tt-${L:0:73}" ]'
fake tt7 'no version here'
o=$(tt_suffix "$T/tt7" 2> "$T/e7s"); rs=$?; p=$(TT_PATH=$T/tt7 tt_env_run echo ran 2> "$T/e7p"); rp=$?
ck "⑦ 都取不到：打印退出 ${rs}、带跑退出 ${rp}、都报【红】、都没输出" '[ $rs != 0 ] && [ $rp != 0 ] && grep -q 【红】 "$T/e7s" && grep -q 【红】 "$T/e7p" && [ -z "$o$p" ]'
unset DIRHELPER_USER_DIR_SUFFIX
k=$(TT_PATH="$C-v27.1.266.1.hA5OXX/x/metal-tt" tt_env_run bash -c 'printf %s "${DIRHELPER_USER_DIR_SUFFIX:-}"')
ck "⑧ tt_env_run：子进程读到 ${k:-空}、调用方没设（${DIRHELPER_USER_DIR_SUFFIX:-没设}）" '[ "$k" = s2a-tt-v27.1.266.1 ] && [ -z "${DIRHELPER_USER_DIR_SUFFIX:-}" ]'
TT_PATH=$T/tt7 tt_env_run touch "$T/ran" 2> /dev/null; r8=$?
ck "⑧ 后缀取不到：不执行命令、返回 ${r8}" '[ $r8 = 1 ] && [ ! -e "$T/ran" ]'
r=$(cd "$H" && git grep -l 'MetalToolchain-(v' -- tools/ | tr '\n' ' ')
ck "⑨ 版本正则全仓只一份：${r}" '[ "$r" = "tools/tt_env.sh " ]'
echo "tt_env 单测：$([ $bad = 0 ] && echo 全过 || echo 有不通)"; exit $bad
