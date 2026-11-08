#!/usr/bin/env python3
# 片元 Alpha 测试 / 多重采样关的可选函数常量（缺口族 34 / 37；S2A.Dsh DshCompiler.FsAlphaMs，graphics/tools/direct/dsh/Dsh.cs，经 dsh_cmp --fn fs_alpha_ms 调（dshfn.py））。
# 期望按契约手写（状态/直连缺陷线.md「给满屏线」：S2A_AT int 常量 100、S2A_MSOFF bool 常量 101、参考值片元缓冲槽 30 按笔给）：
#   ① 改写：声明一行紧跟 using namespace metal;、main0 末尾加参数 constant float* s2a_aref [[buffer(30)]]、main0_out 加 s2a_smask [[sample_mask, function_constant(S2A_MSOFF_ON)]]、
#      每个 return out; 前写满掩码 + 比较颜色 0 的 .w 与 s2a_aref[0]；不写颜色 0 的只有 S2A_AT != 1；再改一次不变；不是片元主入口的原样返回
#   ② 成批合编（C# Unity.Src，graphics/tools/direct/dsh/batch/Unity.cs，经 dsh_batch --unity src）：两支改过的片元拼成一批，声明行只出现一次、在 using namespace metal; 之后
#   ④ 槽唯一（总指挥 11-01）：全仓 graphics/ 下枚举片元可能用到的缓冲槽——各处 *_SLOT 常量（#define / enum）、setFragmentBuffer / setFragmentBytes 的字面 atIndex、
#      C# 改写器（graphics/tools/direct/dsh/*.cs）里字面的 [[buffer(N)]]——30 只能出现在 FsAlphaMs 这一处（AREF_SLOT），别处一个都没有
#   ③ GPU（t_alpha_ms_run）：改过的单支与批源码编库，main0 三种特化（不给 / S2A_AT=5 / 再加 S2A_MSOFF=1）全建得出；s2a_alpha_pass 8 种比较 × 3 组值对手写真值表
# 反证：未改写的原样 MSL 里没有声明行，①直接不符（旧实现没有 fs_alpha_ms，dsh_cmp --fn 报错即红）。用法：t_alpha_ms.py
import collections, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(HERE, '../../../..')); sys.path.insert(0, HERE); import dshfn
TOOLS = os.path.join(R, 'translator'); sys.path.insert(0, TOOLS); import dsh_batch
HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
FS = (HEAD + 'struct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\nstruct main0_in\n{\n    float4 m_0 [[user(locn0)]];\n};\n\n'
      'fragment main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    if (in.m_0.x > 2.0)\n    {\n        out.m_0 = in.m_0;\n        return out;\n    }\n'
      '    out.m_0 = in.m_0 * 0.5;\n    out.m_1 = in.m_0;\n    return out;\n}\n\n')
FS_NOC0 = FS.replace('[[color(0)]]', '[[color(2)]]')
VS = HEAD + 'struct main0_out\n{\n    float4 gl_Position [[position]];\n};\n\nvertex main0_out main0()\n{\n    main0_out out = {};\n    return out;\n}\n\n'
fails = []
def ck(what, cond):
    print(('✓ ' if cond else '✗ ') + what)
    if not cond: fails.append(what)

r = dshfn.batch([('fs_alpha_ms', [FS]), ('fs_alpha_ms', [FS_NOC0]), ('fs_alpha_ms', [VS])])
if any('ok' not in x for x in r): print('✗ dsh_cmp --fn fs_alpha_ms 报错：', [x.get('err') for x in r]); sys.exit(1)
a, b, v = (x['ok'] for x in r)
decl = 'constant int S2A_AT [[function_constant(100)]]; constant bool S2A_AT_ON = is_function_constant_defined(S2A_AT); '
ck('① 声明行紧跟 using namespace metal;', 'using namespace metal;\n\n' + decl in a and a.count(decl) == 1)
ck('① main0 加参数 constant float* s2a_aref [[buffer(30)]]', 'fragment main0_out main0(main0_in in [[stage_in]], constant float* s2a_aref [[buffer(30)]])\n{' in a)
ck('① main0_out 加 s2a_smask（sample_mask，常量 S2A_MSOFF_ON 控制）', '    float4 m_1 [[color(1)]];\n    uint s2a_smask [[sample_mask, function_constant(S2A_MSOFF_ON)]];\n};' in a)
want_ret = '{ if (S2A_MSOFF_ON) out.s2a_smask = 0xffffffffu; if (S2A_AT_ON && !(s2a_alpha_pass(S2A_AT, float(out.m_0.w), s2a_aref[0]))) discard_fragment(); return out; }'
ck('① 两个 return out; 都改成写满掩码 + 比较颜色 0 的 a', a.count(want_ret) == 2 and a.count('return out;') == 2)
ck('① 不写颜色 0：只有 NEVER（S2A_AT != 1）', '!(S2A_AT != 1)) discard_fragment();' in b and 'out.m_0.w' not in b)
ck('① 再改一次不变（幂等）', dshfn.fn('fs_alpha_ms', a) == a)
ck('① 顶点着色器原样返回', v == VS)
ck('反证：原样 MSL 不带声明', decl not in FS)

def unity_src(items):   # [(摘要, MSL)] → 一批的源码（dsh_batch --unity src）
    with tempfile.TemporaryDirectory(prefix='t_alpha_ms_u_') as td:
        args = []
        for i, (k, txt) in enumerate(items):
            p = os.path.join(td, f'{i}.metal'); open(p, 'w').write(txt); args += [k, p]
        o = os.path.join(td, 'u.metal'); r = subprocess.run([*dsh_batch.get()[0], '--unity', 'src', o, *args], capture_output=True, text=True)
        if r.returncode: print('✗ dsh_batch --unity src 报错：' + (r.stdout + r.stderr).strip()[-300:]); sys.exit(1)
        return open(o).read()
u = unity_src([('aaaaaaaaaaaaaaaa', a), ('bbbbbbbbbbbbbbbb', b)])
ck('② 成批合编：声明只一次、在 using namespace metal; 之后', u.count(decl) == 1 and u.index('using namespace metal;') < u.index(decl))

# ④ 片元槽 30 只有这一个用途
GFX = os.path.join(R, 'graphics'); uses = collections.defaultdict(list)
for root, dirs, files in os.walk(GFX):
    dirs[:] = [d for d in dirs if d not in ('third_party', 'bin', 'obj', 'build')]
    for f in files:
        if not f.endswith(('.h', '.m', '.c', '.inc', '.mm', '.cs')): continue
        p = os.path.join(root, f); rel = os.path.relpath(p, R)
        try: txt = open(p, encoding='utf-8', errors='replace').read()
        except OSError: continue
        for m in re.finditer(r'#\s*define\s+(\w+_SLOT)\s+(\d+)\b|\b(\w+_SLOT)\s*=\s*(\d+)\b', txt):
            uses[int(m.group(2) or m.group(4))].append(f'{rel} {m.group(1) or m.group(3)}')
        for m in re.finditer(r'setFragment(?:Buffer|Bytes)[^;]*?atIndex:\s*(\d+)\s*\]', txt): uses[int(m.group(1))].append(f'{rel} atIndex')
        if f.endswith('.cs'):
            for m in re.finditer(r'\[\[buffer\((\d+)\)', txt): uses[int(m.group(1))].append(f'{rel} [[buffer]]')
mine = [u for u in uses.get(30, []) if u.endswith('AREF_SLOT')]
others = [u for u in uses.get(30, []) if not u.endswith('AREF_SLOT')]
ck(f'④ 片元槽 30 只有 FsAlphaMs 一处（AREF_SLOT {len(mine)} 处，别的 {others or "0 处"}；全仓枚举到槽号 {sorted(uses)}）', len(mine) == 1 and not others)
ck('④ 改写结果里用的就是 AREF_SLOT 30', '[[buffer(30)]]' in a)

with tempfile.TemporaryDirectory(prefix='t_alpha_ms_') as t:
    exe = os.path.join(t, 'run'); c = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', '-o', exe, os.path.join(HERE, 't_alpha_ms_run.m')], capture_output=True, text=True)
    if c.returncode: print('✗ t_alpha_ms_run 编不过：' + c.stderr[-400:]); sys.exit(1)
    fd = os.path.join(t, 'decl.txt'); open(fd, 'w').write(re.search(r'^constant int S2A_AT .*$', a, re.M).group(0))
    files = []
    for nm, txt in (('a.metal', a), ('b.metal', b), ('u.metal', u)):
        p = os.path.join(t, nm); open(p, 'w').write(txt); files.append(p)
    o = subprocess.run([exe, fd, *files], capture_output=True, text=True); out = o.stdout
    sp = re.search(r'SPEC (\d+) (\d+)', out); ps = re.search(r'PASS((?: \d)+)', out)
    ck(f'③ 三种特化全建得出（单支 2 + 批 2 个入口 × 3）：{sp.group(0) if sp else out[-300:]}', bool(sp) and sp.group(1) == '12' and sp.group(2) == '0')
    # 真值表（手写）：f 1 NEVER 2 LESS 3 EQUAL 4 LEQUAL 5 GREATER 6 NOTEQUAL 7 GEQUAL 8 ALWAYS；每组 a = 0.2 / 0.5 / 0.8，r = 0.5
    truth = [0,0,0, 1,0,0, 0,1,0, 1,1,0, 0,0,1, 1,0,1, 0,1,1, 1,1,1]
    ck('③ s2a_alpha_pass 24 例对手写真值表', bool(ps) and [int(x) for x in ps.group(1).split()] == truth)
print(('✓ t_alpha_ms：全过' if not fails else f'✗ t_alpha_ms：{len(fails)} 项不符'))
sys.exit(1 if fails else 0)
