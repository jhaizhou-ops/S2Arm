#!/bin/bash
# 本机 colima 一条命令备好（安卓 Linux CTest 门禁子项 android/linux_ctest.sh 要它）：bash tools/colima_setup.sh
#   已备好的步跳过，可重复跑。在有代理的终端里跑（读 https_proxy / http_proxy；列车 / launchd 环境没有代理，门禁不建实例，见 linux_ctest.sh）。
# 10-29 起因：实例被删后门禁每批 colima start 一次，直连 GitHub 约 13 KB/s，600 秒内下不完约 400 MB 的系统镜像；
#   与人工重建同时写同一个 .downloading 文件互相改坏，SHA 校验失败；start 失败时 colima 还清空整个缓存目录。
#   ① 镜像：按本机 colima 版本取镜像地址，经代理下到缓存外临时文件，核对发布页的 .sha512sum 后才放进 ~/Library/Caches/colima/caches/<地址 sha256>
#   ② 起实例：拿与 linux_ctest.sh 同一把锁 ~/.colima/s2a-start.lock，colima start --arch aarch64 --cpu 4 --memory 6 --disk 30（rosetta 等其余设置读 ~/.colima/default/colima.yaml）
#   ③ 虚拟机里装 cmake / g++（apt 经代理：sudo 不带环境变量，显式 -E）
#   ④ 核：colima 在跑、cmake / g++ 版本、rosetta binfmt、⑤ 的定时器在跑
#   ⑤ 虚拟机里装定时器 s2a-dropcache.timer：每 15 秒 echo 2 > /proc/sys/vm/drop_caches，释放没人用的 inode / dentry
#     11-05 起因：本机近死机、强制重启。virtiofs 下客户机缓存住的每个 inode 都在宿主虚拟机进程钉一个文件句柄，客户机内存够就永不释放；
#     linux_ctest.sh（colima ssh 编工作树）、tests/vulkan/run.sh（容器绑挂 /src）每次门禁换一棵新工作树，3 天攒到 204800 个句柄，
#     宿主 vnode 表（kern.maxvnodes 263168）占满，全机 ENFILE。实测客户机 find 117903 个文件 → 宿主句柄 28 → 97174 不回落，drop_caches 后 86。
#     在虚拟机这一处兜住，所有经共享目录读宿主文件的调用方都不用各自处理；在用的 inode 不会被清，只多一次查找
set -u; say() { echo "$(date '+%m-%d %T') $*"; }
command -v colima > /dev/null || { say "【红】没有 colima（brew install colima）"; exit 1; }
CH=${COLIMA_HOME:-$HOME/.colima}; C=$HOME/Library/Caches/colima/caches; TMP=${TMPDIR:-/tmp}/s2a-colima-img
if ! colima status > /dev/null 2>&1 && ! colima list 2> /dev/null | awk 'NR > 1 && $1 == "default" { f = 1 } END { exit !f }'; then
  V=$(colima version 2> /dev/null | sed -n 's/^colima version //p')
  U=$(strings "$(command -v colima)" | grep -o "https://github.com/abiosoft/colima-core/releases/download/v$V/[A-Za-z0-9._-]*-arm64-docker\.qcow2" | head -1)
  [ -n "$U" ] || { say "【红】从 colima $V 里取不到 aarch64 docker 镜像地址"; exit 1; }
  N=$(printf %s "$U" | shasum -a 256 | cut -c1-64)
  E=$(curl -fsSL --retry 3 --max-time 60 "$U.sha512sum" | cut -d' ' -f1)
  [ ${#E} = 128 ] || { say "【红】取不到 ${U##*/} 的 SHA512（${U}.sha512sum）"; exit 1; }
  if [ -f "$C/$N" ] && [ "$(shasum -a 512 "$C/$N" | cut -c1-128)" = "$E" ]; then say "① 镜像已在缓存、校验对：${U##*/}"
  else
    mkdir -p "$TMP"; s=$(date +%s); say "① 下载 ${U##*/}（代理 ${https_proxy:-${HTTPS_PROXY:-无，直连会很慢}}）"
    curl -fL --retry 3 -o "$TMP/$N" "$U" || { say "【红】下载失败"; exit 1; }
    [ "$(shasum -a 512 "$TMP/$N" | cut -c1-128)" = "$E" ] || { say "【红】下好的镜像 SHA512 对不上，不放进缓存"; rm -f "$TMP/$N"; exit 1; }
    mkdir -p "$C" && mv "$TMP/$N" "$C/$N" && say "① 镜像已放进缓存（$(( $(date +%s) - s )) 秒）"
  fi
fi
if colima status > /dev/null 2>&1; then say "② colima 已在跑"
else
  L=$CH/s2a-start.lock
  until mkdir "$L" 2> /dev/null; do p=$(cat "$L/pid" 2> /dev/null); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && { rm -f "$L/pid"; rmdir "$L"; continue; }
    colima status > /dev/null 2>&1 && break; say "别的进程（pid ${p:-?}）在起 colima，等"; sleep 10; done
  if [ -d "$L" ] && [ ! -s "$L/pid" ]; then echo $$ > "$L/pid"; trap 'rm -f "$L/pid"; rmdir "$L" 2> /dev/null' EXIT
    s=$(date +%s); colima status > /dev/null 2>&1 || colima start --arch aarch64 --cpu 4 --memory 6 --disk 30 || { say "【红】colima start 失败"; exit 1; }
    rm -f "$L/pid"; rmdir "$L" 2> /dev/null; trap - EXIT; say "② colima 起好（$(( $(date +%s) - s )) 秒）"; fi
fi
# lavapipe（Mesa CPU Vulkan）+ libvulkan：安卓 S 级真 Vulkan 用例（android/linux_ctest.sh 末段）要（11-06：登记在 mini 跑的 test.sh 里，mini / 本机都没有 lavapipe，main 安卓钩子一直红）
colima ssh -- bash -c 'command -v cmake > /dev/null && command -v g++ > /dev/null && [ -f /usr/share/vulkan/icd.d/lvp_icd.json ] && [ -e /usr/lib/aarch64-linux-gnu/libvulkan.so ] && exit 0
  sudo -E apt-get update -qq && sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake g++ mesa-vulkan-drivers libvulkan-dev > /dev/null' || { say "【红】虚拟机里装 cmake / g++ / lavapipe 失败"; exit 1; }
colima ssh -- sudo bash -c 'set -e; d=/etc/systemd/system
  printf "%s\n" "[Unit]" "Description=S2Arm 释放 virtiofs 缓存 inode（宿主文件句柄），见 tools/colima_setup.sh ⑤" "[Service]" "Type=oneshot" "ExecStart=/bin/sh -c \"echo 2 > /proc/sys/vm/drop_caches\"" > $d/s2a-dropcache.service
  printf "%s\n" "[Unit]" "Description=S2Arm 每 15 秒释放 virtiofs 缓存 inode" "[Timer]" "OnBootSec=15" "OnUnitActiveSec=15" "AccuracySec=1" "[Install]" "WantedBy=timers.target" > $d/s2a-dropcache.timer
  systemctl daemon-reload; systemctl enable --now s2a-dropcache.timer > /dev/null 2>&1' || { say "【红】虚拟机里装 s2a-dropcache 定时器失败"; exit 1; }
say "④ 核：$(colima list 2> /dev/null | awk '$1 == "default" { print $2, $3, $4 " 核", $5, $6 }')；$(colima ssh -- bash -c 'cmake --version | head -1; g++ --version | head -1; echo "rosetta $(head -1 /proc/sys/fs/binfmt_misc/rosetta 2> /dev/null || echo 没有)"; echo "s2a-dropcache.timer $(systemctl is-active s2a-dropcache.timer)"' | awk '{ printf "%s%s", (NR > 1 ? "；" : ""), $0 }')"
