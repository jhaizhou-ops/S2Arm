#!/bin/bash
# 门禁手动：辅助脚本（夹具重建），用固定提交的本地 switch-tools 源码重建已提交 NSO（要传源码目录与新输出目录），本身不是单测
# 手动重建自有 NSO 夹具，不进门禁；只读已准备的本地工具源码，不联网。
set -euo pipefail
fixture=$(cd "$(dirname "$0")" && pwd)
source_dir=${1:?用法：rebuild.sh <本地switch-tools源码> <全新输出目录>}
output=${2:?需要全新输出目录}
test "$(git -C "$source_dir" rev-parse HEAD)" = 22756068dd0ed6ff9734c59cb4f99ebd3f62555b
test ! -e "$output"
mkdir -p "$output"
clang -std=gnu99 -Wall -Wextra $(pkg-config --cflags liblz4) \
    "$source_dir/src/elf2nso.c" "$source_dir/src/sha256.c" \
    $(pkg-config --libs liblz4) -o "$output/elf2nso"
clang --target=aarch64-none-elf -std=c11 -O2 -ffreestanding \
    -fno-stack-protector -fno-pic -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$fixture/fixture.c" -o "$output/fixture.o"
ld.lld -m aarch64elf --build-id=sha1 -T "$fixture/fixture.ld" \
    -o "$output/fixture.elf" "$output/fixture.o"
"$output/elf2nso" "$output/fixture.elf" "$output/fixture.nso"
cmp "$fixture/fixture.nso" "$output/fixture.nso"
shasum -a 256 "$output/fixture.elf" "$output/fixture.nso"
