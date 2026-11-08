#!/bin/bash
# 门禁覆盖：runtime/src/loader.c
# 合成 ELF64 RELA。缺省 JUMP_SLOT 只存 S；S2A_JUMP_SLOT_ADDEND=1 时为 S+A。其它 RELA 两种都加加数。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
CC=${CC:-cc}
mkdir -p build/tests
INC="-Iruntime/include -Iruntime/src -Itests/support/hoststub"
"$CC" -std=c11 -Wall -Wextra -Werror -DS2A_UNIT_TEST -D_GNU_SOURCE $INC \
  -c runtime/src/loader.c -o build/tests/loader_jumpslot_loader.o || { echo "不通 loader.c 编译"; exit 1; }
"$CC" -std=c11 -Wall -Wextra -Werror -DS2A_UNIT_TEST -D_GNU_SOURCE $INC \
  -c runtime/src/nrodefer.c -o build/tests/loader_jumpslot_nrodefer.o || { echo "不通 nrodefer.c 编译"; exit 1; }
"$CC" -std=c11 -Wall -Wextra -Werror -D_GNU_SOURCE -Iruntime/include -Iruntime/src \
  -o build/tests/loader_jumpslot tests/loader_jumpslot.c build/tests/loader_jumpslot_loader.o build/tests/loader_jumpslot_nrodefer.o -pthread \
  || { echo "不通 loader_jumpslot 链接"; exit 1; }
fail=0
env -u S2A_JUMP_SLOT_ADDEND build/tests/loader_jumpslot || fail=1
S2A_JUMP_SLOT_ADDEND=1 build/tests/loader_jumpslot || fail=1
[ "$fail" = 0 ] && echo "loader_jumpslot 自测 通过" || echo "loader_jumpslot 自测 失败"
exit "$fail"
