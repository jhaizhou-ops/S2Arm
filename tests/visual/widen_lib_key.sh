#!/bin/bash
# 宽屏门禁离线着色器库的缓存键：bash tests/visual/widen_lib_key.sh [<树>]   → 打印 16 位
# 键只认会影响离线库产物的输入：GAL 翻译代码（graphics/tools/shbake/xc_key.sh：gal_xc 静态链 + 死代码剥离后的二进制 + Makefile）+ 打包脚本 graphics/metal/tools/gal_offline.py。
# 渲染器里翻译用不到的代码（出图、绘制、缓冲…）改了键不变。10-21 前键 = graphics/metal + graphics/third_party 全部文件内容哈希：帧率能耗线 perf/resfault、perf/rb-split
# 只改渲染器 3–4 个文件也整库重建（912 秒），列车钩子 600 秒必红。单测 tests/visual/widen_lib_key_test.sh。
# 不给树：按仓库 HEAD 算（xc_key.sh 按树号缓存）；graphics/metal 或 graphics/third_party 有未提交改动时按工作树算（库由工作树编的 gal_xc 建，键要跟它一致）。
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
if [ $# -ge 1 ]; then t=$(cd "$1" && pwd) || exit 1; x=$(S2A_XCKEY_TREE=$t bash "$R/graphics/tools/shbake/xc_key.sh") || exit 1
elif [ -z "$(git -C "$R" status --porcelain -- graphics/metal graphics/third_party)" ]; then t=$R; x=$(bash "$R/graphics/tools/shbake/xc_key.sh") || exit 1
else t=$R; x=$(S2A_XCKEY_TREE=$R bash "$R/graphics/tools/shbake/xc_key.sh") || exit 1; fi
[ ${#x} = 16 ] || { echo "【红】widen_lib_key：翻译代码键不是 16 位（${x}）" >&2; exit 1; }
{ echo "$x"; cat "$t/graphics/metal/tools/gal_offline.py"; grep '_DEPLOYMENT_TARGET=' "$t/tools/toolchain.env"; } | shasum -a 256 | cut -c1-16   # 离线库按统一工具链的下限编：下限变了库要重建
