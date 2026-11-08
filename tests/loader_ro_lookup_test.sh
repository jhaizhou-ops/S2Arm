#!/bin/bash
# 门禁覆盖：runtime/src/loader.c
# nn::ro::LookupSymbol 直连跳板：直连命中 → 宿主图形层地址（= 导入槽）、不命中 → sdk 原定义、通用模式不挂、sdk 无定义 → 0xA16。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
CC=${CC:-cc}
mkdir -p build/tests
INC="-Iruntime/include -Iruntime/src -Itests/support/hoststub"
"$CC" -std=c11 -Wall -Wextra -Werror -DS2A_UNIT_TEST -D_GNU_SOURCE $INC \
  -c runtime/src/loader.c -o build/tests/loader_ro_lookup_loader.o || { echo "不通 loader.c 编译"; exit 1; }
"$CC" -std=c11 -Wall -Wextra -Werror -D_GNU_SOURCE -Iruntime/include -Iruntime/src \
  -o build/tests/loader_ro_lookup tests/loader_ro_lookup.c runtime/src/nrodefer.c build/tests/loader_ro_lookup_loader.o -pthread \
  || { echo "不通 loader_ro_lookup 链接"; exit 1; }
build/tests/loader_ro_lookup && echo "loader_ro_lookup 自测 通过" || { echo "loader_ro_lookup 自测 失败"; exit 1; }
