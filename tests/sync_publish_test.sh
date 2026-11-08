#!/bin/bash
# 门禁覆盖：graphics/nvn/gfx/nvn/hle_nvn.c graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_obj.h
# sync 对象先写 fence 再 release 写 fenced。bash tests/sync_publish_test.sh
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
ck "hle_nvn.c 用 sync_publish" 'grep -q sync_publish "$H/graphics/nvn/gfx/nvn/hle_nvn.c"'
ck "nvn_mtl.m 用 sync_publish" 'grep -q sync_publish "$H/graphics/nvn/gfx/nvn/nvn_mtl.m"'
ck "hle_nvn.c 用 sync_published" 'grep -q sync_published "$H/graphics/nvn/gfx/nvn/hle_nvn.c"'
ck "两处不再先写 fenced = 1" '! grep -nE "fenced[[:space:]]*=[[:space:]]*1" "$H/graphics/nvn/gfx/nvn/hle_nvn.c" "$H/graphics/nvn/gfx/nvn/nvn_mtl.m"'
# QueueWaitSync 是 GPU 侧等待：函数体里回 1、不在 CPU 上等（nvn_be_wait / sync_ext_wait）；按函数体取，不按单行（11-01 改成多行后单行 grep 失效）
qws=$(awk '/^NVN\(nvnQueueWaitSync,/{f=1} f{print} f&&/^}/{exit}' "$H/graphics/nvn/gfx/nvn/hle_nvn.c")
ck "QueueWaitSync 仍立刻返回 1、不在 CPU 上等" '[ -n "$qws" ] && grep -q "return 1" <<< "$qws" && ! grep -qE "nvn_be_wait\(|sync_ext_wait\(" <<< "$qws"'
T=$(mktemp -d)
clang -O2 -Wall -Wextra -Werror -pthread -I "$H/graphics/nvn/gfx/nvn" -I "$H/graphics/nvn/gfx/nvn/include" "$H/tests/sync_publish_litmus.c" -o "$T/litmus"
"$T/litmus"
rm -rf "$T"
exit $bad
