#!/usr/bin/env bash
# 门禁手动：只能 Linux（非 Linux 退 75）；同一 native_host_test.c 已在 android/CMakeLists.txt 注册 CTest，由安卓 Linux runtime CTest（linux_ctest.sh）跑
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 S2Arm contributors
set -euo pipefail
if [[ $(uname -s) != Linux ]]; then
  echo 'ENV_NOT_READY: savecommit host tests require Linux' >&2
  exit 75
fi
cc=${CC:-gcc-14}
if ! command -v "$cc" >/dev/null 2>&1; then
  echo "ENV_NOT_READY: missing C compiler: $cc" >&2
  exit 75
fi
cd "$(dirname "$0")"
mkdir -p build logs
"$cc" --version | head -1
"$cc" -std=c11 -O2 -g -Wall -Wextra -Werror -Wpedantic -pthread native_host_test.c ../../../native/s2a_savecommit.c -Wl,--wrap=fsetxattr -Wl,--wrap=fgetxattr -Wl,--wrap=mkdirat -Wl,--wrap=fsync -Wl,--wrap=ioctl -Wl,--wrap=write -Wl,--wrap=syscall -Wl,--wrap=s2a_savecommit_exchange -o build/native_host_test
./build/native_host_test "$PWD"
