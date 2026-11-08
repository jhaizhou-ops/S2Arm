#!/usr/bin/env python3
# 直连巨型着色器阶梯压平单测（S2A.Dsh DshFlat.GiantFix / Flatten：graphics/tools/direct/dsh/Flat.cs，经 dsh_cmp --fn 调（dshfn.py）；10-27 斯普拉遁3 冷启 31 秒停帧；单测约 15 秒）：python3 t_dmsh_giant.py
#   期望按规则手算（不跑被测实现推期望）。深度 = main0 里独占一行的 { 最多套几层，函数自己的大括号算第 1 层；GIANT_DEPTH 缺省 40。
#   ① 尾部嵌套阶梯 39 层（深度 40）：giant_fix 返回 (40, 2)——压成一层平铺序列（守卫 if 1 层 + 函数 1 层），入口不标 [[clang::optnone]]
#   ② 38 层（深度 39）：原样、返回 0
#   ③ 第 20 层 A 里有 return：外层串联在那一层断开（return 留在它的守卫块里、在更深的阶梯之前），块内更深的阶梯各自再压平 → 深度 3
#   ④ 不是 SPIRV-Cross 版式（大括号跟在行尾）：入口原样
#   ⑤ 压不平的深嵌套（每层嵌套 if 之后还有语句，不是尾部）深度 40：入口行首标 [[clang::optnone]]（安全阀）
#   ⑥ GPU 差分：随机生成 24 支带深阶梯的计算核（尾部阶梯、else 分支、do-while 里 break、非尾部嵌套、整数 / 布尔中间量），原版与压平版各编一份，
#      4096 个线程、随机输入跑一遍，输出逐位相同；且每支至少压平了一层（不然没测到）。按 safe 数学编：relaxed / fast 允许编译器重排结合、合并乘加，
#      两份结构不同的源码逐位结果可以合法地不同，比的就不是语义了；另含提前 return（写一个值再返回）
import os, random, re, struct, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H); import dshfn
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)

HEAD = '#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out\n{\n    float4 m_9 [[color(0)]];\n};\nstruct main0_in\n{\n    float4 m_5 [[user(locn0)]];\n};\n\n'
def ladder(k, ret_at=None, tail=True):   # k 层「if (!_c) { …; bool _d = …; if (!_d) { … } }」，SPIRV-Cross 版式
    o, ind = [], '    '
    for i in range(k):
        o += [f'{ind}bool _{100 + i} = in.m_5.x == {i}.0;', f'{ind}if (!_{100 + i})', ind + '{']
        ind += '    '; o.append(f'{ind}float _{300 + i} = in.m_5.y + {i}.0;'); o.append(f'{ind}_9 = _{300 + i};')
        if ret_at == i: o.append(f'{ind}if (_9 > 100.0)'); o.append(ind + '{'); o.append(ind + '    return out;'); o.append(ind + '}')
    for i in reversed(range(k)):
        ind = ind[:-4]
        if not tail: o.append(f'{ind}    _9 = _9 * 0.5;')   # 嵌套 if 之后还有语句：不是尾部
        o.append(ind + '}')
    return o
def frag(body, open_same_line=False):
    sig = 'fragment main0_out main0(main0_in in [[stage_in]])'
    b = ['    main0_out out = {};', '    float _9 = 0.0;'] + body + ['    out.m_9 = float4(_9);', '    return out;']
    return HEAD + sig + (' {\n' if open_same_line else '\n{\n') + '\n'.join(b) + '\n}\n\n'
ON = '[[clang::optnone]] '

a, b, c, d, e = frag(ladder(39)), frag(ladder(38)), frag(ladder(39, ret_at=20)), frag(ladder(39), open_same_line=True), frag(ladder(39, tail=False))
R = dshfn.batch([('giant_fix', [a]), ('giant_fix', [b]), ('giant_fix', [c]), ('flatten', [d]), ('giant_fix', [e])])   # 一次起 dotnet（每起一次要几秒，高负载更久）
(o1, d0, d1), (o2, e0, _), (o3, f0, f1), (o4, _), (o5, g0, g1) = (tuple(x.get('ok') or ('', -1, -1)) for x in R)
ck(f'① 深度 40 的尾部阶梯：返回 (40, 2)（实得 ({d0}, {d1}））、入口不标不优化', d0 == 40 and d1 == 2 and ON + 'fragment' not in o1)
ck(f'② 深度 39：原样、返回 0（实得 {e0}）', o2 == b and e0 == 0)
ck(f'③ 第 20 层有 return：外层串联断开、块内再压平（实得 {f0} → {f1}，期望 40 → 3）', f0 == 40 and f1 == 3 and o3.count('return out;') == 2)
ck('④ 不是 SPIRV-Cross 版式：入口原样', o4 == d)
ck(f'⑤ 压不平的非尾部嵌套深度 40：标不优化（实得 {g0} → {g1}）', g0 == 40 and g1 == 40 and ON + 'fragment main0_out main0(' in o5)

# ⑥ GPU 差分
def gen(rng):
    vid = [1000]; lines = []
    def nv(): vid[0] += 1; return f'_{vid[0]}'
    def block(ind, depth, vars_f, vars_i):
        out = []
        for _ in range(rng.randint(1, 3)):
            v = nv(); a, b = rng.choice(vars_f), rng.choice(vars_f)
            out.append(f'{ind}float {v} = {rng.choice(["fma(" + a + ", 1.5, " + b + ")", a + " * " + b, a + " - " + b, "precise::clamp(" + a + ", -2.0, 2.0)"])};'); vars_f = vars_f + [v]
            if rng.random() < 0.3: w = nv(); out.append(f'{ind}int {w} = int({v}) & 7;'); vars_i = vars_i + [w]
            out.append(f'{ind}_acc = _acc + {v};')
        if depth <= 0: return out
        r = rng.random(); c = nv()
        out.append(f'{ind}bool {c} = {rng.choice(vars_i)} == {rng.randint(0, 7)};' if vars_i and rng.random() < 0.5 else f'{ind}bool {c} = {rng.choice(vars_f)} > {rng.uniform(-1, 1):.3f};')
        if r < 0.65:   # 尾部阶梯
            out += [f'{ind}if ({"!" if rng.random() < 0.7 else ""}{c})', ind + '{'] + block(ind + '    ', depth - 1, vars_f, vars_i) + [ind + '}']
        elif r < 0.8:   # 带 else：随机一侧接着往深走、另一侧是叶子块（两侧都往深走源码按层数指数膨胀，11-01 实测 48 支共 610 万行、单测 200+ 秒）
            deep = rng.random() < 0.5; th, el = (depth - 1, 0) if deep else (0, depth - 1)
            out += [f'{ind}if ({c})', ind + '{'] + block(ind + '    ', th, vars_f, vars_i) + [ind + '}', ind + 'else', ind + '{'] + block(ind + '    ', el, vars_f, vars_i) + [ind + '}']
        elif r < 0.85:   # do-while 里 break
            out += [ind + 'do', ind + '{', f'{ind}    if ({c})', ind + '    {', ind + '        break;', ind + '    }'] + block(ind + '    ', depth - 1, vars_f, vars_i) + [ind + '} while (false);']
        elif r < 0.92:   # 提前返回
            out += [f'{ind}if ({c})', ind + '{', f'{ind}    dst[gid] = _acc + 1000.0;', ind + '    return;', ind + '}'] + block(ind, depth - 1, vars_f, vars_i)
        else:   # 非尾部：嵌套之后还有语句
            out += [f'{ind}if (!{c})', ind + '{'] + block(ind + '    ', depth - 1, vars_f, vars_i) + [ind + '    _acc = _acc * 0.75;', ind + '}']
        return out
    body = ['    float _acc = 0.0;', '    float _1 = src[gid * 2u];', '    float _2 = src[gid * 2u + 1u];', '    int _3 = int(_1 * 8.0) & 7;'] + block('    ', rng.randint(42, 60), ['_1', '_2'], ['_3']) + ['    dst[gid] = _acc;']
    return '#include <metal_stdlib>\nusing namespace metal;\n\nkernel void main0(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]], uint gid [[thread_position_in_grid]])\n{\n' + '\n'.join(body) + '\n}\n\n'
RUNNER = r'''
#import <Metal/Metal.h>
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil; int N = 4096;
    id<MTLBuffer> in = [d newBufferWithLength:N * 8 options:MTLResourceStorageModeShared]; float *p = in.contents; srand(7);
    for (int i = 0; i < N * 2; i++) p[i] = (float)(rand() % 2000) / 250.0f - 4.0f;
    id<MTLCommandQueue> q = [d newCommandQueue];
    for (int k = 1; k < argc; k++) {
        id<MTLLibrary> l = [d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[k])] error:&e]; if (!l) { printf("ERR %s\n", e.localizedDescription.UTF8String); return 2; }
        id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"main0"] error:&e]; if (!ps) { printf("ERR %s\n", e.localizedDescription.UTF8String); return 2; }
        id<MTLBuffer> out = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        fwrite(out.contents, 4, N, stdout);
    }
} return 0; }
'''
with tempfile.TemporaryDirectory() as t:
    rb = os.path.join(t, 'run'); open(rb + '.m', 'w').write(RUNNER)
    r = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', rb + '.m', '-o', rb], capture_output=True, text=True)
    if r.returncode: print(r.stderr[-400:])
    rng = random.Random(20261027); same = flat_ok = 0; K = 24; info = ''
    src = [gen(rng) for _ in range(K)]; flat = dshfn.batch([('flatten', [a]) for a in src])
    for i in range(K):
        a = src[i]; f, lv = flat[i]['ok'] if 'ok' in flat[i] else ('', 0)
        libs = []
        for tag, m in (('a', a), ('f', f)):
            p = os.path.join(t, f'{tag}{i}.metal'); open(p, 'w').write(m)
            c = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-w', '-fmetal-math-mode=safe', '-mmacosx-version-min=15.0', p, '-o', p + '.metallib'], capture_output=True, text=True)
            if c.returncode: info = c.stderr[-300:]
            libs.append(p + '.metallib')
        o = subprocess.run([rb] + libs, capture_output=True)
        if o.returncode == 0 and len(o.stdout) == 2 * 4096 * 4 and o.stdout[:4096 * 4] == o.stdout[4096 * 4:]: same += 1
        elif not info: info = f'第 {i} 支：退出 {o.returncode}，{o.stdout[:200]!r}'
        flat_ok += lv > 0
    ck(f'⑥ GPU 差分：{K} 支随机深阶梯计算核，原版与压平版 4096 个输出逐位相同 {same} / {K}、有压平的 {flat_ok} / {K}' + (f'（{info}）' if info and same < K else ''), same == K and flat_ok == K)
print(f'{"✓" if not bad else "✗"} t_dmsh_giant：{n - bad} / {n} 项通过')
sys.exit(1 if bad else 0)
