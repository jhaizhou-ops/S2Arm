#!/usr/bin/env python3
# 直连库宽屏 16:9 采样换算单测（S2A.Dsh DshCompiler.FsUvx：graphics/tools/direct/dsh/Dsh.cs，经 dsh_cmp --fn fs_uvx 调（dshfn.py））：改写器插进 MSL 的 s2a_uv 放进计算核，在 GPU 上逐例跑。
# 期望值按回放层的取值手算（widen_glue.inc uvx_fill：a = 游戏给的宽 / 存储宽，q = (a − 1, (1 − a) / 2)），放宽内容按页面居中摆：
#   ① q 全 0：坐标逐位不变（含负数、越界、极小值）；② 1280 → 1564：u = 0 → 142 / 1564、u = 1 → 1422 / 1564、u = 0.5 → 0.5；③ 320 → 391（模糊链）：u = 0 → 35.5 / 391、u = 1 → 355.5 / 391；
#   y 一律不动。改写：片元入口里 2D 归一化采样的坐标包上 s2a_uv、表成员加在参数块末尾（id = 最大 id + 1）、整数读和非 2D 贴图不改。
# 反证：同一批例子用不换算的核跑，② ③ 必须对不上（判据不会绿着失效）。用法：t_uvx.py <t_push_run 可执行>
import os, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn
FS = ('struct spvDescriptorSetBuffer0\n{\n    texture2d<float> fp_t_tcb_8 [[id(1)]];\n    sampler fp_t_tcb_8Smplr [[id(2)]];\n    texture3d<float> fp_t_tcb_A [[id(3)]];\n    sampler fp_t_tcb_ASmplr [[id(4)]];\n};\n\n'
      'fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n'
      '    float4 _1 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, in.m_0);\n'
      '    float4 _2 = spvDescriptorSet0.fp_t_tcb_8.read(uint2(gl_FragCoord.xy));\n'
      '    float4 _3 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, float3(in.m_0, 0.0));\n'
      '    out.m_0 = _1 + _2 + _3;\n    return out;\n}\n')
FS3 = FS.replace('texture2d<float> fp_t_tcb_8', 'texture3d<float> fp_t_tcb_8')
# 采样器数组排在参数块最后（11-02 究极4 315 支 metal failed 的形状：array<sampler, 32> … [[id(117)]] 占 117..148）：表成员 id 必须越过整个数组 = 117 + 32 = 149
#   （普查 6c76e4b1b 时按「最大 id + 1」给 118，Metal 报「attribute 'id' set location to 118, but minimum is 149」）
FSA = FS.replace('    sampler fp_t_tcb_ASmplr [[id(4)]];\n};', '    sampler fp_t_tcb_ASmplr [[id(4)]];\n    array<sampler, 32> fp_t_arrSmplr [[id(117)]];\n};')
got, got3, gota = [r.get('ok') for r in dshfn.batch([('fs_uvx', [FS]), ('fs_uvx', [FS3]), ('fs_uvx', [FSA])])]
# 插进去的换算函数 s2a_uv 取改写器输出里结构体之后、入口之前的那一行（它的取值由下面 GPU 逐例核，期望按回放层取值手算）
hm = re.search(r'\};\n\n(static inline float2 s2a_uv\(float2 c, float4 q\) \{.*?\}\n)\n\nfragment ', got or '', re.S)
UVX_HELP = hm.group(1) if hm else ''
want = (FS.replace('    sampler fp_t_tcb_ASmplr [[id(4)]];\n};\n\n', '    sampler fp_t_tcb_ASmplr [[id(4)]];\n    constant float4* s2a_uvx [[id(5)]];\n};\n\n' + UVX_HELP + '\n\n')
        .replace('sample(spvDescriptorSet0.fp_t_tcb_8Smplr, in.m_0)', 'sample(spvDescriptorSet0.fp_t_tcb_8Smplr, s2a_uv(in.m_0, spvDescriptorSet0.s2a_uvx[1]))'))
n = bad = 0
n += 1; ok = bool(UVX_HELP) and got == want; bad += not ok
print(f'{"✓" if ok else "✗"} 改写：2D 采样包 s2a_uv、表成员 id 5、整数读与 3D 贴图不改')
n += 1; ok = got3 == FS3; bad += not ok
print(f'{"✓" if ok else "✗"} 改写：没有 2D 贴图 → 原样（不加表成员）')
n += 1; ok = bool(gota) and 'constant float4* s2a_uvx [[id(149)]];' in gota and '[[id(118)]]' not in gota; bad += not ok
print(f'{"✓" if ok else "✗"} 改写：采样器数组 array<sampler, 32> [[id(117)]] 排在最后 → 表成员 id 149（越过整个数组）')

a1, a2 = 1280 / 1564, 320 / 391
cases = [   # (坐标 x, y, q, 期望 x)
    ((0.3, -0.2), (0, 0, 0, 0), 0.3), ((-1.75, 3.5), (0, 0, 0, 0), -1.75), ((1e-30, 0.0), (0, 0, 0, 0), 1e-30), ((2.25, 0.125), (0, 0, 0, 0), 2.25),
    ((0.0, 0.4), (a1 - 1, (1 - a1) / 2, 0, 0), 142 / 1564), ((1.0, 0.4), (a1 - 1, (1 - a1) / 2, 0, 0), 1422 / 1564), ((0.5, 0.9), (a1 - 1, (1 - a1) / 2, 0, 0), 0.5),
    ((0.0, 0.1), (a2 - 1, (1 - a2) / 2, 0, 0), 35.5 / 391), ((1.0, 0.1), (a2 - 1, (1 - a2) / 2, 0, 0), 355.5 / 391),
]
MAPPED = {4, 5, 7, 8}   # u = 0.5 落在中心，换不换都是 0.5，拿不出反证
def f32(v): return struct.unpack('<f', struct.pack('<f', v))[0]   # GPU 回的是单精度
def run(body, tmp, tag):
    k = ('#include <metal_stdlib>\nusing namespace metal;\n' + UVX_HELP + 'kernel void k(device const float4* P [[buffer(0)]], device const float4* Q [[buffer(1)]], device float4* O [[buffer(2)]], uint i [[thread_position_in_grid]])\n'
         '{\n    float2 c = P[i].xy; float4 q = Q[i];\n    ' + body + '\n    O[i] = float4(c, 0.0, 0.0);\n}\n')
    kp = os.path.join(tmp, tag + '.metal'); open(kp, 'w').write(k)
    cp = os.path.join(tmp, 'cases.txt'); open(cp, 'w').write(''.join(' '.join(repr(float(v)) for v in p + (0.0, 0.0) + q) + '\n' for p, q, _ in cases))
    r = subprocess.run([sys.argv[1], kp, cp], capture_output=True, text=True, timeout=60)
    if r.returncode: sys.exit(f'✗ {tag}：执行器失败 {r.stderr.strip()}')
    return [tuple(f32(float(x)) for x in l.split()) for l in r.stdout.split('\n') if l.strip()]
with tempfile.TemporaryDirectory() as tmp:
    got = run('c = s2a_uv(c, q);', tmp, 'uvx'); base = run('(void)q;', tmp, 'plain')
for i, ((p, q, w), g, b) in enumerate(zip(cases, got, base)):
    n += 1; pf = (f32(p[0]), f32(p[1]))
    ok = (g[:2] == pf) if not q[0] else (abs(g[0] - w) <= 2e-7 and g[1] == pf[1])
    bad += not ok
    print(f'{"✓" if ok else "✗"} 例{i + 1} 坐标 {p} q ({q[0]:.6f}, {q[1]:.6f})：期望 x {w:.7f} → 真结果 {g[0]:.7f}{"（逐位不变）" if not q[0] else ""}')
    if i in MAPPED:
        n += 1; neg = abs(b[0] - w) > 1e-3; bad += not neg
        print(f'{"✓" if neg else "✗"} 反证 例{i + 1}：不换算 x {b[0]:.7f} ≠ 期望 {w:.7f}')
print(f't_uvx：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
