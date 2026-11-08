#!/usr/bin/env bash
# 安卓 Linux runtime CTest（android/CMakeLists.txt：编译 + 链接 + 跑；链生产 runtime/src/svc_mem.c、det.c、layout.c）。
#   Linux 上直接跑；macOS 上进本机 colima 的 aarch64 Linux 虚拟机跑（仓库须在家目录下：colima 只挂载家目录）。
#   门禁接法：android/gate.sh 子项键 linux（android/gate.sh 文件头「# 门禁本机：linux」登记本机跑；mini 没有 colima）。
#   10-28 起因：原生层线 vm-owner 断言给 svc_mem.c 加了外部符号，只补了一个夹具的桩，main 上 guest_page_test 链接红，门禁没 Linux 没拦下。
#   colima 没起就起它（约 30 秒）；起之前拿单实例锁 ~/.colima/s2a-start.lock（10-29：列车门禁、各线自检、人工重建同时 colima start，
#     共用 ~/Library/Caches/colima 里同一个 .downloading 镜像文件互相删改、SHA 校验失败，谁也起不来），别人在起就等它（≤ S2A_COLIMA_WAIT_S，缺省 300 秒）。
#   环境没备好退 75（门禁记「环境未就绪」、不当分支红），不在门禁里补环境：
#     没有 colima 实例 default——建实例要下载约 600 MB 系统镜像再装 cmake / g++，远超门禁 600 秒时限（10-29 实例被删后每批起一次、
#       600 秒被杀、半截下载作废，列车连红）；虚拟机里缺 cmake / g++（装：colima ssh -- sudo apt-get install -y cmake g++），不自动下载。
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run_ctest='set -u; out=$(mktemp -d /tmp/s2a-android-ctest.XXXXXXXX); trap "rm -rf \"$out\"" EXIT
  for t in cmake c++ cc; do command -v $t >/dev/null || { echo "🟡 Linux 缺 ${t}（bash tools/colima_setup.sh 补装）"; exit 75; }; done
  cmake -S android -B "$out" -DCMAKE_BUILD_TYPE=Debug > "$out/cfg.log" 2>&1 || { tail -20 "$out/cfg.log"; echo "配置失败"; exit 1; }
  cmake --build "$out" --parallel 4 > "$out/build.log" 2>&1; b=$?
  [ $b = 0 ] || grep -E "error|undefined reference" "$out/build.log" | head -20
  ( cd "$out" && ctest --output-on-failure --timeout 30 ) > "$out/ctest.log" 2>&1; c=$?
  grep -E "tests passed|FAILED|Not Run|\\*\\*\\*Failed" "$out/ctest.log" | head -20
  # S 级真 Vulkan 用例（Mesa lavapipe，每个 0–2 秒）：只有 Linux 有 lavapipe，原先登记在 mini（macOS）跑的 test.sh 里，mini / 本机都找不到 ICD，
  #   11-06 15:24 起安卓钩子一直红（被别的红挡着没单独报）。挪到这里：缺 lavapipe 同缺 cmake 一样退 75（环境未就绪），不静默跳过
  [ -f /usr/share/vulkan/icd.d/lvp_icd.json ] || { echo "🟡 Linux 缺 lavapipe（bash tools/colima_setup.sh 补装 mesa-vulkan-drivers libvulkan-dev）"; exit 75; }
  v=0; for t in nvn_vk_texcache_content_test nvn_vk_feedback_snapshot_test nvn_vk_bcrt_test nvn_vk_ssbo_guest_test; do
    bash android/tools/$t.sh > "$out/$t.log" 2>&1 && echo "lavapipe $t 通过" || { v=1; tail -15 "$out/$t.log"; echo "【红】lavapipe $t 红"; }; done
  bash android/tests/capacity/run_linux.sh "$out/capacity" || exit $?
  [ $b = 0 ] && [ $c = 0 ] && [ $v = 0 ]'
nr() { echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 环境未就绪（$*）"; exit 75; }
colima_up() {   # 虚拟机在跑就返回；有实例 default 就拿锁起它，别人在起就等；没有实例退 75
  colima status > /dev/null 2>&1 && return 0
  colima list 2> /dev/null | awk 'NR > 1 && $1 == "default" { f = 1 } END { exit !f }' ||
    nr "本机没有 colima 实例 default；建一次要下载约 400 MB 系统镜像，门禁不建。在有代理的终端里一条命令备好：bash tools/colima_setup.sh"
  local L=${COLIMA_HOME:-$HOME/.colima}/s2a-start.lock w=0 p rc
  until mkdir "$L" 2> /dev/null; do
    p=$(cat "$L/pid" 2> /dev/null); if [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null; then rm -f "$L/pid"; rmdir "$L" 2> /dev/null; continue; fi   # 持锁进程已死：清掉再抢
    colima status > /dev/null 2>&1 && return 0
    [ $w -ge "${S2A_COLIMA_WAIT_S:-300}" ] && nr "别的进程（pid ${p:-?}）在起 colima，等了 $w 秒还没起好"
    sleep 5; w=$((w + 5))
  done
  echo $$ > "$L/pid"
  if colima status > /dev/null 2>&1; then rc=0; else echo "colima 没起，起它（aarch64）"; colima start --arch aarch64 --cpu 4 --memory 6 > /dev/null 2>&1; rc=$?; fi
  rm -f "$L/pid"; rmdir "$L" 2> /dev/null
  [ $rc = 0 ] || { echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 colima 起不来（rc=${rc}）→ 红"; exit 1; }
}
case "$(uname -s)" in
  Linux) (cd "$root" && bash -c "$run_ctest"); rc=$? ;;
  Darwin)
    command -v colima > /dev/null || { echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 本机没有 colima（brew install colima），跑不了 → 红"; exit 1; }
    case "$root" in "$HOME"/*) : ;; *) echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 仓库 $root 不在家目录下，colima 挂载不到 → 红"; exit 1 ;; esac
    colima_up
    colima ssh -- bash -c "cd $(printf %q "$root") && $run_ctest"; rc=$? ;;
  *) echo "安卓 Linux CTest：本系统 $(uname -s) 不支持 → 红"; exit 1 ;;
esac
[ $rc = 0 ] && { echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 通过"; exit 0; }
[ $rc = 75 ] && nr "Linux 里缺编译工具，见上"
echo "安卓 Linux CTest：期望 编译 + 链接 + 全过 → 真结果 红（rc=${rc}，见上）"; exit 1
