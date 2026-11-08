#!/bin/bash
# 门禁覆盖：graphics/metal/tools/nxgal_win.py graphics/metal/tools/win_posix.h graphics/metal/gal_tessxc.c graphics/metal/gal_tessxc.m graphics/metal/gal_vpullc.c graphics/metal/gal_vpull.m graphics/metal/gal_tess.h graphics/metal/gal_internal.h graphics/tools/direct/dsh/SpvCross.cs graphics/tools/direct/dsh/batch/Build.cs tests/nxgal_win_exports_test.sh
# Windows 出包机小库 nxgal.dll 的导出要盖住 S2A.Dsh 在 Windows 上会调的 DllImport("nxgal")（11-05 天眼巫师3：旧小库没有 nxgal_dmsh_xc_tess，
#   外壳 / 域着色器 22 支每支翻译失败，只记成缺键、整单照绿）。bash tests/nxgal_win_exports_test.sh（纯静态，约 1 秒；真编与 Mac 对拍见坑记录）
# 期望（手写，不跑被测实现推）：
#   ① nxgal_win.py 导出表 ⊇ 出包工具（graphics/tools/ 下全部 C#，不含 tests/）的 DllImport("nxgal") 名，只除 nxgal_dmsh_xc——它只经 NxgalSpvCross.Msl / Glsl450 调，
#      出库进程 dsh_batch 的翻译器固定是 InprocSpvCross（libspvc_cli，BuildXlate.cs XlateSetup），不进这个类；这一豁免绑定该前提（⑤）
#   ⑤ 豁免的前提：BuildXlate.cs XlateSetup 返回 InprocSpvCross（改成别的就红，豁免随之作废）
#   ⑥ Mac 整库同样成立：出包工具调的每个 nxgal 入口在 graphics/metal 源码（*.m / *.c）里都有 NXGAL_API 定义
#   ② 点名：nxgal_dmsh_xc_tess、nxgal_dmsh_xc_free、nxgal_dmsh_spill、nxgal_spv_harden、nxgal_spv_free、nxgal_dmsh_color_round 都在
#   ③ 曲面段源码是纯 C：gal_tessxc.c / gal_vpullc.c / gal_tess.h 里没有 #import、没有 Metal / Foundation 头；gal_tessxc.m 只剩 #include "gal_tessxc.c"
#   ④ 出库遇到 EntryPointNotFoundException / DllNotFoundException 整份退出（Build.cs 原生库缺件那一行）
# 负对照（手做，见坑记录）：nxgal_win.py 的 SRCS 去掉 gal_tessxc.c → ① ② 红
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import glob, os, re, sys
H = sys.argv[1]; bad = 0
def chk(name, ok, got):
    global bad; bad += not ok; print(f'{"通" if ok else "不通"} {name}：{got}')
sys.path.insert(0, os.path.join(H, 'graphics/metal/tools')); import nxgal_win
have = set(nxgal_win.exports())
used = set()
for f in glob.glob(os.path.join(H, 'graphics/tools/**/*.cs'), recursive=True):
    if '/tests/' in f.replace(os.sep, '/'): continue
    used |= set(re.findall(r'DllImport\("nxgal"\)\][^;]*?\b(nxgal_\w+)\s*\(', open(f, encoding='utf-8').read()))
need = used - {'nxgal_dmsh_xc'}
chk('① 导出表盖住 Windows 会调的 DllImport', need <= have, f'要 {len(need)} 个，缺 {sorted(need - have) or "无"}')
named = {'nxgal_dmsh_xc_tess', 'nxgal_dmsh_xc_free', 'nxgal_dmsh_spill', 'nxgal_spv_harden', 'nxgal_spv_free', 'nxgal_dmsh_color_round'}
chk('② 点名的 6 个导出都在', named <= have, f'缺 {sorted(named - have) or "无"}')
M = os.path.join(H, 'graphics/metal'); objc = []
for n in ('gal_tessxc.c', 'gal_vpullc.c', 'gal_tess.h'):
    t = open(os.path.join(M, n), encoding='utf-8').read()
    if re.search(r'^\s*#\s*import\b|<Metal/|<Foundation/|\bNSString\b|\bid<', t, re.M): objc.append(n)
m = [l for l in open(os.path.join(M, 'gal_tessxc.m'), encoding='utf-8').read().splitlines() if l.strip() and not l.lstrip().startswith('//')]
chk('③ 曲面段纯 C、gal_tessxc.m 只剩 include', not objc and m == ['#include "gal_tessxc.c"'], f'带 Objective-C / Metal 的 {objc or "无"}；.m 非注释行 {m}')
b = open(os.path.join(H, 'graphics/tools/direct/dsh/batch/Build.cs'), encoding='utf-8').read()
chk('④ 原生库缺件整份退出', bool(re.search(r'EntryPointNotFoundException.*DllNotFoundException.*Environment\.Exit\(1\)', b)), '')
xs = open(os.path.join(H, 'graphics/tools/direct/dsh/batch/BuildXlate.cs'), encoding='utf-8').read()
m = re.search(r'static ISpvCross XlateSetup\(\)\s*\{(.*?)\n    \}', xs, re.S)
chk('⑤ 豁免 nxgal_dmsh_xc 的前提：出库翻译器是 InprocSpvCross', bool(m) and 'return new InprocSpvCross(' in m.group(1) and 'NxgalSpvCross' not in m.group(1), '')
defs = set()
for f in glob.glob(os.path.join(M, '*.m')) + glob.glob(os.path.join(M, '*.c')): defs |= set(re.findall(r'^NXGAL_API\b[^(]*?\b(nxgal_\w+)\s*\(', open(f, encoding='utf-8').read(), re.M))
chk('⑥ Mac 整库：出包工具调的入口都有 NXGAL_API 定义', used <= defs, f'用 {len(used)} 个，没定义的 {sorted(used - defs) or "无"}')
print(f'{"✓" if not bad else "✗"} nxgal_win_exports：{bad} 不通')
sys.exit(1 if bad else 0)
PY
