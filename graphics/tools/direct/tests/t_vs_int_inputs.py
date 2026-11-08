#!/usr/bin/env python3
# 顶点输入整数推断不随 DebugMode 变（S2A.Dsh DshCompiler.IntInputs，经 dsh_cmp --fn int_inputs / ampere_compile 调）。
#   规则：某个属性的读出值只经位型转换当整数用（as_type<int / uint>）或原样拷贝（整条语句「左值 = 它;」），且至少一处整数用法 → 按 uint 声明；
#   有一处别的用法（浮点运算等）→ 不动。读出值可以是先落浮点临时量再用（DebugMode 开的写法），也可以直接写 in.m_N.c（关了以后表达式传播把临时量内联）。
#   11-07 坑：顶点阶段关 DebugMode 后直接写的原样拷贝（out.m_Y.x = in.m_X.x; / _M = in.m_X.y;）被判成浮点用法，金刚 154 支顶点着色器 178 个整数输入退成 float，
#   宿主每次提交在 CPU 上转 3.4–6 万个顶点、几何连段 0 段。
# 期望按上面的规则对手写片段 / 合成着色器的语义手推（不跑被测实现）。
# ① 手写 MSL 片段（两种写法各一，外加两个不该判整数的反例）② 合成的 NVN2 顶点着色器整条出包链（DshCompiler.Compile）在缺省选项（顶点关 DebugMode）与开 DebugMode 下各出一遍，看反射 vertex_inputs。
# 负对照：DSH_CMP_DLL 指向改动前的翻译器，标「新」的例必须红。用法：python3 t_vs_int_inputs.py
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../../../..'))
sys.path.insert(0, HERE); import dshfn
sys.path.insert(0, os.path.join(ROOT, 'tests/ampere_isa')); import cases as A   # 指令编码（同 tests/ampere_isa，字段依据见其文件头）

HEAD = """struct main0_out
{
    float4 m_0 [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 m_4 [[attribute(0)]];
    float4 m_5 [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
"""
def vs(body): return HEAD + body + "    return out;\n}\n"

FN = [  # (名, 新, MSL, 期望 IntInputs)
    ('DebugMode 开的写法：落临时量后拷贝 + 位型转整数', False,
     vs("    float _10 = in.m_4.x;\n    out.m_0.x = _10;\n    float _12 = in.m_4.z;\n    out.m_0.z = float(as_type<int>(_12));\n    out.gl_Position = in.m_5;\n"),
     {'0': 'uint'}),
    ('传播后的写法：直接拷进输出 + 直接位型转整数（金刚 00d52f36e09aa9da 属性 3 的形状）', True,
     vs("    out.m_0.x = in.m_4.x;\n    out.m_0.y = in.m_4.y;\n    out.m_0.z = float(as_type<int>(in.m_4.z)) * 0.0039215688593685626983642578125;\n    out.gl_Position = in.m_5;\n"),
     {'0': 'uint'}),
    ('传播后的写法：分支里拷进局部量（动态下标选属性分量，金刚 1109e284d6e7e901 属性 5 的形状）+ 位型转整数', True,
     vs("    float _20 = 0.0;\n    if (in.m_5.w > 0.0)\n    {\n        _20 = in.m_4.y;\n    }\n    out.m_0.x = _20;\n    out.m_0.y = float(as_type<uint>(in.m_4.x));\n    out.gl_Position = in.m_5;\n"),
     {'0': 'uint'}),
    ('反例：只有原样拷贝、没有整数用法 → 不判整数', False,
     vs("    out.m_0.x = in.m_4.x;\n    float _10 = in.m_4.y;\n    out.m_0.y = _10;\n    out.gl_Position = in.m_5;\n"),
     {}),
    ('反例：有一处浮点运算 → 不判整数（另一处位型转整数也不算）', False,
     vs("    out.m_0.x = in.m_4.x * 2.0;\n    out.m_0.z = float(as_type<int>(in.m_4.z));\n    out.gl_Position = in.m_5;\n"),
     {}),
]

# 合成顶点着色器：ALD R4..R5 ← a[0x80..0x84]（属性 0 的 x、y）；AST a[0x80] ← R4（x 原样写到输出 0）；I2F.F32.S32 R6 ← R5、AST a[0x84] ← R6（y 当有符号整数转浮点）；位置写 0
#   ALD 0x321：Rd 16、偏移寄存器 24、顶点 32、地址 40..50、个数 − 1 74..76；AST 0x322：数据 32、地址 40..50（InstEmitAmpereMem.cs AAld / AAst）；I2F 0x106 有符号 74（tests/ampere_isa conv）
ALD = lambda rd, addr, n: A.inst(0x321, rd=(16, rd), ra=(24, A.RZ), rb=(32, A.RZ), addr=(40, addr), n=(74, n - 1))
AST = lambda addr, rs: A.inst(0x322, ra=(24, A.RZ), rb=(32, rs), vtx=(64, A.RZ), addr=(40, addr))
I2F = lambda rd, rb: A.conv(0x106, 1, rd, rb, 2, 2, sg=(74, 1))
SYN = A.vs_shader([ALD(4, 0x80, 2), AST(0x80, 4), I2F(6, 5), AST(0x84, 6), A.MOVI(8, 0), AST(0x70, 8), AST(0x74, 8), AST(0x78, 8), AST(0x7c, 8)])
XL = [  # (名, 新, 答案表行, 期望属性 0 的声明类型)
    ('合成顶点着色器，缺省选项（顶点阶段关 DebugMode）：属性 0 一分量原样写出、一分量 I2F → 整数输入', True, {}, ('uint4', 'int4')),
    ('合成顶点着色器，开 DebugMode：同上', False, {'debug': True}, ('uint4', 'int4')),
]


def main():
    st, code, ctl = SYN
    res = dshfn.batch([('int_inputs', [m]) for _, _, m, _ in FN] + [('ampere_compile', [st, code.hex(), ctl.hex(), json.dumps(f)]) for _, _, f, _ in XL], nxgal=dshfn.NXGAL)
    bad = 0
    for (name, new, _, want), r in zip(FN, res):
        got = r.get('ok', r); ok = got == want; bad += not ok
        print(f'{"✓" if ok else "✗"} {"新 " if new else ""}{name}：期望 {want} → 真结果 {got}')
    for (name, new, _, want), r in zip(XL, res[len(FN):]):
        v = r.get('ok')
        if not isinstance(v, list) or v[0] == 'fail': got = f'翻不过 {v[1:] if isinstance(v, list) else r}'
        else: got = next((e['msl_type'] for e in json.loads(v[1])['vertex_inputs'] if e['location'] == 0), '没有属性 0')
        ok = got in want; bad += not ok
        print(f'{"✓" if ok else "✗"} {"新 " if new else ""}{name}：期望 {" / ".join(want)} → 真结果 {got}')
    n = len(FN) + len(XL)
    print(f'顶点输入整数推断：{n - bad}/{n} 例过（标「新」的 {sum(c[1] for c in FN + XL)} 例在改动前的翻译器上必须红）')
    return 1 if bad else 0


if __name__ == '__main__': sys.exit(main())
