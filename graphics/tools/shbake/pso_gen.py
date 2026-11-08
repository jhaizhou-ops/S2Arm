#!/usr/bin/env python3
# 管线预建脚本（着色器全量预编第 2 步 2c）：出包程序表 + 离线索引 → metal-tt / applegpu-nt 能编的 Metal 4 管线脚本（.mtl4-json）。
# 用法：pso_gen.py <programs.tsv> <gal.idx> <gal.shards 路径（各片 metallib 与它同目录，脚本里按片引用）> <输出前缀> [平均片长 P，缺省 300] [metal_failed.txt] [MSL 目录（量线程组内存）] [spec_pipes.tsv] [fbr.tsv]
#   索引键：函数名逗号相连（与运行时 gal_core.m pso_arch_for_key 同口径）
#   管线首用表（环境变量 S2A_PSO_USE，10-22）：表里的管线按首用先后排进最前面几片，见分片处注释
#   读帧缓冲变体（第 9 个参数，烘焙的 fbr.tsv，10-22）：V 行的（顶点, 变体片元）照程序表顶点 + 片元的规则出基础管线
#   特化管线表（第 8 个参数，specpipe.py 收的 spec_pipes.tsv；10-22 iPhone 上特化与程序不无关）：每行一条运行时真特化 / 现建过的管线（v2 完整 / b2 基础），按完整描述（颜色格式 / 写掩码 / 混合、
#   拓扑类、采样数、a2c / a2one，全写 Metal 枚举数值——applegpu-nt 认，Mac 实测按运行时描述命中）出完整管线；与同程序对的基础管线键串相同、分片时同组不拆开
#   分片边界按内容定（10-21 测试出包线：原先按程序表顺序每 300 个切，怪猎补全着色器后程序增删 2551 个，后面每片组成全变、210 片缓存 0 命中）：
#     管线按「所引用函数名串」排序（计算 s<键>，图形 s<顶点键>,s<片元键>；和 gal_offline 分 metallib 片的键序一致），管线 e 是候选边界 ⇔ sha256(函数名串) 前 8 字节（小端）mod CDC_N == 0；
#     候选只有离上一个候选（开头算 -1）≥ CDC_MIN 个才真切（只看相邻两个候选，不看片从哪起——不连锁）；切出来超过 CDC_MAX 的片均分成 ceil(长 / CDC_MAX) 份。
#     增删一个管线最多动它所在的自然片与下一片的边界：新出现的片键 ≤ 2 个（落在超长片里时为该片均分出的几份），其余片的组成与键不变（tests/t_pso_cdc.py 手算反证）。
#     参数随 P 定：CDC_N = P×17/30、CDC_MIN = P/3、CDC_MAX = 2P（P = 300 → 170 / 100 / 600：随机键模拟平均片长约 300、超长片约 6%，与原先每片 300 个、约 1 GB 内存同量级）
#   每片另写 <前缀>.<序号>.key = sha256(分片脚本去掉函数库路径 + 所引用函数在各片 metallib 函数表里的 HASH 标签)，shader_pack.sh 拿它做管线分片的内容寻址缓存（pso_chunk.sh）。
#   为什么是库内 HASH（10-21 本机 applegpu_g17s / macOS 26 实测，探针同运行时 MTL4Archive 按描述查）：归档命中只看描述 + 所引用函数的库内 HASH（= 该函数在库里位码的 sha256），
#   与库文件 / 库里别的函数无关——别的函数 .air 变、函数挪到另一片库、库增删别的函数，只要引用函数的 HASH 不变，旧归档 4/4 命中；
#   但 HASH ≠ .air 内容：metallib 链接时同名结构体类型按链接序合并 / 加后缀（spvDescriptorSetBuffer0 → .11），排在它前面的函数增删会改它的位码（.air 没变也 0/4）。
#   所以键取库内 HASH，不取 MSL / .air。函数表读不出（格式变了）= 不出键、不用缓存，照编（汇总里 key_err 报出）
#   （10-20 去掉「MSL > 1 MB 不预编」：动森那 3 支编译 10 分钟以上的根因是客体 switch 翻成 42 层尾嵌套 if，已在 Ryujinx 结构化层拉平（补丁 tail-chain-flatten），嵌套 46 → 11）
#   输出 <前缀>.<序号>.mtl4-json：分片——applegpu-nt 一次喂 1.1 万个管线常驻内存涨到 50 GB 以上、只用约 2 核（10-20 本机实测）；300 个一片 2.5 秒、1 GB
# 收哪些：图形程序（顶点 + 片元两阶段）里顶点着色器已自取（记录位 4）、不写层号（位 8；写层号的管线必须指定拓扑，基础管线做不到）的 → 一个基础管线：
#   片元输出（8 个颜色附件的格式 / 混合 / 写掩码）全部留空、拓扑未指定、其余缺省——与渲染器运行时 pso_desc(…, unspec=1) 逐字段相同，按描述命中归档后首遇只特化；
#   只有顶点阶段的图形程序 → 一个只带顶点函数的基础管线（同上留空）；计算程序 → 一个计算管线（只有函数）。其余（顶点没自取、只光栅化丢弃、写层号）首遇照旧现建并计数（frames.tsv pso_n）。
import bisect, hashlib, json, os, struct, sys
prog, idx, man, out = sys.argv[1:5]; per = int(sys.argv[5]) if len(sys.argv) > 5 else 300
# 编库失败的函数（gal_offline 的 metal_failed.txt，第 7 个参数）不进管线：缺一个函数 applegpu-nt 整片（300 个）失败（10-20 动森 4 支编不过拖掉 8 片）
bad = set()
if len(sys.argv) > 6:
    import os
    if os.path.exists(sys.argv[6]): bad = {l.split('\t')[0].split('.')[0].split('_np')[0] for l in open(sys.argv[6]) if l.strip() and not l.startswith('#')}
b = open(idx, 'rb').read()
assert b[:4] == b'GALI', '不是离线索引'
n = struct.unpack_from('<I', b, 16)[0]; flags = {}; iomask = {}; stage = {}
for i in range(n):
    k, off, ln = struct.unpack_from('<QII', b, 24 + 16 * i)
    # 记录：u64 键、u32 阶段、8 × u32 各集大小、u32 输入输出位、32 字节类型、3 × u32 线程组、i32 长度表、u32 标志 …（gal_prog.m rec_write）
    flags[f'{k:016x}'] = struct.unpack_from('<I', b, off + 8 + 4 + 32 + 4 + 32 + 12 + 4)[0]
    iomask[f'{k:016x}'] = struct.unpack_from('<I', b, off + 8 + 4 + 32)[0]   # 输入 / 输出位（顶点 = 读哪些顶点属性；0 = 不读属性，只靠顶点序号）
    stage[f'{k:016x}'] = struct.unpack_from('<I', b, off + 8)[0]
# 分片（gal_offline.py）：第 i 片含首键 ≥ first[i] 的连续键区间；函数 s<键> 引用它所在那片（库标签 gal<片号>）
shards = [l.split('\t') for l in open(man).read().split('\n') if l]
first = [int(k, 16) for k, _ in shards]; libs = [{'label': f'gal{i}', 'path': os.path.join(os.path.dirname(os.path.abspath(man)), f)} for i, (_, f) in enumerate(shards)]
fns, render, compute, skip = {}, [], [], {}
# 描述符直接指向库函数、不套特化：出包译文不带函数常量（gal_spvx.m 计数是翻译期开关）。10-21 合批曾给每个函数套「计数关」特化，
#   applegpu-nt 编渲染管线时带函数常量的片元一特化就报「cannot find private metadata」，三款归档整片失败（docs/坑记录.md）
# 颜色附件描述与运行时 gal_state.m pso_desc_colors 同一规则（11-01 审计 P2-42：整数目标照写混合开，归档按「开」编、运行时按「关」查，预编永远用不上）：
#   整数像素格式不开混合（运行时 gal_fmt_is_int）；RGB9E5Float 的部分写掩码按全写。下表 = gal_fmt_is_int 的 case 名单（MTLPixelFormat 数值），
#   graphics/tools/shbake/tests/t_pso_int_blend.py 核名单与 gal_state.m 一致、数值与 SDK 头一致
MTL_INT_FMTS = {13: 'R8Uint', 14: 'R8Sint', 23: 'R16Uint', 24: 'R16Sint', 33: 'RG8Uint', 34: 'RG8Sint', 53: 'R32Uint', 54: 'R32Sint', 63: 'RG16Uint',
                64: 'RG16Sint', 73: 'RGBA8Uint', 74: 'RGBA8Sint', 91: 'RGB10A2Uint', 103: 'RG32Uint', 104: 'RG32Sint', 113: 'RGBA16Uint', 114: 'RGBA16Sint',
                123: 'RGBA32Uint', 124: 'RGBA32Sint'}
MTL_RGB9E5 = 93
def color_att(pf, wm, be, op, s_, d_, aop, as_, ad, rast):
    m = wm if rast else 0
    if pf == MTL_RGB9E5 and m and m != 0xf: m = 0xf
    c = {'pixel_format': pf, 'write_mask': m}
    if be == 1 and pf not in MTL_INT_FMTS:
        c.update({'blending_state': 'Enabled', 'rgb_blend_operation': op, 'source_rgb_blend_factor': s_, 'destination_rgb_blend_factor': d_,
                  'alpha_blend_operation': aop, 'source_alpha_blend_factor': as_, 'destination_alpha_blend_factor': ad})
    return c
def fd(name):
    lab = hashlib.sha256(name.encode()).hexdigest().upper()
    fns[lab] = {'label': lab, 'name': name, 'library': f'gal{bisect.bisect_right(first, int(name[1:17], 16)) - 1}'}
    return 'fnd:' + lab
un = {k: 'Unspecialized' for k in ('pixel_format', 'write_mask', 'blending_state', 'alpha_blend_operation', 'rgb_blend_operation',
                                    'destination_alpha_blend_factor', 'destination_rgb_blend_factor', 'source_alpha_blend_factor', 'source_rgb_blend_factor')}
# 线程组内存超过 Apple GPU 上限（32 KB）的计算函数建不出管线，一支就让 applegpu-nt 整片（300 个）失败：不进归档，记 skip（运行时同样建不出，照旧计数）。
# 量法：MSL 里 threadgroup 数组（SPIRV-Cross 对 Ryujinx 共享内存全出 uint 数组）元素数 × 元素字节；10-20 怪猎烘焙按控制段读真实共享大小后 11 支 37120 字节
TG_MAX = 32768; tgsz = {'uint': 4, 'int': 4, 'float': 4, 'uint2': 8, 'int2': 8, 'float2': 8, 'uint4': 16, 'int4': 16, 'float4': 16, 'ushort': 2, 'short': 2, 'half': 2, 'uchar': 1, 'char': 1}
tgre = __import__('re').compile(r'^\s*threadgroup\s+(?:spvUnsafeArray<\s*(\w+)\s*,\s*(\d+)\s*>|(\w+)\s+\w+\s*\[\s*(\d+)\s*\])', __import__('re').M)
def tg_bytes(k):
    if len(sys.argv) <= 7: return 0
    mp = os.path.join(sys.argv[7], k + '.metal')
    if not os.path.exists(mp): return 0
    return sum(tgsz.get(m.group(1) or m.group(3), 16) * int(m.group(2) or m.group(4)) for m in tgre.finditer(open(mp, errors='replace').read()))
seen = set()
# 顶点 + 片元两段的图形程序出基础管线的跳过规则（程序表与读帧缓冲变体共用）：返回跳过原因，None = 出
def pair_skip(vs, fs, vtg_pt):
    fl = flags.get(vs)
    if fl is None or flags.get(fs) is None: return '离线索引缺键'
    # 只有「读顶点属性却没自取」的才跳过：运行时那种才挂顶点描述符（gal_state.m pso_desc：vs_inputs && !vs_pulled），描述与这里的基础管线不同。
    #   不读属性的（全屏后处理一类，只靠顶点序号，gal_prog.m 不打自取位 4）运行时同样不挂顶点描述符，与这里逐字段相同——10-21 前一并跳过，怪猎 722 条首遇现建
    if not fl & 4 and iomask.get(vs, 0) and not vtg_pt: return '顶点未自取'
    if fl & (2 | 8): return '写层号'   # 位 8 写层号、位 2 写层号且写点大小：管线必须指定拓扑
    if vs in bad or fs in bad: return '编库失败'
    return None
for line in open(prog).read().split('\n')[1:]:
    f = line.split('\t')
    if len(f) < 7 or f[2] not in ('ok', 'func_only') or not f[6]: continue   # func_only：转计算程序只出函数（ShaderBake.cs 规则三），管线照样预建
    ks = f[6].split(',')
    # 转计算程序（programs.tsv 种类 vtg1 / vtg2，ShaderBake.cs VtgOut）：前 1 / 2 支是顶点 / 几何计算核，各一个计算管线；其后是直通顶点 + 片元，照图形程序出基础管线
    # （直通顶点不读顶点属性，没有顶点描述符可言，不要求自取位）
    if f[3] in ('vtg1', 'vtg2'):
        nc = int(f[3][3]); vtg_pt = True
        for k in ks[:nc]:
            if k in seen: continue
            if k in bad: skip['编库失败'] = skip.get('编库失败', 0) + 1; continue
            if tg_bytes(k) > TG_MAX: skip['线程组内存超 32 KB'] = skip.get('线程组内存超 32 KB', 0) + 1; continue
            seen.add(k); compute.append({'compute_function_descriptor': fd('s' + k)})
        ks = ks[nc:]
    else: vtg_pt = False
    if f[3] == 'compute' and len(ks) == 1:
        if ks[0] in seen: continue
        if ks[0] in bad: skip['编库失败'] = skip.get('编库失败', 0) + 1; continue
        if tg_bytes(ks[0]) > TG_MAX: skip['线程组内存超 32 KB'] = skip.get('线程组内存超 32 KB', 0) + 1; continue
        seen.add(ks[0]); compute.append({'compute_function_descriptor': fd('s' + ks[0])}); continue
    if len(ks) == 4 and all(k in flags for k in ks) and flags[ks[0]] & 16:   # 曲面程序（graphics/metal/gal_tess.m）：曲面前顶点 / TCS 两个计算管线 + TES（顶点函数，无顶点描述符）× 片元的基础管线
        if any(k in bad for k in ks): skip['编库失败'] = skip.get('编库失败', 0) + 1; continue
        for k in ks[:2]:
            if k not in seen: seen.add(k); compute.append({'compute_function_descriptor': fd('s' + k)})
        if flags[ks[2]] & (2 | 8): skip['写层号'] = skip.get('写层号', 0) + 1; continue
        if (ks[2], ks[3]) not in seen: seen.add((ks[2], ks[3])); render.append({'vertex_function_descriptor': fd('s' + ks[2]), 'fragment_function_descriptor': fd('s' + ks[3]), 'color_attachments': [dict(un) for _ in range(8)]})
        continue
    # 只有顶点阶段的图形程序（深度预渲染 / 阴影一类，无片元、光栅化开；10-21 怪猎 2499 个）→ 一个只带顶点函数的基础管线（颜色留空、拓扑未指定），
    #   与运行时 pso_desc(…, unspec=1) 在片元为空时逐字段相同（gal_state.m pso_build 无片元也走基础管线 + 特化）；顶点未自取 / 写层号同下照旧跳过
    if f[3] == 'graphics' and len(ks) == 1:
        vs = ks[0]; fl = flags.get(vs)
        if fl is None: skip['离线索引缺键'] = skip.get('离线索引缺键', 0) + 1; continue
        if not fl & 4 and iomask.get(vs, 0): skip['顶点未自取'] = skip.get('顶点未自取', 0) + 1; continue
        if fl & (2 | 8): skip['写层号'] = skip.get('写层号', 0) + 1; continue
        if vs in bad: skip['编库失败'] = skip.get('编库失败', 0) + 1; continue
        if (vs,) in seen: continue
        seen.add((vs,)); render.append({'vertex_function_descriptor': fd('s' + vs), 'color_attachments': [dict(un) for _ in range(8)]}); continue
    if len(ks) != 2: skip['阶段数不是 2'] = skip.get('阶段数不是 2', 0) + 1; continue
    vs, fs = ks
    r = pair_skip(vs, fs, vtg_pt)
    if r: skip[r] = skip.get(r, 0) + 1; continue
    if (vs, fs) in seen: continue
    seen.add((vs, fs))
    render.append({'vertex_function_descriptor': fd('s' + vs), 'fragment_function_descriptor': fd('s' + fs), 'color_attachments': [dict(un) for _ in range(8)]})
# 读帧缓冲变体（第 9 个参数，烘焙出的 fbr.tsv 的 V 行，gal_xc --fbr）：变体程序 = 原程序顶点 + 变体片元（[[color(n)]] 读颜色附件），运行时按变体表建成后同普通图形程序
#   走「基础管线 + 特化」——照程序表顶点 + 片元的规则出基础管线（跳过原因前缀「读帧缓冲变体：」）
nfv = 0
if len(sys.argv) > 9 and sys.argv[9] and os.path.exists(sys.argv[9]):
    for line in open(sys.argv[9], encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if len(f) < 6 or f[0] != 'V': continue
        vs, fs = f[1], f[4]
        r = pair_skip(vs, fs, False)
        if r: skip['读帧缓冲变体：' + r] = skip.get('读帧缓冲变体：' + r, 0) + 1; continue
        if (vs, fs) in seen: continue
        seen.add((vs, fs)); nfv += 1
        render.append({'vertex_function_descriptor': fd('s' + vs), 'fragment_function_descriptor': fd('s' + fs), 'color_attachments': [dict(un) for _ in range(8)]})
# metallib 函数表（头 'MTLB'，0x18 / 0x20 = 函数表偏移 / 长度；表 = u32 个数 + 每项 u32 长度 + 标签串 <4 字节标签><u16 长度><值>… 'ENDT'）：库标签 → {函数名: HASH 标签 32 字节}
def fn_hashes(p):
    with open(p, 'rb') as f:
        hd = f.read(0x58); assert hd[:4] == b'MTLB', f'{p} 不是 metallib'
        # 0x20 的长度不含表头的 u32 个数
        fl_off, fl_sz = struct.unpack_from('<QQ', hd, 0x18); f.seek(fl_off); b = f.read(4 + fl_sz)
    r, o = {}, 4
    for _ in range(struct.unpack_from('<I', b, 0)[0]):
        q, e = o + 4, {}
        while b[q:q + 4] != b'ENDT':
            ln = struct.unpack_from('<H', b, q + 4)[0]; e[b[q:q + 4]] = b[q + 6:q + 6 + ln]; q += 6 + ln
        assert len(e.get(b'HASH', b'')) == 32 and e.get(b'NAME', b'').endswith(b'\0'), f'{p} 函数表项缺 NAME / HASH'
        r[e[b'NAME'][:-1].decode()] = e[b'HASH']; o += struct.unpack_from('<I', b, o)[0]
    return r
# 特化管线表：v2 = 颜色定了的完整管线（特化结果 / 直接现建的），b2 = 颜色留空的基础管线（运行时才出现的配对、_wl / _np 入口、写层号定了拓扑的）；
#   都按行里的完整描述出（运行时就是按这个描述查归档的，不再套程序表的跳过规则）。函数名带后缀的（s<键>_wl / _np）按键找所在库片；
#   程序不在本包离线索引 / 编库失败的跳过，计 skip
TOPO = {0: None, 1: 'Point', 2: 'Line', 3: 'Triangle'}; nsp = [0, 0]; nbase = len(render); spec_cut = 0
if len(sys.argv) > 8 and sys.argv[8] and os.path.exists(sys.argv[8]):
    sseen = set(); slines = open(sys.argv[8], encoding='utf-8').readlines()
    # 只出特化表时按常见度截（10-25 jhz「超过几分钟就按常见度截」）：收回的种子（真机局实收，行尾没有「# 来源=」）最前，社区换算行按来源数多的在前，其余保持原序；
    #   取前 S2A_PSO_SPEC_MAX 行（缺省 4000：动森 1894 行 8 路编 67 秒、141 MB，按比例 4000 行约 140 秒、约 300 MB）
    if os.environ.get('S2A_PSO_SPEC_ONLY') == '1':
        def prio(l): c = l.split('#', 1)[1] if '#' in l else ''; return 0 if '来源=' not in c else -len(c.split('来源=', 1)[1].split()[0].split(','))
        slines = [l for l in slines if l.split('#')[0].split()[:1] in (['v2'], ['b2'])]; slines.sort(key=lambda l: (prio(l) != 0, prio(l)))
        spec_cut = max(0, len(slines) - int(os.environ.get('S2A_PSO_SPEC_MAX') or 4000)); slines = slines[:len(slines) - spec_cut]
    for line in slines:
        # 行尾「# …」是注释（refpso.py 换算行标的来源 / 推断字段）
        f = line.split('#')[0].split()
        if len(f) < 8 or f[0] not in ('v2', 'b2'): continue
        vs, fs = f[1], (f[2] if f[2] != '-' else None)
        # 光栅化丢弃（第 8 字段 0，10-24）：运行时改为「照开光栅化、不带片元、颜色写掩码 0、剪裁置空」（gal_state.m pso_desc；
        #   Metal 关光栅化要求顶点函数返回 void，翻译出的都返回结构体），这里按同一描述出，旧收集行照样换算
        if len(f) >= 8 and f[7] == '0': fs = None
        vk, fk = vs[1:17], (fs[1:17] if fs else None)
        if vk not in flags or (fs and fk not in flags): skip['特化管线：离线索引缺键'] = skip.get('特化管线：离线索引缺键', 0) + 1; continue
        # 宽线入口 s<键>_wl 只在顶点着色器记录位 14 置位时有（gal_wline.m 不规整的不出）：没有就跳过，不让归档去找不存在的函数
        if vs.endswith('_wl') and not flags[vk] & (1 << 14): skip['特化管线：没有宽线入口'] = skip.get('特化管线：没有宽线入口', 0) + 1; continue
        if vk in bad or (fs and fk in bad): skip['特化管线：编库失败'] = skip.get('特化管线：编库失败', 0) + 1; continue
        key = tuple(f)
        if key in sseen: continue
        sseen.add(key)
        d = {'vertex_function_descriptor': fd(vs)}
        if fs: d['fragment_function_descriptor'] = fd(fs)
        topo, ns, a2c, a2o, rast = int(f[3]), int(f[4]), int(f[5]), int(f[6]), int(f[7])
        if TOPO.get(topo): d['input_primitive_topology'] = TOPO[topo]
        if ns > 1: d['raster_sample_count'] = ns
        if a2c == 1: d['alpha_to_coverage_state'] = 'Enabled'
        if a2o == 1: d['alpha_to_one_state'] = 'Enabled'
        if f[0] == 'b2': d['color_attachments'] = [dict(un) for _ in range(8)]; nsp[1] += 1
        else:
            ca = [{} for _ in range(8)]
            for att in f[8:]:
                i, pf, wm, be, op, s_, d_, aop, as_, ad = (int(x) for x in att.split(':'))
                ca[i] = color_att(pf, wm, be, op, s_, d_, aop, as_, ad, rast)
            d['color_attachments'] = ca; nsp[0] += 1
        render.append(d)
# 只出特化表（S2A_PSO_SPEC_ONLY=1，10-25 jhz：直连款的通用兜底只用社区状态 + 收回的种子编归档，不出每个程序一条的基础管线）：丢掉上面的基础 / 桩 / 读帧缓冲变体管线与计算管线
spec_only = os.environ.get('S2A_PSO_SPEC_ONLY') == '1'
if spec_only: render, compute = render[nbase:], []
key_err = None
try: lib_hash = {l['label']: fn_hashes(l['path']) for l in libs}
except Exception as ex: lib_hash, key_err = None, f'metallib 函数表解析失败（不出分片键、照编）：{ex}'
# 内容定义分块（见文件头）：返回 [(起, 止)]，只依赖排好序的管线名序列
# 冷片（首用表以外的管线）平均片长单独定：S2A_PSO_COLD_P，缺省 8（10-24 异度神剑3 测试机2 低区 OOM：iPhone 上归档片一开就整片映射、由它建的管线活着就不还，
#   冷片平均 32 条、一局只用到约 1.5 条 → 81 片冷片整片 83 MB；切到约 8 条一片估 ≈ 31 MB）。热片（首用表管线）仍按 per 切，同局先后用到的挨着放
cold_per = max(3, int(os.environ.get('S2A_PSO_COLD_P', '8') or 8))
def cdc_params(p): return p * 17 // 30, max(1, p // 3), p * 2
CDC_N, CDC_MIN, CDC_MAX = cdc_params(per)
assert CDC_N >= 1 and CDC_MIN >= 1, f'平均片长 {per} 太小'
def cdc_bounds(names, p=None):
    CDC_N, CDC_MIN, CDC_MAX = cdc_params(p or per)
    cuts, prev = [], -1
    for i, nm in enumerate(names):
        if int.from_bytes(hashlib.sha256(nm.encode()).digest()[:8], 'little') % CDC_N: continue
        if i - prev >= CDC_MIN: cuts.append(i)
        prev = i
    nat, s = [], 0
    for c in cuts: nat.append((s, c + 1)); s = c + 1
    if s < len(names): nat.append((s, len(names)))
    out = []
    for s, e in nat:
        k = -(-(e - s) // CDC_MAX)
        out += [(s + (e - s) * j // k, s + (e - s) * (j + 1) // k) for j in range(k)]
    return out
def pname(d): return ','.join(fns[d[k][4:]]['name'] for k in ('vertex_function_descriptor', 'fragment_function_descriptor', 'compute_function_descriptor') if k in d)
allp = sorted([('r', d) for d in render] + [('c', d) for d in compute], key=lambda x: pname(x[1])); nchunk = 0; nokey = 0
# 「管线描述 → 归档片号」索引（运行时 gal_core.m pso_arch_for 按需只开那一片）：键 = FNV-1a 64(pname)，与运行时按描述里的函数名拼的同一串
def fnv64(t):
    x = 0xcbf29ce484222325
    for c in t.encode(): x = ((x ^ c) * 0x100000001b3) & 0xffffffffffffffff
    return x
pidx = {}
# 同键串的连续一组（基础管线与它的各个特化完整版）当一个单位分片：运行时按键串只开一片
_pn = [pname(d) for _, d in allp]; _gs = [i for i in range(len(_pn)) if i == 0 or _pn[i] != _pn[i - 1]] + [len(_pn)]
grp = [(_gs[g], _gs[g + 1]) for g in range(len(_gs) - 1)]
# 管线首用表（环境变量 S2A_PSO_USE，psouse.py 收各正式局「管线首用」行，每行 <首用帧> <b|f> <函数名串> <管线键编码>，按首用帧升序；10-22 马车8 换场景那帧 145 条散在 79 片里）：
#   表里出现的键串按第一次出现的先后排在最前面、每满 P 个切一片（同局先后用到的挨着放：换场景少开片，运行时后台预取只开这几片、低区只映射用得到的）；
#   其余照内容定义分块（没有表时与原先逐片相同）。表变只动前面这几片和被抽走管线的那几片的键
hot = {}
if os.environ.get('S2A_PSO_USE'):
    for l in open(os.environ['S2A_PSO_USE'], encoding='utf-8'):
        c = l.rstrip('\n').split('\t')
        if not l.startswith('#') and len(c) >= 4: hot.setdefault(c[2], len(hot))
hg = sorted((g for g in grp if _pn[g[0]] in hot), key=lambda g: hot[_pn[g[0]]]); cg = [g for g in grp if _pn[g[0]] not in hot]
parts, cur = [], []
for g in hg:
    cur.append(g)
    if sum(e - s for s, e in cur) >= per: parts.append(cur); cur = []
if cur: parts.append(cur)
nhot = (len(parts), sum(e - s for s, e in hg))
parts += [cg[c0:c1] for c0, c1 in cdc_bounds([_pn[s] for s, _ in cg], cold_per)]
# ---------- Metal 3（.mtlp-json）分支（#116 / M3-9；PSO_M3=1 时改出老格式脚本，缺省关）----------
# 老格式脚本给 metal-tt 吃（不是 applegpu-nt -N）：metal-tt -arch <架构> -<平台>-version-min <最低版本> <脚本> -o <归档>
# 函数以 alias:<库>#<名字> 保留多库归属；颜色附件留空的「基础管线」写 pixel_format: Invalid。
# 10-23 实测（Mac mini M4 / applegpu_g16g / macOS 27.0.1）：Invalid 归档按 Invalid 描述命中、换 BGRA8 未命中；
# BGRA8 归档按 BGRA8 命中、换 Invalid / RGBA8 都未命中。归档的最低系统版本必须与运行时系统一致（27.0 命中，26.0 / 15.0 未命中）。
M3 = os.environ.get('PSO_M3') == '1'
_m3_cache = {}
def m3_enum(prefix):
    """Metal 枚举 数值→名称（去掉前缀），从 SDK 头文件解析；解析不到返回空表（调用方按缺省名兜底）。"""
    if prefix in _m3_cache: return _m3_cache[prefix]
    import glob as _g, re as _re, subprocess
    sdk = os.environ.get('PSO_M3_SDK') or subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                                         capture_output=True, text=True).stdout.strip()
    out = {}
    if sdk:
        for p in _g.glob(os.path.join(sdk, 'System/Library/Frameworks/Metal.framework/Headers/*.h')):
            try: txt = open(p, errors='ignore').read()
            except OSError: continue
            for m in _re.finditer(r'\b' + prefix + r'([A-Za-z0-9_]+)[^=;\n]*?=\s*(\d+)', txt):
                out.setdefault(int(m.group(2)), m.group(1))
    _m3_cache[prefix] = out
    return out
def m3_pipeline(d, is_render):
    """Metal 4 描述 → Metal 3 脚本描述（函数按名字；颜色附件枚举数值换成名字；留空写 Invalid）。"""
    o = {}
    for src, dst in (('vertex_function_descriptor', 'vertex_function'), ('fragment_function_descriptor', 'fragment_function'),
                     ('compute_function_descriptor', 'compute_function')):
        if src in d:
            fn = fns[d[src][4:]]
            o[dst] = f"alias:{fn['library']}#{fn['name']}"
    if not is_render: return o
    if 'color_attachments' in d:
        PF, BF, BO = m3_enum('MTLPixelFormat'), m3_enum('MTLBlendFactor'), m3_enum('MTLBlendOperation')
        ca = []
        for c in d['color_attachments']:
            e = {}
            pf = c.get('pixel_format', 0)   # 未使用的 v2 附件为 {}，同原生描述的缺省 Invalid
            # 查不到就抛：静默写 Invalid 会把一条完整管线写成基础管线的描述，运行时就永远对不上（铁律：不兜底）
            e['pixel_format'] = 'Invalid' if pf == 'Unspecialized' else PF[int(pf)]
            if c.get('write_mask') not in (None, 'Unspecialized'): e['write_mask'] = int(c['write_mask'])
            if c.get('blending_state') == 'Enabled':
                e['blending_enabled'] = True
                for k in ('rgb_blend_operation', 'alpha_blend_operation'):
                    if k in c: e[k] = BO[int(c[k])]
                for k in ('source_rgb_blend_factor', 'destination_rgb_blend_factor', 'source_alpha_blend_factor', 'destination_alpha_blend_factor'):
                    if k in c: e[k] = BF[int(c[k])]
            ca.append(e)
        o['color_attachments'] = ca
    if d.get('input_primitive_topology'): o['input_primitive_topology'] = d['input_primitive_topology']
    if d.get('raster_sample_count'): o['raster_sample_count'] = d['raster_sample_count']
    if d.get('color_sample_count'): o['color_sample_count'] = d['color_sample_count']
    if d.get('alpha_to_coverage_state') == 'Enabled': o['alpha_to_coverage_enabled'] = True
    if d.get('alpha_to_one_state') == 'Enabled': o['alpha_to_one_enabled'] = True
    if d.get('rasterization_enabled') is False: o['rasterization_enabled'] = False
    return o
for gl in parts:
    part = [x for s, e in gl for x in allp[s:e]]
    for _, d in part: pidx.setdefault(fnv64(pname(d)), nchunk)
    used = {v[4:] for _, d in part for k, v in d.items() if k.endswith('function_descriptor')}
    sj = {'version': {'major': 0, 'minor': 1, 'sub_minor': 0}, 'generator': 'MetalFramework', 'libraries': [l for l in libs if l['label'] in {fns[u]['library'] for u in used}],
          'function_descriptors': {'library_function_descriptors': [f for l, f in fns.items() if l in used]},
          'pipeline_descriptors': {'render_pipeline_descriptors': [d for t, d in part if t == 'r'], 'compute_pipeline_descriptors': [d for t, d in part if t == 'c']}}
    if M3:
        m3r, m3c = [], []
        for t, d in part:
            try: (m3r if t == 'r' else m3c).append(m3_pipeline(d, t == 'r'))
            except KeyError as ex:   # 枚举查不到：跳过这一条并报红，不写兜底描述
                skip['Metal 3 枚举查不到'] = skip.get('Metal 3 枚举查不到', 0) + 1
                sys.stderr.write(f'【红】Metal 3 枚举查不到，跳过该条管线：{ex}\n')
        m3 = {'generator': 'MetalFramework', 'version': [0, 1, 0],
              'libraries': {'paths': [{'label': l['label'], 'path': l['path']} for l in libs if l['label'] in {fns[u]['library'] for u in used}]},
              'pipelines': {'render_pipelines': m3r, 'compute_pipelines': m3c}}
        json.dump(m3, open(f'{out}.{nchunk}.mtlp-json', 'w'))
    else:
        json.dump(sj, open(f'{out}.{nchunk}.mtl4-json', 'w'))
    # 分片缓存键：脚本本身（不含随输出目录变的函数库路径）+ 引用函数名与其库内 HASH；有函数在所属片的函数表里找不到 = 本片不出键（照编）
    if lib_hash is not None:
        h = hashlib.sha256(json.dumps({'r': [d for t, d in part if t == 'r'], 'c': [d for t, d in part if t == 'c']}, sort_keys=True).encode())
        hs = [(fns[lab]['name'], lib_hash.get(fns[lab]['library'], {}).get(fns[lab]['name'])) for lab in sorted(used)]
        if all(x for _, x in hs):
            for nm, x in hs: h.update(nm.encode() + x)
            open(f'{out}.{nchunk}.key', 'w').write(h.hexdigest())
        else: nokey += 1
    nchunk += 1
with open(f'{out}.idx', 'wb') as fh:
    fh.write(struct.pack('<4I', 0x49535047, 1, len(pidx), 0))
    for k in sorted(pidx): fh.write(struct.pack('<QII', k, pidx[k], 0))
print(json.dumps({'spec_only': spec_only, 'spec_cut': spec_cut, 'render': len(render), 'compute': len(compute), 'fbr_vars': nfv, 'spec_pipes': nsp[0], 'spec_bases': nsp[1], 'hot_chunks': nhot[0], 'hot_pipes': nhot[1], 'cold_per': cold_per, 'chunks': nchunk, 'skip': skip, 'nokey': nokey, 'key_err': key_err}, ensure_ascii=False))
