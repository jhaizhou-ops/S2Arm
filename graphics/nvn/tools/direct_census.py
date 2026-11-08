#!/usr/bin/env python3
"""直连泛化普查（静态，不起局）：一款游戏一行，回答「出包时自动接 NVN 驱动 + 离线着色器 + 系统服务，这款能不能零配置跑直连，差哪几项」。
用法：python3 graphics/nvn/tools/direct_census.py [--shx <抽取缓存目录>] <产物根> [<产物根> …]   产物根 = 有 exefs/（NSO + main.npdm）和 romfs/ 的解包目录
      python3 graphics/nvn/tools/direct_census.py --header                        只打表头
      着色器数与阶段：先读通用模式出包留下的抽取缓存（<抽取缓存目录>/<程序号小写>-*/extract.log 的「唯一键 N 按阶段 {…}」，缺省 ~/.s2arm/run/s2arm/cache/shx），
      没有再读产物根里的直连库映射表 shaders/direct/shader_map.tsv；都没有就只按容器判能不能离线翻。
每行是一行 Markdown 表格，列见 HEADER；读法与判据见 docs/研究/直连泛化普查.md。
事实取自仓库内 profile_guess.py、loader_census.py 与 nvn_got_census.py；MIT 来源保留在各文件，本文件负责分类与结论。"""
import re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'games')); import profile_guess as pg
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk）
import romfs_list

HEADER = ['游戏', '程序号', '① 图形接口', '② NVN 入口取法', '③ 引擎 / SDK', '④ 着色器', '⑤ Metal 无直接对应', '⑥ 地址需求', '⑧ 大预留来源', '⑦ 结论']
GiB, MiB = 1 << 30, 1 << 20
NVN_NAME = re.compile(rb'\0(nvn[A-Z][A-Za-z0-9]{3,})\0')
SHX = Path.home() / '.s2arm/run/s2arm/cache/shx'
STAGE_NAME = {'vertex': 'vs', 'pixel': 'ps', 'compute': 'cs', 'geometry': 'gs', 'hull': 'hs', 'domain': 'ds'}
XFB = ('nvnCommandBufferBindTransformFeedbackBuffers', 'nvnCommandBufferBeginTransformFeedback')
# shader_split.py 已有读法的容器（profile_guess shader_sources 与 build_ipa_from_nsp.py survey 的说明）：出包时能全部离线翻
OFFLINE_KINDS = {'BNSH', 'BAHS', 'UnityFS', 'Trinity pack', 'MT Framework ARC', 'Bezel Engine archive', 'XNB'}


# 暴雪 CASC：清单是文本 PSV（data/*.psv），行格式 FileId|KeyLayout|Chunk|Archive|CKey|CSize|EKey|ESize|Encoding|Path|Flags，
#   Path 是真文件名（暗黑2 狱火重生：data/hd/shaders/*.bin 162 个）。所以「着色器在哪」不用解 BLTE 就能答；
#   只有真要取内容时才需要 CASC 索引/键布局（archive_manifest 的 key-layout 描述 + 每文件 CKey/EKey）：实测归档是裸 zlib 流序列，
#   没有文件名索引，ESize 会重复、EKey 也不是 md5(压缩)/md5(解出)，按大小或哈希都定位不到具体文件。
CASC_STAGE = {'vs': 'vs', 'ps': 'ps', 'cs': 'cs', 'gs': 'gs', 'hs': 'hs', 'ds': 'ds'}


def casc_shaders(root):
    """CASC 清单里的着色器：({阶段: 个数}, 文件数, 字节数, manifest 名)，没有 CASC 清单为 None"""
    for name in ('build_manifest.psv', 'base_manifest.psv'):
        # 同原先 (Path(root) / 'romfs').rglob(name)：任意深度、文件与目录都算、名字逐字比对
        for p in sorted(Path(dp) / f for dp, dn, fn in romfs_list.walk(Path(root) / 'romfs') for f in dn + fn if f == name):
            try:
                with p.open(errors='replace') as f:
                    if not f.readline().startswith('FileId!STRING:0|'): continue
                    stages, n, size = {}, 0, 0
                    for ln in f:
                        if ln.startswith('##') or not ln.strip(): continue
                        c = ln.rstrip('\n').split('|')
                        if len(c) < 11 or '/shaders/' not in c[9]: continue
                        n += 1
                        try: size += int(c[7] or 0)
                        except ValueError: pass
                        head = c[9].rsplit('/', 1)[-1].split('_')[0].lower()
                        st = CASC_STAGE.get(head) or STAGE_NAME.get(head)
                        if st: stages[st] = stages.get(st, 0) + 1
                    if n: return stages, n, size, p.name
            except OSError: continue
    return None


def loader(path):
    """统计规则加载器；零匹配时核验交错 GOT / 直接槽形态，失败立即报出。"""
    result = subprocess.run([sys.executable, str(HERE / 'loader_census.py'), str(path)],
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'loader_census 失败：{path}（退出 {result.returncode}）\n{result.stderr}')
    out = result.stdout
    m = re.match(r'(\d+) slots stored by a loader', out)
    if m is None:
        raise ValueError(f'loader_census 输出缺少槽统计：{path}')
    count = int(m.group(1))
    if count:
        return count, set(re.findall(r'^\s+\d+\s+(\S+)$', out, re.M)), '展开式按名取'
    sys.path.insert(0, str(HERE)); from nvn_got_census import analyze_nso
    report = {}
    try:
        slots, reads = analyze_nso(path, report)
    except Exception as error:
        raise RuntimeError(f'NVN 槽核验失败：{path}：{error}') from error
    got = sum(row['got'] is not None for row in slots)
    shape = 'GOT 交错形态' if got == len(slots) else '直接全局槽' if got == 0 else 'GOT / 直接全局槽混合形态'
    return len(slots), {row['name'] for row in slots if reads[row['slot']]}, shape


def shx_stages(pid):
    """通用模式抽取器（nxsh_extract）的结果：{阶段: 唯一键数}；没有缓存为 None"""
    for d in sorted(SHX.glob(f'{pid:016x}-*'), key=lambda d: d.stat().st_mtime, reverse=True):
        try: m = re.findall(r"唯一键 (\d+) 按阶段 (\{[^}]*\})", (d / 'extract.log').read_text(errors='replace'))
        except OSError: continue
        if m: return {k: int(v) for k, v in re.findall(r"'(\w+)': (\d+)", m[-1][1])}
    return None


def census(root):
    root = Path(root); ex = root / 'exefs'
    F = pg.facts_of(ex, root / 'romfs'); mods, R = F['mods'], F['romfs']
    G = pg.guess(F, hooks=set())
    unreal = 'Unreal' in F.get('main_markers', set()) and R['exts'].get('.pak', 0) > 0   # 只有「UE4」字串不算（暗黑3 main 里有 UE4 字样，不是 Unreal）
    imp = mods['main']['imports']
    S = pg.shader_sources(imp, F['glsl_src'], [], R['mags']['SPIR-V'], R['exts'].get('.pak', 0) if unreal else 0,
                          R['mags']['Trinity pack'], gl_names=F.get('gl_names', 0), vk_lookup=pg.vk_lookup_of(F))
    gfx = S['graphics'][0]
    # ① 图形接口：各模块的导入（nvnBootstrapLoader / egl* / vk*），按 profile_guess 的判法定主接口；只导入不等于在用（EGL 给 SDL 等），主接口按 shader_sources 定
    uses = {n: [k for k, hit in (('NVN', 'nvnBootstrapLoader' in m['imports']), ('EGL', any(s.startswith('egl') for s in m['imports'])),
                                  ('Vulkan', any(re.match(r'vk[A-Z]', s) for s in m['imports']))) if hit] for n, m in mods.items()}
    api = {'nvn': '只用 NVN', 'gl': 'NVN + EGL·OpenGL（主画面 OpenGL）', 'vulkan': 'Vulkan'}[gfx]
    extra = sorted({k for v in uses.values() for k in v} - {'NVN' if gfx == 'nvn' else '', 'Vulkan' if gfx == 'vulkan' else ''} - {''})
    c1 = api + (f'；另导入 {"/".join(extra)}（{", ".join(n for n, v in uses.items() if set(v) & set(extra))}）' if extra and gfx == 'nvn' else '')
    # ② NVN 入口取法：Switch 上 NVN 函数只能经 nvnBootstrapLoader → nvnDeviceGetProcAddress 按名取；直连在 nvnBootstrapLoader 拦截，取法（循环 / 展开 / adrp 写槽）都自动覆盖
    nvn_mods = [n for n, v in uses.items() if 'NVN' in v]
    parts, used = [], set()
    for n in nvn_mods:
        slots, u, shape = loader(ex / n); used |= u
        names = len(set(NVN_NAME.findall(pg.nso(ex / n)[0])))
        parts.append(f'{n}：{shape} {slots} 个、静态槽读取 {len(u)} 个（名字串 {names} 个）')
    c2 = ('；'.join(parts) + '；运行时拦 nvnBootstrapLoader，取法无关、自动覆盖') if parts else '不经 NVN'
    # ③ 引擎 / SDK
    eng = [k for k in F['markers'] if k not in ('NVN', 'Vulkan', 'EGL / OpenGL', 'Unreal', 'Unreal 4')] + (['Unreal'] if unreal else [])
    if not set(eng) & {'Unity', 'Unity IL2CPP', 'Unreal', 'Nintendo sead', 'Nintendo agl', 'Nintendo gsys', 'MonoGame'}: eng = ['自研引擎'] + eng
    if F['unity']: eng = [f'Unity {", ".join(sorted(F["unity"]))}' if 'Unity' in k else k for k in eng]
    c3 = '、'.join(sorted(set(eng))) + f'；SDK {", ".join(sorted(F["sdkver"])) or "?"}'
    # ④ 着色器
    casc = casc_shaders(root) if F['program'] is not None else None
    st = shx_stages(F['program']) if F['program'] is not None else None
    lib = root / 'shaders/direct/shader_map.tsv'
    if st is None and lib.exists():
        keys = {}
        for ln in lib.read_text(errors='replace').splitlines():
            c = ln.split('\t')
            if len(c) > 3 and not ln.startswith('#'): keys[c[3]] = STAGE_NAME.get(c[2], c[2])
        st = {k: list(keys.values()).count(k) for k in set(keys.values())}
    stages = st or {}
    casc_stages = casc[0] if casc else {}
    kinds = [k for k in R['mags'] if k in OFFLINE_KINDS and R['mags'][k]]
    src = [f'{k} {R["mags"][k]} 个文件' for k in kinds] + ([f'main 内 GLSLC 输出 {F["glslc"]} 个'] if F['glslc'] else [])
    runtime = [S[k][1].split(':')[0] for k in ('vk_capture', 'glslc_capture', 'ue_decode', 'oodle_packs', 'ue_legacy') if S[k][0]]
    nintendo = bool(set(F['markers']) & {'Nintendo sead', 'Nintendo agl', 'Nintendo gsys'}) and any(R['mags'][k] for k in ('zstd', 'Yaz0', 'SARC'))
    if nintendo: src.append('zstd / Yaz0 SARC 打包 ' + str(sum(R['mags'][k] for k in ('zstd', 'Yaz0', 'SARC'))) + ' 个文件')
    if casc: src.append(f'CASC {casc[3]}：着色器 {casc[1]} 个（{casc[2] / 1e6:.2f} MB）' + (f'（{" ".join(f"{k} {v}" for k, v in sorted(casc_stages.items(), key=lambda x: -x[1]))}）' if casc_stages else ''))
    if gfx != 'nvn': offline = '否：非 NVN，直连库不适用'
    elif stages: offline = '能（通用模式抽取器已抽出）'
    elif casc: offline = '待：CASC 清单能枚举、取内容要 CASC 索引 / 键布局（#247）'
    elif runtime: offline = '要在 Mac 上起一次游戏取着色器（' + '；'.join(runtime) + '）'
    elif kinds or F['glslc']: offline = '能（shader_split 已有读法）'
    elif nintendo: offline = '能（任天堂打包：shader_split 读 zstd / Yaz0 SARC 里的 BNSH）'
    else: offline = '先定位容器（顶层没有 BNSH / BAHS / UnityFS 等）'
    c4 = ('、'.join(src) or '顶层无已知容器') + f'；离线全翻：{offline}' + (f'；唯一键 {sum(stages.values())}（' + ' '.join(f'{k} {v}' for k, v in sorted(stages.items(), key=lambda x: -x[1])) + '）' if stages else '')
    # ⑤ Metal 无直接对应：着色器阶段（有库时按映射表）+ NVN 名字表里的曲面细分 / 变换反馈函数（请求了不等于用了）
    cnt = {'geometry': (stages or casc_stages).get('gs', 0), 'hull': (stages or casc_stages).get('hs', 0),
           'domain': (stages or casc_stages).get('ds', 0)}
    flags = [f'{k}着色器 {v} 个' for k, v in (('几何', cnt['geometry']), ('曲面细分控制', cnt['hull']), ('曲面细分求值', cnt['domain'])) if v]
    if used & set(XFB): flags.append('代码读了变换反馈函数槽')
    c5 = '、'.join(flags) or ('无' if stages else '阶段未知（没有抽取结果）')
    # ⑥ 地址需求：NPDM 系统资源（非 0 = 虚拟地址内存）+ profile_guess 的地址键
    vam = F['sysres'] > 0
    c6 = (f'系统资源 {F["sysres"] // MiB} MB（虚拟地址内存）' if vam else '无系统资源（堆模式）') + \
         f'；块 {int(G["mem_reserve"][0], 16) / GiB:.2f} GB、别名区 {int(G["mem_alias"][0], 16) / GiB:.2f} GB' + \
         ('；有 SetMemoryHeapSize' if pg.HEAP_API in imp else '')
    # ⑧ 大预留来源（≥1 GB）：静态能看出的按特征分类，大小常数看不出的标「需 Mac 量」
    img = pg.nso(ex / 'main')[0]
    big = []
    if vam: big.append('SDK AddressRegionManager 节点区 1 GB（虚拟地址内存都有）')
    if any('StandardAllocator10Initialize' in s for s in imp) and vam: big.append('SDK StandardAllocator::Initialize（大小常数需看 nninitStartup 或 Mac 量）')
    if unreal:
        big.append('Unreal 地址区域（-SwitchVirtualAddressSpaceSize，缺省 62 GB）+ FMallocBinned3' if b'SwitchVirtualAddressSpaceSize' in img else 'Unreal 引擎分配器（需 Mac 量）')
    if vam and (F['unity'] or set(F['markers']) & {'Unity', 'Unity IL2CPP'}): big.append('Unity 自有分配器（AllocateAddressRegion）')
    if b'DOTNET_' in img or 'NativeAOT' in str(F['markers']): big.append('.NET GC 区间')
    if vam and not big[1:]: big.append('其他自研（需 Mac 量）')
    if not vam: big.append('无（堆模式：堆 ≤ 应用池，SetMemoryHeapSize 一次给定）' if pg.HEAP_API in imp else '无（只用 bss）')
    sa = any('StandardAllocator10Initialize' in x for x in imp)
    fit5 = '能' if not vam else ('需引擎专项削（Unreal 区域 + 分配器）' if unreal else '能通用削（按 SDK 特征：节点区 + 大块对齐' + (' + StandardAllocator 大小' if sa else '') + '）')
    fit51 = '能' if not unreal else '需削（缺省 62 GB 区域 > 51 GB）'
    c8 = '；'.join(big) + f'；削进 5 GB：{fit5}；51 GB：{fit51}'
    # ⑦ 结论
    gaps = []
    if gfx != 'nvn': gaps.append(f'图形接口是 {gfx}，直连层只有 NVN')
    if not offline.startswith('能'): gaps.append('着色器' + ('需 Mac 起局取' if runtime else '容器未定位'))
    if cnt['hull'] or cnt['domain']: gaps.append('曲面细分（直连层不翻 hull / domain，带曲面细分的管线拒画）')
    if cnt['geometry']: gaps.append('几何着色器走直连层通用几何回放（已有）')
    if vam and unreal: gaps.append('地址要 Unreal 专项削')
    hard = [g for g in gaps if not g.startswith('几何')]
    c7 = '零配置自动接线可行' if not hard else ('不可行：' if gfx != 'nvn' else '差：') + '；'.join(hard)
    if gaps and not hard: c7 += '（' + '；'.join(gaps) + '）'
    reg = F['program'] is not None and (HERE.parent / 'games' / f'{F["program"]:016X}' / 'game.tsv').exists()
    c7 += '；直连层有登记档' if reg else '；直连层无登记档（走临时配置）'
    row = [root.name.split('@')[0], f'{F["program"]:016X}' if F['program'] is not None else '?', c1, c2, c3, c4, c5, c6, c8, c7]
    return '| ' + ' | '.join(x.replace('|', '/') for x in row) + ' |'


def main():
    global SHX
    a = sys.argv[1:]
    if '--shx' in a: i = a.index('--shx'); SHX = Path(a[i + 1]); del a[i:i + 2]
    if not a: sys.exit(__doc__)
    if a == ['--header']:
        print('| ' + ' | '.join(HEADER) + ' |'); print('|' + '---|' * len(HEADER)); return
    for r in a: print(census(r), flush=True)

if __name__ == '__main__': main()
