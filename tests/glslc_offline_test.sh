#!/bin/bash
# 出包期离线编 GLSLC 单测（不读游戏、不起真宿主，约 2 秒）：bash tests/glslc_offline_test.sh
# 被测：translator/glslc_offline.py（dxa_decode / sources / stages / build / need）+ translator/shader_split.py glslc_shaders / skey（读离线编出的 .glslc）。
# 宿主用假的（tests/fake_glslc_host.py：DM_GLSLC_JOB 协议 + 按真 GLSLC 输出布局拼的输出），期望值不跑被测实现算：
#   ① DxLib 压缩：本测试自己按 DXA 格式压一段（字面量、转义字节本身、短 / 长回看、1 / 2 / 3 字节距离都有），解回原文；坏头 / 截断 → None
#   ② 源码发现：手拼的映像里一段明文源码 + 一个 DxLib 压缩包（偏移表 + 3 支 NUL 分隔的源码，其中一支与明文重复）+ 嵌在二进制里、不是整段文本的 '#version'
#      → 恰好 3 支、按出现顺序、重复的只留一次
#   ③ 阶段：写 gl_Position → 顶点在前；EmitVertex → 几何在前；local_size_x → 计算在前；其余 → 片元在前；候选总含顶点 / 片元 / 几何
#   ④ 键一致：三支源码（顶点 / 片元 / 编不过）经 build() 给假宿主编（2 路）→ .glslc → shader_split.glslc_shaders 出的键与阶段，
#      等于按「游戏运行时」的读法（段头 +0x94 段数据、+0xc0 控制段 / +0xc4 代码区偏移、+0xc8 / +0xcc 长度，即 DxLib 交给 nvnProgramSetShaders 的两块）
#      对控制段前 0x880 字节 + 代码区算的 sha256 前 16 位（宿主 hle_nvn.c keys_hash 的口径）；编不过的一支不出文件内容、计数 1
#   ⑤ 宿主崩 / 卡住（到墙钟上限）→ build() 报 [RED] 退 1、留那路宿主日志，不出半份当成功；⑥ need()：没有 GLSL 源码的真 NSO（shader_split_reuse 的自编夹具）→ 不需要
#   ⑦ 源码在 RomFS 的 NRO 里：按 NRO0 认模块（不认普通文件）、跨模块去重、need() 把 NRO 源码算进「有没有源码」
#   ⑧ 截断的 GLSLC 输出（魔数贴文件尾 / 控制段贴输出尾）跳过、不越界抛异常（审计 P2-45）
#   ⑨ #version 前有注释的整段源码认出（GRID）；⑩ 只有版本头的格式串、#version 前有代码 → 不算；⑪ 要编但认不出源码 → 黄行退 0、交运行时现编
# 门禁覆盖：translator/glslc_offline.py translator/shader_split.py tests/fake_glslc_host.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
cd "$H" && "$PY" -B - "$H" <<'PY'
import hashlib, io, os, shutil, struct, sys, tempfile, contextlib
H = sys.argv[1]
T = tempfile.mkdtemp(prefix='s2a-glslc-off-')
prof = os.path.join(T, 'profile'); os.makedirs(prof)
shutil.copyfile(os.path.join(H, 'tests/fixtures/shader_split_reuse/shader_split_reuse_profile.tsv'), os.path.join(prof, 'game.tsv'))
os.environ['DM_GAME'] = prof
sys.path.insert(0, os.path.join(H, 'translator'))
import glslc_offline as G, shader_split as S
bad = 0
def ck(c, msg):
    global bad
    print(('通 ' if c else '不通 ') + msg)
    if not c: bad += 1

def dxa(raw):
    """测试自带的 DXA 压缩（贪心找 ≥4 字节的最早匹配）；转义字节取出现最少的字节"""
    key = min(range(256), key=lambda b: (raw.count(bytes([b])), b))
    out, i = bytearray(), 0
    while i < len(raw):
        best = (0, 0)
        for j in range(max(0, i - 0x20000), i):
            n = 0
            while i + n < len(raw) and raw[j + n] == raw[i + n] and n < 4 + 0x1f + (0xff << 5): n += 1
            if n > best[0]: best = (n, i - j)
        n, dist = best
        if n >= 4:
            L = n - 4; w = 1 if dist - 1 < 0x100 else 2 if dist - 1 < 0x10000 else 3
            code = (L & 0x1f) << 3 | (4 if L >= 32 else 0) | (w - 1)
            out += bytes([key, code + (code >= key)])
            if L >= 32: out.append(L >> 5)
            out += (dist - 1).to_bytes(w, 'little'); i += n
        else:
            out += bytes([key, key]) if raw[i] == key else bytes([raw[i]]); i += 1
    return struct.pack('<IIB', len(raw), len(out) + 9, key) + bytes(out)

# ① DxLib 压缩
pat = b'ABCD' * 3 + bytes(range(256)) + b'xyz' * 40 + bytes(range(256)) * 300 + b'tail\x00'   # 每个字节值都出现（转义字节本身要按两字节写）
pat = pat + pat[:5000]   # 远距离（> 0x10000 字节前）的回看
blob = dxa(pat)
ck(G.dxa_decode(blob, 0) == pat, f'① DXA 解回原文（{len(pat)} 字节 → 压成 {len(blob)}）')
ck(G.dxa_decode(blob[:-3], 0) is None and G.dxa_decode(b'\0' * 4 + blob[4:], 0) is None, '① 截断 / 坏头 → None')

# ② 源码发现
vs = b'#version 440 core\nlayout(location=0) in vec3 aPos;\nvoid main() { gl_Position = vec4(aPos, 1.0); }\n'
fs = b'#version 440 core\nlayout(location=0) out vec4 color;\nvoid main() { color = vec4(1.0); }\n'
gs = b'#version 440 core\nlayout(points) in;\nlayout(points, max_vertices=1) out;\nvoid main() { gl_Position = gl_in[0].gl_Position; EmitVertex(); EndPrimitive(); }\n'
pkg = struct.pack('<8H', 3, 0, 16, 200, 400, 600, 0, 0) + b'\0' + vs + b'\0' + fs + b'\0' + gs + b'\0'
img = b'\x01\x02' * 64 + b'\0' + gs + b'\0' + b'\x90\x91#version 440 core\x8f\x00' + b'\x00' * 33 + dxa(pkg) + b'\x00\xff' * 64
got = G.sources(img)
ck([s for _, s in got] == [gs.rstrip(b'\0'), vs, fs], f'② 明文 1 + 压缩包 3（其中 1 支重复）→ 3 支、顺序对（实 {[s[:40] for _, s in got]}）')
ck([l.split('@')[0] for l, _ in got] == ['main', 'main#DXA', 'main#DXA'], f'② 来源标注（实 {[l for l, _ in got]}）')

# ③ 阶段
ck(G.stages(vs) == [0, 1, 2] and G.stages(fs) == [1, 0, 2] and G.stages(gs) == [2, 0, 1], f'③ 顶点 / 片元 / 几何（实 {G.stages(vs)} {G.stages(fs)} {G.stages(gs)}）')
ck(G.stages(b'#version 440\nlayout(local_size_x = 8) in;\nvoid main(){}') == [5, 0, 1, 2], '③ 计算着色器 → 计算在前')

# ④ 键一致
host = os.path.join(T, 'host'); open(host, 'w').write(f'#!/bin/sh\nexec "{sys.executable}" "{H}/tests/fake_glslc_host.py" "$@"\n'); os.chmod(host, 0o755)
out = os.path.join(T, 'cap'); badsrc = b'#version 440\nBAD\n'
with contextlib.redirect_stdout(io.StringIO()): ok, fail, by, J = G.build([('a', vs), ('b', fs), ('c', badsrc)], host, T, out, J=2)
ck((ok, fail, by, J) == (2, 1, {0: 1, 1: 1}, 2), f'④ 编成 2、编不过 1、顶点 1 片元 1、2 路（实 {(ok, fail, by, J)}）')
files = sorted(f for f in os.listdir(out))
ck(files == ['glslc_0.glslc', 'glslc_1.glslc'], f'④ 输出目录只剩两份 .glslc，作业与中间输出已删（实 {files}）')
def runtime_key(o):   # 游戏运行时交给 nvnProgramSetShaders 的控制段 / 代码区（按段头读，不找魔数）
    data = struct.unpack_from('<I', o, 0x94)[0]; co, ko, kn, cn = struct.unpack_from('<4I', o, 0xc0)
    ctl, code = o[data + co:data + co + cn], o[data + ko:data + ko + kn]
    own = struct.unpack_from('<I', ctl, 0x20)[0]
    return hashlib.sha256(ctl[:own if 0x760 <= own < 0x880 else 0x880] + code).hexdigest()[:16]
sys.path.insert(0, os.path.join(H, "tests")); import fake_glslc_host as F
want = {(runtime_key(F.output(vs, 0)), 'vs'), (runtime_key(F.output(fs, 1)), 'ps')}
have = set()
for f in files: have |= {(S.skey(c, k), st) for _, st, c, k in S.glslc_shaders(open(os.path.join(out, f), 'rb').read(), f'/glslc_capture/{f}', need=False)}
ck(have == want, f'④ shader_split 读出的（键, 阶段）= 运行时口径（期望 {sorted(want)}，实 {sorted(have)}）')

# ⑤ 宿主崩
os.environ['FAKE_GLSLC_DIE'] = '1'
try:
    with contextlib.redirect_stdout(io.StringIO()) as so: G.build([('a', vs)], host, T, os.path.join(T, 'cap2'), J=1)
    ck(False, '⑤ 宿主崩应报红退出')
except SystemExit as e: ck(e.code == 1 and '[RED] GLSLC 工具模式失败（1/1 路）：宿主退出 134' in so.getvalue(), f'⑤ 宿主崩 → [RED] 退 1（实 {e.code}：{so.getvalue().strip()[:120]}）')
del os.environ['FAKE_GLSLC_DIE']
os.environ['FAKE_GLSLC_HANG'] = '1'; G.TIMEOUT = 2
try:
    with contextlib.redirect_stdout(io.StringIO()) as so: G.build([('a', vs)], host, T, os.path.join(T, 'cap3'), J=1)
    ck(False, '⑤ 宿主卡住应报红退出')
except SystemExit as e: ck(e.code == 1 and '宿主超时' in so.getvalue() and os.path.isfile(os.path.join(T, 'cap3', 'job_0.dmgj.host.log')), f'⑤ 宿主卡住 → 到墙钟上限报 [RED] 宿主超时、留宿主日志（实 {e.code}：{so.getvalue().strip()[:100]}）')
del os.environ['FAKE_GLSLC_HANG']

# ⑥ need()
ex = os.path.join(T, 'exefs'); os.makedirs(ex); shutil.copyfile(os.path.join(H, 'tests/fixtures/shader_split_reuse/fixture.nso'), os.path.join(ex, 'main'))
m, why = G.need(ex, G.nso_syms.load(os.path.join(ex, 'main')))
ck(m is None and why, f'⑥ 没有 GLSL 源码的 NSO → 不需要（{why}）')

# ⑦ 源码在 RomFS 的 NRO 里（以撒 忏悔 / 胎衣+：main 只是装载器、导入 glslcCompile，明文源码在 romfs/.nro/*.nro）
root = os.path.join(T, 'root'); os.makedirs(os.path.join(root, 'romfs', '.nro')); os.makedirs(os.path.join(root, 'romfs', 'data'))
nro = b'\0' * 0x10 + b'NRO0' + b'\0' * 12 + b'\0' + vs + b'\0' + fs + b'\0' + fs + b'\0'   # 同一 NRO 里 fs 出现两次
open(os.path.join(root, 'romfs', '.nro', 'Game.nro'), 'wb').write(nro)
open(os.path.join(root, 'romfs', 'data', 'shader.txt'), 'wb').write(b'\0' + gs + b'\0')   # 不是 NRO（没有 NRO0 标记）的文件不算模块
nros = G.romfs_nros(root)
ck([l for l, _ in nros] == ['/.nro/Game.nro'], f'⑦ 按 NRO0 标记认出 1 个 NRO、不认普通文件（实 {[l for l, _ in nros]}）')
got = G.all_sources(b'\x01' * 8 + b'\0' + vs + b'\0', nros)   # main 里也有 vs：跨模块去重、留 main 那条
ck([(l.split('@')[0], s) for l, s in got] == [('main', vs), ('/.nro/Game.nro', fs)], f'⑦ main 1 支 + NRO 2 支（vs 与 main 重复、fs 自身重复）→ 2 支（实 {[(l, s[:24]) for l, s in got]}）')
nimg = G.nso_syms.load(os.path.join(ex, 'main'))
m1, why1 = G.need(ex, nimg); ds = G.nso_syms.dynsyms; G.nso_syms.dynsyms = lambda img: []   # 夹具 NSO 没有动态段：过了源码关后按「无导入」读
m2, why2 = G.need(ex, nimg, nros); G.nso_syms.dynsyms = ds
ck(m1 is None and 'GLSL' in why1 and m2 is None and why2 == 'main 不导入 glslcCompile', f'⑦ main 没源码、NRO 有 → 过源码这关、停在导入判断（不给 NRO：{why1}；给：{why2}）')
# ⑧ 截断输出不越界（审计 P2-45）：魔数贴着文件尾（+0x44 长度字段不在文件里）、控制段魔数离输出尾不到 0x708（+0x704 代码长度不在输出里）→ 跳过、不抛异常
M = struct.pack('<I', 0x19866891); sz = 0x800
near = M + b'\0' * 0x40 + struct.pack('<I', sz) + b'\0' * (sz - 0x48 - 0x10) + S.CTL_MAGIC + b'\0' * 12
for nm, d in (('魔数在文件尾', b'\0' * 16 + M + b'\0' * 8), ('控制段贴近输出尾', near)):
    try: r = S.glslc_shaders(d, 'x', need=False); ck(r == [], f'⑧ {nm} → 空（实 {r}）')
    except Exception as e: ck(False, f'⑧ {nm} → 空（实 抛 {type(e).__name__}：{e}）')
# ⑨ #version 前有注释的整段源码（GRID Autosport 的内置 FERAL_gui_*）：从前一个 NUL 之后整段认，源码含开头的注释
cs = b'// FERAL_gui_vs\n/* block */\n' + vs
got = G.sources(b'\x01' * 8 + b'\0' + cs + b'\0' + b'\x02' * 8)
ck([s for _, s in got] == [cs], f'⑨ 注释开头的源码整段认出（实 {[s[:30] for _, s in got]}）')
# ⑩ 只有版本头的格式串（GRID："#version %u es\n" 等，运行时拼源码用）、#version 前是代码而不是注释：都不算源码
got = G.sources(b'\x01' * 8 + b'\0#version %u es\n\0#version %u core\n\0int x;\n' + vs + b'\0')
ck(got == [], f'⑩ 版本头片段 / #version 前有代码 → 0 支（实 {[s[:30] for _, s in got]}）')
# ⑪ 要编（导入 glslcCompile、有模块带编译器）但认不出整段源码：打黄行、退出 0（交运行时现编），不报红停
sv = (G.need, G.all_sources, G.romfs_nros, G.nso_syms.load, sys.argv)
G.need = lambda *a: ('subsdk1', ''); G.all_sources = lambda *a: []; G.romfs_nros = lambda r: []; G.nso_syms.load = lambda p: b''
sys.argv = ['glslc_offline.py', T, os.path.join(T, 'o11')]; out = io.StringIO(); code = 0
try:
    with contextlib.redirect_stdout(out): G.main()
except SystemExit as ex: code = ex.code
G.need, G.all_sources, G.romfs_nros, G.nso_syms.load, sys.argv = sv
ck(code in (0, None) and '【黄】' in out.getvalue() and '[RED]' not in out.getvalue(), f'⑪ 认不出源码 → 黄行、退出 0（实 退出 {code}：{out.getvalue()[:80]!r}）')
# ⑫ ExeFS 里带 NSO 魔数却解析不了的模块（审计 P2-209）→ [RED] 退 1，不答「不需要」；不是 NSO 的旁路文件照旧跳过
ex12 = os.path.join(T, 'exefs12'); os.makedirs(ex12)
open(os.path.join(ex12, 'subsdk1'), 'wb').write(b'NSO0' + b'\0' * 12)          # NSO 魔数、头截断：load 必抛
open(os.path.join(ex12, 'datafile'), 'wb').write(b'not an nso at all')           # 旁路数据文件
main12 = b'#version 450\nvoid main(){}'
sv12 = G.nso_syms.dynsyms
G.nso_syms.dynsyms = lambda img: [('glslcCompile', False, 0)] if img == main12 else sv12(img)   # main 导入 glslcCompile（夹具不造整个 NSO）
out = io.StringIO(); code = 0
try:
    with contextlib.redirect_stdout(out): r12 = G.need(ex12, main12)
except SystemExit as ex: code = ex.code; r12 = None
ck(code == 1 and '[RED]' in out.getvalue() and 'subsdk1' in out.getvalue(), f'⑫ NSO 魔数却解析不了 → [RED] 退 1（实 退出 {code}、返回 {r12!r}：{out.getvalue()[:90]!r}）')
os.remove(os.path.join(ex12, 'subsdk1')); out = io.StringIO(); code = 0
try:
    with contextlib.redirect_stdout(out): r12 = G.need(ex12, main12)
except SystemExit as ex: code = ex.code; r12 = None
ck(code in (0, None) and r12 is not None and r12[0] is None and '定义它' in r12[1], f'⑫ 只剩非 NSO 的旁路文件 → 跳过、答没有模块定义它（实 {r12!r}）')
G.nso_syms.dynsyms = sv12
shutil.rmtree(T)
print('GLSLC 离线编单测：' + ('全通' if not bad else f'{bad} 项不通'))
sys.exit(1 if bad else 0)
PY
