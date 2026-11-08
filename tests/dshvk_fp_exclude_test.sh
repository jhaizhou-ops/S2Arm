#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/S2A.Dsh.csproj translator/dmsh_chain.py pack/stage_inputs/direct.tsv graphics/tools/direct/dsh/DshVk.cs tests/dshvk_fp_exclude_test.sh
# DshVk.cs（安卓 Vulkan 导出：XGS / _b.spv）不进 Metal 直连的三处指纹（约 2 秒）：bash tests/dshvk_fp_exclude_test.sh
#   11-02 合入线审 #1254：只改 DshVk.cs 却让全部款 Metal 冷翻译一次——三处都把它算进去了：S2A.Dsh.csproj 的翻译器指纹 DshXfpInput（@(Compile) 全收）、
#   dmsh_chain.py 的 xlate_fp（每支着色器的缓存键，dsh/*.cs 全收）、pack/stage_inputs/direct.tsv 的出包直连阶段键。Metal 产物不经它，三处都剔除。
#   剔除成立的前提（本测试断言，任一条不成立就红，要么把 DshVk.cs 放回三处指纹、要么拆开引用）：
#   ① Metal 出库路径（dsh/、dsh/batch/、dmsh_xlate、宽屏读文本、compiler/Sha256.cs 等 S2A.Dsh 编进来的源码，DshVk.cs 自身除外）不出现标识符 DshVk
#   ② DshVk.cs 只声明一个顶层类型 DshVk，且没有 partial、扩展方法（this 参数）、模块初始化器——它没法从旁改变别的代码的行为
#   ③ 三处指纹都不含 DshVk.cs，且都还含 Dsh.cs（正对照：不是整个清单读空了）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); D=$H/graphics/tools/direct/dsh; bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
SRC=$(cd "$H" && ls graphics/tools/direct/dsh/*.cs graphics/tools/direct/dsh/batch/*.cs graphics/tools/direct/compiler/Sha256.cs translator/dmsh_xlate/Program.cs graphics/widen/SpirvCbufUseText.cs | grep -v '/DshVk\.cs$')
ck "① Metal 路径源码清单读到了（正对照：含 Dsh.cs）" 1 "$(grep -c '^graphics/tools/direct/dsh/Dsh\.cs$' <<< "$SRC")"
ck "① Metal 路径源码不引用 DshVk" "" "$(cd "$H" && grep -l -w 'DshVk' $SRC)"
V=$D/DshVk.cs
ck "② DshVk.cs 顶层类型只有 DshVk 一个" "public static class DshVk" "$(grep -E '^    (public |internal )?(static |sealed |abstract )*(partial )?(class|struct|record|enum|interface) ' "$V" | sed 's/^ *//; s/ *{.*//')"
ck "② DshVk.cs 无 partial / 扩展方法 / 模块初始化器" 0 "$(grep -c -E '\bpartial\b|\(this [A-Za-z]|ModuleInitializer' "$V")"
X=$(cd "$D" && dotnet msbuild S2A.Dsh.csproj -getItem:DshXfpInput 2>/dev/null | python3 -c 'import json, sys; print("\n".join(i["Identity"] for i in json.load(sys.stdin)["Items"]["DshXfpInput"]))') || X=""
ck "③ 翻译器指纹 DshXfpInput 含 Dsh.cs（正对照）" 1 "$(grep -c '^Dsh\.cs$' <<< "$X")"
ck "③ 翻译器指纹 DshXfpInput 不含 DshVk.cs" 0 "$(grep -c 'DshVk\.cs' <<< "$X")"
F=$(cd "$H/translator" && python3 -c 'import dmsh_chain; print("\n".join(dmsh_chain.xfp_files()))')   # 11-02 起 xlate_fp 与生产指纹同一份清单（S2A.Dsh.csproj DshXfpInput）
ck "③ xlate_fp 输入含 dsh/Dsh.cs（正对照）" 1 "$(grep -c '/dsh/Dsh\.cs$' <<< "$F")"
ck "③ xlate_fp 输入不含 DshVk.cs" 0 "$(grep -c 'DshVk\.cs' <<< "$F")"
T=$H/pack/stage_inputs/direct.tsv
ck "③ 出包直连阶段键含 dsh/Dsh.cs（正对照）" 1 "$(grep -c '^入	graphics/tools/direct/dsh/Dsh\.cs	' "$T")"
ck "③ 出包直连阶段键不含 DshVk.cs（只看第二列路径，理由文字里提到不算）" 0 "$(awk -F'\t' '$2 ~ /(^|\/)DshVk\.cs$/' "$T" | wc -l | tr -d ' ')"
[ $bad = 0 ] && echo "dshvk_fp_exclude：全过" || echo "dshvk_fp_exclude：有失败"; exit $bad
