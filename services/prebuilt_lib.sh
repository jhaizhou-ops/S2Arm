#!/bin/bash
# 随 App 分发的预编静态库（libvpx / dav1d；别的库照 launchers/macos/bundle_engine.py PREBUILT_LIBS 追加一项）：玩家机器出包只链接、不构建。services/vpx/build.sh、services/dav1d/build.sh 开头 source 本文件。
# 发版时 launchers/macos/bundle_engine.py bundle_prebuilt_libs 在发版机上照常构建，把 iOS arm64 / macOS arm64 的静态库、头文件、build.txt 放进
#   引擎 Binaries/Prepare/libs/<库>/<平台>/（与 shbake / romfs 等预编工具同一处，prepare.json 记每个文件的 sha256）；出包作业环境给
#   S2A_PREBUILT_TOOLS 指到 Binaries/Prepare（pack/jobs/core.py），这时 build.sh 走这里：核构建键与库的 sha256，对上就回库路径，对不上报红退出，不回落现编。
# build.txt：key=<构建键：版本-脚本与系统下限哈希-垫片哈希，build.sh --key 打印> version= source_sha256= lib_sha256=
# s2a_prebuilt_lib <库名> <平台> <构建键> <库文件名>：没设 S2A_PREBUILT_TOOLS 时返回（照常构建）；设了则输出库路径并 exit 0 / 报红 exit 1
s2a_prebuilt_lib() {
  local d=${S2A_PREBUILT_TOOLS:-} k s
  [ -n "$d" ] || return 0
  d=$d/libs/$1/$2
  [ -f "$d/build.txt" ] && [ -f "$d/$4" ] || { echo "🔴 $1：App 里没有 $2 的预编库（$d/$4）；玩家机器不现编，请安装完整的 S2Arm" >&2; exit 1; }
  k=$(sed -n 's/^key=//p' "$d/build.txt"); s=$(sed -n 's/^lib_sha256=//p' "$d/build.txt")
  [ "$k" = "$3" ] || { echo "🔴 $1：App 预编库的构建键 $k 与引擎要的 $3 不符（App 与引擎不是同一版）" >&2; exit 1; }
  [ "$(shasum -a 256 "$d/$4" | cut -c1-64)" = "$s" ] || { echo "🔴 $1：App 预编库 $d/$4 的 sha256 与 build.txt 不符" >&2; exit 1; }
  # 返回值会进入 make 的空白分隔链接参数，校验后统一换成现有的无空格别名。
  source "$(dirname "${BASH_SOURCE[0]}")/../tools/nospace.sh" || exit 1
  case $d in *' '*) d=$(cd "$d" && pwd) || exit 1;; esac
  d=$(s2a_nospace "$d") || { echo "🔴 $1：预编库无法建立无空格路径" >&2; exit 1; }
  echo "$d/$4"; exit 0
}
