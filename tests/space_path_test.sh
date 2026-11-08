#!/bin/bash
# 路径带空格 / 中文时出包链里的 make 照样能走（tools/nospace.sh；10-25 启动器实测 Hades：引擎与产物根在「~/Library/Application Support」下，
#   直连库 libnxgal 与 make ios 被 make 按空格拆成多个目标全失败）：bash tests/space_path_test.sh（约 20 秒，只做 make -n 与静态核对，不真编）
# 期望（按规则手写）：
#   ① 无空格路径 s2a_nospace 原样返回；带空格的返回不带空格的软链、同一路径两次同一别名、软链指回原路径
#   ② 仓库拷到「带 空格/引擎 树」：对照组——直接用真路径 make -n 直连库 libnxgal → 失败（证明这条路径真会把 make 拆坏）
#   ③ 用别名（-C / ROOT / 目标）make -n：直连库 libnxgal、渲染器 iOS 库（graphics/metal ios）、make ios（IOS_MODS / BUILD 在「产物 根」）都成功，
#      展开出的命令里不出现带空格的真路径
#   ④ 出包脚本（pack/stage_direct.sh、pack/ipa.sh）里每条 make 的 -C / 目标都用别名（${RN} / ${WN}），没有直接拿 "$R" / "$W" 喂 make 的
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/nospace.sh"
D="$T/带 空格/引擎 树"; M="$T/产物 根"; mkdir -p "$D" "$M"
a1=$(s2a_nospace "$T/no_space"); a2=$(s2a_nospace "$D"); a3=$(s2a_nospace "$D")
ck "① 无空格原样（${a1}）；带空格 → ${a2}（无空格、两次一致、指回原路径）" '[ "$a1" = "$T/no_space" ] && [[ "$a2" != *" "* ]] && [ "$a2" = "$a3" ] && [ "$(readlink "$a2")" = "$D" ]'
# 拷仓库（不拷 docs 与 Ryujinx 源码树，只留 libnxgal 要的抗锯齿查找表）
(cd "$H" && git ls-files -z | grep -zv '^compat/\|^docs/'; git ls-files -z compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Textures) | (cd "$H" && tar --null -T - -cf -) | tar -xf - -C "$D"
# make ios 展开链接参数时会现编 C# / vpx / opus 三个宿主库（分钟级、要 Ryujinx 源码树）：拷出的树里换成只打印库路径的桩，这里只测 make 对路径的处理
for f in services/nxaot.sh services/vpx/build.sh services/opus/build.sh; do printf '#!/bin/bash\necho %s\n' "$(s2a_nospace "$D")/build/桩/$(basename "$(dirname "$f")").a" > "$D/$f"; done
make -n -s -C "$D/graphics/metal" "$D/build/gal/libnxgal.dylib" > "$T/raw.log" 2>&1; r2=$?
ck "② 对照：真路径（带空格）make -n 直连库 → rc=${r2}（非 0：$(grep -m1 -E 'No rule|Stop' "$T/raw.log" | cut -c1-80)）" '[ $r2 != 0 ]'
RN=$(s2a_nospace "$D"); MN=$(s2a_nospace "$M")
make -n -s -C "$RN/graphics/metal" ROOT="$RN" "$RN/build/gal/libnxgal.dylib" > "$T/gal.log" 2>&1; r3=$?
make -n -s -C "$RN/graphics/metal" ROOT="$RN" ios > "$T/galios.log" 2>&1; r4=$?
printf 'NPDM' > "$M/main.npdm"; : > "$M/main.patched.bin"; : > "$M/main.fixups.tsv"; : > "$M/main.gates.tsv"
make -n -s -C "$RN" ROOT="$RN" ios S2A_CS=0 IOS_MODS="$MN" BUILD="$MN/build" IOS_BUNDLE=t.b IOS_DISPLAY="带 空格 名" > "$T/ios.log" 2>&1; r5=$?
sp=$(cat "$T/gal.log" "$T/galios.log" "$T/ios.log" | sed -E 's/"[^"]*"//g' | grep -c -F "带 空格/引擎 树")   # 加了引号的（调试映射 "$(CURDIR)"）不算
ck "③ 别名 make -n：直连库 rc=${r3}、渲染器 iOS 库 rc=${r4}、make ios rc=${r5}（$(grep -m1 -E 'No rule|Stop|Error' "$T/ios.log" | cut -c1-80)）；展开命令里没加引号的带空格真路径 ${sp} 处" \
  '[ $r3 = 0 ] && [ $r4 = 0 ] && [ $r5 = 0 ] && [ "$sp" = 0 ]'
bm=$(perl -ne 'next if /^\s*#/ or !/(^|[^a-z_-])make [^>]*-C /; s/^.*?(?:^|[^a-z_-])(make .*)$/$1/; s/ (?:>>?|\|\||2>).*$//; print "$ARGV:$.: $_\n" if /"\$[RW][\/"]/; close ARGV if eof' "$H/pack/stage_direct.sh" "$H/pack/ipa.sh" "$H/pack/stage_extract.sh")   # 每行只看第一个 make 起到重定向 / || 之前（重定向用真路径没问题）
ck "④ 出包脚本喂 make 的路径都是别名（直接用 \$R / \$W 的：$(echo "${bm:-无}" | cut -c1-160)）" '[ -z "$bm" ]'
[ $bad = 0 ] && echo "space_path 单测全过" || { echo "space_path 单测有不通"; exit 1; }
