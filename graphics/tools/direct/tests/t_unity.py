#!/usr/bin/env python3
# 直连库成批合编单测（C# 出库链 graphics/tools/direct/dsh/batch：Build.cs UnityFlush + Unity.cs 切批 / 拼源码；11-01 出库链挪进 C#，原 dmsh_build.py unity_src / unity_flush 随之删除）。
#   经 dsh_batch --unity flush 跑整份出库里真正的编批库那一步（只出 Mac，真 xcrun metal，按内容的编译缓存放在本用例的临时目录），--unity cut 跑切批规则；约 1–2 分钟。
# 期望（按规则手写，不跑被测实现推）：
# 批库按 MSL 内容分批、命名：D(源码) = sha256(MSL)[:16]；批按 D 排、D 是 48 的倍数处切，批库 u<批首 D>，函数前缀 s<D>_。下面的 D 都由已知源码文本直接算
#   ① 6 个能编的片元键同一批（前提：各 D 都不是 48 的倍数，用例先核）→ Metal 只新编 1 次；每键 _b.json 有 fn_prefix = s<D>_、fn_lib = u<最小 D>、writes_layer = false，_b.metallib 与批库逐字节相同；批库里有 s<D>_main0
#   ② 同一批里混进一个编不过的键 → 整批退回逐键编：日志一行「[unity] batch u<首键> (6 keys) … built key by key」写明各键结局（自成 4、去掉额外入口 1、失败 1）；
#      编不过的键 _b.json / _b.metal / _b.metallib 都没有、失败表里有它；带额外入口的键（main0_u 编不过）去掉入口重编成功，_b.json 里没了 entry_u / u_mask，_b.metal 换成去掉入口的源码；
#      ②b 影子输入库：编不过的键没有 _bv，其余 5 键按真名单重切成 1 批（库里没有编不过那支的函数）
#   ③ MSL 逐字节相同的键只编一次：6 键里 3 支同一份源码、另 3 支各不相同 → Metal 新编 1 次、批库里只有 4 份源码的函数；同源两支 json 的 fn_prefix = s<那份 D>_、
#      fn_lib = u<最小 D>，_b.metallib 与批库逐字节相同；计数「same MSL keys」= 2
#   ④ 同一份编不过的源码出现两次、与 2 份能编的（各两支）同批 → 批里只放 3 个代表键（日志「(3 keys)」）、退回逐键 2 份编成 1 份失败；两支编不过的都在失败表里、产物都没有；
#      与能编键同源的那支照样指到它的库
#   ⑤ 翻译器改了、MSL 没变（去全局链号的验收）：同样 6 份源码换一套键、共用按内容的编译缓存 → Metal 新编 0 次，批库名 / 函数前缀与第一次相同；
#      反证：其中 1 支 MSL 真变了 → 只新编它所在的 1 批
#   ⑥ 切批按源码大小封顶（11-01：影子输入批 14–18 MB、编 70–80 秒成长尾）：摘要都不是 48 的倍数时只看大小；上限 0 不按大小切；摘要 % 48 == 0 处照旧切
# 11-01 总指挥定删：每键单独编库（DMSH_UNITY=0）与冷热分批（两段式热键 DMSH_HOT）随迁移删除，对应旧用例不再有。
# 反证：旧实现没有 --unity flush / cut 子命令（dsh_batch 报用法、退出 2 → 红）。用法：t_unity.py
import hashlib, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); TOOLS = os.path.abspath(os.path.join(HERE, '../../../../translator'))
sys.path.insert(0, TOOLS); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(c, m):
    print(('  ✓ ' if c else '  ✗ ') + m)
    if not c: fails.append(m)

FS = ('#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct main0_out\n{\n    float4 m_0 [[color(0)]];\n};\n\n'
      'static inline float h(float x) { return x * %s; }\n\nfragment main0_out main0()\n{\n    main0_out out = {};\n    out.m_0 = float4(h(1.0));\n    return out;\n}\n')
BAD = FS.replace('return out;', 'return out_undeclared;')
EXTRA = FS + '\nstruct main0_out_u\n{\n    uint4 m_0 [[color(0)]];\n};\n\nfragment main0_out_u main0_u()\n{\n    main0_out_u out = {};\n    out.m_0 = uint4(undeclared_value);\n    return out;\n}\n'
KEYS = [f'{i:016x}' for i in (1, 2, 3, 5, 6, 7)]
D = lambda text: hashlib.sha256(text.encode()).hexdigest()[:16]   # 期望：源码文本的摘要（批库名 / 函数前缀的口径）

class Run:   # 一次 --unity flush：入目录放键，出目录看产物
    def __init__(self, t, name, cas, texts, refl=None, plain=None, vin=None, env=None):
        self.i, self.o = os.path.join(t, name, 'in'), os.path.join(t, name, 'out'); os.makedirs(self.i)
        for k, tx in texts.items():
            open(os.path.join(self.i, k + '_b.metal'), 'w').write(tx)
            json.dump((refl or {}).get(k, {'key': k + '_b', 'stage': 'ps', 'entry': 'main0'}), open(os.path.join(self.i, k + '_b.json'), 'w'))
        for k, tx in (plain or {}).items(): open(os.path.join(self.i, k + '_b.plain.metal'), 'w').write(tx)
        for k, tx in (vin or {}).items(): open(os.path.join(self.i, k + '_bv.metal'), 'w').write(tx)
        r = subprocess.run([*CMD, '--unity', 'flush', self.i, self.o, cas, '-j', '2'], capture_output=True, text=True, env=env)
        self.rc, self.log = r.returncode, r.stdout
        if r.returncode: print(f'  ✗ dsh_batch --unity flush 退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-400:]}')
        self.failed = sorted(l.split('\t')[1] for l in self.log.splitlines() if l.startswith('FAILED\t'))
        self.stat = {l.split('\t')[1]: int(l.split('\t')[2]) for l in self.log.splitlines() if l.startswith('STAT\t')}
        m = re.search(r'mac (\d+) reused, (\d+) compiled', self.log)
        self.compiled = int(m.group(2)) if m else -1
    def has(self, n): return os.path.exists(os.path.join(self.o, n))
    def bytes(self, n): return open(os.path.join(self.o, n), 'rb').read()
    def json(self, k): return json.load(open(os.path.join(self.o, k + '_b.json')))
    def line(self, prefix): return next((l for l in self.log.splitlines() if l.startswith(prefix)), '')

with tempfile.TemporaryDirectory(prefix='t_unity_') as t:
    # ①
    ds = [D(FS % f'{i + 1}.0') for i in range(6)]
    g = Run(t, '1', os.path.join(t, 'cas1'), {k: FS % f'{i + 1}.0' for i, k in enumerate(KEYS)})
    check(all(int(d, 16) % 48 for d in sorted(ds)[1:]), f'① 前提：除批首外各 D 都不是 48 的倍数（{ds}）')
    lib = f'u{min(ds)}.metallib'
    check(g.rc == 0 and not g.failed and g.compiled == 1, f'① 一批 6 键 Metal 只新编 1 次、没有失败（新编 {g.compiled} 次，失败 {g.failed}）')
    if g.has(lib):
        js = [g.json(k) for k in KEYS]; b = g.bytes(lib)
        check(all(j.get('fn_prefix') == f's{d}_' and j.get('fn_lib') == f'u{min(ds)}' and j.get('writes_layer') is False for j, d in zip(js, ds)), '① 每键 json：fn_prefix = s<D>_、fn_lib = u<最小 D>、writes_layer = false')
        check(all(g.bytes(k + '_b.metallib') == b for k in KEYS), '① 每键 _b.metallib 与批库逐字节相同')
        check(all(f's{d}_main0'.encode() in b for d in ds), '① 批库里每键都有 s<D>_main0')
    else: check(False, f'① 批库 {lib} 不在')
    # ②
    texts = {KEYS[0]: FS % '1.0', KEYS[1]: FS % '2.0', KEYS[2]: BAD, KEYS[3]: EXTRA, KEYS[4]: FS % '5.0', KEYS[5]: FS % '6.0'}
    refl = {k: {'key': k + '_b', 'stage': 'ps', 'entry': 'main0', **({'entry_u': 'main0_u', 'u_mask': 1} if k == KEYS[3] else {})} for k in KEYS}
    g = Run(t, '2', os.path.join(t, 'cas2'), texts, refl, plain={KEYS[3]: FS % '4.0'}, vin={k: FS % f'{9 + i}.0' for i, k in enumerate(KEYS)})
    line = g.line(f'[unity] batch u{min(D(tx) for tx in texts.values())} (6 keys)')
    check('built key by key' in line and '4 built alone' in line and '1 built without extra entry points' in line and '1 failed' in line, f'② 日志写明哪批退回、各键结局（{line[:150]}）')
    check(g.failed == [KEYS[2]] and not any(g.has(KEYS[2] + x) for x in ('_b.json', '_b.metal', '_b.metallib')), f'② 编不过的键：失败表里有它、三样产物都没有（{g.failed}）')
    if g.has(KEYS[3] + '_b.json'):
        je = g.json(KEYS[3])
        check('entry_u' not in je and 'u_mask' not in je and je.get('fn_lib') == f'u{D(FS % "4.0")}' and g.bytes(KEYS[3] + '_b.metal').decode() == FS % '4.0',
              f'② 带额外入口的键：去掉 main0_u 重编成功、json 没了 entry_u / u_mask、MSL 换成去掉入口的源码（fn_lib {je.get("fn_lib")}）')
    else: check(False, '② 带额外入口的键 json 不在')
    check(all(g.has(k + '_b.json') and g.json(k).get('fn_lib') == f'u{D(texts[k])}' for k in (KEYS[0], KEYS[1], KEYS[4], KEYS[5])), '② 能编的键各自成库（fn_lib = u<自己的 D>）')
    keep = [k for k in KEYS if k != KEYS[2]]
    bv = {k: g.bytes(k + '_bv.metallib') for k in KEYS if g.has(k + '_bv.metallib')}
    check(sorted(bv) == keep and len(set(bv.values())) == 1 and f's{D(BAD)}_'.encode() not in bv[keep[0]] and all(f's{D(texts[k])}_'.encode() in bv[keep[0]] for k in (KEYS[0], KEYS[1], KEYS[4], KEYS[5]))
          and g.stat.get('vin batches') == 1,
          f'②b 影子输入库：编不过的键没有 _bv；其余 5 键共用按真名单重切的一批（库里没有它的函数），计 1 批（有 _bv 的 {len(bv)} 键、批数 {g.stat.get("vin batches")}）')
    # ③
    texts = {KEYS[0]: FS % '1.0', KEYS[1]: FS % '2.0', KEYS[2]: FS % '1.0', KEYS[3]: FS % '4.0', KEYS[4]: FS % '1.0', KEYS[5]: FS % '6.0'}
    g = Run(t, '3', os.path.join(t, 'cas3'), texts)
    dist = sorted({D(tx) for tx in texts.values()}); lib = f'u{dist[0]}.metallib'
    check(g.rc == 0 and not g.failed and g.compiled == 1, f'③ 6 键（3 支同源）Metal 新编 1 次、没有失败（新编 {g.compiled} 次）')
    if g.has(lib):
        b = g.bytes(lib)
        check(len(dist) == 4 and all(b.count(f's{d}_main0'.encode()) >= 1 for d in dist), '③ 批库里有 4 份不同源码的函数（同源三支共用 s<D>_main0）')
        js = {k: g.json(k) for k in (KEYS[2], KEYS[4])}
        check(all(j.get('fn_prefix') == f's{D(FS % "1.0")}_' and j.get('fn_lib') == f'u{dist[0]}' for j in js.values()), f'③ 同源两支 json 指向同一份：fn_prefix = s<那份源码的 D>_、fn_lib = u<最小 D>（{[(j.get("fn_prefix"), j.get("fn_lib")) for j in js.values()]}）')
        check(all(g.bytes(k + '_b.metallib') == b for k in KEYS), '③ 每键 _b.metallib 与批库逐字节相同')
    else: check(False, f'③ 批库 {lib} 不在')
    check(g.stat.get('unity same MSL keys') == 2, f'③ 计数 same MSL keys = 2（{g.stat.get("unity same MSL keys")}）')
    # ④
    texts = {KEYS[0]: FS % '1.0', KEYS[1]: FS % '2.0', KEYS[2]: FS % '1.0', KEYS[3]: BAD, KEYS[4]: FS % '2.0', KEYS[5]: BAD}
    g = Run(t, '4', os.path.join(t, 'cas4'), texts)
    line = g.line(f'[unity] batch u{min(D(FS % "1.0"), D(FS % "2.0"), D(BAD))} (3 keys)')
    check(g.compiled == 2 and '2 built alone' in line and '1 failed' in line, f'④ 批里 3 个代表键、退回逐键 2 份编成 1 份失败（Metal 新编 {g.compiled} 次；{line[:120]}）')
    check(g.failed == [KEYS[3], KEYS[5]] and not any(g.has(k + x) for k in (KEYS[3], KEYS[5]) for x in ('_b.json', '_b.metal', '_b.metallib')), f'④ 同源编不过的两支都在失败表里、产物都没有（{g.failed}）')
    check(g.has(KEYS[4] + '_b.json') and g.json(KEYS[4]).get('fn_prefix') == f's{D(FS % "2.0")}_' and g.has(KEYS[2] + '_b.json') and g.json(KEYS[2]).get('fn_lib') == f'u{D(FS % "1.0")}', '④ 与能编键同源的照样指到它的库')
    # ⑤ 翻译器改了、MSL 没变：换一套键、共用按内容的编译缓存
    cas = os.path.join(t, 'cas5'); T6 = [FS % f'{i + 1}.0' for i in range(6)]; K6b = [f'{i:016x}' for i in (0x11, 0x12, 0x13, 0x15, 0x16, 0x17)]
    ga = Run(t, '5a', cas, dict(zip(KEYS, T6))); gb = Run(t, '5b', cas, dict(zip(K6b, T6)))
    names = lambda g, ks: [(g.json(k).get('fn_lib'), g.json(k).get('fn_prefix')) if g.has(k + '_b.json') else None for k in ks]
    same_names = names(ga, KEYS) == names(gb, K6b) and None not in names(ga, KEYS)
    check(not ga.failed and not gb.failed and ga.compiled == 1 and gb.compiled == 0 and same_names,
          f'⑤ 换一套键、MSL 不变 → 第二次 Metal 新编 0 次（{gb.compiled}）、批库名与前缀和第一次相同（{same_names}）')
    T6c = T6[:]; T6c[3] = FS % '9.5'
    gc = Run(t, '5c', cas, dict(zip(K6b, T6c)))
    check(not gc.failed and gc.compiled == 1, f'⑤ 反证：1 支 MSL 真变了 → 只新编 1 批（{gc.compiled}）')
    # ⑦ 换了 Xcode（Metal 编译器版本与锁 / 上次不同，11-02 恢复「版本不同照常出包」）：编译缓存按编译器身份分键，旧编译器编的库不得复用。
    #   假 xcrun 只把 metal / metallib --version 报成另一个版本、编译照转真 xcrun：同样 6 份源码、同一个缓存（⑤ 的 cas5）→ 新编 1 次；换回真编译器 → 新编 0 次（两份各自留着）
    fake = os.path.join(t, 'fakebin'); os.makedirs(fake); real = shutil.which('xcrun')
    open(os.path.join(fake, 'xcrun'), 'w').write(f'#!/bin/sh\ncase " $* " in *" --version "*) "{real}" "$@" | sed "1s/^/S2A-TEST-OTHER-COMPILER /";; *) exec "{real}" "$@";; esac\n')
    os.chmod(os.path.join(fake, 'xcrun'), 0o755)
    gd = Run(t, '7a', cas, dict(zip(KEYS, T6)), env=dict(os.environ, PATH=fake + os.pathsep + os.environ['PATH']))
    ge = Run(t, '7b', cas, dict(zip(KEYS, T6)))
    check(not gd.failed and gd.compiled == 1, f'⑦ 换了编译器版本、MSL 不变 → 不复用旧库、新编 1 次（{gd.compiled}）')
    check(not ge.failed and ge.compiled == 0, f'⑦ 换回原编译器 → 新编 0 次（两份各自留着）（{ge.compiled}）')
    # ⑧ 按成员复用批库（11-02 jhz「已有缓存为什么不能复用」）：6 键一批（带影子输入）编过一次；翻译器改了、只 1 支 _b MSL 变 →
    #   原批库整批拿来给没变的 5 支（fn_lib 仍是第一次的批名、库逐字节同第一次），变了的那支单独成新批（u<新 D>）；影子输入同理：没变的 5 支拿原库、那支新编。
    #   Metal 新编 2 次（新批 1 + 新影子输入批 1），计数 unity reused batches 1 / keys 5、vin reused batches 1 / keys 5
    cas = os.path.join(t, 'cas8'); V6 = [FS % f'{20 + i}.0' for i in range(6)]
    g8a = Run(t, '8a', cas, dict(zip(KEYS, T6)), vin=dict(zip(KEYS, V6)))
    T8 = T6[:]; T8[2] = FS % '7.25'
    g8b = Run(t, '8b', cas, dict(zip(KEYS, T8)), vin=dict(zip(KEYS, V6)))
    old = f'u{min(D(x) for x in T6)}'; stay = [k for i, k in enumerate(KEYS) if i != 2]
    ok8 = g8a.rc == 0 and g8b.rc == 0 and all(g8b.has(k + '_b.json') for k in KEYS)
    check(ok8 and all(g8b.json(k).get('fn_lib') == old and g8b.json(k).get('fn_prefix') == f's{D(T8[i])}_' for i, k in enumerate(KEYS) if i != 2)
          and g8b.json(KEYS[2]).get('fn_lib') == f'u{D(T8[2])}' and g8b.json(KEYS[2]).get('fn_prefix') == f's{D(T8[2])}_',
          f'⑧ 1 支 MSL 变：没变的 5 支 fn_lib 仍是 {old}、变了的那支自成 u<新 D>（{[g8b.json(k).get("fn_lib") for k in KEYS] if ok8 else "缺产物"}）')
    check(ok8 and g8b.has(old + '.metallib') and g8b.bytes(old + '.metallib') == g8a.bytes(old + '.metallib') and all(g8b.bytes(k + '_b.metallib') == g8a.bytes(old + '.metallib') for k in stay)
          and all(g8b.bytes(k + '_bv.metallib') == g8a.bytes(KEYS[0] + '_bv.metallib') for k in stay) and g8b.bytes(KEYS[2] + '_bv.metallib') != g8a.bytes(KEYS[0] + '_bv.metallib'),
          '⑧ 没变的 5 支：批库、_b 库、影子输入库都与第一次逐字节同；变了的那支影子输入库是新编的')
    check(g8b.compiled == 2 and g8b.stat.get('unity reused batches') == 1 and g8b.stat.get('unity reused keys') == 5 and g8b.stat.get('vin reused batches') == 1 and g8b.stat.get('vin reused keys') == 5,
          f'⑧ Metal 新编 2 次（{g8b.compiled}）、拿来编批库 1 批 5 键 / 影子输入 1 批 5 键（{[g8b.stat.get(x) for x in ("unity reused batches", "unity reused keys", "vin reused batches", "vin reused keys")]}）')
    # ⑧b 过半成员变了（6 支里 4 支）：不拿旧批（库里会多一半以上不用的函数），6 支按原切法重切成 1 批新编（前提同 ①：除批首外新 D 都不是 48 的倍数）
    T8c = T6[:2] + [FS % f'{30 + i}.5' for i in range(4)]
    g8c = Run(t, '8c', cas, dict(zip(KEYS, T8c)))
    nd = sorted(D(x) for x in T8c)
    check(all(int(d, 16) % 48 for d in nd[1:]) and g8c.rc == 0 and g8c.compiled == 1 and not g8c.stat.get('unity reused batches')
          and all(g8c.json(k).get('fn_lib') == f'u{nd[0]}' for k in KEYS),
          f'⑧b 4/6 支变了：不拿旧批、6 支新编 1 批 u<最小新 D>（新编 {g8c.compiled}，拿来 {g8c.stat.get("unity reused batches")}）')
    # ⑨ 任务 / 网格着色器（头两行同片元夹具：签名 = #include 集合，不同就分批）（MeshStage.cs 出的入口 [[object]] void main0 / [[mesh]] void main0 + main0_z）与片元同批合编：都认得出入口、改名进批库
    #   （11-05 时之笛第十二版：入口正则只认 fragment / vertex / kernel，网格键整批抛 no entry point、出库崩）
    MS = ('#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct V { float4 p [[position]]; };\nusing M = mesh<V, void, 3, 1, topology::triangle>;\n\n'
          '[[mesh]] void main0(M m, uint t [[thread_index_in_threadgroup]])\n{\n    if (t == 0) m.set_primitive_count(0);\n}\n\n'
          '[[mesh]] void main0_z(M m, uint t [[thread_index_in_threadgroup]])\n{\n    if (t == 0) m.set_primitive_count(%s);\n}\n')
    TS = ('#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct P { uint x; };\n\n'
          '[[object]] void main0(object_data P& p [[payload]], mesh_grid_properties g, uint t [[thread_index_in_threadgroup]])\n{\n    if (t == 0) { p.x = %su; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n}\n')
    for n in range(64):   # 选个让 3 份源码落进同一批的取值（除批首外 D 都不是 48 的倍数），期望照样由源码文本直接算
        T9 = {KEYS[0]: FS % f'{40 + n}.25', KEYS[1]: MS % n, KEYS[2]: TS % n}
        d9 = {k: D(x) for k, x in T9.items()}
        if all(int(d, 16) % 48 for d in sorted(d9.values())[1:]): break
    r9 = {KEYS[0]: {'key': KEYS[0] + '_b', 'stage': 'ps', 'entry': 'main0'}, KEYS[1]: {'key': KEYS[1] + '_b', 'stage': 'ms', 'entry': 'main0', 'entry_z': 'main0_z', 'msl_entry_kind': 'mesh'},
          KEYS[2]: {'key': KEYS[2] + '_b', 'stage': 'ts', 'entry': 'main0', 'msl_entry_kind': 'object'}}
    g9 = Run(t, '9', os.path.join(t, 'cas9'), T9, r9)
    lib9 = f'u{min(d9.values())}.metallib'
    if g9.compiled != 1: print('\n'.join(l for l in g9.log.splitlines() if 'unity' in l or 'error' in l.lower())[-1500:])
    check(g9.rc == 0 and not g9.failed and g9.compiled == 1, f'⑨ 片元 + 网格 + 任务 3 键同批 Metal 新编 1 次、没有失败（退出 {g9.rc}，新编 {g9.compiled}，失败 {g9.failed}）')
    b9 = g9.bytes(lib9) if g9.has(lib9) else b''
    want9 = [f's{d9[KEYS[0]]}_main0', f's{d9[KEYS[1]]}_main0', f's{d9[KEYS[1]]}_main0_z', f's{d9[KEYS[2]]}_main0']
    check(all(w.encode() in b9 for w in want9), f'⑨ 批库 {lib9} 里有 {want9}')
    # ⑩ 编批库按源码大小封顶（DMSH_UNITY_BATCH_MB；11-05 时之笛：运行时用一支就整批建 Metal 库，批大低区占满）。6 支同签名、同大小、摘要都不在 48 倍数处（同 ① 的源码）：
    #   上限 = 2.5 支的码点数 → 每批 2 支、3 批、Metal 新编 3 次；同一缓存先不封顶编 1 批 6 支，再封顶重跑 → 旧的 6 支大批超上限不拿来（计数 1），照新切法编 3 批
    T10 = [FS % f'{i + 1}.0' for i in range(6)]; L10 = len(T10[0])
    check(all(len(x) == L10 for x in T10), f'⑩ 前提：6 份源码等长（{L10} 码点）')
    capmb = str(2.5 * L10 / (1 << 20))
    e0 = dict(os.environ, DMSH_UNITY_BATCH_MB='0'); e1 = dict(os.environ, DMSH_UNITY_BATCH_MB=capmb)
    g10a = Run(t, '10a', os.path.join(t, 'cas10a'), dict(zip(KEYS, T10)), env=e1)
    libs10 = sorted({g10a.json(k).get('fn_lib') for k in KEYS if g10a.has(k + '_b.json')})
    check(g10a.rc == 0 and g10a.compiled == 3 and len(libs10) == 3, f'⑩ 封顶：6 支切 3 批、Metal 新编 3 次（新编 {g10a.compiled}，批库 {libs10}）')
    cas10 = os.path.join(t, 'cas10b')
    g10b = Run(t, '10b', cas10, dict(zip(KEYS, T10)), env=e0)
    g10c = Run(t, '10c', cas10, dict(zip(KEYS, T10)), env=e1)
    check(g10b.rc == 0 and g10b.compiled == 1 and g10c.rc == 0 and g10c.compiled == 3 and g10c.stat.get('unity reuse over cap') == 1 and not g10c.stat.get('unity reused batches'),
          f'⑩ 复用守卫：不封顶编 1 次（{g10b.compiled}）→ 封顶重跑不拿旧大批（超上限 {g10c.stat.get("unity reuse over cap")}、拿来 {g10c.stat.get("unity reused batches")}）、新编 3 次（{g10c.compiled}）')

# ⑥ 切批按源码大小封顶：摘要都不是 48 的倍数时只看大小
def cut(rows, cap):
    r = subprocess.run([*CMD, '--unity', 'cut', '48', str(cap)], input=''.join(f'{k}\t{d}\t{s}\n' for k, d, s in rows), capture_output=True, text=True)
    if r.returncode: print(f'  ✗ dsh_batch --unity cut 退出 {r.returncode}：{(r.stdout + r.stderr).strip()[-300:]}'); return None
    return [l.split(',') for l in r.stdout.splitlines()]
MB = 1 << 20; sz = {'a': 1, 'b': 1, 'c': 1, 'd': 1, 'e': 2, 'f': 2, 'g': 5, 'h': 1}
rows = [(k, f'{i:016x}', sz[k] * MB) for i, k in enumerate('abcdefgh', 1)]   # 摘要 1..8：都不是 48 的倍数
got = cut(rows, 3 * MB)
check(got == [['a', 'b', 'c'], ['d', 'e'], ['f'], ['g'], ['h']], f'⑥ 上限 3 MB：累计到上限前切、单个 5 MB 自成一批（{got}）')
check(cut(rows, 0) == [list('abcdefgh')], '⑥ 上限 0 = 不按大小切：8 键一批')
check(cut([('a', '0000000000000001', MB), ('b', '0000000000000030', MB), ('c', '0000000000000031', MB)], 3 * MB) == [['a'], ['b', 'c']], '⑥ 摘要 % 48 == 0 的边界照旧切（0x30 = 48；增删一个键只动它那一批）')
print(f't_unity：{len(fails)} 项失败' if fails else 't_unity：全过')
sys.exit(1 if fails else 0)
