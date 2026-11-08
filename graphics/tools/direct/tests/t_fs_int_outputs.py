#!/usr/bin/env python3
# 整数输出入口的 u_mask 只含真装整数的输出（S2A.Dsh DshCompiler.FsUint / IntOutputs，经 dsh_cmp --fn fs_uint 调；11-06 照上游参考实现（MIT）a4d7bb7b int_outputs）。
# 翻译器把寄存器放在整数局部量里，浮点颜色也经 as_type<float>(_n) 写出（_n = as_type<int>(某浮点)）：只看 as_type 会把它们全算成整数，u_mask 比管线的整数画布宽，
#   宿主（nvn_mtl.m pso_desc：need == u_mask 才用 main0_u）就只能现编 main0_t。期望按规则手推（不跑被测实现）：
#   ① 星之卡比 新星同盟草地（c44819fbd37e33dc 形状）：颜色 0 / 1 是浮点 _10 的位、颜色 2 来自整数局部（64、移位、非规格化字面量 8.96831e-44 = 整数 64 的位）、颜色 3 写 0.0
#      → u_mask = 1 << 2，main0_u 里 m_52 是 uint4、m_48 / m_50 / m_54 仍 float4（修前三个 as_type 写都算整数：0b111）
#   ② 每个输出都是浮点的位：说不清，照旧按「经整数位写」算 → u_mask = 1（颜色 0 经 as_type 写、颜色 1 直接写浮点）
#   ③ 三目选整数常量 1 / 0 的输出算整数、颜色 0 是算出来的浮点位 → u_mask = 1 << 1
#   ④ 位型原样往返（11-07 卡顿线，旷野之息 0ccb43f6e3901c18 形状）：颜色 0 = as_type<int>(浮点临时量)、那个浮点临时量 = as_type<float>(数组里的 uint) → 实为整数；
#      颜色 1 = 浮点 _10 的位 → u_mask = 1（修前往返被当成「浮点的位」，两个颜色都说不清，退回全算整数 0b11）
# 负对照：DSH_CMP_DLL 指向改动前的翻译器，① ③ ④ 必须红。用法：python3 t_fs_int_outputs.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

GBUFFER = """struct main0_out
{
    float4 m_48 [[color(0)]];
    float4 m_50 [[color(1)]];
    float4 m_52 [[color(2)]];
    float4 m_54 [[color(3)]];
};

fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    float _10 = in.m_1.x;
    int _20 = 0;
    int _21 = 0;
    if (_10 > 0.0)
    {
        _20 = as_type<int>(_10);
        _21 = 64;
    }
    int _30 = _20;
    int _31 = _21;
    int _32 = _31 << 1;
    out.m_48.x = as_type<float>(_30);
    out.m_50.x = as_type<float>(_30);
    out.m_52.x = as_type<float>(_31);
    out.m_52.y = as_type<float>(_32);
    out.m_52.z = 8.96831e-44;
    out.m_54.x = 0.0;
    return out;
}
"""
FLOATBITS = """struct main0_out
{
    float4 m_48 [[color(0)]];
    float4 m_50 [[color(1)]];
};

fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    float _10 = in.m_1.x;
    int _20 = as_type<int>(_10);
    out.m_48.x = as_type<float>(_20);
    out.m_50.x = _10;
    return out;
}
"""
CHOICE = """struct main0_out
{
    float4 m_48 [[color(0)]];
    float4 m_50 [[color(1)]];
};

fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    float _10 = in.m_1.x;
    int _20 = as_type<int>(_10 * 2.0);
    int _21 = (_10 > 0.5) ? 1 : 0;
    out.m_48.x = as_type<float>(_20);
    out.m_50.x = as_type<float>(_21);
    return out;
}
"""
ROUNDTRIP = """struct main0_out
{
    float4 m_48 [[color(0)]];
    float4 m_50 [[color(1)]];
};

fragment main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    spvUnsafeArray<uint, 4> _26;
    _26[0] = 5u;
    float _10 = in.m_1.x;
    float _39 = as_type<float>(_26[min(uint(_10), 3u)]);
    int _29 = as_type<int>(_39);
    int _37 = as_type<int>(_10);
    out.m_48.x = as_type<float>(_29);
    out.m_50.x = as_type<float>(_37);
    return out;
}
"""
res = [r.get('ok') for r in dshfn.batch([('fs_uint', [GBUFFER]), ('fs_uint', [FLOATBITS]), ('fs_uint', [CHOICE]), ('fs_uint', [ROUNDTRIP])])]
n = bad = 0
def ck(name, ok, got):
    global n, bad
    n += 1; bad += not ok; print(f'{"✓" if ok else "✗"} {name}（真结果 {got}）')
g, f, c, rt = res
ck('① 卡比 G-buffer：u_mask = 0b100、main0_u 只把颜色 2 改 uint4', bool(g) and g[1] == 0b100
   and 'struct main0_out_u\n{\n    float4 m_48 [[color(0)]];\n    float4 m_50 [[color(1)]];\n    uint4 m_52 [[color(2)]];\n    float4 m_54 [[color(3)]];\n};' in g[0], g and bin(g[1]))
ck('② 全是浮点位：照旧 u_mask = 1', bool(f) and f[1] == 1, f and bin(f[1]))
ck('③ 三目选 1 / 0 算整数：u_mask = 0b10', bool(c) and c[1] == 0b10, c and bin(c[1]))
ck('④ 位型往返 as_type<int>(as_type<float>(uint)) 算整数：u_mask = 1', bool(rt) and rt[1] == 1, rt and bin(rt[1]))
print(f'整数输出 u_mask：{n - bad}/{n} 例过')
sys.exit(1 if bad else 0)
