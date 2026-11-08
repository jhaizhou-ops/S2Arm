#!/bin/bash
# 带空格路径给 make 用的无空格别名（10-25 启动器实测：引擎 / 产物根在「~/Library/Application Support」下，make 把路径按空格拆成多个目标，
#   直连库 libnxgal 与 make ios 全失败。make 天生不支持目标 / 依赖里带空格，用户目录又不能限制）：
#   source 后 s2a_nospace <路径>：路径不带空格原样打印；带空格就在 ${TMPDIR:-/tmp}/s2a-nospace/ 下建（或复用）一个指向它的软链，打印软链路径。
#   软链名 = 真实路径的 sha1 前 12 位：同一路径每次同一别名（增量构建的目标路径不变），不同路径不撞。
#   用法：make 的 -C 目录、ROOT=、BUILD= / IOS_MODS= 这类会进目标和依赖的路径都换成别名；脚本自己的引用照常加引号用真路径
s2a_nospace() {
  local p=${1:?s2a_nospace <路径>} d h l
  case $p in *' '*) ;; *) printf '%s\n' "$p"; return 0;; esac
  d=${TMPDIR:-/tmp}; case $d in *' '*) d=/tmp;; esac; d=${d%/}/s2a-nospace
  mkdir -p "$d" || return 1
  h=$(printf '%s' "$p" | shasum | cut -c1-12); l=$d/$h
  [ "$(readlink "$l" 2> /dev/null)" = "$p" ] || ln -sfn "$p" "$l" || return 1
  printf '%s\n' "$l"
}
