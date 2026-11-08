#!/bin/bash
# 直连出库失败分类单测（graphics/tools/direct/direct_lib.sh 的 gap，10-25 总指挥：内容缺口打黄退 3、本款走通用；基础设施出错与判不清的报红）：bash tests/direct_gap_test.sh，约 1 秒
# 从 direct_lib.sh 抠出 say / gap 两个函数，喂各子步骤真实形状的日志（消息原文取自 C# 整份出库 dsh_batch build（graphics/tools/direct/dsh/batch/Build.cs Translate）/ graphics/tools/spirv_msl.py / vk_shaders.py），期望按规则手写：
#   ① NVN 一支结构不支持整份停住（「[RED] <16 位键>: vertex shader of shader type 0 without a VertexB part …」）→ 退 3、黄行「直连缺口：NVN 着色器 翻不了 1 支（<键>：<原因去掉括号尾>）」
#   ② 「[RED] vertex shader without a main0 main function … (<键>)」（原因在前、键在括号尾）→ 退 3，键记成「-」（gap 去掉括号尾）
#   ③ 工具链对不上锁文件（基础设施）→ 不退（调用方报红）
#   ④ 前面有单支非致命红行（影子输入库编不过）、最后是发布核验红行（Build.cs LibPack）→ 不退（只认列出的致命形状）
#   ⑤ 有 Python 异常栈 → 不退（判不清），即使日志里也有①的形状
#   11-01 出库链挪进 C#：①② 由 Build.cs Translate 打（S2A.Dsh DshError 原文），打完整份停住（退 1），direct_lib.sh 按 gap 判缺口
#   ⑥ Vulkan 一支 spirv-cross 失败「[RED] /<路径>: spirv-cross failed: …」→ 退 3、类别「spirv-cross failed: …」；⑦ 「[RED] no SPIR-V files in …」→ 不退
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
{ sed -n '/^say() {/p' "$H/graphics/tools/direct/direct_lib.sh"; sed -n '/^gap() {/,/^}/p' "$H/graphics/tools/direct/direct_lib.sh"; } > $T/fn.sh
[ -s $T/fn.sh ] && grep -q '^gap() {' $T/fn.sh || { echo "不通 抠不出 gap 函数"; exit 1; }
G() { printf '%s\n' "$2" > $T/log; o=$(bash -c "source $T/fn.sh; gap $T/log '$1'; echo 返回" 2>&1); r=$?; }
G "NVN 着色器" $'[RED] 1111111111111111: the shadow-input library does not compile (x): its integer inputs keep the CPU conversion\n[RED] 0123456789abcdef: vertex shader of shader type 0 without a VertexB part in the expected place (control +0x748 0x30 0x0 0x0 0x0)'
ck "① NVN 一支结构不支持 → 退 3、黄行带键与原因（${o}）" '[ $r = 3 ] && [ "$o" = "[直连库] 🟡 直连缺口：NVN 着色器 翻不了 1 支（0123456789abcdef：vertex shader of shader type 0 without a VertexB part in the expected place），现有出库不支持部分出库，本款这次走通用" ]'
G "NVN 着色器" '[RED] vertex shader without a main0 main function, cannot add the depth entry points (0123456789abcdef)'
ck "② main0 缺失（键在括号尾） → 退 3（rc=${r}）" '[ $r = 3 ] && [[ "$o" == *"直连缺口：NVN 着色器 翻不了 1 支（-：vertex shader without a main0 main function, cannot add the depth entry points）"* ]]'
G "NVN 着色器" '[RED] translation chain tools do not match the lock file: spirv-cross: lock 1 / actual missing'
ck "③ 工具链对不上 → 不退、不打黄（rc=${r}）" '[ $r = 0 ] && [ "$o" = 返回 ]'
G "NVN 着色器" $'[RED] 1111111111111111: the shadow-input library does not compile (x): its integer inputs keep the CPU conversion\n[RED] 发布 iOS 库却没编 iOS 那份（DMSH_NO_IOS_LIB）'
ck "④ 单支非致命红行 + 发布核验红行 → 不退（rc=${r}）" '[ $r = 0 ] && [ "$o" = 返回 ]'
G "NVN 着色器" $'Traceback (most recent call last):\n  File "vk_shaders.py", line 9\n[RED] 0123456789abcdef: vertex shader of shader type 0 without a VertexB part in the expected place (x)'
ck "⑤ 有异常栈 → 不退（rc=${r}）" '[ $r = 0 ] && [ "$o" = 返回 ]'
G "Vulkan 着色器" '[RED] /r/romfs/shaders/a.frag.spv: spirv-cross failed: error: unsupported capability'
ck "⑥ Vulkan 一支 spirv-cross 失败 → 退 3、类别带原因（${o}）" '[ $r = 3 ] && [[ "$o" == *"直连缺口：Vulkan 着色器 翻不了 1 支（a.frag.spv：spirv-cross failed: error: unsupported capability）"* ]]'
G "Vulkan 着色器" '[RED] no SPIR-V files in /r/romfs'
ck "⑦ 一个 SPIR-V 都没有 → 不退（rc=${r}）" '[ $r = 0 ] && [ "$o" = 返回 ]'
[ $bad = 0 ] && echo "直连出库失败分类单测全过" || { echo "直连出库失败分类单测有不通"; exit 1; }
