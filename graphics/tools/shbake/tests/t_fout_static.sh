#!/bin/bash
# 片元输出「按整数位写」静态判定单测（graphics/tools/shbake/FoutStatic.cs，ShaderBake 5d 用）：手写 SPIR-V（tests/fout_static/*.spvasm），期望掩码写在各文件头、手算。
#   int_fs：0 号按分量写整数 bitcast、1 号写浮点、2 号整体写含一个整数 bitcast 分量、深度内置写 bitcast → 5；反证 float_fs（同一支全写浮点值）→ 0、uint_fs（输出本身是 uint，Uint 变体的形状）→ 0
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd); H=$R/graphics/tools/shbake/tests/fout_static
O=${T_VTG_OUT:-$R/build/t_vtg}; mkdir -p "$O"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build_fs.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build_fs.log）"; exit 1; }
n=0; bad=0
for c in int_fs:5 float_fs:0 uint_fs:0; do
  f=${c%%:*}; want=${c#*:}; n=$((n + 1))
  spirv-as --target-env vulkan1.0 "$H/$f.spvasm" -o "$T/$f.spv" && spirv-val --target-env vulkan1.0 "$T/$f.spv" || { echo "✗ $f 汇编 / 校验失败"; bad=$((bad + 1)); continue; }
  got=$("$O/bin/S2A.ShBake" fout-int-mask "$T/$f.spv")
  if [ "$got" = "$want" ]; then echo "✓ ${f}：按整数位写的位置掩码 期望 $want → 真结果 $got"; else echo "✗ ${f}：期望 $want → 真结果 $got"; bad=$((bad + 1)); fi
done
echo "t_fout_static：$n 项，失败 $bad"
[ $bad = 0 ]
