#!/usr/bin/env python3
# 直通几何快路的翻译判定与两份新产物（dmsh_xlate → Dsh.cs GeometryFinish 出 _bgs<拓扑> / _bgc，宿主 nvn_geometry.inc geo_draw 走快路）：
#   python3 t_gs_passthrough.py <dmsh_xlate.dll>（tests/gs_passthrough_test.sh 先编翻译器）；要 Homebrew 的 spirv-cross
# 输入是现造的 Maxwell 几何着色器（不来自游戏）：头 = VTG、版本 3、几何阶段、1 次调用、三角带、最多 3 顶点，第 0 字第 24 位 = 直通；
#   代码 = 只有 EXIT（直通几何的常见形态：本体什么都不写，输出全靠直通），或本体先 AST 写一个通用输出再 EXIT。指令编码同 tests/compiler/Program.cs
# 期望按规格写死（不跑被测实现推）：
#   ① 直通、本体不写：res.json gs_passthrough = 真、gs_passthrough_fast = 真，出 .side.spv / .capture.spv
#   ② 负对照：直通但本体写了输出（这个值只在记录里，抓顶点读取器给不出）→ gs_passthrough = 真、gs_passthrough_fast = 假，不出两份新产物
#   ③ 不直通 → 两样都假、不出
#   ④ 抓顶点读取器的取字：几何输入固定布局（ResourceReservations.FillGeometryInputMap，每顶点 144 字：位置 0–3、点大小 4、裁剪距离 5–12、图层 13、视口 14、
#      通用属性 a 的分量 c 在 16 + 4a + c）→ 顶点基址 = 顶点号 × 144，位置分量 c 取 +c，32 个通用输出 locn a 的 xyzw 取 +16+4a+c，点大小 = 记录初值 1.0
#   ⑤ 只算副作用的核里没有记录 / 下标缓冲（geometry_vb_output / geometry_ib_output 0 处）；同一着色器的普通核里有（判据不会绿着失效）
import json, os, re, struct, subprocess, sys, tempfile

DLL = sys.argv[1]; DN = os.environ.get('DOTNET') or 'dotnet'
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)

SCHED, EXIT = 0x001F8000FC0007E0, 0xE30000000007000F
def ast(loc, comp=0, reg=0xFF):   # AST a[0x80 + 16 * loc + 4 * comp], R<reg>（RZ = 0xFF）
    return 0xEFF0000000000000 | (0xFF << 39) | ((0x80 + loc * 16 + comp * 4) << 20) | (7 << 16) | (0xFF << 8) | reg
def guest(passthrough, ops):
    blocks = (len(ops) + 1 + 2) // 3
    b = bytearray(0x50 + blocks * 32)
    struct.pack_into('<5I', b, 0, 1 | (3 << 5) | (4 << 10) | ((1 << 24) if passthrough else 0), 0, 1 << 24, 7 << 24, 3)
    for i in range(blocks * 4):
        oi = i // 4 * 3 + i % 4 - 1
        struct.pack_into('<Q', b, 0x50 + i * 8, SCHED if i % 4 == 0 else ops[oi] if oi < len(ops) else EXIT)
    return bytes(b)

def msl(p):
    r = subprocess.run(['spirv-cross', '--msl', '--msl-version', '30000', p], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ''

with tempfile.TemporaryDirectory() as t:
    cases = {'pt': guest(True, []), 'ptw': guest(True, [ast(0)]), 'npt': guest(False, [])}
    jobs = []
    for k, code in cases.items():
        open(os.path.join(t, k + '.bin'), 'wb').write(code)
        jobs.append({'key': k + '_g3', 'stage': 'gs', 'code': os.path.join(t, k + '.bin'), 'geometry_topology': 3, 'debug': False})
    json.dump(jobs, open(os.path.join(t, 'jobs.json'), 'w'))
    out = os.path.join(t, 'out')
    r = subprocess.run([DN, DLL, os.path.join(t, 'jobs.json'), out], capture_output=True, text=True)
    ck(f'翻译器跑完三支（退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-200:]}）', r.returncode == 0)
    def res(k):
        try: return json.load(open(os.path.join(out, k + '_g3.res.json')))
        except OSError: return {}
    def has(k, ext): return os.path.exists(os.path.join(out, f'{k}_g3.{ext}.spv'))
    a, w, z = res('pt'), res('ptw'), res('npt')
    ck(f"① 直通、本体不写：直通 {a.get('gs_passthrough')}、快路 {a.get('gs_passthrough_fast')}、副作用核 {has('pt', 'side')}、抓顶点读取器 {has('pt', 'capture')}（期望全真）",
       a.get('gs_passthrough') is True and a.get('gs_passthrough_fast') is True and has('pt', 'side') and has('pt', 'capture'))
    ck(f"② 负对照：直通但本体写了 locn0.x：直通 {w.get('gs_passthrough')}、快路 {w.get('gs_passthrough_fast')}、副作用核 {has('ptw', 'side')}、读取器 {has('ptw', 'capture')}（期望 真 / 假 / 无 / 无）",
       w.get('gs_passthrough') is True and w.get('gs_passthrough_fast') is False and not has('ptw', 'side') and not has('ptw', 'capture'))
    ck(f"③ 不直通：直通 {z.get('gs_passthrough')}、快路 {z.get('gs_passthrough_fast')}、副作用核 {has('npt', 'side')}（期望 假 / 假 / 无）",
       z.get('gs_passthrough') is False and z.get('gs_passthrough_fast') is False and not has('npt', 'side') and not has('npt', 'capture'))

    cap = msl(os.path.join(out, 'pt_g3.capture.spv')) if has('pt', 'capture') else ''
    m = re.search(r'int (_\d+) = int\(gl_VertexIndex\) \* (\d+);', cap)
    base = m.group(1) if m else None
    loc = {f: int(l) for f, l in re.findall(r'float4 (\w+) \[\[user\(locn(\d+)\)\]\];', cap)}
    got = {}
    for f, c, off in re.findall(r'out\.(\w+)\.([xyzw]) = vertex_output\._m0\[' + re.escape(base or '?') + r'(?: \+ (\d+))?\];', cap):
        got[(f, 'xyzw'.index(c))] = int(off or 0)
    want = {('gl_Position', c): c for c in range(4)}
    for f, a_ in loc.items():
        for c in range(4): want[(f, c)] = 16 + 4 * a_ + c
    ck(f"④ 抓顶点读取器：顶点基址 = 顶点号 × {m.group(2) if m else '?'}（期望 144），{len(loc)} 个通用输出（期望 32、locn0–31），取字 {len(got)} 处与固定布局一致 {got == want}（期望 132 处），"
       f"点大小 = 1.0 {'out.gl_PointSize = 1.0;' in cap}",
       m is not None and m.group(2) == '144' and sorted(loc.values()) == list(range(32)) and got == want and len(got) == 132 and 'out.gl_PointSize = 1.0;' in cap)

    side = msl(os.path.join(out, 'pt_g3.side.spv')) if has('pt', 'side') else ''
    full = msl(os.path.join(out, 'pt_g3.spv'))
    ns = len(re.findall(r'geometry_(?:vb|ib)_output', side)); nf = len(re.findall(r'geometry_(?:vb|ib)_output', full))
    ck(f'⑤ 只算副作用的核：记录 / 下标缓冲 {ns} 处（期望 0，且是计算核 {"kernel void main0(" in side}）；普通核 {nf} 处（期望 > 0）',
       bool(side) and 'kernel void main0(' in side and ns == 0 and nf > 0)
print(f"{'✓' if not bad else '✗'} t_gs_passthrough：{n} 项，失败 {bad}")
sys.exit(1 if bad else 0)
