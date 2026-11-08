#!/bin/bash
# 驱动名字全集 ⊆ 直连名字表（11-03，大乱斗 SPECIAL 取 nvnSetExternalDebuggerEnabledNVX 拿到 NULL 崩在 pc 0 之后按族收口）：bash tests/nvn_drv_names_test.sh
# 门禁只看：graphics/nvn/gfx/nvn/nvn_drv_names.txt graphics/nvn/gfx/nvn/names.txt
#   graphics/nvn/gfx/nvn/nvn_drv_names.txt = 游戏自带 NVN 驱动按名可取到的全部名字（三版并集，表头写了抽法）；names.txt = 宿主 nvnBootstrapLoader / GetProcAddress 认得的名字。
#   差集（驱动有、宿主没有）必须为空：宿主不认得的名字回 NULL，游戏不判空就调，崩在 pc 0。实现与语义由 graphics/nvn/tests/t_nvn_nvx.c 逐个测。
# 反证：从 names.txt 去掉 nvnSetExternalDebuggerEnabledNVX 再算，差集里应恰好是它
H=$(cd "$(dirname "$0")/.." && pwd); D=$H/graphics/nvn/gfx/nvn; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
grep -v '^#' "$D/nvn_drv_names.txt" | grep . | sort -u > "$T/drv"; grep . "$D/names.txt" | sort -u > "$T/ours"
n=$(wc -l < "$T/drv" | tr -d ' '); miss=$(comm -23 "$T/drv" "$T/ours")
if [ "$n" -ge 569 ] && [ -z "$miss" ]; then echo "通 驱动名字 ${n} 个全在 names.txt 里"; else echo "不通 驱动名字 ${n} 个，names.txt 缺：$(tr '\n' ' ' <<< "$miss")"; bad=1; fi
grep -vx nvnSetExternalDebuggerEnabledNVX "$T/ours" > "$T/ours2"; neg=$(comm -23 "$T/drv" "$T/ours2")
if [ "$neg" = nvnSetExternalDebuggerEnabledNVX ]; then echo "通 反证：去掉一个名字差集恰好报出它"; else echo "不通 反证：差集是「${neg}」"; bad=1; fi
exit $bad
