#!/usr/bin/env python3
# 社区管线状态 → 特化管线 v2 行（画面·着色器线 10-22，总指挥批：社区着色器缓存里存着各程序的管线状态，换算成 v2 行出包预编，不等运行时收集）：
#   python3 graphics/tools/shbake/refpso.py <输入表> <gal.idx> <输出表>
# 输入表（ShBake --reflib 写，制表符分隔，# 开头为注释）：参考库里配上的每个「社区程序 × 我方候选程序」一行——
#   <顶点阶段 s<16 位十六进制>[_后缀]> <片元阶段 | -> <我方这份的透明测试：关 = -，开 = <GAL 比较方式>:<参考值浮点位十六进制>> <来源格式 u32 十六进制> <代码生成版本 u32 十六进制> <状态原样字节十六进制>
#   同一社区程序在包里烘了几份（只差透明测试）就有几行，这里按社区状态里的透明测试挑对应的那份（其余丢掉）。
# 来源格式：yuzu 系 = 0xFFFF0000 | 缓存版本（认版本 5：状态 = unique_hashes[6] 48 字节 + FixedPipelineState 984 字节；版本 10 同长、混合附件挪到偏移 72，见 from_yuzu10；
#   版本 16 开着动态混合（raw1 位 3），混合状态不进缓存，换不出整行，单独计数）；
#   其余按 Ryujinx ShaderSpecializationState（GFXS + 可选 PGPS 段，结构 size 不大于本树的按本树布局解、缺尾补 0；没有 PGPS 的出不了颜色附件、跳过）。
# 输出表：v2 行（格式同 specpipe.py 的 spec_pipes.tsv，pso_gen.py 第 8 个参数读到 # 截断），行尾「# 来源=…[ 推断=…]」：
#   来源 yuzu5 / ryu<格式>；推断 = 社区数据里没有、按缺省给的字段（Ryujinx 的 a2one 按 0）。同一行几个来源都给出时合并标出。
#   我方规则（不在社区数据里）：顶点记录标志位 0 = 写点大小 → 拓扑类不是点时记 0（未指定）；位 1 = 有无点大小变体 → 拓扑类不是点时顶点改 _np、拓扑类照原样（同 gal_state.m pso_desc）。
#   末尾注释行汇总：输入行数、按来源的出行数、不认识的来源格式 / 版本计数、透明测试两类丢弃（同一社区状态的其他变体 = 正常挑选；真对不上 = 社区要的比较方式我方没烘）、
#   无格式号的重复行（S2RL 格式版本 1 的参考库不带来源格式，同一状态在带格式号的参考库里也有：按重复跳过，不当 Ryujinx 格式 0 硬解）。
# 换算依据与逐字段对位反证：scratchpad 评估（10-22，动森 212 行：yuzu5 逐字段一致 195、不一致 0；两份合并 199），单测 tests/t_refpso.py 锁住
import hashlib, os, re, struct, subprocess, sys

R = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))

# ---------- 枚举 ----------
# Metal MTLBlendOperation / MTLBlendFactor 数值（MTLRenderPipeline.h，ABI 固定）
MBO = {'Add': 0, 'Subtract': 1, 'ReverseSubtract': 2, 'Min': 3, 'Max': 4}
MBF = {'Zero': 0, 'One': 1, 'SourceColor': 2, 'OneMinusSourceColor': 3, 'SourceAlpha': 4, 'OneMinusSourceAlpha': 5, 'DestinationColor': 6, 'OneMinusDestinationColor': 7,
       'DestinationAlpha': 8, 'OneMinusDestinationAlpha': 9, 'SourceAlphaSaturated': 10, 'BlendColor': 11, 'OneMinusBlendColor': 12, 'BlendAlpha': 13, 'OneMinusBlendAlpha': 14,
       'Source1Color': 15, 'OneMinusSource1Color': 16, 'Source1Alpha': 17, 'OneMinusSource1Alpha': 18}
# GAL BlendOp / BlendFactor（Ryujinx 枚举数值，含 Gl 别名）→ Metal 名，照 graphics/metal/gal_state.m bop / bfac
GBO = {1: 'Add', 0x8006: 'Add', 2: 'Subtract', 0x800a: 'Subtract', 3: 'ReverseSubtract', 0x800b: 'ReverseSubtract', 4: 'Min', 0x8007: 'Min', 5: 'Max', 0x8008: 'Max'}
GBF = {1: 'Zero', 0x4000: 'Zero', 2: 'One', 0x4001: 'One', 3: 'SourceColor', 0x4300: 'SourceColor', 4: 'OneMinusSourceColor', 0x4301: 'OneMinusSourceColor',
       5: 'SourceAlpha', 0x4302: 'SourceAlpha', 6: 'OneMinusSourceAlpha', 0x4303: 'OneMinusSourceAlpha', 7: 'DestinationAlpha', 0x4304: 'DestinationAlpha',
       8: 'OneMinusDestinationAlpha', 0x4305: 'OneMinusDestinationAlpha', 9: 'DestinationColor', 0x4306: 'DestinationColor', 10: 'OneMinusDestinationColor', 0x4307: 'OneMinusDestinationColor',
       11: 'SourceAlphaSaturated', 0x4308: 'SourceAlphaSaturated', 0x10: 'Source1Color', 0xc900: 'Source1Color', 0x11: 'OneMinusSource1Color', 0xc901: 'OneMinusSource1Color',
       0x12: 'Source1Alpha', 0xc902: 'Source1Alpha', 0x13: 'OneMinusSource1Alpha', 0xc903: 'OneMinusSource1Alpha', 0xc001: 'BlendColor', 0xc002: 'OneMinusBlendColor',
       0xc003: 'BlendAlpha', 0xc004: 'OneMinusBlendAlpha'}
# yuzu 打包的混合方程 / 因子序号（Maxwell 序）
YEQ = ['Add', 'Subtract', 'ReverseSubtract', 'Min', 'Max']
YFAC = ['Zero', 'One', 'SourceColor', 'OneMinusSourceColor', 'SourceAlpha', 'OneMinusSourceAlpha', 'DestinationAlpha', 'OneMinusDestinationAlpha',
        'DestinationColor', 'OneMinusDestinationColor', 'SourceAlphaSaturated', 'Source1Color', 'OneMinusSource1Color', 'Source1Alpha', 'OneMinusSource1Alpha',
        'BlendColor', 'OneMinusBlendColor', 'BlendAlpha', 'OneMinusBlendAlpha']
YMSAA = {0: 1, 1: 2, 2: 4, 3: 8, 4: 8, 5: 2, 6: 16, 8: 4, 9: 4, 10: 8, 11: 8}

def fmt_tables():
    """GAL Format 序号 → Metal 像素格式数值（照 graphics/metal/gal_tex.m k_fmt）；Maxwell 渲染目标格式 → GAL Format 序号（照 Ryujinx ColorFormat.cs）"""
    h = open(os.path.join(R, 'graphics/metal/gal_formats.h'), encoding='utf-8').read()
    body = h[h.index('enum {') + 6:h.index('F_COUNT')]
    names = [x.strip() for x in re.sub(r'//[^\n]*', '', body).replace('\n', ' ').split(',') if x.strip()]
    idx = {n: i for i, n in enumerate(names)}
    t = open(os.path.join(R, 'graphics/metal/gal_tex.m'), encoding='utf-8').read(); t = t[t.index('k_fmt[F_COUNT]'):]; t = t[:t.index('};')]
    # Xcode 按「指定 > 环境 > xcode-select」（10-25 总指挥：全仓不写死 Xcode 路径与版本，同 Makefile / tools/toolchain.sh）
    dev = os.environ.get('S2A_DEVELOPER_DIR') or os.environ.get('DEVELOPER_DIR') or subprocess.run(['xcode-select', '-p'], capture_output=True, text=True).stdout.strip()
    ph = open(os.path.join(dev, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers/MTLPixelFormat.h'), encoding='utf-8').read()
    pf = {m.group(1): int(m.group(2), 0) for m in re.finditer(r'\b(MTLPixelFormat[A-Za-z0-9_]+)\b[^=\n]*=\s*([0-9xa-fA-F]+)', ph)}
    fmt = {idx[m.group(1)]: pf[m.group(2)] for m in re.finditer(r'\[(F_[A-Za-z0-9_]+)\]\s*=\s*(MTLPixelFormat[A-Za-z0-9_]+)', t)}
    cf = open(os.path.join(R, 'compat/tree/src/Ryujinx.Graphics.Gpu/Engine/Types/ColorFormat.cs'), encoding='utf-8').read()
    cfv = {m.group(1): int(m.group(2), 16) for m in re.finditer(r'^\s*(\w+)\s*=\s*0x([0-9a-fA-F]+),', cf, re.M)}
    gidx = {n[2:]: i for i, n in enumerate(names)}
    cf2gal = {cfv[m.group(1)]: gidx[m.group(2)] for m in re.finditer(r'ColorFormat\.(\w+)\s*=>\s*new FormatInfo\(Format\.(\w+)', cf) if m.group(2) in gidx}
    return fmt, cf2gal

# ---------- Ryujinx 特化状态（C# 顺序布局，照 compat/tree：ShaderSpecializationState.cs、GpuChannelGraphicsState.cs、ProgramPipelineState.cs）----------
class T:
    def __init__(s, name, size, align, fields=None): s.name, s.size, s.align, s.fields = name, size, align, fields
def prim(n, sz): return T(n, sz, sz)
BOOL, BYTE, INT, UINT, FLOAT = prim('bool', 1), prim('byte', 1), prim('int', 4), prim('uint', 4), prim('float', 4)
def struct_(name, fields):
    off = 0; al = 1; lay = []
    for fn, ft in fields:
        off = (off + ft.align - 1) // ft.align * ft.align; lay.append((fn, ft, off)); off += ft.size; al = max(al, ft.align)
    return T(name, (off + al - 1) // al * al, al, lay)
def arr(t, n): return T(f'{t.name}[{n}]', t.size * n, t.align, ('arr', t, n))
COLORF = struct_('ColorF', [(c, FLOAT) for c in 'RGBA'])
BLEND = struct_('BlendDescriptor', [('Enable', BOOL), ('BlendConstant', COLORF)] + [(n, INT) for n in ('ColorOp', 'ColorSrcFactor', 'ColorDstFactor', 'AlphaOp', 'AlphaSrcFactor', 'AlphaDstFactor')])
VAD = struct_('VertexAttribDescriptor', [('BufferIndex', INT), ('Offset', INT), ('IsZero', BOOL), ('Format', INT)])
BPD = struct_('BufferPipelineDescriptor', [('Enable', BOOL), ('Stride', INT), ('Divisor', INT)])
DTD = struct_('DepthTestDescriptor', [('TestEnable', BOOL), ('WriteEnable', BOOL), ('Func', INT)])
STD = struct_('StencilTestDescriptor', [('TestEnable', BOOL)] + [(n, INT) for n in
      'FrontFunc FrontSFail FrontDpPass FrontDpFail FrontFuncRef FrontFuncMask FrontMask BackFunc BackSFail BackDpPass BackDpFail BackFuncRef BackFuncMask BackMask'.split()])
PGPS = struct_('ProgramPipelineState', [
    ('SamplesCount', INT), ('AttachmentEnable', arr(BOOL, 8)), ('AttachmentFormats', arr(INT, 8)), ('DepthStencilEnable', BOOL), ('DepthStencilFormat', INT),
    ('LogicOpEnable', BOOL), ('LogicOp', INT), ('BlendDescriptors', arr(BLEND, 8)), ('ColorWriteMask', arr(UINT, 8)),
    ('VertexAttribCount', INT), ('VertexAttribs', arr(VAD, 32)), ('VertexBufferCount', INT), ('VertexBuffers', arr(BPD, 32)),
    ('DepthTest', DTD), ('StencilTest', STD), ('FrontFace', INT), ('CullMode', INT), ('CullEnable', BOOL), ('BiasEnable', INT),
    ('LineWidth', FLOAT), ('DepthClampEnable', BOOL), ('RasterizerDiscard', BOOL), ('Topology', INT), ('PrimitiveRestartEnable', BOOL),
    ('PatchControlPoints', UINT), ('DepthMode', INT)])
GFXS = struct_('GpuChannelGraphicsState', [
    ('EarlyZForce', BOOL), ('Topology', INT), ('TessellationMode', UINT), ('AlphaToCoverageEnable', BOOL), ('AlphaToCoverageDitherEnable', BOOL),
    ('ViewportTransformDisable', BOOL), ('DepthMode', BOOL), ('ProgramPointSizeEnable', BOOL), ('PointSize', FLOAT), ('AlphaTestEnable', BOOL),
    ('AlphaTestCompare', INT), ('AlphaTestReference', FLOAT), ('AttributeTypes', arr(BYTE, 32)), ('HasConstantBufferDrawParameters', BOOL),
    ('HasUnalignedStorageBuffer', BOOL), ('FragmentOutputTypes', arr(BYTE, 8)), ('DualSourceBlendEnable', BOOL), ('YNegateEnabled', BOOL)])
def decode(t, b, off=0):
    if t.fields is None: return struct.unpack_from({'bool': '<B', 'byte': '<B', 'int': '<i', 'uint': '<I', 'float': '<f'}[t.name], b, off)[0]
    if isinstance(t.fields, tuple): _, et, n = t.fields; return [decode(et, b, off + i * et.size) for i in range(n)]
    return {fn: decode(ft, b, off + fo) for fn, ft, fo in t.fields}
def ryu_state(s):
    """→ (gfx, pgps)；不是图形 / 魔数不对 / 段比本树大 / 没有 PGPS → None"""
    q = 4; comp = s[q]; q += 1
    if comp or s[q:q + 4] != b'GFXS': return None
    sz = struct.unpack_from('<i', s, q + 4)[0]; q += 8
    if sz > GFXS.size: return None
    g = decode(GFXS, s[q:q + sz] + bytes(GFXS.size - sz)); q += sz
    cbm = s[q]; q += 1 + 4 * bin(cbm).count('1')
    if not s[q]: return None
    q += 1
    if s[q:q + 4] != b'PGPS': return None
    sz = struct.unpack_from('<i', s, q + 4)[0]; q += 8
    if sz > PGPS.size: return None
    return g, decode(PGPS, s[q:q + sz] + bytes(PGPS.size - sz))

# ---------- 公共 ----------
def mtl_mask(m): return (8 if m & 1 else 0) | (4 if m & 2 else 0) | (2 if m & 4 else 0) | (1 if m & 8 else 0)
def topo_class(t): return 1 if t == 0 else 2 if t in (1, 2, 3) else 3
def norm_at(c):   # GAL / Maxwell 比较方式 → 1..7（Never … GreaterOrEqual），Always / 关 → 'A'（透明测试不翻出代码）
    c = c - 0x200 + 1 if c >= 0x200 else c
    return 'A' if c == 8 else c
def head(vs, vflag, fs, tc, ns, a2c, a2one, disc):
    vn = vs; topo = 0 if (vflag & 1) and tc != 1 else tc
    if (vflag & 2) and tc != 1: vn += '_np'; topo = tc
    return ['v2', vn, '-' if disc or fs == '-' else fs, str(topo), str(ns), str(a2c), str(a2one), str(int(not disc))]

WLINE = 1 << 14   # 离线索引记录位 14：顶点着色器带宽线展开入口 s<键>_wl（graphics/metal/gal_internal.h GAL_REC_WLINE）
def wl_line(line, vflag, p):
    """宽线（graphics/metal/gal_wline.m）：线拓扑且线宽 > 1 时运行时换 s<键>_wl 入口建管线（自己取数、拓扑不进描述 = 0）。宽线是绘制状态、着色器里判不出（坑记录 10-24），
    只能按观测补：社区状态里线拓扑 + 线宽 > 1、顶点带 _wl 入口的，同出一行 _wl，与运行时收的 spec_pipes 行同口径"""
    if line is None or not (vflag & WLINE) or topo_class(p['Topology']) != 2 or not p['LineWidth'] > 1.0 or line[2] == '-': return None
    return ['v2', line[1] + '_wl', line[2], '0'] + line[4:]

def from_ryu(s, vs, vflag, fs, fmt, wl=None):
    r = ryu_state(s)
    if r is None: return None, None
    g, p = r
    at = norm_at(g['AlphaTestCompare']) if g['AlphaTestEnable'] else 'A'
    disc = bool(p['RasterizerDiscard'])
    h = head(vs, vflag, fs, topo_class(p['Topology']), p['SamplesCount'] or 1, int(bool(g['AlphaToCoverageEnable'])), 0, disc)
    sl = []
    for i in range(8):
        if not p['AttachmentEnable'][i]: continue
        f = fmt.get(p['AttachmentFormats'][i], 0)
        if not f: continue
        b = p['BlendDescriptors'][i]
        bl = (1, MBO[GBO.get(b['ColorOp'], 'Add')], MBF[GBF.get(b['ColorSrcFactor'], 'One')], MBF[GBF.get(b['ColorDstFactor'], 'One')],
              MBO[GBO.get(b['AlphaOp'], 'Add')], MBF[GBF.get(b['AlphaSrcFactor'], 'One')], MBF[GBF.get(b['AlphaDstFactor'], 'One')]) if b['Enable'] else (0, 0, 1, 0, 0, 1, 0)
        sl.append(':'.join(map(str, (i, f, mtl_mask(p['ColorWriteMask'][i])) + bl)))
    if wl is not None: wl.append(wl_line(h + sl, vflag, p))
    return h + sl, at

def from_yuzu5(s, vs, vflag, fs, fmt, cf2gal):
    if len(s) != 1032: return None, None
    k = s[48:]; raw1, raw2 = struct.unpack_from('<II', k, 0); cf = list(k[8:16]); att = struct.unpack_from('<8I', k, 24)
    atf = raw2 >> 1 & 7; at = 'A' if atf == 7 else atf + 1
    disc = not (raw2 & 1)
    h = head(vs, vflag, fs, topo_class(raw1 >> 24 & 15), YMSAA.get(raw1 >> 28, 0), raw2 >> 15 & 1, raw2 >> 16 & 1, disc)
    sl = []
    for i in range(8):
        if not cf[i]: continue
        f = fmt.get(cf2gal.get(cf[i], -1), 0)
        if not f: return None, None
        a = att[i]
        bl = (1, MBO[YEQ[a >> 4 & 7]], MBF[YFAC[a >> 10 & 31]], MBF[YFAC[a >> 15 & 31]], MBO[YEQ[a >> 7 & 7]], MBF[YFAC[a >> 20 & 31]], MBF[YFAC[a >> 25 & 31]]) \
            if a >> 30 & 1 else (0, 0, 1, 0, 0, 1, 0)
        sl.append(':'.join(map(str, (i, f, mtl_mask(a & 15)) + bl)))
    return h + sl, at

def from_yuzu10(s, vs, vflag, fs, fmt, cf2gal):
    """yuzu 系缓存版本 10（10-25 按数据定位，对照 eden fixed_pipeline_state.h）：FixedPipelineState 在 color_formats / alpha_test_ref / point_size 之后多了
    viewport_swizzles[16]（u16）、attribute_types（u64）、DynamicState（2 个 u32），混合附件从偏移 24 挪到 72（马车8 14908 行：有格式的槽合法率 0.898，版本 5 在 24 为 0.914）；
    raw1 / raw2 的拓扑、采样数、透明测试、a2c / a2one 位同版本 5。raw1 位 1（扩展动态状态 2）开着时光栅化开关是动态的、不进缓存 → 按不丢弃，标推断 disc；
    关着时取 DynamicState.raw1 位 5（rasterize_enable）。返回 (行, 透明测试, 推断字段)"""
    if len(s) != 1032: return None, None, None
    k = s[48:]; raw1, raw2 = struct.unpack_from('<II', k, 0); cf = list(k[8:16]); att = struct.unpack_from('<8I', k, 72)
    atf = raw2 >> 1 & 7; at = 'A' if atf == 7 else atf + 1
    if raw1 >> 1 & 1: disc, inf = False, 'disc'
    else: disc, inf = not (struct.unpack_from('<I', k, 64)[0] >> 5 & 1), ''
    h = head(vs, vflag, fs, topo_class(raw1 >> 24 & 15), YMSAA.get(raw1 >> 28, 0), raw2 >> 15 & 1, raw2 >> 16 & 1, disc)
    sl = []
    for i in range(8):
        if not cf[i]: continue
        f = fmt.get(cf2gal.get(cf[i], -1), 0)
        if not f: return None, None, None
        a = att[i]
        if a >> 31 or (a >> 4 & 7) > 4 or (a >> 7 & 7) > 4 or any((a >> sh & 31) >= len(YFAC) for sh in (10, 15, 20, 25)): return None, None, None
        bl = (1, MBO[YEQ[a >> 4 & 7]], MBF[YFAC[a >> 10 & 31]], MBF[YFAC[a >> 15 & 31]], MBO[YEQ[a >> 7 & 7]], MBF[YFAC[a >> 20 & 31]], MBF[YFAC[a >> 25 & 31]]) \
            if a >> 30 & 1 else (0, 0, 1, 0, 0, 1, 0)
        sl.append(':'.join(map(str, (i, f, mtl_mask(a & 15)) + bl)))
    return h + sl, at, inf

def idx_flags(p):
    b = open(p, 'rb').read(); assert b[:4] == b'GALI', '不是离线索引'
    n = struct.unpack_from('<I', b, 16)[0]; out = {}
    for i in range(n):
        k, off, _ln = struct.unpack_from('<QII', b, 24 + 16 * i)
        out[f'{k:016x}'] = struct.unpack_from('<I', b, off + 96)[0]   # 记录标志（同 pso_gen.py）
    return out

def main(a):
    if len(a) != 3: print('用法：refpso.py <输入表> <gal.idx> <输出表>', file=sys.stderr); return 2
    fmt, cf2gal = fmt_tables(); flags = idx_flags(a[1])
    out = {}; nin = 0; unk = {}; nokey = 0; bad = 0; bysrc = {}; dup = 0; dynb = 0
    def hk(x): return hashlib.blake2b(x.encode(), digest_size=8).digest()
    # 带格式号的状态（格式版本 1 的参考库里同一状态没有格式号：见到孪生就按重复跳过）
    labeled = set()
    for l in open(a[0], encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        c = l.rstrip('\n').split('\t')
        if len(c) == 6 and c[3] != '00000000': labeled.add(hk(c[5]))
    atgrp = {}   # 透明测试：社区状态（顶点 + 状态字节）→ [有一份我方变体对上, 对不上丢掉的行数]
    for l in open(a[0], encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        nin += 1; c = l.rstrip('\n').split('\t')
        if len(c) != 6: bad += 1; continue
        vs, fs, ours, sf, cg, hx = c
        vs = vs[:17]; fs = fs if fs == '-' else fs[:17]
        if vs[1:] not in flags: nokey += 1; continue
        try: s = bytes.fromhex(hx); sf = int(sf, 16); cgv = int(cg, 16)
        except ValueError: bad += 1; continue
        if sf == 0 and cgv == 0 and hk(hx) in labeled: dup += 1; continue
        if sf >> 16 == 0xffff:
            if sf & 0xffff == 5: line, at = from_yuzu5(s, vs, flags[vs[1:]], fs, fmt, cf2gal); src, inf = 'yuzu5', ''
            elif sf & 0xffff == 10: line, at, inf = from_yuzu10(s, vs, flags[vs[1:]], fs, fmt, cf2gal); src = 'yuzu10'
            elif sf & 0xffff == 16 and len(s) >= 52 and struct.unpack_from('<I', s, 48)[0] >> 3 & 1: dynb += 1; continue
            else: unk[f'{sf:#x}:{cgv}'] = unk.get(f'{sf:#x}:{cgv}', 0) + 1; continue
        elif sf >> 16 == 0xfffe: unk[f'{sf:#x}:{cgv}'] = unk.get(f'{sf:#x}:{cgv}', 0) + 1; continue
        else: wls = []; line, at = from_ryu(s, vs, flags[vs[1:]], fs, fmt, wls); src, inf = f'ryu{sf:x}', 'a2one'
        if line is None: unk[f'{sf:#x}:{cgv}（解不出）'] = unk.get(f'{sf:#x}:{cgv}（解不出）', 0) + 1; continue
        mine = 'A' if ours == '-' else norm_at(int(ours.split(':')[0], 0))
        g = atgrp.setdefault(hk(vs + hx), [False, 0])
        if mine != at: g[1] += 1; continue
        g[0] = True
        for ln in [line] + ([w for w in wls if w] if src.startswith('ryu') else []):   # 宽线另一行（wl_line）
            key = ' '.join(ln); e = out.setdefault(key, [set(), set()]); e[0].add(src); e[1].update([inf] if inf else [])
        bysrc[src] = bysrc.get(src, 0) + 1
    at_other = sum(n for ok, n in atgrp.values() if ok); at_miss = sum(n for ok, n in atgrp.values() if not ok); at_miss_g = sum(1 for ok, n in atgrp.values() if not ok)
    # 推断只在没有任何来源给出该字段时标：yuzu5 给了 a2one，就不算推断
    with open(a[2] + '.tmp', 'w', encoding='utf-8') as f:
        f.write('# 社区管线状态换算的 v2 行（refpso.py）；格式同 spec_pipes.tsv，# 后为来源与推断字段\n')
        for k in sorted(out):
            src, inf = out[k]
            if src & {'yuzu5', 'yuzu10'}: inf -= {'a2one'}   # yuzu 系给了 a2one
            if src - {'yuzu10'}: inf -= {'disc'}   # 别的来源给了光栅化开关
            f.write(f'{k}\t# 来源={",".join(sorted(src))}' + (f' 推断={",".join(sorted(inf))}' if inf else '') + '\n')
        f.write(f'# 汇总：输入 {nin} 行，出 {len(out)} 行（按来源 {", ".join(f"{k} {v}" for k, v in sorted(bysrc.items())) or "无"}），'
                f'透明测试：同一社区状态的其他变体 {at_other} 行（正常挑选）、真对不上 {at_miss} 行 / {at_miss_g} 个状态（社区要的比较方式我方没烘），'
                f'无格式号的重复 {dup}，yuzu 版本 16 动态混合（缓存不含混合状态）{dynb}，阶段键不在离线索引 {nokey}，坏行 {bad}\n')
        for k, v in sorted(unk.items()): f.write(f'# 不认识 {k} {v} 条\n')
    os.replace(a[2] + '.tmp', a[2])
    print(f'refpso：输入 {nin} 行 → {len(out)} 行 v2（透明测试真对不上 {at_miss}、其他变体 {at_other}；无格式号重复 {dup}；动态混合 {dynb}；缺键 {nokey}、坏行 {bad}、不认识 {sum(unk.values())}）')
    return 0

if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
