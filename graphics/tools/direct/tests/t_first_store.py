#!/usr/bin/env python3
# 只有派发里第一个调用做的存储（S2A.Dsh DshCompiler.FirstStore，经 dsh_cmp --fn first_store 调；11-06 照上游参考实现（MIT）c8521eeb + e07cba1c 的 first_store 与其单测移植）：
#   确切认出的条件 → 存储挪出着色器、交宿主派发前按序写；别的形状一律原样。片段照上游单测的形状手写（斯普拉遁 突击队 Hoian_Proc、马车世界 2ce9071c2f22d74f / 5fea9b7ddb30e8a8 /
#   0823b08c2027a38d / 649e36162cad9e79），外加我方加固后的存储形状（uint _i = uint(k); if (_i < 长度) { …[min(_i, 末项)] = v; }，tests/ampere_isa 同形状的合成着色器现编所得）。
# 期望按规则手推（不跑被测实现）。负对照：DSH_CMP_DLL 指向改动前的翻译器，所有例都红（没有这个函数）。用法：python3 t_first_store.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

BODY = """    float _59 = as_type<float>(gl_WorkGroupID.x);
    float _61 = as_type<float>(gl_LocalInvocationID.x);
    int _63 = as_type<int>(_59) << %d;
    int _65 = ~as_type<int>(_61);
    int _67 = _65 + 1;
    bool _71 = _67 %s _63;
    if (!_71)
    {
        (*spvDescriptorSet0.cp_s0)._m0[1] = 0u;
    }
    int _73 = as_type<int>(_61) + _63;
"""
HARD = """    float _39 = as_type<float>(gl_WorkGroupID.x);
    float _41 = as_type<float>(gl_LocalInvocationID.x);
    int _44 = as_type<int>(_39) << 5;
    int _46 = ~as_type<int>(_41);
    int _48 = _46 + 1;
    bool _52 = _48 != _44;
    if (!_52)
    {
        uint _96 = uint(1);
        if (_96 < _91)
        {
            (*spvDescriptorSet0.cp_s0)._m0[min(_96, _93)] = 0u;
        }
        uint _97 = uint(3);
        if (_97 < _91)
        {
            (*spvDescriptorSet0.cp_s2)._m0[min(_97, _95)] = 7u;
        }
    }
    int _54 = as_type<int>(_41) + _44;
"""
SPLIT = """    float _53 = as_type<float>(gl_WorkGroupID.x);
    float _55 = as_type<float>(gl_LocalInvocationID.x);
    int _57 = as_type<int>(_53) << 6;
    int _59 = ~as_type<int>(_55);
    int _61 = _59 + 1;
    bool _65 = _61 != _57;
    int _67 = _61;
    if (!_65)
    {
        _67 = 1;
    }
    int _69 = _67;
    if (!_65)
    {
        (*spvDescriptorSet0.cp_s0)._m0[0] = 0u;
    }
    if (!_65)
    {
        (*spvDescriptorSet0.cp_s0)._m0[2] = uint(_69);
    }
    if (!_65)
    {
        (*spvDescriptorSet0.cp_s0)._m0[3] = uint(_69);
    }
    if (!_65)
    {
        (*spvDescriptorSet0.cp_s0)._m0[1] = 0u;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int _71 = as_type<int>(_55) + _57;
"""
ROWS = """    float _74 = as_type<float>(gl_WorkGroupID.y);
    float _76 = as_type<float>(gl_LocalInvocationID.y);
    float _78 = as_type<float>(gl_LocalInvocationID.x);
    float _80 = as_type<float>(gl_WorkGroupID.x);
    float _82 = as_type<float>(gl_WorkGroupID.z);
    int _84 = as_type<int>(_74) << 3;
    int _86 = ~as_type<int>(_76);
    int _88 = _86 + 1;
    bool _92 = _88 != _84;
    int _94 = as_type<int>(_80) << 3;
    int _96 = ~as_type<int>(_78);
    int _98 = _96 + 1;
    bool _100 = _98 == _94;
    bool _102 = !_92;
    bool _104 = _100 && _102;
    bool _106 = as_type<int>(_82) == 0;
    bool _108 = _106 && _104;
    int _110 = as_type<int>(_82) * 24;
    int _112 = _110 + 8;
    if (_108)
    {
        (*spvDescriptorSet0.cp_s0)._m0[1] = 0u;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
"""
SETUP = """    float _78 = as_type<float>(gl_WorkGroupID.y);
    float _80 = as_type<float>(gl_LocalInvocationID.y);
    float _82 = as_type<float>(gl_LocalInvocationID.x);
    float _84 = as_type<float>(gl_WorkGroupID.x);
    float _86 = as_type<float>(gl_WorkGroupID.z);
    int _88 = as_type<int>(_78) << 3;
    int _90 = ~as_type<int>(_80);
    int _91 = _90 + 1;
    bool _94 = _91 != _88;
    int _96 = as_type<int>(_84) << 3;
    int _97 = ~as_type<int>(_82);
    int _98 = _97 + 1;
    bool _100 = _98 == _96;
    bool _102 = !_94;
    bool _104 = _100 && _102;
    bool _106 = 0 == as_type<int>(_86);
    bool _108 = _106 && _104;
    bool _110 = !_108;
    if (!_110)
    {
        (*spvDescriptorSet0.cp_s0)._m0[0] = 0u;
        bool _112 = 0u < as_type<uint>((*spvDescriptorSet0.cp_c4)._m0[0].x);
    }
"""
L1, L64, L88 = [32, 1, 1], [64, 1, 1], [8, 8, 1]
cases = [   # (名, 源码, 线程组, 期望存储 [] = 原样, 改写后必须有 / 不得有)
    ('一维：确切形状 → 1 条存储挪走、其余照旧', BODY % (5, '!='), L1, [['cp_s0', 1, 0]], ['int _73 = as_type<int>(_61) + _63;', 'bool _71 = _67 != _63;'], ['_m0[1] = 0u', 'if (!_71)']),
    ('一维：同块两条', (BODY % (5, '!=')).replace('= 0u;', '= 0u;\n        (*spvDescriptorSet0.cp_s2)._m0[3] = 7u;'), L1, [['cp_s0', 1, 0], ['cp_s2', 3, 7]], [], []),
    ('一维：移位不等于线程组 → 原样', BODY % (4, '!='), L1, [], [], []),
    ('一维：条件反了（除第一个外都写）→ 原样', BODY % (5, '=='), L1, [], [], []),
    ('一维：线程组带行 → 原样', BODY % (5, '!='), [32, 2, 1], [], [], []),
    ('一维：没有线程组尺寸 → 原样', BODY % (5, '!='), None, [], [], []),
    ('一维：值只有着色器知道 → 原样', (BODY % (5, '!=')).replace('= 0u;', '= _63;'), L1, [], [], []),
    ('加固形状：两条带界检查的存储都挪走', HARD, L1, [['cp_s0', 1, 0], ['cp_s2', 3, 7]], ['int _54 = as_type<int>(_41) + _44;'], ['_m0[min(', 'if (!_52)']),
    ('分块：4 块、两个值来自同守卫下的常量局部量，按着色器次序', SPLIT, L64, [['cp_s0', 0, 0], ['cp_s0', 2, 1], ['cp_s0', 3, 1], ['cp_s0', 1, 0]], ['int _69 = _67;', 'threadgroup_barrier', 'int _71 = as_type<int>(_55) + _57;'], ['_m0[']),
    ('分块：值是别的局部量 → 整支原样', SPLIT.replace('[2] = uint(_69)', '[2] = uint(_71)'), L64, [], [], []),
    ('分块：后面还有认不出的同守卫存储 → 整支原样', SPLIT + '    if (!_65)\n    {\n        (*spvDescriptorSet0.cp_s0)._m0[9] = 2u;\n    }\n', L64, [], [], []),
    ('分块：超过宿主收的 4 条 → 整支原样', SPLIT.replace('[1] = 0u;', '[1] = 0u;\n        (*spvDescriptorSet0.cp_s0)._m0[4] = 0u;'), L64, [], [], []),
    ('分块：线程组 32 对不上移位 6 → 原样', SPLIT, L1, [], [], []),
    ('带行（8×8）：1 条挪走', ROWS, L88, [['cp_s0', 1, 0]], ['int _112 = _110 + 8;', 'threadgroup_barrier'], ['_m0[']),
    ('带行：线程组 8×4 → 原样', ROWS, [8, 4, 1], [], [], []),
    ('带行：线程组 4×8 → 原样', ROWS, [4, 8, 1], [], [], []),
    ('带行：线程组 z = 2 → 原样', ROWS, [8, 8, 2], [], [], []),
    ('带行：一维 64 → 原样', ROWS, L64, [], [], []),
    ('带行：第一个调用不只存储（还读 uniform）→ 原样', SETUP, L88, [], [], []),
]
res = dshfn.batch([('first_store', [src, loc]) for _, src, loc, _, _, _ in cases])
n = bad = 0
for (name, src, loc, want, must, mustnot), r in zip(cases, res):
    v = r.get('ok'); n += 1
    if not isinstance(v, list): err = f'调用失败 {r}'
    elif not want: err = None if v == [src, []] else f'应原样，真结果存储 {v[1]}'
    else:
        out, got = v
        err = (f'存储 {got}，应 {want}' if got != want else
               next((f'改写后缺 {m!r}' for m in must if m not in out), None) or next((f'改写后仍有 {m!r}' for m in mustnot if m in out), None))
    bad += err is not None
    print(f'{"✓" if err is None else "✗"} {name}{"" if err is None else "：" + err}')
# 与追不到槽的池数组（DshCompiler.PoolArrays，11-06 Switch2 线 63）同在一支计算核里：生产次序是 Msl() 里先改池（结构体成员换池指针、参数号重排、读改成 (&p->e[0])[dm_pool_mark(p, …)]），
#   再在 Finish 里做 first_store。池改写不碰存储缓冲成员名、不碰 main0 开场与守卫块，first_store 照样只挪那一条存储；池读保留在 main0 里、存储缓冲参数号不变
COMBO = ('struct S0 { uint _m0[1]; };\n\nstruct spvDescriptorSetBuffer0\n{\n    device S0* cp_s0 [[id(0)]];\n'
         '    array<texture2d<float>, 1048576> cp_t2d_cb0_40000000 [[id(1)]];\n    array<sampler, 4096> cp_s_cb0_40000000 [[id(1048577)]];\n};\n\n'
         'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gl_WorkGroupID [[threadgroup_position_in_grid]], uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]])\n{\n'
         + BODY % (5, '!=') + '    float _80 = spvDescriptorSet0.cp_t2d_cb0_40000000[uint(_73) & 1048575u].sample(spvDescriptorSet0.cp_s_cb0_40000000[uint(_73) >> 20u], float2(0.5), level(0.0)).x;\n}\n')
pr = dshfn.batch([('pool_arrays', [COMBO])])[0].get('ok')
r2 = dshfn.batch([('first_store', [pr, L1])])[0].get('ok') if isinstance(pr, str) else None
n += 1
if not isinstance(r2, list): err = f'调用失败 pool_arrays → {str(pr)[:120]}'
else:
    out, got = r2
    need = ['device S0* cp_s0 [[id(0)]];', 'constant spvPool_cp_t2d_cb0_40000000* cp_t2d_cb0_40000000 [[id(1)]];', 'constant spvPool_cp_s_cb0_40000000* cp_s_cb0_40000000 [[id(2)]];',
            '(&spvDescriptorSet0.cp_t2d_cb0_40000000->e[0])[dm_pool_mark(spvDescriptorSet0.cp_t2d_cb0_40000000, ', 'int _73 = as_type<int>(_61) + _63;']
    err = (f'存储 {got}，应 [[\'cp_s0\', 1, 0]]' if got != [['cp_s0', 1, 0]] else
           next((f'改写后缺 {m!r}' for m in need if m not in out), None) or ('改写后仍有存储' if '_m0[1] = 0u' in out else None))
bad += err is not None
print(f'{"✓" if err is None else "✗"} 与池数组同支：先改池、再挪第一个调用的存储{"" if err is None else "：" + err}')
print(f'第一个调用的存储：{n - bad}/{n} 例过')
sys.exit(1 if bad else 0)
