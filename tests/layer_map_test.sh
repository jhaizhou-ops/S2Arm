#!/bin/bash
# 门禁只看：tools/layer_map.py tools/layer_map.tsv
# 分层地图（tools/layer_map.py / layer_map.tsv，架构梳理阶段一 S1）单测，约 1 秒：bash tests/layer_map_test.sh
# 期望（按修订稿 4.1.3 / 4.4.1 手写，不跑被测实现推）：
#   ① 真仓库：check 0 未覆盖、0 空行
#   ② which 最长前缀：graphics/nvn/gfx/nvn/x.c → 共用层；graphics/nvn/gfx/vk/x.m → Metal档；graphics/nvn/host_adapt.m → Metal档；runtime/src/host_main.c → 终端壳；
#      runtime/src/loader.c → 共用层；android/native/nvn/x.c → 直连Vulkan；android/native/plat_android.c → 直连Vulkan；
#      android/app/x.java → 安卓自己；pack/ipa.sh → 终端壳；pack/stage_direct.sh → 共用层；compat/patches/x.patch → 按补丁分类；docs/x.md → 工具与文档
#   ③ 负对照：临时仓库多一个顶层目录 newdir/ → check 红并点名 newdir/；表里多一行指向不存在的目录 → 红并点名行号
#   ④ 格式：层写错 / 列数不对 → 红（不静默当未覆盖）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); M=$H/tools/layer_map.py; T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o1=$(python3 "$M" check "$H" 2>&1); r1=$?
ck "① 真仓库全覆盖（${o1##*$'\n'}）" '[ $r1 = 0 ]'
f() { python3 "$M" which "$1" | cut -f4; }
w="$(f graphics/nvn/gfx/nvn/x.c) $(f graphics/nvn/gfx/vk/x.m) $(f graphics/nvn/host_adapt.m) $(f runtime/src/host_main.c) $(f runtime/src/loader.c) $(f android/native/nvn/x.c) $(f android/native/plat_android.c) $(f android/app/x.java) $(f pack/ipa.sh) $(f pack/stage_direct.sh) $(f compat/patches/x.patch) $(f docs/x.md)"
ck "② 最长前缀：${w}" '[ "$w" = "共用层 Metal档 Metal档 终端壳 共用层 直连Vulkan 直连Vulkan 安卓自己 终端壳 共用层 按补丁分类 工具与文档" ]'
R=$T/r; mkdir -p "$R/tools" "$R/runtime/src" "$R/newdir"; git -C "$R" init -q
printf '前\n' > "$R/runtime/src/a.c"; printf 'x\n' > "$R/newdir/b.txt"; cp "$M" "$R/tools/"; printf '# 头\nruntime/src/\t核心\t原生\t共用层\ntools/\t工具与测试\t工具\t工具与文档\nghost/\t核心\t幽灵\t共用层\n' > "$R/tools/layer_map.tsv"
git -C "$R" add -A
o3=$(python3 "$R/tools/layer_map.py" check "$R" 2>&1); r3=$?
ck "③ 新顶层目录 + 空行 → 红（rc=${r3}）" '[ $r3 = 1 ] && grep -q "没有覆盖 newdir/" <<< "$o3" && grep -q "layer_map.tsv:4 前缀 ghost/" <<< "$o3"'
printf 'runtime/src/\t内核\t原生\t共用层\n' > "$R/tools/layer_map.tsv"
o4=$(python3 "$R/tools/layer_map.py" check "$R" 2>&1); r4=$?
printf 'runtime/src/\t核心\t原生\n' > "$R/tools/layer_map.tsv"
o4b=$(python3 "$R/tools/layer_map.py" check "$R" 2>&1); r4b=$?
ck "④ 层写错 / 少一列 → 红（rc=${r4} ${r4b}）" '[ $r4 = 1 ] && grep -q "层「内核」" <<< "$o4" && [ $r4b = 1 ] && grep -q "要四列" <<< "$o4b"'
[ $bad = 0 ] && echo "layer_map 单测全过"; exit $bad
