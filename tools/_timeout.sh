#!/bin/bash
# 超时一律用仓库的 perl 版 tools/bin/timeout（#591；口径同 tools/toolchain.sh:13-15）：无条件把仓库 tools/bin 放到 PATH 最前。
#   为什么不用 GNU timeout（10-28：GNU 自立进程组，嵌套时外层按组杀不到内层——出包撞 nchain 2 小时上限后 direct_lib 成孤儿、
#   续写盘 2 小时；perl 版留在调用方组里、收信号转给子组）。不探测 PATH 上有没有别的 timeout：仓库自带的这份就是口径。
# 用法：脚本头加载一次（任何 cwd、仓库内任意深度），之后 `timeout <秒> <命令…>` 原样照写；exec timeout 也能用（PATH 上是外部文件）：
#   _s2a_d=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || _s2a_d=; while [ -n "$_s2a_d" ] && [ ! -f "$_s2a_d/tools/_timeout.sh" ] && [ "$_s2a_d" != / ]; do _s2a_d=${_s2a_d%/*}; done; { [ -n "$_s2a_d" ] && [ -f "$_s2a_d/tools/_timeout.sh" ] && . "$_s2a_d/tools/_timeout.sh"; } || :
# 加载本文件只改 PATH，不改调用者的 set -e / set -u / trap；重复加载幂等。单测：bash tests/timeout_shim_test.sh
_s2a_td=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || _s2a_td=
if [ -n "$_s2a_td" ]; then
  case ":$PATH:" in *":$_s2a_td/bin:"*) ;; *) export PATH="$_s2a_td/bin:$PATH";; esac
fi
unset _s2a_td
