#!/bin/bash
# 门禁手动：辅助脚本（夹具重建），用固定版本 switch-tools 源码重建已提交的 module.nso（要传源码目录与新输出目录），门禁直接读已提交 NSO，本身不是单测
# 手动重建自有模块；门禁直接读已提交 NSO，不下载工具或依赖。
set -euo pipefail
fixture=$(cd "$(dirname "$0")" && pwd)
source_dir=${1:?rebuild.sh <固定版本switch-tools源码> <全新输出目录>}
output=${2:?需要全新输出目录}
test "$(shasum -a 256 "$source_dir/src/elf2nso.c" | cut -d ' ' -f1)" = 268db50e351c5efed0c562a2b8466b16403f120dba3a4169eb19b75677d5b137
test ! -e "$output"
mkdir -p "$output"
clang -std=gnu99 -Wall -Wextra $(pkg-config --cflags liblz4) \
    "$source_dir/src/elf2nso.c" "$source_dir/src/sha256.c" \
    $(pkg-config --libs liblz4) -o "$output/elf2nso"
clang --target=aarch64-none-elf -c "$fixture/module.S" -o "$output/module.o"
ld.lld -m aarch64elf -shared -Bsymbolic --hash-style=sysv --eh-frame-hdr \
    --build-id=sha1 -T "$fixture/module.ld" -o "$output/module.elf" "$output/module.o"
"$output/elf2nso" "$output/module.elf" "$output/module.nso"
cmp "$fixture/module.nso" "$output/module.nso"
shasum -a 256 "$output/module.elf" "$output/module.nso"
