#!/usr/bin/env python3
# 整数输出入口编译期共用函数体单测（C# Unity.Share，graphics/tools/direct/dsh/batch/Unity.cs，经 dsh_batch --unity share 调；编批库拼源码 Unity.Src 调它；10-27 斯普拉遁3 冷编），约 10 秒：python3 t_dmsh_ushare.py
#   11-01 出库链挪进 C#（原 translator/dmsh_ushare.py 随之删除），期望照旧按规则手写（不跑被测实现推期望）。源码照 fs_uint 的写法手造：main0 原样 + struct main0_out_u + main0_u（main0 函数体，每处 return out; 换成转换）。
#   ① 参数里有模板逗号（texture2d<float, access::sample>）、入口带 [[early_fragment_tests]]、函数体里有 discard 与两处 return out;：变换；
#      结果里 main0_impl 定义 1 处（static、参数去掉 [[…]]）、main0 薄壳 return main0_impl(in, t, s, cb, gl_FragCoord);、main0_u 薄壳先取 out 再返回原转换；
#      [[early_fragment_tests]] 留在两个入口上、不在 main0_impl 上；原样与变换后都能用 iOS 编译器编过
#   ② 压平临时量编号错开（giant_fix 跨整份文件连续编号：main0 用 s2a_g0..1、main0_u 用 s2a_g2..3）：照样变换
#   ③ main0 带 [[clang::optnone]]（giant_fix 安全阀）：标记移到 main0_impl，两个入口都不带
#   ④ 反例：main0_u 函数体多一句（不是 main0 的照抄）→ 原样返回、不变换；⑤ 没有 main0_u → 原样返回
#   ⑥ 顶格右括号属于嵌套块：仍共享完整函数体
import atexit, os, re, shutil, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(H, '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(R, 'translator')); import dsh_batch
CMD, _ = dsh_batch.get(); TMP = tempfile.mkdtemp(prefix='t_ushare_'); atexit.register(shutil.rmtree, TMP, True)
def share(text):   # → (结果, 是否共用了函数体)，同旧 dmsh_ushare.share 的返回形状
    i, o = os.path.join(TMP, 'in.metal'), os.path.join(TMP, 'out.metal'); open(i, 'w').write(text)
    r = subprocess.run([*CMD, '--unity', 'share', i, o], capture_output=True, text=True)
    if r.returncode or r.stdout.strip() not in ('shared 0', 'shared 1'): sys.exit(f'✗ dsh_batch --unity share 失败（{r.returncode}）：{(r.stdout + r.stderr).strip()[-300:]}')
    return open(o).read(), r.stdout.strip() == 'shared 1'
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
HEAD = ('#include <metal_stdlib>\nusing namespace metal;\n\nstruct CB\n{\n    float4 k;\n};\n\nstruct main0_out\n{\n    float4 m_9 [[color(0)]];\n};\n\n'
        'struct main0_in\n{\n    float4 m_5 [[user(locn0)]];\n};\n\n')
SIG = ('main0_in in [[stage_in]], texture2d<float, access::sample> t [[texture(0)]], sampler s [[sampler(0)]], constant CB& cb [[buffer(0)]], '
       'float4 gl_FragCoord [[position]]')
def body(g0, g1):
    return ('    main0_out out = {};\n'
            f'    bool s2a_g{g0} = in.m_5.x < 0.0;\n    if (s2a_g{g0})\n    {{\n        discard_fragment();\n    }}\n'
            f'    bool s2a_g{g1} = in.m_5.y > 0.5;\n    if (s2a_g{g1})\n    {{\n        out.m_9 = as_type<float4>(uint4(7u));\n        return out;\n    }}\n'
            '    out.m_9 = t.sample(s, in.m_5.xy) * cb.k + gl_FragCoord;\n    return out;\n')
RET = 'main0_out_u{as_type<uint4>(out.m_9)}'
def src(attr='[[early_fragment_tests]] ', g=(0, 1, 0, 1), extra='', unindented=False):
    b = body(g[0], g[1]); bu = body(g[2], g[3])
    if unindented:
        b = b.replace('return out;', '{\nreturn out;\n}\n')
        bu = bu.replace('return out;', '{\nreturn out;\n}\n')
    bu = bu.replace('return out;', f'return {RET};') + extra
    return (HEAD + f'{attr}fragment main0_out main0({SIG})\n{{\n{b}}}\n\n'
            + 'struct main0_out_u\n{\n    uint4 m_9 [[color(0)]];\n};\n\n'
            + f'{attr}fragment main0_out_u main0_u({SIG})\n{{\n{bu}}}\n\n')
def comp(t, tag):
    d = tempfile.mkdtemp(); p = os.path.join(d, tag + '.metal'); open(p, 'w').write(t)
    r = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'metal', '-c', '-mios-version-min=18.0', '-fmetal-math-mode=relaxed', '-fpreserve-invariance', p, '-o', p[:-6] + '.air'], capture_output=True, text=True)
    return r.returncode == 0, (r.stderr.strip().splitlines() or [''])[0][:160]
s1 = src(); o1, ok1 = share(s1)
ck(f'① 变换（{ok1}）', ok1)
ck('① main0_impl 定义 1 处、static、参数去掉属性',
   o1.count('static main0_out main0_impl(main0_in in, texture2d<float, access::sample> t, sampler s, constant CB& cb, float4 gl_FragCoord)\n') == 1 and o1.count('main0_impl(') == 3)
ck('① main0 薄壳 return main0_impl(in, t, s, cb, gl_FragCoord);',
   f'[[early_fragment_tests]] fragment main0_out main0({SIG})\n{{\n    return main0_impl(in, t, s, cb, gl_FragCoord);\n}}\n' in o1)
ck('① main0_u 薄壳先取 out 再返回原转换',
   f'[[early_fragment_tests]] fragment main0_out_u main0_u({SIG})\n{{\n    main0_out out = main0_impl(in, t, s, cb, gl_FragCoord);\n    return {RET};\n}}\n' in o1)
ck('① discard 只剩函数体里 1 处（main0_u 那份不再编）', o1.count('discard_fragment()') == 1 and s1.count('discard_fragment()') == 2)
okA, wA = comp(s1, 'orig'); okB, wB = comp(o1, 'shared')
ck(f'① 原样与变换后都能用 iOS 编译器编过（{wA or "原样过"}；{wB or "变换后过"}）', okA and okB)
o2, ok2 = share(src(g=(0, 1, 2, 3)))
ck(f'② 压平临时量编号错开照样变换（{ok2}）', ok2)
o3, ok3 = share(src(attr='[[clang::optnone]] '))
ck('③ optnone 移到 main0_impl、两个入口都不带', ok3 and '[[clang::optnone]] static main0_out main0_impl(' in o3 and o3.count('[[clang::optnone]]') == 1)
s4 = src(extra='    out.m_9.x += 1.0;\n'); o4, ok4 = share(s4)
ck(f'④ main0_u 多一句 → 原样不变换（{ok4}）', not ok4 and o4 == s4)
s5 = HEAD + f'fragment main0_out main0({SIG})\n{{\n{body(0, 1)}}}\n'; o5, ok5 = share(s5)
ck(f'⑤ 没有 main0_u → 原样（{ok5}）', not ok5 and o5 == s5)
s6 = src(unindented=True); o6, ok6 = share(s6)
ck('⑥ 顶格右括号属于嵌套块，仍共享完整函数体', ok6)
okA, wA = comp(s6, 'unindented-original'); okB, wB = comp(o6, 'unindented-shared')
ck(f'⑥ 原始与共享函数体均通过 iOS 编译（{wA or "原样过"}；{wB or "共享过"}）', okA and okB)
print(f't_dmsh_ushare：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
