#!/bin/bash
# 翻译器指纹单一来源单测（11-02 总指挥 / 出包线：生产翻译缓存键用 C# DshChain.Xfp，冷改动核查用 Python dmsh_chain.xlate_fp，原先各有一份手写清单、对不上——
#   Python 收了 dsh/batch/*.cs 却不进任何生产键，核查据它报「全部冷翻译」是虚报；Build.cs 里影响翻译的那段反倒不在生产键里）。约 1 分钟：bash tests/xfp_single_source_test.sh
# 期望（按规则写，不经被测实现推）：
#   ① 编出来的 S2A.Dsh 里 DshChain.Xfp（obj/…/DshChain.g.cs）= dmsh_chain.xlate_fp()：两边同一份清单（S2A.Dsh.csproj DshXfpInput）、同一算法
#   ② 清单里有影响翻译产物的 dsh/Dsh.cs、dsh/batch/BuildXlate.cs；没有编排文件 batch/Build.cs / LibPack.cs / Unity.cs / C1Cb.cs / Program.cs，也没有安卓 DshVk.cs
#   ③ 清单里每一类（dsh 源码、BuildXlate、Sha256、dmsh_xlate、宽屏读数格式、加固 gal_spvx、Ryujinx 着色器翻译器、Spv.Generator、宽屏着色器分析）各挑一个文件改一个字节 → 指纹都变
#   ④ 改清单外的编排文件（batch/Build.cs、LibPack.cs）一个字节 → 指纹不变（翻译缓存照命中；11-02 异度3 用 main 缓存仓跑本分支 DLL：Metal 1489 支全复用、产物逐字节同）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=dotnet
O=$(mktemp -d); trap 'rm -rf "$O"' EXIT
G="$H/graphics/tools/direct/dsh/obj/Release/net10.0/DshChain.g.cs"; rm -f "$G"   # 编译期由 DshXfpHash 任务写（S2A.Dsh.csproj）：先删，读到的一定是这次编的
"$DN" build -c Release "$H/graphics/tools/direct/dsh/S2A.Dsh.csproj" -o "$O/out" -nodeReuse:false -v q -p:UseSharedCompilation=false > "$O/build.log" 2>&1 \
  || { echo "不通 S2A.Dsh 编不过：$(tail -3 "$O/build.log")"; exit 1; }
CS=$(grep -o 'Xfp = "[0-9a-f]*"' "$G" 2> /dev/null | cut -d'"' -f2)
R=$(cd "$H/translator" && python3 - <<'PY'
import os, dmsh_chain as d
fs = d.xfp_files(); fp0 = d.xlate_fp(); root = d.ROOT
def bumped(rel):
    return d.xlate_fp(lambda f: open(os.path.join(root, f), 'rb').read() + (b' ' if f == rel else b''))
print('PY', fp0)
print('FILES', ' '.join(fs))
groups = [('dsh', 'graphics/tools/direct/dsh/Dsh.cs'), ('BuildXlate', 'graphics/tools/direct/dsh/batch/BuildXlate.cs'), ('Sha256', 'graphics/tools/direct/compiler/Sha256.cs'),
          ('dmsh_xlate', 'translator/dmsh_xlate/Program.cs'), ('宽屏读数格式', 'graphics/widen/SpirvCbufUseText.cs'), ('加固', 'graphics/metal/gal_spvx.c')]
for tag, pre in (('Ryujinx着色器翻译器', 'compat/tree/src/Ryujinx.Graphics.Shader/'), ('Spv.Generator', 'compat/tree/src/Spv.Generator/'), ('宽屏着色器分析', 'graphics/widen/shader/')):
    groups.append((tag, next((f for f in fs if f.startswith(pre)), pre + '（清单里没有）')))
for tag, rel in groups: print('IN', tag, rel, int(rel in fs and bumped(rel) != fp0))
for rel in ('graphics/tools/direct/dsh/batch/Build.cs', 'graphics/tools/direct/dsh/batch/LibPack.cs'): print('OUT', rel, int(rel not in fs and bumped(rel) == fp0))
PY
)
PYF=$(awk '$1 == "PY" {print $2}' <<< "$R"); FL=$(awk '$1 == "FILES"' <<< "$R")
ck "① C# DshChain.Xfp = Python xlate_fp（${CS:-取不到} / ${PYF:-取不到}）" '[ -n "$CS" ] && [ "$CS" = "$PYF" ]'
ck "② 清单含 dsh/Dsh.cs、batch/BuildXlate.cs" '[[ "$FL" == *" graphics/tools/direct/dsh/Dsh.cs "* ]] && [[ "$FL" == *" graphics/tools/direct/dsh/batch/BuildXlate.cs"* ]]'
for f in Build.cs LibPack.cs Unity.cs C1Cb.cs Program.cs; do ck "② 清单不含编排 batch/$f" '[[ "$FL" != *"/dsh/batch/'"$f"'"* ]]'; done
ck "② 清单不含 DshVk.cs" '[[ "$FL" != *DshVk.cs* ]]'
while read -r _ tag rel ok; do ck "③ 改清单里的 ${tag}（${rel}）一个字节 → 指纹变" '[ "'"$ok"'" = 1 ]'; done < <(grep '^IN ' <<< "$R")
while read -r _ rel ok; do ck "④ 改清单外的编排 ${rel} 一个字节 → 指纹不变" '[ "'"$ok"'" = 1 ]'; done < <(grep '^OUT ' <<< "$R")
[ $bad = 0 ] && echo "翻译器指纹单一来源：全过" || echo "翻译器指纹单一来源：有不通"; exit $bad
