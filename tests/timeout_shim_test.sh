#!/bin/bash
# tools/_timeout.sh 单测（#591）：bash tests/timeout_shim_test.sh
# 口径（同 tools/toolchain.sh:13-15）：超时一律用仓库的 perl 版 tools/bin/timeout；加载即无条件把 tools/bin 放到 PATH 最前。
#   为什么不用 GNU timeout：它自立进程组，嵌套时外层按组杀不到内层（出包撞 nchain 2 小时上限后 direct_lib 成孤儿、续写盘 2 小时）；
#   perl 版留在调用方组里、收信号转给子组。所以这里不探测「PATH 上已有 timeout 就沿用」——仓库自带的那份就是口径。
# 判据：干净 macOS（env -i PATH=/usr/bin:/bin，没有 Homebrew 的 coreutils）下，加载后 command -v timeout 必须指向 tools/bin/timeout，
#   且语义对齐（超时 124、自己的退出码原样、exec 可用、子孙一个不剩）；不许「exit 0 但什么都没做」——那正是 #591 要消灭的形态。
set -u
H=$(cd "$(dirname "$0")"/.. && pwd); SHIM=${H}/tools/_timeout.sh; SYS=/usr/bin:/bin; TO=${H}/tools/bin/timeout
export SHIM TO
bad=0; T=$(mktemp -d); trap 'rm -rf "${T}"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
lines() { printf '%s\n' "$1"; }

echo "—— ⓪ PATH 里本来就有别的 timeout：仓库版仍放最前（不再「有 GNU 就用 GNU」）"
mkdir -p "${T}/fakebin"; printf '#!/bin/sh\nexit 99\n' > "${T}/fakebin/timeout"; chmod +x "${T}/fakebin/timeout"
s=$(env -i PATH="${T}/fakebin:${SYS}" SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
command -v timeout
EOS
)
ck "⓪ 已存在别的 timeout 时仍指向 tools/bin/timeout（实得 ${s}）" '[ "$s" = "$TO" ]'

echo "—— ① 干净 PATH（没有 coreutils）：加载后 command -v timeout 指向 tools/bin/timeout"
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
command -v timeout
EOS
)
ck "① command -v timeout 实得 ${s}，期望 ${TO}" '[ "$s" = "$TO" ]'
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
echo "$PATH" | cut -d: -f1
EOS
)
ck "① tools/bin 在 PATH 最前（第一段实得 ${s}）" '[ "$s" = "${H}/tools/bin" ]'

echo "—— ② 语义对齐：超时 124 / 没超时 0 / 自己的退出码原样"
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
timeout 1 sleep 5
echo $?
EOS
)
ck "② timeout 1 sleep 5 退出 124（实得 ${s}）" '[ "$s" = 124 ]'
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
timeout 5 true
echo $?
EOS
)
ck "② timeout 5 true 退出 0（没超时不能误杀，实得 ${s}）" '[ "$s" = 0 ]'
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
timeout 5 sh -c 'exit 7'
echo $?
EOS
)
ck "② 命令自己的退出码原样返回（7，实得 ${s}）" '[ "$s" = 7 ]'

echo "—— ③ 命令不存在 127：必须同时断言 timeout 来自 tools/bin（只断言 127 是假绿：timeout 本身不存在也返回 127）"
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
printf 'path=%s\n' "$(command -v timeout)"
timeout 5 no_such_cmd_for_591
echo "rc=$?"
EOS
)
ck "③ 同时成立：timeout 指向 tools/bin/timeout 且命令不存在返回 127（实得【${s}】）" 'lines "$s" | grep -qxF "path=${TO}" && lines "$s" | grep -qxF "rc=127"'

echo "—— ④ exec timeout 可用（PATH 上是外部文件，不是 shell 函数）"
env -i PATH=${SYS} SHIM="${SHIM}" bash -c '. "$SHIM" 2> /dev/null; exec timeout 5 sh -c "exit 3"' > /dev/null 2>&1; rc4=$?   # exec 换掉 shell 本身，只能取进程退出码
ck "④ exec timeout 5 sh -c 'exit 3' 退出 3（实得 ${rc4}）" '[ "$rc4" = 3 ]'

echo "—— ⑤ 超时杀整个进程组（sleep 是单进程好杀；真实场景杀的是 xcrun 那种会拉子进程的）"
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
. "$SHIM" 2> /dev/null
timeout 1 bash -c 'sleep 31.7 & wait'
echo $?
EOS
)
sleep 1; left=$(pgrep -f 'sleep 31.7' 2> /dev/null | tr '\n' ' ')
ck "⑤ 超时 124、子孙一个不剩（rc 实得 ${s}，残留「${left}」）" '[ "$s" = 124 ] && [ -z "$left" ]'

echo "—— ⑥ 真实入口：services/romfs_index.sh 在干净 PATH 下不再静默失败（#591 的原始形态）"
# 两处都设 S2A_PREBUILT_TOOLS 走预编分支（只有一行 exec timeout，不碰构建）：#962 把「构建报成功但没有产物」判红，
# 干净树里没有 romfs_index.dll，DOTNET=/usr/bin/true 的构建路径会被判红——与本 PR 的 timeout 口径无关。
if git -C "$H" cat-file -e origin/main:services/romfs_index.sh 2> /dev/null; then
  git -C "$H" show origin/main:services/romfs_index.sh > "${T}/romfs_main.sh"
  rc0=$(env -i PATH=${SYS} DOTNET=/usr/bin/true S2A_PREBUILT_TOOLS="${T}/pre" bash "${T}/romfs_main.sh" "${T}/root" > /dev/null 2>&1; echo $?)
  ck "⑥ main 的 romfs_index.sh 在干净 PATH 下退出 127（实得 ${rc0}）" '[ "$rc0" = 127 ]'
else
  echo "跳过 ⑥ 的 main 对照：取不到 origin/main:services/romfs_index.sh"
fi
rc1=$(env -i PATH=${SYS} DOTNET=/usr/bin/true S2A_PREBUILT_TOOLS="${T}/pre" bash "${H}/services/romfs_index.sh" "${T}/root" > /dev/null 2>&1; echo $?)
ck "⑥ 本树的 romfs_index.sh 在干净 PATH 下退出 0（实得 ${rc1}）" '[ "$rc1" = 0 ]'

echo "—— ⑦ 加载不改调用者的 shell 选项与 trap；重复加载幂等"
s=$(env -i PATH=${SYS} SHIM="${SHIM}" bash -s <<'EOS'
set -eu
. "$SHIM" 2> /dev/null
before=$(trap -p INT)
timeout 5 true
after=$(trap -p INT)
p1=$PATH; . "$SHIM" 2> /dev/null
[ "$before" = "$after" ] && [ "$p1" = "$PATH" ] && echo "rc=$? trap=same path=same"
EOS
)
ck "⑦ set -eu 下加载并调用不炸、trap 与 PATH 都不变（重复加载幂等，实得【${s}】）" '[ "$s" = "rc=0 trap=same path=same" ]'

if [ "${bad}" = 0 ]; then echo "结果：全通（无条件 PATH 前置 / 124 语义 / 退出码透传 / exec 可用 / 进程组清理 / 真实入口 / trap 不变）"; else echo "结果：有不通项"; fi
exit ${bad}
