#!/usr/bin/env python3
# Provisional game profiles: the profile keys a game's own files decide, for a game without a hand-made profile in dm/games (scripts/build_ipa_from_nsp.py writes them).
# facts_of(ExeFS, RomFS) reads the code modules (dynamic symbols, sizes, SDK strings) and the RomFS file headers (a romfs_manifest.tsv from nx_extract --manifest, or a RomFS folder);
# guess(facts) turns the facts into profile keys, each with the reason written above it in game.tsv. Every rule was checked against the hand-made profiles; --check runs that comparison again.
# The keys no short run decides (render_cond, tex_flush_upload,
# tex_dirty_upload, core_preempt, gpu_timestamps, feedback_snap, alpha_from_red, vconv_range, present_interval) keep their defaults for a developer: a minute's boot without input
# cannot tell the games that need them (Tears of the Kingdom) from those that only use what they answer (Wonder's conditional clears, Breath of the Wild's flushed textures).
# Usage: profile_guess.py <ExeFS dir> <romfs_manifest.tsv | RomFS dir>   the facts and the guessed keys
#        profile_guess.py --check [<NSP root>]                        every profile in dm/games against its extraction under <NSP root> (default /Volumes/T7/nsp): where the guess differs
import collections, os, re, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'tools')); import nso_syms   # dynamic symbols, the host's hooks
# the one RomFS walk (file names, sizes, first 32 bytes, read once per RomFS content)
import romfs_list
import gfx_api   # the Vulkan rule (vulkan_why / vk_lookup): one rule for the pack split (gfx_api.py) and the shader sources here

MAGICS = [(b'UnityFS\0', 'UnityFS'), (b'UnityWeb', 'UnityWeb'), (b'UnityRaw', 'UnityRaw'), (b'BNSH', 'BNSH'), (b'BAHS', 'BAHS'), (b'SARC', 'SARC'), (b'Yaz0', 'Yaz0'),
          (bytes.fromhex('28b52ffd'), 'zstd'), (b'FRES', 'bfres'), (b'BNTX', 'BNTX'), (b'BWAV', 'BWAV'), (b'FSAR', 'BFSAR'), (b'CPK ', 'CRI CPK'), (b'CRID', 'CRI USM'),
          (b'@UTF', 'CRI UTF'), (b'AKPK', 'Wwise pck'), (b'BKHD', 'Wwise bnk'), (b'FSB5', 'FMOD'), (b'\x89PNG', 'PNG'), (b'RIFF', 'RIFF'), (b'OggS', 'Ogg'), (b'PK\x03\x04', 'zip'), (b'NSO0', 'NSO'),
          (bytes.fromhex('03022307'), 'SPIR-V'), (b'ONEPACK\0', 'Trinity pack'), (b'ARC\0', 'MT Framework ARC'), (b'SCNE', 'Bezel Engine archive'), (b'XNB', 'XNB')]
PACKED = {'UnityFS', 'UnityWeb', 'Yaz0', 'zstd', 'BWAV', 'CRI CPK', 'CRI USM', 'Wwise pck', 'FMOD', 'PNG', 'Ogg', 'zip', 'Trinity pack', 'MT Framework ARC', 'Bezel Engine archive'}   # file headers of compressed / media formats (zip_store)
# IL2CPP by the metadata file every IL2CPP player opens: Unity 2022's main (Ace Attorney Investigations Collection) has no il2cpp_ API names, Engage's 2020.3 has both
MARKERS = [(b'nvnBootstrapLoader', 'NVN'), (b'vkCreateInstance', 'Vulkan'), (b'eglGetProcAddress', 'EGL / OpenGL'), (b'global-metadata.dat', 'Unity IL2CPP'), (b'UnityEngine', 'Unity'),
           (b'sead::', 'Nintendo sead'), (b'agl::', 'Nintendo agl'), (b'gsys::', 'Nintendo gsys'), (b'Unreal', 'Unreal'), (re.compile(rb'(?<![A-Za-z])UE4'), 'Unreal 4'), (b'Havok', 'Havok'), (b'CRIWARE', 'CRIWARE'), (b'Wwise', 'Wwise'),
           (b'MonoGame.Framework', 'MonoGame'), (b'FMOD mixer', 'FMOD')]
# UE4 要是独立词头：暗黑3 main 的 UE4 来自「VALUE4」，子串命中误标 Unreal（10-29 情报核实）；「UE4Game」这类真 Unreal 串照认
hit = lambda pat, img: bool(pat.search(img)) if isinstance(pat, re.Pattern) else pat in img
GLSLC_MAGIC = b'\x91\x68\x86\x19'   # GLSLC compiler outputs (shader_split.py glslc_shaders)
APP_POOL = 0xCD500000               # the application memory pool of a 4 GB Switch (3285 MiB), what every profile but Engage's reports
MiB = 1 << 20


def nso(path):
    """An NSO module: its three segments decompressed (the image without bss), build ID, segment sizes and bss size"""
    from lz4blk import lz4_block
    d = Path(path).read_bytes(); flags = struct.unpack_from('<I', d, 0xc)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4_block(raw, sz) if flags >> i & 1 else raw
    return bytes(img), d[0x40:0x50].hex(), [sz for _, _, sz in segs], struct.unpack_from('<I', d, 0x3c)[0]


def kind(m):   # a short name for what a module is: its NintendoSDK component, GLSLC, or the nn:: namespace most of its exports are in
    if m['comps']: return sorted(m['comps'])[0]
    if any(s.startswith('glslc') for s in m['exports']): return 'GLSLC'
    areas = collections.Counter(nso_syms.area(s) for s in m['exports'])
    return areas.most_common(1)[0][0] if areas else '?'


def romfs_files(romfs):   # (path, size, first 32 bytes) of every RomFS file: from nx_extract's manifest, or read from a RomFS folder
    romfs = Path(romfs)
    if romfs.is_file():
        for line in romfs.read_text(errors='replace').splitlines():
            if line.startswith('#'): continue
            path, size, head = line.split('\t'); yield path, int(size), bytes.fromhex(head)
        return
    # RomFS 文件头只读一次（graphics/nvn/tools/romfs_list.py：按内容身份落盘清单，各阶段 / 各进程共用）；顺序同原先 os.walk，读失败照原先在碰到时抛
    tree = romfs_list.heads(romfs)
    byrel = {e.rel: e for e in tree.entries}
    for d, _, names in tree.walk():
        rd = os.path.relpath(d, tree.top)
        for n in names:
            e = byrel['/'.join(x for x in (rd, n) if x != '.').replace(os.sep, '/')]
            if not e.file: raise IsADirectoryError(21, 'Is a directory', e.path) if e.walkdir else FileNotFoundError(2, 'No such file or directory', e.path)
            size, head = e.read()
            yield '/' + e.rel, size, head


def npdm(path):   # (system resource size, program ID) from main.npdm; a non-zero system resource means virtual address memory (Engage 16 MB); (0, None) without the file
    if not Path(path).exists(): return 0, None
    d = Path(path).read_bytes(); a = d.find(b'ACI0')
    return (struct.unpack_from('<I', d, 0x14)[0] if d[:4] == b'META' else 0), (struct.unpack_from('<Q', d, a + 0x10)[0] if a >= 0 else None)


def facts_of(exefs, romfs):
    """What the profile rules (and the survey report) need from a game's code modules and RomFS"""
    exefs = Path(exefs)
    F = {'mods': {}, 'markers': {}, 'sdkver': set(), 'comps': set(), 'unity': set(), 'glslc': 0, 'glsl_src': 0, 'gl_names': 0, 'sysres': 0, 'program': None}
    for p in sorted(exefs.iterdir()):
        with open(p, 'rb') as f:
            if f.read(4) != b'NSO0': continue
        img, bid, szs, bss = nso(p)
        syms = nso_syms.dynsyms(img)
        end = ((((len(img) + bss + 0x3FFF) & ~0x3FFF) + 0x4000 + 0xFFFF) & ~0xFFFF)   # where patch_nso.py would append the patch area (NEAR_PATCH_OFF)
        m = F['mods'][p.name] = {'bid': bid, 'sizes': szs, 'bss': bss, 'far': end > 0x7000000,   # far: the patch area goes before the base (patch_nso.py FAR), the bss counts as used memory (hle_svc.c big_bss_bytes)
                                 'imports': {s for s, defined, _ in syms if not defined}, 'exports': {s for s, defined, bind in syms if defined and bind in (1, 2)},
                                 'comps': {c.decode().rsplit('-', 1)[0] for c in re.findall(rb'NintendoSDK_(?!nnSdk)\w+-[0-9_]+', img)}}
        F['sdkver'] |= {v.decode() for v in re.findall(rb'(?i)NintendoSDK_nnSdk-([0-9_]+)', img)}   # SDK 12 spells it NintendoSdk_, SDK 16 NintendoSDK_
        F['comps'] |= {c.decode() for c in re.findall(rb'SDK MW\+Nintendo\+([\w]+-[0-9_]+)', img)}
        for pat, name in MARKERS:
            if hit(pat, img): F['markers'].setdefault(name, []).append(p.name)
        if p.name == 'main':
            F['unity'] = {v.decode() for v in re.findall(rb'(?:20[12][0-9]|6000)\.[0-9]+\.[0-9]+f[0-9]', img)}   # Unity 6 起版本号 6000.x（丝之歌 6000.0.50f1）
            F['glslc'], F['glsl_src'], F['gl_names'] = img.count(GLSLC_MAGIC), img.count(b'#version '), img.count(b'glShaderSource')
            F['main_markers'] = {name for pat, name in MARKERS if hit(pat, img)}
            F['vk_name'] = gfx_api.VK_NAME in img   # the name main passes to nn::ro::LookupSymbol for its Vulkan entry (vk_lookup_of)
        m['kind'] = {'main': 'the game', 'sdk': 'nnSdk', 'rtld': 'rtld'}.get(p.name) or kind(m)
    F['sysres'], F['program'] = npdm(exefs / 'main.npdm')
    major = {v.split('_')[0] for v in F['sdkver']}
    F['sdk'] = min((int(v) for v in major if v.isdigit()), default=0)

    # RomFS: counts by top level (two levels: Unity keeps everything under Data/), extension and header magic
    R = F['romfs'] = {'n': 0, 'bytes': 0, 'tops': collections.Counter(), 'topb': collections.Counter(), 'exts': collections.Counter(), 'extb': collections.Counter(), 'extc': collections.Counter(),
                      'mags': collections.Counter(), 'magb': collections.Counter(), 'dirs': collections.Counter(), 'biggest': (0, ''), 'root': set()}
    for path, size, h in romfs_files(romfs):
        R['n'] += 1; R['bytes'] += size
        parts = path.strip('/').split('/')
        top = '/'.join(parts[:2]) if len(parts) > 2 else parts[0] if len(parts) > 1 else '(root)'
        R['tops'][top] += 1; R['topb'][top] += size
        ext = os.path.splitext(path)[1].lower()
        R['exts'][ext or '(none)'] += 1; R['extb'][ext] += size
        if len(parts) > 1: R['dirs'][parts[0]] += 1
        else: R['root'].add(parts[0])
        R['biggest'] = max(R['biggest'], (size, path.strip('/')))
        mag = next((n for m, n in MAGICS if h.startswith(m)), None)
        if mag: R['mags'][mag] += 1; R['magb'][mag] += size
        if mag in PACKED: R['extc'][ext] += 1
    return F


# ---- Rules ----
def host_hooks():   # the host's own functions for imports, leaving out the HLE_FORCE wrappers that still call the module's function
    return nso_syms.host_hooks(str(HERE.parent / 'host'), forced=False)


def guess(F, hooks=None):
    """{key: (value, reason)} for the keys the files decide, in profile order; keys left out keep game.py's defaults"""
    G, mods, R = {}, F['mods'], F['romfs']
    imp = mods['main']['imports']
    hooks = host_hooks() if hooks is None else hooks
    preset = engine(F)

    # Code modules: every module is loaded, as on Horizon, except NVIDIA's OpenGL and Vulkan drivers (gpu_driver_modules: the NintendoSDK component a module is built from):
    # they program the GPU through NvRm, which the host does not have, and the host's Vulkan / GL layer answers main's calls (a loaded driver would take them first).
    # pack/stage_rewrite.sh leaves the same modules out of the package. (10-25: nn::pcm under Super Mario Galaxy 2 used to be left out because its data shared a 16 KB host page
    # with its text; the rewriter's LOAD_BIAS fixed that)
    order = lambda m: (m != 'main', m == 'sdk', int(m[6:]) if m.startswith('subsdk') and m[6:].isdigit() else 0)
    keep, drop = [], []
    for name in sorted((m for m in mods if m != 'rtld'), key=order):
        if name in ('main', 'sdk') or mods[name]['kind'] not in GPU_DRIVERS: keep.append(name)
        else: drop.append(f'{name} ({mods[name]["kind"]})')
    G['modules'] = (' '.join(keep), f'not loaded, GPU drivers the host replaces: {", ".join(drop)}' if drop else 'every module')


    # Memory: the guest block is 256 MB in front + alias region + stack region + heap region (hle_svc.c mem_init)
    giant = sum(m['bss'] for n, m in mods.items() if n in keep and m['far'])
    heap_api = HEAP_API in imp
    if F['sysres']:   # virtual address memory: Engage's 5 GB block. With a heap, the heap check moves the alias / heap split once it sees the heap the game asks for (Wonder, Tears of the Kingdom);
        # without one the game maps everything in the alias region itself (Hollow Knight: Silksong's Unity 6 through AllocateAddressRegion / AllocateMemoryPages, 1.5 GB in its first room;
        # Absolum's and Pokémon Legends: Z-A's StandardAllocator), which a 256 MB alias region cannot hold
        mem = (0x140000000, 0x118000000, APP_POOL, f'the NPDM declares {F["sysres"] // MiB} MB of system resource (virtual address memory) and main ' +
               ('sets a heap: a 5 GB block with a large alias region; the heap check sizes the heap region from the heap the game asks for' if heap_api else
                'never sets a heap: a 5 GB block with a 4.375 GB alias region, where the game maps its memory itself'))
    else:
        heap = max(0x10000000, -(-(APP_POOL - 64 * MiB - giant) // 0x10000000) * 0x10000000) if heap_api else 0x10000000
        mem = (0x30000000 + heap, 0x10000000, APP_POOL,
               ('main sets a heap of at most the pool − 64 MB' + (f' − {giant // MiB} MB of bss (counted as used memory)' if giant else '') + f': a {heap // MiB} MB heap region')
               if heap_api else 'main never sets a heap (its memory is its own bss): a 256 MB heap region')
    G['mem_reserve'] = (f'{mem[0]:#x}', mem[3]); G['mem_alias'] = (f'{mem[1]:#x}', ''); G['mem_stack'] = ('0x10000000', ''); G['app_pool'] = (f'{mem[2]:#X}'.replace('0X', '0x'), '')
    G['sys_resource'] = (f'{F["sysres"]:#x}', f'the NPDM declares {F["sysres"] // MiB} MB of system resource' + ('' if F['sysres'] else
                         ': IsVirtualAddressMemoryEnabled is false, as on Horizon (Big Brain Academy: Brain vs. Brain sets a heap only then)'))

    if F.get('main_markers', set()) & {'Unreal', 'Unreal 4'} and R['exts'].get('.pak') and 'nvnBootstrapLoader' in imp:
        G['shader_groups'] = ('ShaderArchive-Global-=global ShaderArchive-=game', 'the decoded shader code archives: the engine\'s global shaders and the game\'s material shaders')
        G['mem_reserve'] = ('0x1028000000', 'Unreal: nninitStartup reserves a 62 GB address region and its FMallocBinned3 takes 37 GB of it, so a 64 GB alias region for the bring-up on the Mac. '
                            'An iPhone needs the allocator cut for the build and a capped region (game_args), as Octopath Traveler 0\'s profile (docs/agents/03)')
        G['mem_alias'] = ('0x1008000000', '')
    G.update(preset)
    return G


HEAP_API = '_ZN2nn2os17SetMemoryHeapSizeEm'
GPU_DRIVERS = {'NintendoSDK_OpenGL', 'NintendoSDK_Vulkan'}


def gpu_driver_modules(exefs):   # the ExeFS modules that are NVIDIA GPU drivers (kind in GPU_DRIVERS): not rewritten, packed or loaded (pack/stage_rewrite.sh, runtime/run_mac.sh)
    out = []
    for p in sorted(Path(exefs).iterdir()):
        if p.name in ('main', 'sdk', 'rtld'): continue
        with open(p, 'rb') as f:
            if f.read(4) != b'NSO0': continue
        img = nso(p)[0]
        m = {'exports': {s for s, defined, bind in nso_syms.dynsyms(img) if defined and bind in (1, 2)},
             'comps': {c.decode().rsplit('-', 1)[0] for c in re.findall(rb'NintendoSDK_(?!nnSdk)\w+-[0-9_]+', img)}}
        if kind(m) in GPU_DRIVERS: out.append(p.name)
    return out


# ---- Shader sources: decided from the game files at every build, not kept in the profile (scripts/build_ipa_from_nsp.py; shader_split.py reads what those steps write) ----
def shader_sources(imports, glsl_src, glslc_mods, spirv, unreal_paks, trinity_packs=0, legacy_paks=0, gl_names=0, vk_lookup=None):
    """{name: (value, reason)}: graphics (vulkan by gfx_api.vulkan_why: main imports Vulkan functions, or looks vkGetInstanceProcAddr up through nn::ro::LookupSymbol in the module
    vk_lookup names (Minecraft), and does not import nvnBootstrapLoader; gl when it imports eglCreateWindowSurface and names glShaderSource, so it compiles
    GLSL through OpenGL (gl_names: how often main has that name; Absolum imports the same EGL functions for SDL3 but renders with NVN and names no GL function); else nvn), vk_capture (a Vulkan game without SPIR-V files generates its shaders at
    run time), glslc_capture (main holds GLSL sources and calls glslcCompile in a module the game loads: it compiles some shaders at run time), ue_decode (Unreal paks keep the shaders Oodle-compressed
    in their shader code archives, which only the game's own Oodle decodes), oodle_packs (Trinity packs, Oodle-compressed file by file, which the shader split decodes with the game's own decoder in
    the Mac host's tool mode), ue_legacy (legacy Unreal paks, version 4: the shaders are inline in the cooked packages, which the shader split reads through the game's own decoder the same way).
    unreal_paks counts the version 11 paks, legacy_paks the older ones. Checked against every profile: Hades and Super Mario Galaxy Vulkan, Galaxy alone with no SPIR-V file, Three Houses alone compiling
    shaders (13 Sentinels holds 106 GLSL sources but does not import glslcCompile; Captain Toad: Treasure Tracker imports it with agl's GLSL sources, but no module defines it), Octopath Traveler 0
    alone with version 11 Unreal paks, DRAGON QUEST XI S alone with legacy ones, Pokémon Legends: Z-A alone with Trinity packs, Digimon Story Cyber Sleuth alone with OpenGL (of the 22 games extracted)"""
    vk = gfx_api.vk_imports(imports); vulkan = bool(gfx_api.vulkan_why(vk, 'nvnBootstrapLoader' in imports, vk_lookup))
    gl = not vulkan and 'eglCreateWindowSurface' in imports and bool(gl_names)
    how = (f'imports {vk} Vulkan functions and not nvnBootstrapLoader' if vk else
           f'imports neither Vulkan functions nor nvnBootstrapLoader and looks {gfx_api.VK_ENTRY} up through nn::ro::LookupSymbol ({vk_lookup} defines it)')
    return {'graphics': ('vulkan', f'main {how}: the host\'s Vulkan layer (dm/gfx/vk/hle_vk.m)') if vulkan else
                        ('gl', 'main imports EGL and names glShaderSource: it renders with OpenGL and compiles GLSL, the host\'s GL layer (dm/gfx/gl/hle_gl.m)') if gl else ('nvn', 'main imports nvnBootstrapLoader'),
            'vk_capture': (vulkan and not spirv, 'no SPIR-V file in the RomFS: the game generates its shaders at run time (Super Mario Galaxy): packing does not boot it, every shader is compiled on the device the first time it is met'),
            'glslc_capture': (not vulkan and not gl and bool(glsl_src) and 'glslcCompile' in imports and bool(glslc_mods),
                              f'main holds {glsl_src} GLSL sources and calls glslcCompile in {", ".join(glslc_mods) or "no module it loads"}: shaders compiled at run time (Fire Emblem: Three Houses), captured by booting it on the Mac'),
            'ue_decode': (not vulkan and not gl and bool(unreal_paks), f'{unreal_paks} Unreal pak(s): the shaders are Oodle-compressed in their shader code archives (Octopath Traveler 0), decoded by booting the game on the Mac'),
            'oodle_packs': (not vulkan and not gl and bool(trinity_packs), f'{trinity_packs} Trinity pack file(s) (ONEPACK, arc/data.trpfs: Pokémon Legends: Z-A), Oodle-compressed: the shader split decodes them with the game\'s own decoder in the Mac host (dm/host/hle_oodle.c DM_OODLE_SERVE)'),
            'ue_legacy': (not vulkan and not gl and bool(legacy_paks), f'{legacy_paks} legacy Unreal pak(s) (version 4, UE 4.18: DRAGON QUEST XI S): the shaders are inline in the cooked packages, compressed in the pak; the shader split decodes them with the game\'s own decoder in the Mac host (dm/host/hle_oodle.c DM_OODLE_SERVE)')}




def vk_lookup_of(F):   # gfx_api.vk_lookup from facts_of's facts (the modules' exports are already read): the module main looks its Vulkan entry up in, or None
    mods = F['mods']
    if gfx_api.vk_imports(mods['main']['imports']): return None
    return gfx_api.vk_lookup(mods['main']['imports'], F.get('vk_name', False), lambda: ((n, m['exports']) for n, m in mods.items() if n != 'main'))


def va_heap(sysres, imports):   # virtual address memory (an NPDM system resource) and a heap: the alias / heap split is a starting point the heap check corrects (Wonder, Tears of the Kingdom; Engage's pool is its own measurement)
    return bool(sysres) and HEAP_API in imports




def engine(F):   # keys that follow from the engine rather than from a general signal
    out = {}
    if 'hagi.config' in F['romfs']['root']:   # NERD's Hagi Wii layer: the pointer is the touch screen in handheld mode (docked it is the Joy-Con gyro, which the host does not have)
        out['op_mode'] = ('handheld', 'Hagi (hagi.config): the Wii pointer is the touch screen in handheld mode')
        out['pad_layout'] = ('full', 'Hagi: a 3D game pad (D-pad, right stick)')

    # present_interval 推导（10-28 60 帧零配置放开）：引擎 / 呈现路径标记 + L3 判定 → 缺省值
    # 推导写独立键 present_interval_derived，运行时规则：显式 present_interval 优先；否则推导 display 且 L3=ok → display；否则 game
    # L3 判定文件由名单线产出（fps_l3_results.tsv），直连线运行时读取；这里推导的是编译期缺省
    markers = F.get('main_markers', set())
    # Unity / Unreal：呈现路径标记表明不依赖游戏自己的节拍（Unity Application.targetFrameRate / QualitySettings.vSyncCount、UE t.MaxFPS 控制引擎限帧）
    # 注：L3 判定由运行时读取 fps_l3_results.tsv，这里只按引擎推导；显式写了 present_interval 的 game.tsv 优先
    if markers & {'Unity', 'Unity IL2CPP'}:
        out['present_interval_derived'] = ('display', 'Unity: Application.targetFrameRate / QualitySettings.vSyncCount control the frame limit, not the present interval; runtime checks L3 results (fps_l3_results.tsv) to confirm no timestep speedup')
    elif markers & {'Unreal', 'Unreal 4'} and (F['romfs']['exts'].get('.pak') or F['romfs']['exts'].get('.utoc')):   # 同上面 Unreal 内存预设：要有 Unreal 资源包
        out['present_interval_derived'] = ('display', 'Unreal: t.MaxFPS / r.VSync / rhi.SyncInterval control the frame limit, not the present interval; runtime checks L3 results (fps_l3_results.tsv) to confirm no timestep speedup')
    return out






# ---- Checking the rules against the hand-made profiles ----
DEFAULTS = {'op_mode': 'console', 'pad_layout': 'simple'}
NO_SIGNAL = {'pad_layout', 'op_mode'}   # no static signal outside the engine presets; the player switches the pad layout in game, DM_OPMODE in env.txt sets the mode


def find_extraction(root, g):   # (ExeFS, RomFS manifest or folder) for a profile: its survey, else a work folder's extraction of the packed version
    for d in sorted(Path(root).iterdir()):
        s = d / f'{g.id}_survey/extract'
        if (s / 'ExeFS').is_dir() and (s / 'romfs_manifest.tsv').exists(): return s / 'ExeFS', s / 'romfs_manifest.tsv'
    for data in (f'{g.id}-work/data', f'{g.id}_build/extract'):   # the by-hand work layout (docs/development.md), then the NSP script's (<NSP folder>/<id>_build/extract/<version>): either holds what --check needs
        for d in sorted(Path(root).iterdir()):
            base = d / data
            for v in [g.get('package', '')] + sorted(x.name for x in base.glob('v*')):
                w = base / v
                if (w / 'ExeFS').is_dir() and (w / 'RomFS').is_dir(): return w / 'ExeFS', w / 'RomFS'
    return None


def check(root):
    sys.path.insert(0, str(HERE)); import game
    hooks, bad = host_hooks(), 0
    for g in game.all_games():
        if g.dir.parent != HERE: continue
        ex = find_extraction(root, g)
        if not ex: print(f'{g.id} {g.get("name")}: no extraction under {root}'); continue
        F = facts_of(*ex); G = guess(F, hooks)
        diff, unknown, later = [], [], []
        for k in list(DEFAULTS) + ['modules', 'mem_reserve', 'mem_alias', 'mem_stack', 'app_pool']:
            want, got = g.get(k, DEFAULTS.get(k, '')), G.get(k, (DEFAULTS.get(k, ''),))[0]
            if k.startswith('mem_') or k == 'app_pool': want, got = int(want, 0), int(got, 0)
            if want == got: continue
            if k in ('mem_alias', 'app_pool') and F['sysres']: later.append((k, got, want))
            elif k in NO_SIGNAL and k not in G: unknown.append((k, got, want))
            else: diff.append((k, got, want))
        fmt = lambda v: f'{v:#x}' if isinstance(v, int) else v
        print(f'{g.id} {g.get("name")}: ' + ('ok' if not diff else 'DIFF ' + '; '.join(f'{k} {fmt(got)} (profile {fmt(want)})' for k, got, want in diff))
              + (' | heap check / measured: ' + ', '.join(f'{k} {fmt(got)} (profile {fmt(want)})' for k, got, want in later) if later else '')
              + (' | no signal: ' + ', '.join(f'{k} {fmt(want)}' for k, _, want in unknown) if unknown else ''))
        bad += bool(diff)
    return bad


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['--gpu-drivers'] and len(a) == 2:   # one module name per line
        sys.stdout.reconfigure(newline='\n')   # 调用方重定向成 gpu_drivers.tsv：Windows 标准输出缺省把 \n 写成 CRLF
        print('\n'.join(gpu_driver_modules(a[1]))); sys.exit(0)
    if a[:1] == ['--check']:
        sys.exit(1 if check(a[1] if len(a) > 1 else '/Volumes/T7/nsp') else 0)
    if len(a) != 2: sys.exit(__doc__ or 'usage: profile_guess.py <ExeFS dir> <romfs_manifest.tsv | RomFS dir> | profile_guess.py --check [<NSP root>]')
    F = facts_of(*a)
    for n, m in F['mods'].items():
        print(f'{n}: {m["kind"]}, build {m["bid"]}, bss {m["bss"] / MiB:.1f} MB{" (far)" if m["far"] else ""}, {len(m["imports"])} imports, {len(m["exports"])} exports')
    print(f'SDK {F["sdk"]}, system resource {F["sysres"] // MiB} MB, GLSLC outputs in main {F["glslc"]}, GLSL sources {F["glsl_src"]}, SPIR-V files {F["romfs"]["mags"]["SPIR-V"]}')
    for k, (v, why) in guess(F).items(): print(f'{k}\t{v}' + (f'\t# {why}' if why else ''))
