#!/usr/bin/env bash
# 门禁手动：只能 Linux（生产 svc_mem.c 按 __ANDROID__ 编要 Linux 内核头；非 Linux 自己跳过退 0），门禁 Linux 路径本轮没实跑验证
# 改表断言单测（owner_test.c）：只在 Linux 上跑（生产 svc_mem.c 按 __ANDROID__ 编，要 Linux 内核头）。
#   bash run_owner.sh [svc_mem.c 路径]   缺省 runtime/src/svc_mem.c；给旧源时 ③ 应红（旧代码不拦漏登记的改表）
set -euo pipefail
cd "$(cd "$(dirname "$0")/../../../.." && pwd)"
[ "$(uname -s)" = Linux ] || { echo "【黄】owner_test 只在 Linux 跑（本机 $(uname -s)），跳过"; exit 0; }
src=${1:-native/src/svc_mem.c}; out=$(mktemp -d)
f=(-D_GNU_SOURCE -DS2A_UNIT_TEST -std=gnu11 -O2 -pthread -Iruntime/include -Iruntime/src -Iandroid/native)
cc "${f[@]}" -D__ANDROID__ -w -c "$src" -o "$out/svc.o"
cc "${f[@]}" -w -c android/native/runtime/vm/backing.c -o "$out/backing.o"
cc "${f[@]}" -w android/core-link/runtime-tests/vm/owner_test.c "$out/svc.o" "$out/backing.o" -o "$out/owner_test"
"$out/owner_test"
