#!/usr/bin/env python3
# 直连库宽屏外推尾段单测（S2A.Dsh DshCompiler.VsPush：graphics/tools/direct/dsh/Dsh.cs，经 dsh_cmp --fn vs_push 调（dshfn.py））：把 VsPush 插进顶点函数的那段原文抽出来放进计算核，在 GPU 上逐例跑。
# 期望值按宽屏线给的规格式子手算（与 graphics/widen/shader/SpirvEdgePush.cs 同一式子），k = 1.2：外推量 d = 1 − 1/k = 1/6，门限² e2 = ((1 − 3e-3)/k)²，带宽比² = ((1 + 3e-3)/(1 − 3e-3))²：
#   ① 参数全 0：位置逐位不变；② 不收缩、t = 0.832（t² 落在 [e2, e2 × 带宽比²] 窄带里）→ x + d；③ 同 ②、t = −0.832、w = 2 → x − d·w；
#   ④ 不收缩、t = 0.95（窄带外，游戏自己排在两侧的元素）→ 不动；⑤ 不收缩、t = 0.5（画布内）→ 不动；
#   ⑥ 收缩 z = d、x = 1（画布边）→ x(1 − z) + d = 1（恰好回到原值，不进反证）；⑦ 收缩、x = 0.5（画布内）→ 只收缩 0.5(1 − z)；⑧ 收缩、x = −2（收缩后 t = −5/3，已在屏幕外）→ 只收缩 −2(1 − z)；y / z / w 一律不动
#   ⑬⑭ 裁剪空间写死的全屏三角形顶点 x = −1、3（w = 1），外推开、收缩量 NoBandZ = 1e-6（核心推满的实际参数）：屏幕边上及外的顶点不推（t² < (1 − 3‰)² 才推，11-05；±1 乘 1 − 1e-6 后仍算在屏幕边上）→ 只乘 1 − 1e-6；
#     旧规则推成 −1 − d、3 + d，三角形插值的采样坐标整体左移 pad/2（旷野之息光照合成一深一浅两个林克）——旧尾段跑这两例必红
# 反证：同一批例子用不带尾段的核跑，外推的 ②③⑦⑧ 必须对不上（判据不会绿着失效）。用法：t_push.py <t_push_run 可执行>
import os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn
VS = 'struct main0_out\n{\n    float4 gl_Position [[position]];\n};\n\nvertex main0_out main0(uint vid [[vertex_id]])\n{\n    main0_out out = {};\n    out.gl_Position = float4(0.0);\n    return out;\n}\n'
pushed, noarg = [r.get('ok') or '' for r in dshfn.batch([('vs_push', [VS]), ('vs_push', [VS.replace('(uint vid [[vertex_id]])', '()')])])]
m = re.search(r'\n    (\{ float4 s2a_q = s2a_push; float4 .*?\})\n    (\{ float4 s2a_q = s2a_push; if \(s2a_q\.w > 0\.0f\) .*?\} \})\n    return out;', pushed)   # 横向段 + 竖向段（11-05）
if not m or ', constant float4& s2a_push [[buffer(13)]])' not in pushed or noarg.count('main0(constant float4& s2a_push [[buffer(13)]])') != 1: sys.exit(f'✗ vs_push 没按约定插参数 / 尾段：\n{pushed}')

d = 1 - 1 / 1.2; e2 = ((1 - 3e-3) / 1.2) ** 2; z = d
cases = [   # (位置, s2a_push, 期望 x)
    ((0.3, -0.2, 0.5, 1.0), (0, 0, 0, 0), 0.3),
    ((0.832, 0.1, 0.2, 1.0), (d, e2, 0, 0), 0.832 + d),
    ((-1.664, 0.0, 0.0, 2.0), (d, e2, 0, 0), -1.664 - d * 2),
    ((0.95, 0.0, 0.0, 1.0), (d, e2, 0, 0), 0.95),
    ((0.5, 0.0, 0.0, 1.0), (d, e2, 0, 0), 0.5),
    ((1.0, 0.0, 0.0, 1.0), (d, e2, z, 0), 1.0 * (1 - z) + d),
    ((0.5, 0.0, 0.0, 1.0), (d, e2, z, 0), 0.5 * (1 - z)),
    ((-2.0, 0.3, 0.4, 1.0), (d, e2, z, 0), -2.0 * (1 - z)),
    ((-1.0, -1.0, 0.5, 1.0), (d, e2, 1e-6, 0), -1.0 * (1 - 1e-6)),
    ((3.0, -1.0, 0.5, 1.0), (d, e2, 1e-6, 0), 3.0 * (1 - 1e-6)),
]
# 竖向段（11-05 族 6，Duo 加高）：Ky = 1.25，外推量 dy = 1 − 1/Ky = 0.2，门限² ey2 = (0.997/Ky)²；核心给 (0, ey2, 0, dy)，横向段只加 0。
#   ⑨ y = 0.8（画布上边，t² 0.64 > ey2 0.6362）→ y + 0.2；x = 0.9 照原样（横向外推量 0）；⑩ y = −1.6、w = 2（t = −0.8）→ y − 0.2·2；
#   ⑪ y = 0.5（画布内）→ 不动；⑫ y = 0.9（画布外、屏幕内）→ y + 0.2；⑬ y = −1（全屏三角形顶点，已在屏幕边）→ 不动（同横向只推屏幕内的，11-05）。例①–⑧ w = 0：竖向段不动 y（逐位比 y / z / w 已覆盖）
dy = 1 - 1 / 1.25; ey2 = ((1 - 3e-3) / 1.25) ** 2
vcases = [
    ((0.9, 0.8, 0.5, 1.0), (0, ey2, 0, dy), 0.8 + dy),
    ((0.0, -1.6, 0.0, 2.0), (0, ey2, 0, dy), -1.6 - dy * 2),
    ((0.3, 0.5, 0.0, 1.0), (0, ey2, 0, dy), 0.5),
    ((-0.2, 0.9, 0.0, 1.0), (0, ey2, 0, dy), 0.9 + dy),
    ((0.4, -1.0, 0.0, 1.0), (0, ey2, 0, dy), -1.0),
]
VPUSHED = {0, 1, 3}
PUSHED = {1, 2, 6, 7}   # ⑥ 的画布边经「收缩 + 外推」恰好回到原值（设计如此：画布边 → 屏幕边），拿不出反证
def f32(v): return struct.unpack('<f', struct.pack('<f', v))[0]   # GPU 回的是单精度：例子的位置先舍成单精度再比

def run(tail, tmp, tag, cases=cases):
    k = ('#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device const float4* P [[buffer(0)]], device const float4* Q [[buffer(1)]], device float4* O [[buffer(2)]], uint i [[thread_position_in_grid]])\n'
         '{\n    struct { float4 gl_Position; } out; out.gl_Position = P[i]; float4 s2a_push = Q[i];\n    ' + tail + '\n    O[i] = out.gl_Position;\n}\n')
    kp = os.path.join(tmp, tag + '.metal'); open(kp, 'w').write(k)
    cp = os.path.join(tmp, 'cases.txt'); open(cp, 'w').write(''.join(' '.join(repr(float(v)) for v in p + q) + '\n' for p, q, _ in cases))
    r = subprocess.run([sys.argv[1], kp, cp], capture_output=True, text=True, timeout=60)
    if r.returncode: sys.exit(f'✗ {tag}：执行器失败 {r.stderr.strip()}')
    return [tuple(f32(float(x)) for x in l.split()) for l in r.stdout.split('\n') if l.strip()]   # %.9g 读回成单精度才与 GPU 的值逐位相同

with tempfile.TemporaryDirectory() as tmp:
    tail = m.group(1) + '\n    ' + m.group(2)
    got = run(tail, tmp, 'push'); base = run('', tmp, 'nopush')
    vgot = run(tail, tmp, 'vpush', vcases); vbase = run(m.group(1), tmp, 'vpush_xonly', vcases)   # 竖向反证：只带横向段
n = bad = 0
for i, ((p, q, want), g, b) in enumerate(zip(cases, got, base)):
    n += 1
    pf = tuple(f32(v) for v in p)
    ok = (g == pf if i == 0 else abs(g[0] - want) <= 2e-6 and g[1:] == pf[1:])
    if not ok: bad += 1
    print(f'{"✓" if ok else "✗"} 例{"①②③④⑤⑥⑦⑧⑬⑭"[i]} 位置 {p} 参数 ({q[0]:.6f}, {q[1]:.6f}, {q[2]:.6f}, 0)：期望 x {want:.7f} → 真结果 {g[0]:.7f}{"（逐位不变）" if i == 0 else ""}')
    if i in PUSHED:
        n += 1; neg = abs(b[0] - want) > 1e-3
        if not neg: bad += 1
        print(f'{"✓" if neg else "✗"} 反证 例{"①②③④⑤⑥⑦⑧⑬⑭"[i]}：不带尾段 x {b[0]:.7f} ≠ 期望 {want:.7f}')
for i, ((p, q, want), g, b) in enumerate(zip(vcases, vgot, vbase)):
    n += 1
    pf = tuple(f32(v) for v in p)
    ok = abs(g[1] - want) <= 2e-6 and g[0] == pf[0] and g[2:] == pf[2:]
    if not ok: bad += 1
    print(f'{"✓" if ok else "✗"} 竖向例{"⑨⑩⑪⑫⑬"[i]} 位置 {p} 参数 (0, {q[1]:.6f}, 0, {q[3]:.6f})：期望 y {want:.7f}、x 逐位不变 → 真结果 y {g[1]:.7f} x {g[0]:.7f}')
    if i in VPUSHED:
        n += 1; neg = abs(b[1] - want) > 1e-3
        if not neg: bad += 1
        print(f'{"✓" if neg else "✗"} 反证 竖向例{"⑨⑩⑪⑫⑬"[i]}：只带横向段 y {b[1]:.7f} ≠ 期望 {want:.7f}')
print(f't_push：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
