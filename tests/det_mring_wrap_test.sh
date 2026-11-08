#!/bin/bash
# 门禁覆盖：runtime/src/det.c runtime/src/det_mring.h
# 确定性记录环跨环尾。期望是写入的原字节；线性读会拿到环外的字节或被 ASan 打断。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
CC=${CC:-cc}
mkdir -p build/tests
o=build/tests/det_mring_wrap
SAN=
if echo 'int main(void){return 0;}' | "$CC" -fsanitize=address,undefined -x c -o build/tests/asan_probe - >/dev/null 2>&1; then
  SAN="-fsanitize=address,undefined"
elif command -v gcc >/dev/null 2>&1 &&
     echo 'int main(void){return 0;}' | gcc -fsanitize=address,undefined -x c -o build/tests/asan_probe - >/dev/null 2>&1; then
  CC=gcc
  SAN="-fsanitize=address,undefined"
fi
echo "det_mring_wrap 编译器：${CC}；检测：${SAN:-无 ASan/UBSan}"
rm -f build/tests/asan_probe
"$CC" -std=c11 -Wall -Wextra -Werror $SAN -g -O1 \
  -o "$o" tests/det_mring_wrap.c || { echo "不通 det_mring_wrap 编译"; exit 1; }
"$o"; rc=$?
[ "$rc" = 0 ] && echo "det_mring_wrap 自测 通过" || echo "det_mring_wrap 自测 失败 rc=$rc"
exit "$rc"
