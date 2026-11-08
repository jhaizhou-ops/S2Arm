#!/bin/bash
# metal-tt 子进程的查询缓存隔离（10-29 基础设施线约定的入口；全仓只此一份，11-01 审计 P2-27 删掉了没有调用方的 Python 副本）。
# 为什么：air-tt 把「有哪些翻译器、各支持哪些架构」的查询结果存在每用户一份的
#   $(getconf DARWIN_USER_CACHE_DIR)air-config/com.apple.ggdsw.toolchain.XcodeDefault-queries.cache，文件名不认工具链版本。
#   机器上装着两套 Metal 工具链（如 Xcode-27.1 的 v27.1.266.1 与 Xcode.app 的 v17.6.109.0）时，一套跑 metal-tt 就把它判成另一套「过期」重建，
#   另一套的并发调用报「air-tt: No available translator」（10-29 本机两套各 4 路 × 20 次：不带后缀失败 140 / 160、119 / 160，带后缀 0 / 160 × 2）。
#   DIRHELPER_USER_DIR_SUFFIX 让系统给这个进程另起一份用户缓存目录（<缓存根>/<后缀>/），按工具链版本命名 → 每个版本一份，谁也冲不掉谁。
#   只有 metal-tt / air-tt（及 air-config / metal-config）读这份缓存；metal 前端、metallib、metal-tt -version 不碰（10-29 逐样用新后缀实测没建出 air-config）。
# 版本取法：① metal-tt 真实路径（cryptex 挂载 …/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.<挂载随机后缀>/…）里的 v<数字和点>，不带随机后缀；
#   ② 取不到（工具链在 Xcode 包里、不在 cryptex）→ metal-tt -version 首行「AIR-TT <版本>」；③ 都取不到 → 【红】、返回 1，不给空后缀。
# 后缀：s2a-tt-<版本>，只留 [A-Za-z0-9._-]、截 80 字节，例如 s2a-tt-v27.1.266.1。Python 调用方要用就 subprocess 调 tt_suffix，不另写一份。
#   用法：source tools/tt_env.sh
#     tt_suffix [<metal-tt 路径>]   打印 s2a-tt-<版本>；不给路径取 xcrun -sdk ${TT_SDK:-iphoneos} -f metal-tt；版本取不到打【红】、返回 1（不给空后缀）
#     tt_env_run <命令…>            带 DIRHELPER_USER_DIR_SUFFIX=$(tt_suffix "${TT_PATH:-}") 执行命令（只给这一个子进程，不导出）；后缀取不到不执行、返回 1
#   不要在 tools/toolchain.sh 里全局导出：宿主运行时的 Metal 系统缓存也在用户缓存目录里
tt_suffix() {
  local tt=${1:-} rp v
  [ -n "$tt" ] || tt=$(xcrun -sdk "${TT_SDK:-iphoneos}" -f metal-tt 2> /dev/null)
  rp=$(realpath "$tt" 2> /dev/null || printf '%s' "$tt")
  # 挂载随机后缀（.hA5OXX，可能以数字开头）不进版本：版本后紧跟「.<含字母的一段>/」处截止；没有挂载后缀时取到 / 或结尾
  v=$(sed -nE 's#.*MetalToolchain-(v[0-9]+(\.[0-9]+)*)\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*/.*#\1#p' <<< "$rp" | head -1)
  [ -n "$v" ] || v=$(sed -nE 's#.*MetalToolchain-(v[0-9]+(\.[0-9]+)*)(/.*)?$#\1#p' <<< "$rp" | head -1)
  [ -n "$v" ] || { [ -n "$tt" ] && v=$("$tt" -version 2> /dev/null | head -1 | sed -n 's/^ *AIR-TT  *\([^ ]*\).*/\1/p'); }
  if [ -z "$v" ]; then echo "【红】tt_env：取不到 metal-tt 工具链版本（${tt:-xcrun 找不到 metal-tt}：路径里没有 MetalToolchain-v<版本>、-version 也没有 AIR-TT 版本）" >&2; return 1; fi
  printf 's2a-tt-%s' "$v" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-80
}
tt_env_run() {
  local s; s=$(tt_suffix "${TT_PATH:-}") || return 1
  DIRHELPER_USER_DIR_SUFFIX=$s "$@"
}
