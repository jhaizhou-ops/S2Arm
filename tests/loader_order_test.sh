#!/bin/bash
# 门禁覆盖：runtime/src/loader.c
# 装载顺序回归：合成模块两种装载序核 JUMP_SLOT 绑定 + s2a_module_order_ok 名单校验。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
CC=${CC:-cc}
mkdir -p build/tests
INC="-Iruntime/include -Iruntime/src -Itests/support/hoststub"
"$CC" -std=c11 -Wall -Wextra -Werror -DS2A_UNIT_TEST -D_GNU_SOURCE $INC \
  -c runtime/src/loader.c -o build/tests/loader_order_loader.o || { echo "不通 loader.c 编译"; exit 1; }
"$CC" -std=c11 -Wall -Wextra -Werror -DS2A_UNIT_TEST -D_GNU_SOURCE $INC \
  -c runtime/src/nrodefer.c -o build/tests/loader_order_nrodefer.o || { echo "不通 nrodefer.c 编译"; exit 1; }
"$CC" -std=c11 -Wall -Wextra -Werror -D_GNU_SOURCE -Iruntime/include -Iruntime/src \
  -o build/tests/loader_order tests/loader_order.c build/tests/loader_order_loader.o build/tests/loader_order_nrodefer.o -pthread \
  || { echo "不通 loader_order 链接"; exit 1; }
build/tests/loader_order && echo "loader_order 自测 通过" || { echo "loader_order 自测 失败"; exit 1; }
