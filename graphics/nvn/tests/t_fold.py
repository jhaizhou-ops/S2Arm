#!/usr/bin/env python3
# 折行贴图对拍（11-03 Nintendo Switch Sports：字库 1024×32768 R8 线性贴图超 Metal 2D 上限 16384，宿主折行建在池缓冲上，nvn_mtl.m tex_linear / nvn_red.h nvn_fold_k / nvn_se_fold；
#   着色器侧 S2A.Dsh FsRd 的 RedHelp s2a_fx / s2a_ff，经 dsh_cmp --fn 调）：脱离游戏，在 Mac 上跑
#   ① nvn_fold_k 手算：(16, 16384, 16) → 1；(16, 32768, 256) → 2；(1024, 32768, 1024) → 2；(1024, 49153, 1024) → 4；(9000, 20000, 9000) → 0（折后宽 18000 超限）；(16, 65537, 16) → 5
#   ② GPU 对拍（t_fold_run.m）：SPIRV-Cross 形态的计算核（2D / 2D 数组各一支，采样带 level / gradient2d / 偏移 / bias 之外的显式 LOD）经 fs_rd 出变体；
#      期望 = 原样 main0 用 Metal 硬件采样逻辑贴图（W×H，R32Float，每纹素一个值，硬件的过滤 / 寻址就是定义，与被测实现无关）；
#      真结果 = 变体 main0 采同一份数据按 k 行折成一行的池缓冲线性贴图 + 表项 nvn_se_fold；逐点差 ≤ 1/256（硬件双线性权重 8 位定点）。
#      覆盖：k = 2 / 3（H 不整除）、行距有补齐（P > W）、放大 / 缩小过滤四种组合、寻址 夹边 / 重复 / 镜像重复 / 镜像夹边 / 夹边框（透明黑、不透明白）、2D 数组的层号越界夹回
#      反证：同样位置变体拿零表项（不当折行读）必须有对不上的
# 用法：python3 graphics/nvn/tests/t_fold.py（末行「t_fold：N 项，失败 F」）
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../../..'))
sys.path.insert(0, os.path.join(ROOT, 'graphics/tools/direct/tests')); import dshfn   # noqa: E402
n = fail = 0
def ck(ok, msg):
    global n, fail
    n += 1; fail += not ok; print(('✓ ' if ok else '✗ ') + msg)

# ① nvn_fold_k：C 头单独编一个小程序算（期望上面手写）
FK = [((16, 16384, 16), 1), ((16, 32768, 256), 2), ((1024, 32768, 1024), 2), ((1024, 49153, 1024), 4), ((9000, 20000, 9000), 0), ((16, 65537, 16), 5)]
with tempfile.TemporaryDirectory(prefix='t_fold_') as tmp:
    c = os.path.join(tmp, 'fk.c'); exe = os.path.join(tmp, 'fk')
    open(c, 'w').write('#include "nvn_red.h"\n#include <stdio.h>\nint main(void) {\n' + ''.join(
        f'    printf("%d\\n", nvn_fold_k({w}u, {h}u, {p}u, 16384u));\n' for (w, h, p), _ in FK) + '    return 0;\n}\n')
    subprocess.run(['xcrun', 'clang', '-O1', '-I', os.path.join(ROOT, 'graphics/nvn/gfx/nvn'), '-o', exe, c], check=True)
    got = subprocess.run([exe], capture_output=True, text=True, check=True).stdout.split()
    for ((w, h, p), want), g in zip(FK, got): ck(int(g) == want, f'nvn_fold_k(W {w}, H {h}, 行距 {p} 纹素) = {g}（期望 {want}）')

    # ② 计算核：SPIRV-Cross 形态参数块（贴图 + 采样器 + 输出 + 采样位置），fs_rd 出变体
    def kern(kind, call):
        return ('#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct spvDescriptorSetBuffer0\n{\n'
                f'    {kind}<float> cp_t_tcb_8 [[id(0)]];\n    sampler cp_t_tcb_8Smplr [[id(1)]];\n    device float* cs_s0 [[id(2)]];\n    const device float4* cs_s1 [[id(3)]];\n}};\n\n'
                'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])\n{\n'
                '    float4 _9 = spvDescriptorSet0.cs_s1[gl_GlobalInvocationID.x];\n'
                f'    spvDescriptorSet0.cs_s0[gl_GlobalInvocationID.x] = {call}.x;\n}}\n')
    S = 'spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, '
    K = {   # 名 → (贴图种类, 采样调用)：_9.xy 位置、_9.z LOD、_9.w 层号
        'lv2d': ('texture2d', S + '_9.xy, level(_9.z))'),
        'off2d': ('texture2d', S + '_9.xy, level(_9.z), int2(1, -2))'),
        'gr2d': ('texture2d', S + '_9.xy, gradient2d(float2(exp2(_9.z) / 64.0), float2(0.0)))'),
        'lvarr': ('texture2d_array', S + '_9.xy, uint(_9.w), level(_9.z))'),
    }
    paths = []
    for nm, (kind, call) in K.items():
        src = kern(kind, call); rd = dshfn.fn('fs_rd', src)
        ck(rd.startswith('// s2a:samp-emu 4 ') and 's2a_bs(spvDescriptorSet0.cp_t_tcb_8' in rd and 'kernel void s2a_se_fold()' in rd and 's2a_red [[buffer(26)]]' in rd,
           f'fs_rd {nm}：版本 4、采样包 s2a_bs、带折行标记 s2a_se_fold、表参数槽 26')
        a, b = os.path.join(tmp, nm + '_main.metal'), os.path.join(tmp, nm + '_se.metal'); open(a, 'w').write(src); open(b, 'w').write(rd); paths += [nm, a, b]
    exe = os.path.join(tmp, 't_fold_run')
    r = subprocess.run(['xcrun', 'clang', '-O1', '-fobjc-arc', '-Wall', '-I', os.path.join(ROOT, 'graphics/nvn/gfx/nvn'), '-o', exe, os.path.join(HERE, 't_fold_run.m'),
                        '-framework', 'Metal', '-framework', 'Foundation'], capture_output=True, text=True)
    if r.returncode: sys.exit('✗ t_fold_run 编不过：' + r.stderr[-400:])
    r = subprocess.run([exe] + paths, capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if l[:2] in ('✓ ', '✗ '): ck(l.startswith('✓'), l[2:])
    if r.returncode not in (0, 1): ck(False, f't_fold_run 退出 {r.returncode}：{r.stderr[-300:]}')
print(f'{"✓" if not fail else "✗"} t_fold：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
