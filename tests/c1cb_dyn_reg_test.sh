#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/batch/C1Cb.cs graphics/tools/direct/dsh/batch/Build.cs tests/c1cb_dyn_reg_test.sh
# 出库两张表（c1 越界核查 / 常量读范围，C1Cb）认动态句柄数组的 "reg": null（约 30 秒，编 dsh_batch）：bash tests/c1cb_dyn_reg_test.sh
#   11-02 马力欧派对 超级巨星：6370 支片元带 Ryujinx 追不到单一槽的动态句柄数组（fp_tcubes_cb0_40000000 array<texturecube<float>, 32>，反射 kind tex、"reg": null），
#   C1Cb.BindingsOf 把 null 当「reg 不是整数」抛异常，整份出库 rc=134。旧 Python c1_guard 用 b.get('reg')，None 照收
#   夹具：一支 k_b.metal（读 fp_c3 第 2 个 vec4）+ k_b.json（cbuf reg 0 + 上述动态数组 reg null）；dsh_batch --c1cb <目录>
#   期望（手写）：退出 0、输出有 k_b.metal 一行，且与去掉动态数组那项的同一支逐字节相同（null 照没有，不影响结果）；
#   反证：把 null 改成字符串 "x"（真的非整数）→ 照旧抛「reg 不是整数」、退出非 0（不是一律放过）（并入出包线 t_c1cb.py 的两条，11-02 两线撞同一修复，以本支为准）
#   另核 Build.cs 汇总：动态句柄数组（名以 _cb0_40000000 结尾、类型 array<）不计入「slot was not decoded / unrecognized binding kind」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/c1cb_dyn.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
(cd "$H/translator" && python3 -c 'import dsh_batch, shlex; print(shlex.join(dsh_batch.build()[0]))') > "$T/cmd" 2> "$T/b.log" || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
CMD=$(tail -n 1 "$T/cmd"); [ -n "$CMD" ] || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
mkdir -p "$T/a" "$T/b" "$T/c"
cat > "$T/a/k_b.metal" <<'EOF'
struct _17 { float4 _m0[4096]; };
struct spvDescriptorSetBuffer0 { constant _17* fp_c3 [[id(0)]]; };
fragment float4 main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]) { return spvDescriptorSet0.fp_c3->_m0[1u]; }
EOF
J='{"key": "k_b", "route": "B", "bindings": [{"msl_name": "fp_c3", "msl_type": "constant _17*", "arg_id": 0, "kind": "cbuf", "reg": 0}, {"msl_name": "fp_tcubes_cb0_40000000", "msl_type": "array<texturecube<float>, 32>", "arg_id": 1, "kind": "tex", "reg": REG}]}'
echo "${J/REG/null}" > "$T/a/k_b.json"; cp "$T/a/k_b.metal" "$T/b/"; echo "${J/REG/\"x\"}" > "$T/b/k_b.json"
cp "$T/a/k_b.metal" "$T/c/"; echo '{"key": "k_b", "route": "B", "bindings": [{"msl_name": "fp_c3", "msl_type": "constant _17*", "arg_id": 0, "kind": "cbuf", "reg": 0}]}' > "$T/c/k_b.json"
o=$($CMD --c1cb "$T/a" -j 1 2> "$T/a.err"); r=$?
ck "动态句柄数组 reg null：退出 0" 0 "$r"
ck "动态句柄数组 reg null：输出有 k_b.metal 一行" 1 "$(grep -c '^k_b.metal	' <<< "$o")"
ck "动态句柄数组 reg null：与去掉这一项的同一支输出逐字节相同" 1 "$([ "$o" = "$($CMD --c1cb "$T/c" -j 1 2>/dev/null)" ] && echo 1 || echo 0)"
$CMD --c1cb "$T/b" -j 1 > /dev/null 2> "$T/b.err"; r=$?
ck "反证：reg 是字符串照旧报错（退出非 0、报「reg 不是整数」）" 1 "$([ $r != 0 ] && grep -q 'reg 不是整数' "$T/b.err" && echo 1 || echo 0)"
B=$H/graphics/tools/direct/dsh/batch/Build.cs
ck "Build 汇总两项都排除动态句柄数组" 2 "$(grep -c 'Binds(x).Any(b => !Dyn(b) &&' "$B")"
ck "Dyn 判据与宿主 nvn_refl.m 同（_cb0_40000000 + array<）" 1 "$(grep -c 'EndsWith("_cb0_40000000", StringComparison.Ordinal) && b.GetValueOrDefault("msl_type") is string t && t.StartsWith("array<"' "$B")"
[ $bad = 0 ] && echo "c1cb_dyn_reg：全过" || echo "c1cb_dyn_reg：有失败"; exit $bad
