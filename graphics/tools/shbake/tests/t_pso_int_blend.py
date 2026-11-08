#!/usr/bin/env python3
# 特化管线颜色附件描述与运行时同规则（11-01 审计 P2-42）：bash 外直接 python3 graphics/tools/shbake/tests/t_pso_int_blend.py，约 1 秒
# 期望由运行时 gal_state.m pso_desc_colors 的规则手写（不跑被测函数推）：
#   ① pso_gen.MTL_INT_FMTS 的名单 = gal_state.m gal_fmt_is_int 的 case 名单（防两份漂移）；Darwin 上数值 = SDK 头 MTLPixelFormat 枚举值
#   ② RGBA8Unorm(70) 混合开 → blending_state Enabled；RGBA8Uint(73) / R32Sint(54) 混合开 → 没有 blending_state（运行时强制关）
#   ③ RGB9E5Float(93) 写掩码 0x3 → 0xF；0x0 → 0x0；0xF → 0xF；非 RGB9E5 的 0x3 不动；不光栅化（rast=0）写掩码恒 0
#   反证：修前 pso_gen 没有 color_att / MTL_INT_FMTS，整数目标照写 Enabled（本单测对修前文件报「找不到 color_att」）
import ast, os, re, subprocess, sys
H = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(H, '..', '..', '..', '..'))
src = open(os.path.join(R, 'graphics/tools/shbake/pso_gen.py')).read()
G = {}
for node in ast.parse(src).body:
    names = {node.name} if isinstance(node, ast.FunctionDef) else {x.id for x in getattr(node, 'targets', []) if isinstance(x, ast.Name)}
    if names & {'MTL_INT_FMTS', 'MTL_RGB9E5', 'color_att'}: exec(compile(ast.Module([node], []), 'pso_gen.py', 'exec'), G)
fails = []
def ck(cond, msg):
    print(('✓ ' if cond else '✗ ') + msg)
    if not cond: fails.append(msg)
if 'color_att' not in G:
    print('✗ pso_gen.py 里找不到 color_att / MTL_INT_FMTS（修前代码）'); sys.exit(1)
m = re.search(r'int gal_fmt_is_int\(MTLPixelFormat f\) \{(.*?)\n\}', open(os.path.join(R, 'graphics/metal/gal_state.m')).read(), re.S)
rt = set(re.findall(r'MTLPixelFormat(\w+)', m.group(1))) if m else set()
ck(rt and rt == set(G['MTL_INT_FMTS'].values()), f'① 整数格式名单与 gal_state.m gal_fmt_is_int 一致（运行时 {len(rt)} 个、pso_gen {len(G["MTL_INT_FMTS"])} 个）')
if sys.platform == 'darwin':
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    hdr = open(os.path.join(sdk, 'System/Library/Frameworks/Metal.framework/Headers/MTLPixelFormat.h')).read()
    vals = {n: int(v) for n, v in re.findall(r'MTLPixelFormat(\w+)\s*=\s*(\d+)', hdr)}
    want = {**G['MTL_INT_FMTS'], G['MTL_RGB9E5']: 'RGB9E5Float'}
    bad = [f'{n}={k}（SDK {vals.get(n)}）' for k, n in want.items() if vals.get(n) != k]
    ck(not bad, f'① 数值与 SDK MTLPixelFormat.h 一致（核 {len(want)} 个{"；不符 " + "、".join(bad) if bad else ""}）')
ca = G['color_att']
ck(ca(70, 0xF, 1, 0, 1, 0, 0, 1, 0, 1).get('blending_state') == 'Enabled', '② RGBA8Unorm 混合开 → Enabled')
for pf, n in ((73, 'RGBA8Uint'), (54, 'R32Sint')):
    ck('blending_state' not in ca(pf, 0xF, 1, 0, 1, 0, 0, 1, 0, 1), f'② {n} 混合开 → 不写 blending_state（运行时强制关）')
for wm, want in ((0x3, 0xF), (0x0, 0x0), (0xF, 0xF)):
    ck(ca(93, wm, 0, 0, 0, 0, 0, 0, 0, 1)['write_mask'] == want, f'③ RGB9E5Float 写掩码 {wm:#x} → {want:#x}')
ck(ca(70, 0x3, 0, 0, 0, 0, 0, 0, 0, 1)['write_mask'] == 0x3, '③ 非 RGB9E5 的部分写掩码不动')
ck(ca(93, 0x3, 0, 0, 0, 0, 0, 0, 0, 0)['write_mask'] == 0, '③ 不光栅化 → 写掩码 0')
print(f't_pso_int_blend：{"全过" if not fails else "失败 " + str(len(fails))}')
sys.exit(1 if fails else 0)
