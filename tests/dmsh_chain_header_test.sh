#!/bin/bash
# 直连翻译链头文件核对：宿主按 graphics/nvn/gfx/nvn/dmsh_chain.h 里写死的链号找库（b-<链号>/），出库按链文件内容现算的链号（dmsh_chain.py version()）写库。
# 改了链文件忘跑 dmsh_chain.py --header，两边就对不上：宿主找旧号的库、新出的库没人认（10-26 graphics/widen-uvmap：头文件还是 2b1fd180ed01，库是 e6cfabc96777，一份 Mac 根白出）。
#   ① 头文件 = header_text(version()) 逐字相同（链号对、格式对）
#   ② 链号只跟接口版本 ABI 走（10-30 去全局链号）：沙箱里拷一份链文件、给沙箱里的 dmsh_chain.py 末尾加一行注释——链号必须不变、翻译指纹 xlate_fp 必须变
#      （翻译器改动进单支键，不再整库换目录）；ABI 加 1 时链号必须变
#   ③ 预编译翻译器 dmsh_xlate_bin 是按仓库源码编的：它的 --source-sha = dmsh_chain.xlate_source_sha()（含 compat/tree 着色器翻译器与 graphics/widen/shader 逐文件指纹，10-30 两份 Ryujinx 合一）。
#      通用线改了 compat/tree 的 Shader / Common / Spv 或宽屏着色器分析而没重编 dmsh_xlate_bin，这里就红（原先要到出包时链核对才拦）
#   ④ 反证：宽屏着色器源码拷进沙箱、指过去，指纹与原来相同；改一个文件一个字节，指纹必须变
# 门禁覆盖：translator/dmsh_chain.py
# 门禁覆盖：graphics/tools/direct/dsh/batch/* translator/dmsh_xlate/* translator/dmsh_chain.lock graphics/nvn/gfx/ios/tools/ios_metal.py graphics/nvn/gfx/nvn/dmsh_chain.h
# 门禁覆盖：graphics/metal/gal_tessxc.* graphics/third_party/spirv_cross/spirv_msl.cpp graphics/third_party/spirv_cross/spirv_cross.cpp graphics/third_party/spirv_cross/spirv_cross_c.cpp
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/* compat/tree/src/Ryujinx.Common/* compat/tree/src/Spv.Generator/* graphics/widen/shader/* translator/dmsh_xlate_bin/*
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$R" "$T" <<'PY'
import os, shutil, sys
R, T = sys.argv[1:3]; tools = os.path.join(R, 'translator'); sys.path.insert(0, tools)
import dmsh_chain
bad = 0
v = dmsh_chain.version(); want = dmsh_chain.header_text(v); got = open(dmsh_chain.HEADER).read()
ok = got == want; bad += not ok
hv = got.split('"')[1] if got.count('"') >= 2 else '?'
print(f'{"✓" if ok else "✗"} ① 头文件 = 按链文件现算：期望 {v} → 真结果 {hv}' + ('' if ok else '（改了链文件后在最终的树上跑 python3 translator/dmsh_chain.py --header 并提交）'))
# ② 链号只跟 ABI 走、翻译指纹只跟翻译器指纹输入走（11-02 起两者分开：指纹输入的唯一来源是 S2A.Dsh.csproj DshXfpInput，dmsh_chain.xlate_fp 按同一清单算）：
#   按读取函数换内容，不动工作树——改 dmsh_chain.py 自己：链号不变、翻译指纹不变（它不在指纹输入里）；改指纹输入里的 Dsh.cs：翻译指纹变、链号不变；ABI 加 1：链号变
src = os.path.join(dmsh_chain.ROOT, 'graphics/tools/direct/dsh/Dsh.cs')
def read_with(path, extra):
    return lambda f: open(os.path.join(dmsh_chain.ROOT, f), 'rb').read() + (extra if os.path.join(dmsh_chain.ROOT, f) == path else b'')
fp0 = dmsh_chain.xlate_fp(); fp_self = dmsh_chain.xlate_fp(read_with(os.path.join(dmsh_chain.ROOT, 'translator/dmsh_chain.py'), b'# t\n'))
fp_dsh = dmsh_chain.xlate_fp(read_with(src, b'// t\n')); bumped = dmsh_chain.version(dmsh_chain.ABI + 1)
ok = 'graphics/tools/direct/dsh/Dsh.cs' in dmsh_chain.xfp_files() and fp_self == fp0 and fp_dsh != fp0 and dmsh_chain.version() == v and bumped != v; bad += not ok
print(f'{"✓" if ok else "✗"} ② 翻译指纹 {fp0}：改 dmsh_chain.py → {fp_self}（应不变）、改 Dsh.cs → {fp_dsh}（应变）；链号 {v}，ABI 加 1 → {bumped}（应变）')
# ③ 预编译翻译器按仓库源码编
import subprocess
# dotnet 按 vulkan_backend_test 同一顺序找（门禁机的 dotnet 可能在 ~/.dotnet，翻译器自带的启动器不一定找得到运行时）
dn = os.environ.get('DOTNET') or os.path.expanduser('~/.dotnet/dotnet')
if not os.access(dn, os.X_OK): dn = shutil.which('dotnet') or 'dotnet'
emb = subprocess.run([dn, os.path.join(tools, 'dmsh_xlate_bin/dmsh_xlate.dll'), '--source-sha'], capture_output=True, text=True).stdout.strip(); here = dmsh_chain.xlate_source_sha()
ok = emb == here; bad += not ok
print(f'{"✓" if ok else "✗"} ③ 预编译翻译器的源码指纹 = 仓库现算：期望 {here} → 真结果 {emb or "（取不到）"}' + ('' if ok else '（改了 compat/tree 着色器翻译器 / graphics/widen/shader / dmsh_xlate 源码后：dotnet build translator/dmsh_xlate/dmsh_xlate.csproj -c Release -o <临时目录> -p:PathMap=<仓库根>=/s2arm -p:EnableSourceLink=false -p:EnableSourceControlManagerQueries=false，只把已跟踪的产物拷进 dmsh_xlate_bin，锁文件只改翻译器那几行，再 dmsh_chain.py --header）'))
# ④ 反证：宽屏着色器源码进沙箱
W = os.path.join(T, 'widen_shader'); shutil.copytree(dmsh_chain.LIB_SOURCES[1][1], W, ignore=shutil.ignore_patterns('obj', 'bin'))
dmsh_chain.LIB_SOURCES = (dmsh_chain.LIB_SOURCES[0], ('widen', W, dmsh_chain.LIB_SOURCES[1][2]))
s1 = dmsh_chain.xlate_source_sha()
cs = sorted(os.path.join(d, f) for d, _, fs in os.walk(W) for f in fs if f.endswith('.cs'))[0]
with open(cs, 'ab') as fp: fp.write(b' ')
s2 = dmsh_chain.xlate_source_sha()
ok = s1 == here and s2 != here; bad += not ok
print(f'{"✓" if ok else "✗"} ④ 反证：沙箱拷贝指纹 {s1}（应 = {here}），改一个 .cs 一个字节后 {s2}（应 ≠ {here}）')
print(f'dmsh_chain_header_test：4 项，失败 {bad}')
sys.exit(1 if bad else 0)
PY
