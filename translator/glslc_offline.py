#!/usr/bin/env python3
# 出包期离线编 GLSLC（直连库，「游戏运行时才用 glslc 编着色器」的款）：glslc_offline.py <产物根（已改写：exefs/main + <模块>.fixups.tsv / .patched.bin）> <输出目录>
# 为什么：这类游戏不带编好的着色器，运行时拿 main 里的 GLSL 源码调游戏自带的 glslcCompile 现编（神之天平 外传 DxLib：main 里 4 个 DxLib 压缩包共 3509 支源码，subsdk0 带编译器）。
#   直连库按「控制段 + 代码区」的哈希认键，键要和游戏运行时提交的对上，只能用游戏自己的编译器、同样的源码、同样的选项编：这里从 main 找出源码，
#   交 Mac 宿主的 GLSLC 工具模式（runtime/src/glslc_tool.c，DM_GLSLC_JOB）调游戏的 glslcCompile 编，输出写成 <输出目录>/glslc_<n>.glslc，
#   shader_split.py 按 DM_GLSLC_CAPTURE 读（同运行时抓到的输出，glslc_shaders）。设备上的现编只当安全网（漏的、游戏另从数据文件读的源码）。
# 判要不要编（与 shader_split.py 报「no captured GLSLC outputs」红行同一判据）：main 里有 '#version '、main 导入 glslcCompile、ExeFS 里另有模块定义 glslcCompile；不满足 → 打一行、不出文件、退 0。
# 源码（main 映像与 RomFS 里的 NRO 模块，不看文件名 / 款号；以撒 忏悔 / 胎衣+：main 只是装载器、导入 glslcCompile，游戏代码与 68 支明文源码在 romfs/.nro/*.nro，
#   由 nn::ro 装进来后交 main 编——只看 main 时判成「不需要」、直连库一个键都没出）：
#   · 明文：以 NUL 起头、NUL 结尾的整段 '#version …' 文本（KTGL 一类把源码原样放在只读段）
#   · DxLib 压缩包（DxLib 的 DXA 压缩：u32 原长、u32 压缩长（含 9 字节头）、u8 转义字节；正文里转义字节后跟 {转义字节 = 原字节本身 | 码字：
#     码 > 转义字节时减一；长度 = 码 >> 3（码 bit2 置位时再拼一字节 << 5）+ 4；回看距离字节数 = (码 & 3) + 1，距离 = 读出的值 + 1}）：包里第一支源码的 '#version' 一定是原样字面量，
#     从每个不是明文源码的 '#version' 往前找能解开、解出来盖住它的包头；解出的包是「偏移表 + NUL 分隔的源码」，取每段 NUL 起头的 '#version …'
# 阶段：源码自己说（写 gl_Position → 顶点，EmitVertex / EndPrimitive → 几何，layout(vertices…) → 曲面控制，gl_TessCoord → 曲面求值，local_size_x → 计算，其余片元），
#   先试它、编不过再试顶点 / 片元 / 几何（glslc_tool.c 按候选顺序取第一个编过的）
# 宿主：DM_GLSLC_HOST（缺省本仓库 build/s2arm-host，S2A_CS=1 make host 编出：工具模式要 C# 服务层）；并行 J 路（每路一个宿主进程编一段源码）
# 退出：0 = 不需要 / 编成（末行「GLSLC 离线编：…」）；1 = 要编却编不成（找不到源码、没有宿主、宿主失败、一支都没编成），末行 [RED] 原因
import concurrent.futures as cf, os, re, shutil, struct, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'graphics', 'nvn', 'tools')); import nso_syms
# 仓库里唯一的 RomFS 遍历与文件头清单（graphics/nvn/tools/romfs_list.py）
import romfs_list

def red(msg): print('[RED] ' + msg, flush=True); sys.exit(1)

def dxa_decode(d, s):
    """DxLib 的 DXA 压缩块（头在 s）→ 解出的字节，头不对 / 解不开 / 长度对不上 → None"""
    if s < 0 or s + 9 > len(d): return None
    dest, src, key = struct.unpack_from('<IIB', d, s)
    if not (16 < dest < 1 << 28 and 9 < src and s + src <= len(d)): return None
    sp, end, out = s + 9, s + src, bytearray()
    try:
        while sp < end:
            c = d[sp]
            if c != key: out.append(c); sp += 1; continue
            if d[sp + 1] == key: out.append(key); sp += 2; continue
            code = d[sp + 1] - (d[sp + 1] > key); sp += 2
            n = code >> 3
            if code & 4: n |= d[sp] << 5; sp += 1
            n += 4; w = (code & 3) + 1
            if w == 4: return None
            dist = int.from_bytes(d[sp:sp + w], 'little') + 1; sp += w
            if dist > len(out) or len(out) + n > dest: return None
            for _ in range(n): out.append(out[-dist])
    except IndexError: return None
    return bytes(out) if len(out) == dest and sp == end else None

TEXT = re.compile(rb'[\t\n\r\x20-\x7e]*')
LEAD = re.compile(rb'(?:\s+|//[^\n]*\n|/\*.*?\*/)*', re.S)   # #version 前允许的：空白、行注释、块注释
MAIN = re.compile(rb'\bmain\s*\(')
def plain_at(d, a, back=0x1000):
    """d[a:] 起的 '#version' 是不是一整段明文源码的开头 → 整段源码（从前一个 NUL 之后起）或 None。
    整段：前一个 NUL 之后到 '#version' 之间只有空白 / 注释（GRID Autosport：5 支内置着色器 FERAL_gui_* 的 '#version' 前有注释），到下一个 NUL 都是文本，且有 main(。
    只有版本头、没有 main( 的不算（GRID 的 "#version %u es\n" 一类是游戏运行时拼源码用的格式串，当源码编会全部编不过）"""
    s = a
    while s > 0 and a - s < back and d[s - 1]: s -= 1
    if s and d[s - 1]: return None
    if LEAD.match(d, s, a).end() != a: return None
    e = d.find(b'\0', a)
    if e < 0: return None
    if TEXT.match(d, s, e).end() != e: return None
    return d[s:e] if MAIN.search(d, a, e) else None

def sources(img, back=0x40000, lab='main', seen=None):
    """模块映像里的 GLSL 源码 → [(来源, 源码)]，同一源码只留第一次（来源 = <模块>@偏移 或 <模块>#DXA@包头偏移+包内偏移）；seen 跨模块共用时去重跨模块"""
    out, covered = [], []
    seen = set() if seen is None else seen
    def add(lab, s):
        if s not in seen: seen.add(s); out.append((lab, s))
    for m in re.finditer(rb'#version ', img):
        a = m.start()
        s = plain_at(img, a)
        if s is not None: add(f'{lab}@{a:#x}', s); continue
        if any(h <= a < h + n for h, n in covered): continue
        for h in range(a - 9, max(-1, a - back), -1):
            dest, src = struct.unpack_from('<II', img, h)
            if not (h + src > a and src < 2 * dest): continue
            blob = dxa_decode(img, h)
            if blob is None or b'#version ' not in blob: continue
            covered.append((h, src))
            for b in re.finditer(rb'#version ', blob):
                s = plain_at(blob, b.start())
                if s is not None: add(f'{lab}#DXA@{h:#x}+{b.start():#x}', s)
            break
    return out

def stages(src):
    """候选阶段（NVNshaderStage：0 顶点 1 片元 2 几何 3 曲面控制 4 曲面求值 5 计算），源码自己说的那个在前"""
    t = src.decode('latin1')
    g = (5 if 'local_size_x' in t else 3 if re.search(r'layout\s*\(\s*vertices', t) else 4 if 'gl_TessCoord' in t
         else 2 if 'EmitVertex' in t or 'EndPrimitive' in t else 0 if re.search(r'\bgl_Position\b(\s*\.\s*\w+)?\s*=[^=]', t) else 1)
    return [g] + [s for s in (0, 1, 2) if s != g]

def romfs_nros(root):
    """产物根 romfs 下的 NRO 模块（按文件头 +0x10 的 NRO0 认，不看扩展名；映像不压缩、文件即映像）→ [(romfs 相对路径, 映像)]，按路径排序"""
    # 文件头从 RomFS 清单取（romfs_list.heads：同一份 RomFS 只读一次头，火纹 27 万文件原先逐个打开要 82 秒），只打开头对上的文件读全文
    rf, out = os.path.join(root, 'romfs'), []
    for e in romfs_list.heads(rf).files():
        if e.error is not None or e.head[0x10:0x14] != b'NRO0': continue
        try:
            with open(e.path, 'rb') as h: out.append(('/' + e.rel.replace('/', os.sep), h.read()))
        except OSError: pass
    return sorted(out)

def all_sources(img, nros):
    """main 与 NRO 模块里的 GLSL 源码，跨模块去重（同一源码只留第一次出现）"""
    seen = set(); out = sources(img, seen=seen)
    for lab, d in nros: out += sources(d, lab=lab, seen=seen)
    return out

def need(exefs, img, nros=()):
    """要不要离线编 → (定义 glslcCompile 的模块 | None, 原因)；nros = romfs_nros()（源码可以在 main 或 RomFS 的 NRO 里）"""
    if b'#version ' not in img and not any(b'#version ' in d for _, d in nros): return None, 'main 与 RomFS 的 NRO 模块里都没有 GLSL 源码'
    if 'glslcCompile' not in {s for s, defined, _ in nso_syms.dynsyms(img) if not defined}: return None, 'main 不导入 glslcCompile'
    for m in sorted(os.listdir(exefs)):
        p = os.path.join(exefs, m)
        if m in ('main', 'rtld') or m.endswith('.npdm') or not os.path.isfile(p): continue
        try: syms = nso_syms.dynsyms(nso_syms.load(p))
        except Exception as e:   # 不是 NSO 的旁路文件本来就解析不了，照旧跳过；带 NSO 魔数却解析失败 = 判不了它定不定义 glslcCompile，
            #   走红通道（审计 P2-209：原先一律跳过，扫完没找到就答「不需要」退 0，该编的款没编）
            with open(p, 'rb') as fh:
                if fh.read(4) == b'NSO0': red(f'GLSLC 离线编：ExeFS 的 {m} 是 NSO 却解析不了（{type(e).__name__}: {e}），判不了它是否定义 glslcCompile')
            continue
        if any(s == 'glslcCompile' and defined for s, defined, _ in syms): return m, ''
    return None, 'main 导入 glslcCompile，但 ExeFS 里没有模块定义它（导入不会被绑定）'

def job_write(path, items):
    with open(path, 'wb') as f:
        f.write(struct.pack('<4sI', b'DMGJ', len(items)))
        for _, src in items:
            st = stages(src); f.write(struct.pack(f'<I{len(st)}I', len(st), *st)); f.write(struct.pack('<I', len(src))); f.write(src)

def job_read(path, n):
    """glslc_tool.c 的输出 → [(阶段 | None, GLSLC 输出)]"""
    d = open(path, 'rb').read()
    if d[:4] != b'DMGR' or struct.unpack_from('<I', d, 4)[0] != n: raise ValueError(f'{path}：不是 {n} 条的 GLSLC 工具输出')
    o, out = 8, []
    for _ in range(n):
        st, ln = struct.unpack_from('<II', d, o); o += 8
        out.append((None if st == 0xffffffff else st, d[o:o + ln])); o += ln
    if o != len(d): raise ValueError(f'{path}：末尾多 {len(d) - o} 字节')
    return out

TIMEOUT = int(os.environ.get('S2A_GLSLC_HOST_S') or 1200)   # 一路宿主的墙钟上限（秒）：编一支是毫秒级，卡住的宿主不让出包无限等

def run_host(host, mods, job, n):
    # 工具模式照常起 C# 服务层（SDK 初始化要连系统服务）：游戏数据指产物根，文档 / Ryujinx 数据 / 着色器缓存落本作业的私有目录（同 runtime/run_mac.sh，不碰整机共用的 ~/Documents）
    priv = job + '.d'; os.makedirs(priv, exist_ok=True)
    env = dict(os.environ, DM_GLSLC_JOB=job, S2A_AUTOPLAY='0', S2A_DOCS=priv, S2A_RYU_DATA=os.path.join(priv, 'ryu'), NXGAL_SHADER_CACHE_DIR=os.path.join(priv, 'gal'))
    env.setdefault('S2A_GAME_DATA', mods)
    try: r = subprocess.run([host, mods], env=env, capture_output=True, text=True, errors='replace', timeout=TIMEOUT)
    except subprocess.TimeoutExpired as e: r = subprocess.CompletedProcess(e.cmd, 124, e.stdout or '', e.stderr or '')
    shutil.rmtree(priv, ignore_errors=True)
    out = r.stdout if isinstance(r.stdout, str) else (r.stdout or b'').decode(errors='replace')
    err = r.stderr if isinstance(r.stderr, str) else (r.stderr or b'').decode(errors='replace')
    log = (out + err).strip().splitlines()
    if r.returncode or not os.path.isfile(job + '.out'):
        open(job + '.host.log', 'w').write('\n'.join(log) + '\n')   # 失败的那路宿主日志留在输出目录里查
        why = '超时' if r.returncode == 124 else f'退出 {r.returncode}'
        return None, f'宿主{why}（日志 {job}.host.log）：' + (' / '.join(l for l in log if '【红】' in l or 'FATAL' in l)[-400:] or (log[-1] if log else '没有输出'))
    return job_read(job + '.out', n), [l for l in log if 'DM_GLSLC_JOB' in l]

def build(srcs, host, mods, out, J=None):
    """srcs 分 J 段、每段一个宿主进程（mods = 改写模块目录）编 → <out>/glslc_<i>.glslc（第 i 段编成的输出首尾相接）；→ (编成数, 编不过数, {阶段: 数}, J)。宿主失败 → red"""
    os.makedirs(out, exist_ok=True)
    J = max(1, min(J or int(os.environ.get('J') or os.cpu_count() or 1), len(srcs)))
    parts = [srcs[i::J] for i in range(J)]
    jobs = [os.path.join(out, f'job_{i}.dmgj') for i in range(J)]
    for p, items in zip(jobs, parts): job_write(p, items)
    with cf.ThreadPoolExecutor(J) as ex: res = list(ex.map(lambda a: run_host(host, mods, *a), [(p, len(items)) for p, items in zip(jobs, parts)]))
    bad = [m for r, m in res if r is None]
    if bad: red(f'GLSLC 工具模式失败（{len(bad)}/{J} 路）：{bad[0]}')
    for r, log in res:
        for l in log: print(l, flush=True)
    ok = fail = 0; by = {}
    for i, ((r, _), items) in enumerate(zip(res, parts)):
        with open(os.path.join(out, f'glslc_{i}.glslc'), 'wb') as f:
            for st, o in r:
                if st is None: fail += 1; continue
                f.write(o); ok += 1; by[st] = by.get(st, 0) + 1
        os.remove(jobs[i]); os.remove(jobs[i] + '.out')
    return ok, fail, by, J

def main():
    if sys.argv[1:2] == ['--need'] and len(sys.argv) == 3:   # 出包阶段问要不要先编宿主（pack/stage_extract.sh）：打 yes / no
        print('yes' if need(os.path.join(sys.argv[2], 'exefs'), nso_syms.load(os.path.join(sys.argv[2], 'exefs', 'main')), romfs_nros(sys.argv[2]))[0] else 'no'); return
    if len(sys.argv) != 3: sys.exit('用法：glslc_offline.py <产物根（已改写）> <输出目录> | glslc_offline.py --need <产物根>')
    root, out = sys.argv[1:3]
    img = nso_syms.load(os.path.join(root, 'exefs', 'main'))
    nros = romfs_nros(root)
    mod, why = need(os.path.join(root, 'exefs'), img, nros)
    if not mod: print(f'GLSLC 离线编：不需要（{why}）'); return
    srcs = all_sources(img, nros)
    if not srcs:   # 源码不在模块里（GRID Autosport：着色器是 DXBC，游戏运行时自己翻成 GLSL 再编）：出包期编不了，交设备上的现编兜底，不判直连库失败
        print(f'【黄】GLSLC 离线编：main 导入 glslcCompile、{mod} 带编译器，但 main 与 RomFS 的 NRO 里认不出整段 GLSL 源码（只有版本头片段或没有）：这些着色器由设备运行时现编', flush=True)
        print('GLSLC 离线编：不需要（源码不在模块里，运行时现编）', flush=True); return
    host = os.environ.get('DM_GLSLC_HOST') or os.path.normpath(os.path.join(HERE, '..', 'build', 's2arm-host'))
    if not os.path.isfile(host): red(f'没有 Mac 宿主 {host}（S2A_CS=1 make host 编出，或设 DM_GLSLC_HOST）')
    if not os.path.isfile(os.path.join(root, 'main.fixups.tsv')): red(f'{root} 里没有改写后的模块（main.fixups.tsv）：先跑改写阶段')
    ok, fail, by, J = build(srcs, host, root, out)
    if not ok: red(f'{len(srcs)} 支源码一支都没编成（glslc_tool.c 打的编译日志见上）')
    nm = {0: '顶点', 1: '片元', 2: '几何', 3: '曲面控制', 4: '曲面求值', 5: '计算'}
    plain = sum(1 for lab, _ in srcs if '#DXA@' not in lab); in_nro = sum(1 for lab, _ in srcs if not lab.startswith('main'))
    print(f'GLSLC 离线编：{mod} 的 glslcCompile 编成 {ok} 支（' + '、'.join(f'{nm[k]} {v}' for k, v in sorted(by.items())) + f'），编不过 {fail} 支；'
          f'源码 {len(srcs)} 支（明文 {plain}、DxLib 压缩包 {len(srcs) - plain}；在 NRO 里 {in_nro}），{J} 路 → {out}', flush=True)

if __name__ == '__main__': main()
