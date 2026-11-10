#!/bin/bash
# 编 Mac 宿主 build/s2arm-host 的唯一入口（11-04 合入运维线，维护者令根修）：bash tools/host_build.sh [--tree <树>] [make 额外参数…]
#   一棵树一把锁：lockf build/.make_host.lock（进程被杀锁随之释放，不像 mkdir 锁留残），最多等 S2A_HOST_LOCK_S 秒（缺省 600）；
#   先到的编完，后到的 make 是空操作。
#   S2A_CS 缺省 1，且只升不降：这棵树的构建配置戳 build/.host_cfg 已是 S2A_CS=1 时，调用方给 0 也按 1 编。
#   起因：Makefile 的构建配置戳含 S2A_CS，配置一变就整个重链同一个 build/s2arm-host。11-02 / 11-03 普查同一棵树里，
#   出包的 pack/stage_extract.sh（只用 Oodle 的款 S2A_CS=0）、runtime/run_mac.sh / tools/mac_health.sh（不带 S2A_CS、不加锁）
#   与起局的 维护方 entry_check.sh（S2A_CS=1、加锁）交替重编，把正要起局的宿主盖成「S2A_Init：没链 C#」（幻想水浒、火炬3、激战前锋、假面骑士）。
#   --tree：要编的树（缺省本仓库；pack/stage_extract.sh 给无空格别名），锁和配置戳都在这棵树的 build/ 下。
set -u
T=$(cd "$(dirname "$0")/.." && pwd); [ "${1:-}" = --tree ] && { T=${2:?--tree 要给目录}; shift 2; }
mkdir -p "$T/build" || exit 1
CS=${S2A_CS-1}; grep -q 'S2A_CS=1 ' "$T/build/.host_cfg" 2> /dev/null && CS=1
S2A_CS=$CS exec lockf -k -t "${S2A_HOST_LOCK_S:-600}" "$T/build/.make_host.lock" make -C "$T" -s "$@" host
