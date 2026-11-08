#!/usr/bin/env python3
# Unreal 着色器抽取（10-25 总指挥 / jhz「借鉴实践、按我方自研」：直连库出库要 <产物根>/ue_shaders/*.ushaderbytecode，上游靠它的 NSP 脚本出，我方出包链原来没有这一步）。
# 按 pak 格式识别、不按游戏写死：RomFS 里每个 .pak → 读尾部与索引 → 取出其中的着色器代码存档（*.ushaderbytecode）→ 存档里每支着色器解压 → 按原格式重写（存储长 = 原长）。
# 消费方：translator/shader_split.py ue_shaders()（版本 2 存档、每支是 LSLG 记录）。
#
# 格式（UE 源码 IPlatformFilePak / ShaderCodeArchive 的公开布局；上游 uepak.py 头注释同样记了，这里按自己的读法实现）：
#   pak 尾部，版本 ≥ 8（最后 0xdd 字节）：加密密钥 GUID 16、索引加密 u8、魔数 0x5A6F12E1、版本 u32、索引偏移 u64、长 u64、SHA-1 20、5 个压缩方法名各 32 字节
#   pak 尾部，旧版（最后 0x2d 字节）：索引加密 u8、魔数、版本、索引偏移、长、SHA-1；压缩标志是位（1 zlib、2 gzip、4 自定）
#   版本 ≥ 10 的索引：挂载点 FString、条目数 i32、路径哈希种子 u64、路径哈希索引（i32 有无 + u64 偏移 + u64 长 + SHA-1）、完整目录索引（同）、编码条目区（i32 长 + 字节）、未编码条目数 i32
#     完整目录索引（与索引同样加密）：i32 目录数，每目录 FString 名 + i32 文件数，每文件 FString 名 + i32（编码条目区里的偏移）
#     编码条目：u32 位域（0–5 压缩块大小 >> 11，0x3f = 后跟 u32；6–21 块数；22 加密；23–28 压缩方法序号（1 起）；29 存储长 32 位够；30 原长 32 位够；31 偏移 32 位够），
#       再偏移、原长、（压缩时）存储长；多块或加密时每块 u32 存储长。数据前面重复一份 FPakEntry（53 字节，压缩时 + 4 + 16 × 块数）；加密时各块按 16 字节对齐
#   旧版索引：挂载点、条目数，每文件 FString 名（相对挂载点）+ FPakEntry（偏移 / 存储长 / 原长 i64、压缩标志 i32、SHA-1、压缩时块数 i32 + 每块起止 i64、加密 u8、块大小 u32）
#   着色器代码存档（版本 2）：着色器图哈希、着色器哈希（各 20 字节）、着色器图条目 {u32 首、数、首预载、预载数}、着色器条目 {u64 偏移、u32 存储长、u32 原长、u8 阶段}（17 字节紧排）、
#     预载条目（16 字节）、着色器下标（u32）：每个数组 u32 个数 + 元素；之后是代码区，偏移相对代码区起点。存储长 ≠ 原长 = 压缩
# 解压：zlib（Python 自带）、LZ4 块（UE 4.26 起着色器缺省压缩；venv 的 lz4）。Oodle（块头 8C 0A 等）与 LZ5（旧版标志 3）只有游戏自带解码器能解：
#   走 Mac 宿主的工具模式（runtime/src/oodle_tool.c，DM_OODLE_SERVE 协议；OodleDecoder，宿主 / 改写模块目录按 DM_OODLE_HOST / DM_OODLE_MODULES，缺省 build/s2arm-host 与 RomFS 父目录），
#   没有宿主时碰到才照实报出、整款判红（写明缺什么），不猜、不静默跳过。双人成行 1.0.2：pak 级 Oodle 块 70,438 个 / 10.35 GB 30 秒解完，内嵌布局 32,260 支（10-28）。
# IoStore 容器（#247：UE 4.27 / 5 把着色器代码库搬进 .utoc + .ucas，包里一支存档都没有）：不另写读取器，复用 translator/uepak.py 的
#   Toc / io_library_name / io_archive 枚举着色器代码库 chunk、解出记录，产物与 pak 同一格式（ue_shaders/*.ushaderbytecode，每支存原长）。
#   容器块方法 Stored / Zlib / LZ4 当场解；Oodle 块同样交给 OodleDecoder（没宿主时与 pak 口径一致判失败，退非 0，日志点名 Oodle）。
#   来源串 iostore:<utoc 文件名>@<chunk id 十六进制>，与通用链的 pak: / kpka: 同一套写法。
# 加密：复用 graphics/tools/shbake/pak_crypto.py，按 NSO 段映射还原常量构造或扫描连续常量，索引 SHA-1 通过才接受；密钥只在内存中。
#   缺省从标准产物根的 exefs/main 取 NSO，也可 --main <NSO 或已解压镜像>。
# 用法：ue_pak.py <RomFS 目录> <输出目录> [--main <main 已解压镜像>]   退出 0 = 输出目录里是解好的存档（可能为 0 个：没有 pak 或 pak 里没有着色器存档）；1 = 解不了（报出原因）
import argparse, hashlib, os, struct, sys, zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics/tools/shbake"))
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，listdir 同 os.listdir）
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics/nvn/tools")); import romfs_list
import unreal_pak as UP   # 唯一的 pak 读取实现（graphics/tools/shbake/unreal_pak.py：尾部 / 索引 / 条目布局 / 密钥 / 解块都在那里，这里只管着色器存档）

Unsupported = UP.Unsupported

def red(msg): print(f'【红】ue_pak：{msg}', file=sys.stderr); sys.exit(1)

class R:   # 小端读游标
    def __init__(s, b, o=0): s.b, s.o = b, o
    def u8(s): v = s.b[s.o]; s.o += 1; return v
    def u32(s): v = struct.unpack_from('<I', s.b, s.o)[0]; s.o += 4; return v
    def i32(s): v = struct.unpack_from('<i', s.b, s.o)[0]; s.o += 4; return v
    def u64(s): v = struct.unpack_from('<Q', s.b, s.o)[0]; s.o += 8; return v
    def raw(s, n): v = s.b[s.o:s.o + n]; s.o += n; return v
    def fstr(s):
        n = s.i32()
        if n >= 0: return s.raw(n).rstrip(b'\0').decode('utf-8', 'replace')
        return s.raw(-2 * n).decode('utf-16-le', 'replace').rstrip('\0')

def decompress(method, data, raw, oodle=None):
    """oodle：游戏自带解码器 decode(压缩字节, 原长)（OodleDecoder；宿主按 main 自动选 OodleLZ_Decompress 或 LZ5_decompress_safe），pak 的 Oodle / LZ5 块都走它"""
    m = (method or '').lower()
    if m in ('zlib', 'gzip'): return zlib.decompress(data, 47 if m == 'gzip' else 15)
    if m == 'lz4':
        import lz4.block; return lz4.block.decompress(data, uncompressed_size=raw)
    if m in ('oodle', 'lz5'):
        if oodle is None: raise Unsupported(f'压缩方法 {method}（只有游戏自带解码器能解）')
        return oodle(data, raw)
    raise Unsupported(f'压缩方法 {method or "?"}（只有游戏自带解码器能解）')

class OodleDecoder:
    """游戏自带的解码器（Mac 宿主工具模式 DM_OODLE_SERVE，runtime/src/oodle_tool.c）：decode(压缩字节, 原长) → 原文，长度不符即抛 Unsupported。
    宿主与改写模块目录按 translator/uepak.py oodle_host_find（DM_OODLE_HOST / DM_OODLE_MODULES，缺省 build/s2arm-host 与 RomFS 的父目录）；
    没有宿主时不预先报错——用不到就无所谓，真碰到 Oodle 块才抛 Unsupported 并写明缺什么（不静默跳过）"""
    def __init__(self, romfs):
        self.romfs = romfs; self.U = None; self.found = None; self.why = ''; self.p = None; self.n = 0; self.nbytes = 0
    def _resolve(self):   # 首次真用到才找宿主与模块目录：没有 Oodle 块的 RomFS 不碰 uepak.py、不碰环境变量
        if self.U is None: self.U = uepak_module(); self.found, self.why = self.U.oodle_host_find(self.romfs)
    def __call__(self, comp, raw):
        self._resolve()
        if not self.found: raise Unsupported(f'Oodle / LZ5 块只有游戏自带解码器能解（宿主工具模式），但没有宿主：{self.why}')
        if self.p is None:
            try: self.p = self.U.OodleHost(*self.found)
            except OSError as e: raise Unsupported(f'起不了 Oodle 宿主 {self.found[0]}：{e}')
        try: out = self.p(comp, raw)
        except ValueError as e: raise Unsupported(f'游戏解码器失败（宿主 {self.found[0]}，模块 {self.found[1]}）：{e}')
        self.n += 1; self.nbytes += len(out)
        return out
    def close(self):
        if self.p is not None: self.p.close()

unpack_shader = UP.unpack_shader   # 着色器存档每支的解压只有一份（unreal_pak.unpack_shader），直连抽取 nxsh_extract 也调它

LSLG_FREQ, legacy_layout, v1_layout = UP.LSLG_FREQ, UP.legacy_layout, UP.v1_layout   # 着色器存档无版本号旧布局的解析只有一份（unreal_pak.legacy_layout），直连抽取 nxsh_extract 也调它

def archive_legacy(d, oodle=None):
    """无版本号旧布局 → 版本 2 存档（archive_build：每支解压、阶段按 LSLG 标签）；返回（字节，支数，原本压缩的支数）"""
    base, ents = legacy_layout(d); out = []; nc = 0
    for i, (off, size, raw) in enumerate(ents):
        b = d[base + off:base + off + size]
        if size != raw: nc += 1; b = unpack_shader(b, raw, oodle)
        fr = LSLG_FREQ.get(b[4:6]) if b[:4] == b'LSLG' else None
        if fr is None: raise Unsupported(f'旧布局存档第 {i} 支不是认得的 LSLG 记录（头 {b[:6].hex()}）')
        out.append((fr, b))
    return archive_build(out), len(ents), nc

def archive_v1(d, oodle=None):
    """版本 1 存档（unreal_pak.v1_layout）→ 版本 2 存档（archive_build：每支解压、阶段取条目自带的）；返回（字节，支数，原本压缩的支数）"""
    base, ents = v1_layout(d); out = []; nc = 0
    for i, (off, size, raw, fr) in enumerate(ents):
        b = d[base + off:base + off + size]
        if size != raw: nc += 1; b = unpack_shader(b, raw, oodle)
        if b[:4] != b'LSLG': raise Unsupported(f'版本 1 存档第 {i} 支解出来不是 LSLG 记录（头 {b[:6].hex()}）')
        out.append((fr, b))
    return archive_build(out), len(ents), nc

def archive_rewrite(d, oodle=None):
    """版本 2 着色器代码存档 → 每支解压后的同格式字节（存储长 = 原长）；返回（字节，支数，原本压缩的支数）。
    oodle：游戏自带解码器（OodleDecoder）——Oodle 块头的支交给它；没给就照旧判 Unsupported（只有游戏自带解码器能解）"""
    r = R(d)
    if legacy_layout(d): return archive_legacy(d, oodle)
    if v1_layout(d): return archive_v1(d, oodle)
    if r.u32() != 2: raise Unsupported(f'着色器代码存档版本 {struct.unpack_from("<I", d, 0)[0]}（只认 2、版本 1 与无版本号的旧布局）')
    parts = []; head_start = 4
    def arr(elem):
        n = r.u32(); return n, r.raw(n * elem)
    sm_hash = arr(20); sh_hash = arr(20); sm_ent = arr(16)
    n = r.u32(); ent_at = r.o; ents = [struct.unpack_from('<QIIB', d, r.o + 17 * i) for i in range(n)]; r.o += 17 * n
    pre = arr(16); idx = arr(4); code = r.o
    new_code = bytearray(); new_ents = []; nc = 0
    for off, size, raw, fr in ents:
        b = d[code + off:code + off + size]
        if size != raw: nc += 1; b = unpack_shader(b, raw, oodle)
        new_ents.append(struct.pack('<QIIB', len(new_code), raw, raw, fr)); new_code += b
    out = bytearray(d[:ent_at - 4]) + struct.pack('<I', n) + b''.join(new_ents) + d[ent_at + 17 * n:code] + new_code
    return bytes(out), n, nc

INLINE_EXT = ('.uexp', '.bin', '.ushadercode', '.uasset')
def inline_entries(data, oodle=None):
    """内嵌布局（UE4 / UE5 没有共享着色器代码库：八方2 = UE 4.27、七龙珠 电光炸裂 ZERO = UE5）：资源里的 FShaderMapResourceCode 每支 = [i32 存储长 n][n 字节][i32 原长 u][u8 阶段 0..5]，
    n < u 时是压缩块：LZ4（八方2）或 Oodle（电光炸裂，交游戏自带解码器 oodle）——解压只走 unreal_pak.unpack_shader 一份；位置是猜的，Oodle 候选先核帧结构（unreal_pak.oodle_frames），错流不喂给解码器：
    电光炸裂全局缓存里一处字面量 cc30 前的 4 字节被当成 2700 字节长度，喂进去宿主就崩了）。
    认法同通用链 graphics/tools/shbake/nxsh_extract.py scan_ue：原文以 LSLGS 开头，压缩后这串字面量落在条目起点后不远（LZ4 +5～+8，Oodle 块头 + 量子头 + 字面量长后 +12～+15），
    以它为锚只在前 24 字节里试；认定 = 长度 / 原长 / 阶段自洽 + 解出恰好 u 字节且以 LSLG 开头。→ [(阶段, 解开的 LSLG 记录)]"""
    out = []; L = len(data); p = data.find(b'LSLGS')
    while p >= 0:
        for i in range(p - 4, max(-1, p - 28), -1):
            n = struct.unpack_from('<i', data, i)[0]
            if not (16 <= n < (16 << 20)) or i + 9 + n > L: continue
            u = struct.unpack_from('<i', data, i + 4 + n)[0]; fr = data[i + 8 + n]
            if fr > 5 or not (n <= u < (64 << 20)): continue
            b = bytes(data[i + 4:i + 4 + n])
            if n != u:
                if b[:2] in UP.OODLE_HEADS and not UP.oodle_frames(b, 0, n, u): continue   # 猜出来的候选：帧结构不成立就不喂给游戏解码器
                try: b = unpack_shader(b, u, oodle)
                except Unsupported: continue
            if len(b) != u or b[:4] != b'LSLG': continue
            out.append((fr, b)); p = i + 9 + n - 1; break
        p = data.find(b'LSLGS', p + 1)
    return out

def uepak_module():
    """IoStore 解析不另写：复用 translator/uepak.py 的 Toc / io_library_name / io_archive（直连离线链出包读的是同一份）。
    按路径单独加载，不把它旁边的兄弟模块塞进 sys.path；改前那版 pack/ue_pak.py 没有这一步，纯 .utoc 的 RomFS 一支也抽不到。"""
    import importlib.util
    p = Path(__file__).resolve().parents[1] / 'translator/uepak.py'
    try:
        spec = importlib.util.spec_from_file_location('uepak', str(p))
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    except (OSError, ImportError) as e:
        red(f'取不到 IoStore 解析器 {p}（{e}）')
    return m

def no_oodle(comp, raw):
    """uepak.io_archive 的解码入口（没给 OodleDecoder 时）：碰到 Oodle 块当场判失败（与 pak 的 Oodle 口径一致）"""
    raise Unsupported('IoStore chunk 用 Oodle 压缩，需解码服务（只有游戏自带解码器能解）')

IO_EXPORT_BUNDLE = {True: 1, False: 2}   # EIoChunkType ExportBundleData：UE5 编号（TOC 版本 ≥ 4）是 1，UE 4.26 / 4.27 编号（TOC 2 / 3）是 2（鬼灭之刃 火之神血风谭 TOC 2，11-02）

def iostore_archives(romfs, out, oodle=None, key=None, scan_inline=True):
    """IoStore 容器（.utoc，数据在同名 .ucas）里的着色器代码库 → 与 pak 同一格式的版本 2 存档（每支存原长、已解压，shader_split 的 ue_shaders() 照旧读）。
    chunk 枚举与库表解析走 uepak.Toc / io_library_name / io_archive：库表 chunk 与原组 chunk 都在容器里，块方法 Stored / Zlib / LZ4 当场解。
    Oodle 块交给 oodle（OodleDecoder，游戏自带解码器）；没给就与 pak 的 Oodle 口径一致：判失败（退非 0），日志点名 Oodle。
    加密容器用 key（同包 pak 索引解开时找到的游戏密钥，UE 一套包共用；11-02 普查七龙珠 电光炸裂 ZERO 18 个 .utoc 全加密，原先不带密钥、当「不是 IoStore」跳过，写出 0 个）。
    → (容器数, [每个容器的说明行], 写出个数)"""
    tocs = sorted(os.path.join(dp, n) for dp, _, fs in romfs_list.walk(romfs) for n in fs if n.lower().endswith('.utoc'))
    if not tocs: return 0, [], 0
    U = uepak_module(); names = U.archive_names(romfs); notes = []; got = 0
    opened = []   # 按 UE 挂载优先级（补丁 _P 在前，uepak.io_priority）：同一 chunk 号取高优先级那份；库表的着色器组可以落在别的容器里
    for p in U.io_priority(tocs):
        rel = os.path.relpath(p, romfs)
        try: opened.append(U.Toc(p, key))
        except (OSError, ValueError, struct.error) as e:
            if key is None and 'encrypted and no key' in str(e): red(f'{rel}：IoStore 容器加密，同包 pak 里没找到游戏密钥（.utoc 自己不带能验证密钥的加密索引）')
            notes.append(f'{rel}：不是 IoStore 容器（{e}），跳过')
    done = set()
    for t in opened:
        p = t.path; rel = os.path.relpath(p, romfs)
        libs = t.of_type(U.IO_SHADER_LIBRARY)
        if not libs and scan_inline:
            # 不开共享着色器代码库：着色器内嵌在资源导出数据（ExportBundleData）里，与 pak 的内嵌布局同一种条目
            #   （七龙珠 电光炸裂 ZERO UE5：18 个容器 31 万个导出、Oodle 块；鬼灭之刃 火之神血风谭 UE 4.26：TOC 2、Zlib 块，约 1 万个导出带着色器）。
            #   pak 里已经写出了着色器存档（轩辕剑柒：UE 4.26、存档在 pak）就不扫：scan_inline=False，不为别处已有的着色器把全部导出解一遍
            seen = {}; nf = 0; exp = IO_EXPORT_BUNDLE[t.version >= 4]
            for i, c in enumerate(t.ids):
                if c[11] != exp: continue
                try: d = t.read(i, oodle or no_oodle)
                except (ValueError, Unsupported) as e: red(f'iostore:{os.path.basename(p)}@{c.hex()}：{e}')
                if b'LSLGS' not in d: continue
                got_k = inline_entries(d, oodle)
                if got_k: nf += 1
                for fr, b in got_k: seen.setdefault(b, fr)
            if seen:
                dst = os.path.join(out, f'ShaderArchive-IoStoreInline-{os.path.splitext(os.path.basename(p))[0]}.ushaderbytecode'); tmp = dst + '.tmp'   # 与同名 pak 的内嵌存档（ShaderArchive-Inline-<包名>）分开：电光炸裂 pakchunk0-Switch.pak / .utoc 同名，先写的全局着色器被覆盖
                open(tmp, 'wb').write(archive_build([(fr, b) for b, fr in seen.items()])); os.replace(tmp, dst); got += 1
                print(f'  {rel}：内嵌布局：{nf} 个导出里共 {len(seen)} 支不同的着色器 → {dst}')
                continue
        if not libs:
            # 版本 < 4（UE 4.27 的 TOC 3）没有着色器代码库这套 chunk 编号：那版把着色器代码存档留在 pak 里，走上面 pak 那条
            notes.append(f'{rel}：IoStore 版本 {t.version}（{len(t.ids)} 个 chunk）没有着色器代码库'
                         + ('（版本 < 4 没有这套 chunk 编号，UE 4.27 的着色器存档在 pak 里）' if t.version < 4 else ''))
            continue
        for i in libs:
            src = f'iostore:{os.path.basename(p)}@{t.ids[i].hex()}'
            if t.ids[i] in done: print(f'  {src}：同一着色器库在更高优先级的容器（补丁）里，以那份为准'); continue
            done.add(t.ids[i])
            try: b = U.io_archive(t, i, oodle or no_oodle, opened)   # 组按优先级全局取：补丁的库没变的组留在本体（11-02 LEGO 地平线大冒险 1.4.0「shader group 0 has no chunk」），补丁也可以只换本体库的某个组
            except (ValueError, Unsupported) as e: red(f'{src}：{e}')
            dst = os.path.join(out, U.io_library_name(t, i, names) + '.ushaderbytecode'); tmp = dst + '.tmp'
            open(tmp, 'wb').write(b); os.replace(tmp, dst); got += 1
            print(f'  {src}：{len(U.archive(b)["shaders"])} 支着色器 → {dst}')
    return len(tocs), notes, got

def archive_build(shaders):
    """[(阶段, 记录)] → 版本 2 着色器代码存档（一张着色器图含全部、无预载，每支不压缩）"""
    import hashlib
    code = bytearray(); ents = []; hs = []
    for fr, b in shaders: ents.append(struct.pack('<QIIB', len(code), len(b), len(b), fr)); code += b; hs.append(hashlib.sha1(b).digest())
    n = len(shaders)
    return (struct.pack('<II', 2, 1) + hashlib.sha1(b''.join(hs)).digest() + struct.pack('<I', n) + b''.join(hs) + struct.pack('<IIIII', 1, 0, n, 0, 0)
            + struct.pack('<I', n) + b''.join(ents) + struct.pack('<I', 0) + struct.pack('<I', n) + struct.pack(f'<{n}I', *range(n)) + bytes(code))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('romfs'); parser.add_argument('out')
    parser.add_argument('--main', dest='main_image')
    args = parser.parse_args()
    romfs, out = args.romfs, args.out
    # stage_direct 的标准产物根已经有 exefs/main，无需游戏专用配置。取「给的 romfs 路径」的父目录、不顺软链：
    #   产物根的 romfs 是指向 .romfs_store/<款>/<身份>/ 的软链（pack/roots.sh，a25bf3785），resolve() 会落到存储目录旁、找不到 exefs/main（11-04 电光炸裂 / 小小梦魇3 索引加密报红）
    main_path = Path(args.main_image) if args.main_image else Path(os.path.abspath(romfs)).parent / 'exefs/main'
    paks = sorted(os.path.join(dp, n) for dp, _, ns in romfs_list.walk(romfs) for n in ns if n.lower().endswith('.pak'))
    os.makedirs(out, exist_ok=True); got = 0; key = None
    oodle = OodleDecoder(romfs)   # 游戏自带解码器：pak 块 / 存档支 / IoStore chunk 里的 Oodle（LZ5）都走它；没宿主时碰到才报红
    main_img = []
    def images():   # 只有索引加密、真要找密钥时才读 main（迭代到才读，读一次）；密钥本身由 pak_crypto 进程内缓存，后续 pak 先试已找到的
        if not main_img and main_path.is_file(): main_img.append(main_path.read_bytes())
        yield from main_img
    for p in paks:
        rel = os.path.relpath(p, romfs)
        if not UP.is_pak(p): print(f'{rel}：不是 Unreal pak（尾部没有魔数），跳过'); continue
        try: pk = UP.Pak(p, images=images())
        except Unsupported as e:
            if str(e) == '索引加密':
                red(f'{rel} 索引加密，main 里找不到通过索引 SHA-1 校验的嵌入密钥' if main_path.is_file() else f'{rel} 索引加密，要给 --main <main 已解压镜像> 找游戏自带密钥')
            red(f'{rel}：{e}')
        key = key or pk.key
        with pk:
            try:
                ents = {(pk.mount + n).replace('../../../', ''): h for n, h in pk.files}
                def rd(h):
                    m = pk.entry(h)['method']
                    return pk.read(h, decode=lambda b, k: decompress(m, b, k, oodle))
                arcs = sorted(k for k in ents if k.endswith('.ushaderbytecode'))
                print(f'{rel}：版本 {pk.version}，索引{"加密" if pk.encrypted else "未加密"}，压缩方法 {pk.methods if not pk.legacy or pk.version >= 8 else "旧版标志"}，'
                      f'{len(ents)} 个文件，着色器代码存档 {len(arcs)} 个')
                for k in arcs:
                    n0 = oodle.n; b, n, nc = archive_rewrite(rd(ents[k]), oodle)
                    dst = os.path.join(out, os.path.basename(k)); tmp = dst + '.tmp'
                    open(tmp, 'wb').write(b); os.replace(tmp, dst); got += 1
                    print(f'  {k}：{n} 支着色器（原压缩 {nc} 支，已解{f"，其中 {oodle.n - n0} 支由游戏解码器解出" if oodle.n > n0 else ""}）→ {dst}')
                if not arcs and not pk.legacy:   # 没有共享着色器代码库：着色器内嵌在资源里，逐个读出来收（按内容去重），合成一个存档。这种 LZ4 内嵌布局 UE 4.26 起才有，那时 pak 已是版本 ≥10；
                                                 # 旧版 pak（UE 4.18–4.2x：勇者斗恶龙 XI S、无主之地3）的内嵌着色器是 zlib 流，归 shader_split.py ue_legacy_jobs 用游戏解码器读，这里不重复解一遍
                    seen = {}; nf = 0
                    for k in sorted(e for e in ents if e.lower().endswith(INLINE_EXT)):
                        got_k = inline_entries(rd(ents[k]), oodle)
                        if got_k: nf += 1
                        for fr, b in got_k: seen.setdefault(b, fr)
                    if seen:
                        dst = os.path.join(out, f'ShaderArchive-Inline-{os.path.splitext(os.path.basename(p))[0]}.ushaderbytecode'); tmp = dst + '.tmp'
                        open(tmp, 'wb').write(archive_build([(fr, b) for b, fr in seen.items()])); os.replace(tmp, dst); got += 1
                        print(f'  内嵌布局：{nf} 个资源里共 {len(seen)} 支不同的着色器 → {dst}')
            except Unsupported as e: red(f'{rel}：{e}')
    # IoStore 容器（UE 4.27 / 5 把着色器库放进 .utoc + .ucas，包里一个存档都没有）：同一个产物目录、同一格式（#247）
    ntoc, notes, iogot = iostore_archives(romfs, out, oodle, key, scan_inline=got == 0)
    for n in notes: print(n)
    oodle.close()
    print(f'ue_pak：{len(paks)} 个 pak + {ntoc} 个 IoStore 容器，写出着色器代码存档 {got + iogot} 个（{out}）'
          + (f'；游戏解码器（{oodle.found[0]}）解出 Oodle / LZ5 块 {oodle.n} 个、{oodle.nbytes} 字节' if oodle.n else ''))

if __name__ == '__main__': main()
