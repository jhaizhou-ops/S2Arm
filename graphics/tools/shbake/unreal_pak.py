# Unreal .pak 只读——仓库里唯一的 pak 读取实现（11-01 出包线：原先三份 pack/ue_pak.py、translator/uepak.py、graphics/tools/shbake/ue_pak.py 各写一遍，
#   无主之地3 紧凑条目只补进前两份、第三份 98 个 pak 全报「字符串越界」；密钥缓存也只修了一处。现在条目 / 索引 / 密钥 / 解压只在这里，另两处调它）。
#   模块名不叫 ue_pak：pack/ue_pak.py（着色器存档命令行）同名，同一进程里两个都导入时会互相顶掉（oodle_proto_test）。
# 布局（UE 源码 FPakInfo / FPakFile::LoadIndex / FPakEntry::Serialize / DecodePakEntry 的公开布局）：
#   文件尾：魔数 0x5A6F12E1 离文件尾 0x2c（版本 1–7，FPakInfo 44 字节）、0xcc（版本 ≥8，后面 5 个 32 字节压缩方式名）、0xac（UE 4.22 的版本 8：4 个名字）、
#     0xcd（版本 9：SHA-1 后多 1 字节冻结索引标志）或 0xc8（UE5 八方旅人0：最后一个名字 28 字节）；
#     魔数前 1 字节 = 索引加密标志（版本 ≥4 才有，PakFile_Version_IndexEncryption），魔数后：版本 u32、索引偏移 / 长 u64、SHA-1 20、（9）冻结标志、（≥8）压缩方式名
#   版本 10 / 11 索引：挂载点、条目数、路径哈希种子、路径哈希索引（不用）、完整目录索引（偏移 / 长 / SHA-1，与索引同样加密）、编码条目区
#     编码条目：u32 位域（0–5 块大小 >> 11，0x3f = 后跟 u32；6–21 块数；22 加密；23–28 压缩方式号（1 起）；29 / 30 / 31 存储长 / 原长 / 偏移用 u32），
#       数据前重复一份 FPakEntry（53 字节，压缩时 + 4 + 16 × 块数）；单块未加密的块 = 整份存储长；多块或加密时逐块 u32 存储长，加密块按 16 字节对齐
#   版本 1–9 索引：挂载点、条目数，逐条文件名 + FPakEntry。布局不止一种，按「恰好读完索引」认（读完剩下的只能是 < 16 字节的加密补齐：索引开头循环或全 0）：
#     标准：偏移 / 存储长 / 原长 i64、压缩标志 i32、（v1）时间戳 i64、SHA-1 20、（≥3）压缩时块表 i32 + 每块起止 i64、加密 u8、块大小 u32
#     紧凑（无主之地3 / Gearbox，版本 6）：偏移 u64、存储长 / 原长 u32、压缩标志 u8、压缩时块表 u32 + 起止、标志 u8；没有 SHA-1 与块大小（按 UE 缺省 64 KiB）
#     块起止版本 5 前是文件内绝对偏移、5 起相对条目偏移；压缩标志：1 Zlib、2 Gzip、3 LZ5（勇者斗恶龙 XI S）、4 自定（无主之地3 是 Oodle）
#     版本 8 / 9（PakFile_Version_FNameBasedCompressionMethod）：压缩字段换成文件尾名字表的序号（1 起，0 = 不压缩），UE 4.22 的版本 8 是 u8、其余 u32，别的字段同标准布局
#       （BRAVELY DEFAULT Ⅱ：版本 8、5 个名字 Zstd / Zlib）
#   版本 9 冻结索引（bIndexIsFrozen = 1，UE 4.25 / 4.26 把 FPakFile 的内存映像原样写进索引；11-02 普查鬼灭之刃 火之神血风谭、轩辕剑柒）：
#     数组 / 字符串 = {u64 冻结指针, i32 Num, i32 Max}，指针低位 1、值 >> 1 = 相对这个字段自身地址的偏移（0 = 空）；字符串 UTF-16LE、Num 含结尾 0
#     顶层 88 字节：挂载点 @0、条目数组 @16（FPakEntry 80 字节：偏移 / 存储长 / 原长 i64、SHA-1 20、补 4、块表数组 @48（每块 {起, 止} i64，相对条目偏移）、
#       块大小 u32 @64、压缩方式号 u32 @68（1 起，文件尾名字表）、标志 u8 @72（bit0 加密））、目录表 TMap<目录名, FPakDirectory> 的稀疏数组 @32（元素 80 字节：
#       目录名 @0、FPakDirectory = TMap<文件名, i32 条目号> @16（元素 32 字节：文件名 @0、条目号 @16））；稀疏数组 = 元素数组 @0、分配位数组 @16（{指针, 位数, 最大位数}）
#     数据前的条目头与标准布局相同；冻结索引的文件尾 SHA-1 全 0（不记），不能拿来核索引——条目数 = 名字数且每个条目号恰好一个名字才认
# 加密：密钥由调用方给，或从 images（main 的 NSO / 镜像）里找嵌入常量（pak_crypto.find_key，按索引 SHA-1 验证、进程内缓存）；只在内存中。
# 解压：Zlib / Gzip / Zstd 在这里解（Zstd 走 zstd_lib：出包链自带 zstd 旁边的 libzstd，玩家 App 的 Python 3.12 也能解）；其余（LZ4、Oodle、LZ5…）交给调用方的 decode(压缩字节, 本块原长)——游戏自带解码器等；没给就抛 Unsupported。
#   解出总长必须等于索引原长（审计 #846 F-uepak-usz-slice），否则 Corrupt。
# 接口：Pak(路径, key=None, images=()) → .version .legacy .mount .encrypted .key .methods（方式号 1 起对应的名字）
#   .names / .handles（索引顺序，一一对应；名字不含挂载点）、.files（[(名字, 句柄)]，同名都留）、.by_name（名字 → 句柄）、.entry(句柄) → dict(off raw size method encrypted block_size blocks head)、
#   .read(句柄, decode=None) → 字节、.close()。is_pak(路径)、footer(文件, 大小)。Unsupported 是 ValueError，Corrupt 是 Unsupported。
import hashlib, os, struct, zlib
from pak_crypto import aes_ecb, find_key
import zstd_lib
MAGIC = 0x5A6F12E1
LEGACY_METHODS = {1: 'Zlib', 2: 'Gzip', 3: 'LZ5', 4: 'Oodle'}
class Unsupported(ValueError): pass
class Corrupt(Unsupported): pass

def footer(f, size):
    """→ dict(version, back, enc, off, size, digest, methods)；不是 pak → None。back = 魔数离文件尾的字节数"""
    for back in (0x2c, 0xcc, 0xc8, 0xac, 0xcd):
        if size < back + 1: continue
        f.seek(size - back - 1); t = f.read(back + 1)
        if len(t) != back + 1 or struct.unpack_from('<I', t, 1)[0] != MAGIC: continue
        v, off, isz = struct.unpack_from('<IQQ', t, 5)
        if back == 0x2c and not 1 <= v <= 7: continue
        if back in (0xcc, 0xc8) and v < 8 or back == 0xac and v != 8 or back == 0xcd and v != 9: continue
        n0 = 46 if back == 0xcd else 45   # 版本 9：SHA-1 后 1 字节冻结标志，名字表往后挪 1
        names = [t[n0 + 32 * i:n0 + 32 + 32 * i].split(b'\0')[0].decode('latin1') for i in range((back - (n0 - 1) + 31) // 32)] if back != 0x2c else None
        return dict(version=v, back=back, enc=t[0] if v >= 4 else 0, off=off, size=isz, digest=bytes(t[25:45]), methods=names,
                    frozen=t[45] if back == 0xcd else 0, method_u8=back == 0xac)
    return None

def is_pak(path):
    try:
        with open(path, 'rb') as f: return footer(f, os.path.getsize(path)) is not None
    except OSError: return False

class _B:   # 小端读游标；越界 / 结构错误抛 Corrupt
    def __init__(s, b, o=0): s.b, s.o = b, o
    def take(s, fmt):
        try: v = struct.unpack_from(fmt, s.b, s.o)
        except struct.error: raise Corrupt('PAK 索引越界') from None
        s.o += struct.calcsize(fmt); return v if len(v) > 1 else v[0]
    def raw(s, n):
        if n < 0 or s.o + n > len(s.b): raise Corrupt('PAK 索引越界')
        v = s.b[s.o:s.o + n]; s.o += n; return v
    def fstr(s):
        n = s.take('<i')
        if n == 0: return ''
        size = -2 * n if n < 0 else n
        if size > len(s.b) - s.o: raise Corrupt('PAK 字符串越界')
        b = s.raw(size)
        try: return b.decode('utf-16-le')[:-1] if n < 0 else b[:-1].decode('latin1')
        except UnicodeError: raise Corrupt('PAK 字符串编码无效') from None

def _legacy_std(r, ver, method_u8=False):
    off, size, raw, fl = r.take('<qqqB' if method_u8 else '<qqqi')
    if ver == 1: r.take('<q')   # 时间戳
    r.raw(20); head = 24 + (1 if method_u8 else 4) + (8 if ver == 1 else 0) + 20; blocks = []; enc = 0; bs = 65536
    if ver >= 3:
        if fl:
            nb = r.take('<i'); head += 4 + 16 * nb
            if nb < 0: raise Corrupt('PAK 块数无效')
            blocks = [r.take('<qq') for _ in range(nb)]
        enc, bs = r.take('<BI'); head += 5
    elif fl: raise Unsupported(f'pak 版本 {ver} 的压缩条目')   # v1 / v2 的压缩条目没有块表
    return off, raw, size, fl, enc, bs, blocks, head

def _legacy_compact(r, ver, method_u8=False):
    off, size, raw, fl = r.take('<QIIB'); blocks = []
    if fl: blocks = [r.take('<qq') for _ in range(r.take('<I'))]
    enc = r.take('<B')
    return off, raw, size, fl, enc, 65536, blocks, 8 + 4 + 4 + 1 + (4 + 16 * len(blocks) if fl else 0) + 1

class Pak:
    def __init__(s, path, key=None, images=()):
        s.path = path; s.f = open(path, 'rb'); s.fsize = os.path.getsize(path); s.key = key
        try:
            ft = footer(s.f, s.fsize)
            if ft is None: raise Corrupt('PAK 文件尾无效（没有魔数或截断）')   # 调用方先用 is_pak 筛：到这里还认不出 = 坏了
            s.version, s.encrypted = ft['version'], bool(ft['enc']); s.legacy = s.version <= 9
            if ft['frozen'] and s.encrypted: raise Unsupported('pak 版本 9 的冻结索引且加密（文件尾不记索引 SHA-1，找不到能核的密钥）')
            idx = s._index(ft['off'], ft['size'], s.encrypted, ft['digest'], images)
            if ft['frozen']: s._load_frozen(idx, ft['methods'])
            elif s.legacy: s._load_legacy(idx, ft['methods'], ft['method_u8'])
            else:
                if s.version not in (10, 11): raise Unsupported(f'pak 版本 {s.version}')
                s.methods = ft['methods']; s._load_v10(idx, images)
        except (struct.error, IndexError, UnicodeError) as e:
            s.f.close(); raise Corrupt(f'PAK 索引结构或加密数据无效（{e}）') from None
        except Exception:
            s.f.close(); raise
        s.files = list(zip(s.names, s.handles)); s.by_name = dict(s.files); s.ver = s.version   # files：(名字, 句柄) 按索引顺序（同名都留）；by_name：名字 → 句柄（同名取后者）
    def close(s): s.f.close()
    def __enter__(s): return s
    def __exit__(s, *a): s.close()
    def _read(s, off, size):
        if off < 0 or size < 0 or off + size > s.fsize: raise Corrupt('PAK 数据范围越界')
        s.f.seek(off); data = s.f.read(size)
        if len(data) != size: raise Corrupt('PAK 数据截断')
        return data
    def _index(s, off, size, encrypted, digest, images):
        data = s._read(off, size)
        if not encrypted: return data
        if size < 16 or size % 16: raise Corrupt('加密索引长度无效')
        try:
            if s.key is None:
                for image in images:
                    s.key = find_key(image, data, digest)
                    if s.key is not None: break
            if s.key is None: raise Unsupported('索引加密')
            plain = aes_ecb(s.key, data)
        except Unsupported: raise
        except ValueError as e: raise Corrupt(str(e)) from None
        if hashlib.sha1(plain).digest() != digest: raise Corrupt('加密索引 SHA-1 不符')
        return plain
    def _load_v10(s, idx, images):
        r = _B(idx); s.mount = r.fstr(); n = r.take('<i'); r.take('<Q')   # 路径哈希种子
        if r.take('<i'): r.take('<QQ'); r.raw(20)   # 路径哈希索引（不用）
        if not r.take('<i'): raise Unsupported('没有完整目录索引')
        fdo, fds = r.take('<qq'); fd_hash = r.raw(20)
        s.enc = r.raw(r.take('<i'))
        fd = s._index(fdo, fds, s.encrypted, fd_hash, images); d = _B(fd); s.names, s.handles = [], []
        for _ in range(d.take('<i')):
            dn = d.fstr()
            for _ in range(d.take('<i')):
                fn = d.fstr(); eo = d.take('<i')
                if eo >= 0: s.names.append(dn + fn); s.handles.append(eo)   # 负值 = 未编码条目（这个格式下没见到），不认
        if s.encrypted and (n < 0 or len(s.names) != n): raise Corrupt('加密索引条目计数不符')
    def _load_legacy(s, idx, methods=None, method_u8=False):
        s.methods = methods if s.version >= 8 else [LEGACY_METHODS.get(i, f'标志 {i}') for i in range(1, 8)]   # 版本 8 / 9：压缩字段是文件尾名字表的序号
        why = []
        for layout in (_legacy_std, _legacy_compact) if s.version < 8 else (_legacy_std,):
            r = _B(idx)
            try:
                mount = r.fstr(); names, ents = [], []
                for _ in range(r.take('<i')):
                    names.append(r.fstr()); ents.append(layout(r, s.version, method_u8))
            except Corrupt as e: why.append(f'{layout.__name__[1:]}：{e}'); continue
            tail = idx[r.o:]
            if len(tail) < 16 and tail in (idx[:len(tail)], bytes(len(tail))):
                s.mount, s.names, s.handles, s._ents = mount, names, list(range(len(names))), ents; return
            why.append(f'{layout.__name__[1:]}：读完条目还剩 {len(tail)} 字节')
        raise Corrupt(f'旧版 pak（版本 {s.version}）索引的条目布局认不出：' + '；'.join(why))
    def _load_frozen(s, idx, methods):
        """版本 9 冻结索引（布局见文件头）→ 与旧版索引同一形式的条目表（s._ents：偏移、原长、存储长、方式号、加密、块大小、块起止（相对条目）、条目头长）"""
        L = len(idx)
        def ptr(o):
            p = struct.unpack_from('<Q', idx, o)[0]
            if p == 0: return None
            if not p & 1 or not 0 <= o + (p >> 1) <= L: raise Corrupt(f'冻结索引 0x{o:x} 处不是有效的冻结偏移（0x{p:x}）')
            return o + (p >> 1)
        def arr(o):
            n, m = struct.unpack_from('<ii', idx, o + 8)
            if n < 0 or m < n: raise Corrupt(f'冻结索引 0x{o:x} 处数组 Num {n} / Max {m} 无效')
            a = ptr(o)
            if n and a is None: raise Corrupt(f'冻结索引 0x{o:x} 处数组非空却没有数据')
            return a, n
        def fstr(o):
            a, n = arr(o)
            if not n: return ''
            if a + 2 * n > L: raise Corrupt(f'冻结索引 0x{o:x} 处字符串越界')
            t = idx[a:a + 2 * n].decode('utf-16-le')
            if t[-1] != '\0': raise Corrupt(f'冻结索引 0x{o:x} 处字符串没有结尾 0')
            return t[:-1]
        def sparse(o, elem):   # 稀疏数组：已分配元素的地址
            a, n = arr(o); fa, fn = arr(o + 16)
            if fn != n or (n and fa + (n + 7) // 8 > L) or (n and a + elem * n > L): raise Corrupt(f'冻结索引 0x{o:x} 处稀疏数组越界或位数不符')
            return [a + elem * i for i in range(n) if idx[fa + (i >> 3)] >> (i & 7) & 1]
        s.methods = methods; s.mount = fstr(0)
        fa, fn = arr(16)
        if fn and fa + 80 * fn > L: raise Corrupt('冻结索引条目数组越界')
        ents = []
        for i in range(fn):
            o = fa + 80 * i
            off, size, raw = struct.unpack_from('<qqq', idx, o); ba, nb = arr(o + 48)
            bs, meth, flags = struct.unpack_from('<IIB', idx, o + 64)
            if nb and ba + 16 * nb > L: raise Corrupt(f'冻结索引条目 {i} 块表越界')
            blocks = [struct.unpack_from('<qq', idx, ba + 16 * k) for k in range(nb)]
            ents.append((off, raw, size, meth, flags, bs, blocks, 53 + (4 + 16 * nb if meth else 0)))
        names = [None] * fn
        for d in sparse(32, 80):
            dn = fstr(d)
            if not arr(d + 16)[1]: continue
            for e in sparse(d + 16, 32):
                k = struct.unpack_from('<i', idx, e + 16)[0]
                if not 0 <= k < fn or names[k] is not None: raise Corrupt(f'冻结索引目录 {dn} 里的条目号 {k} 越界或重复')
                names[k] = dn + fstr(e)
        if None in names: raise Corrupt(f'冻结索引有 {names.count(None)} 个条目没有名字')
        s.names, s.handles, s._ents = names, list(range(fn)), ents
    def entry(s, h):
        """→ dict(off 条目偏移, raw 原长, size 存储长, method 压缩方式名（'' = 不压缩）, encrypted, block_size, blocks [(相对条目偏移的起点, 存储长)], head 数据前的条目头长)"""
        if s.legacy:
            off, raw, size, fl, enc, bs, blocks, head = s._ents[h]
            blocks = [(a - off, b - a) if s.version < 5 else (a, b - a) for a, b in blocks]
            return dict(off=off, raw=raw, size=size, method=s.methods[fl - 1] if 0 < fl <= len(s.methods) and s.methods[fl - 1] else (f'标志 {fl}' if fl else ''),
                        encrypted=enc & 1, block_size=bs, blocks=blocks, head=head)   # 压缩却没有块表：解出 0 字节，read 按原长不符判 Corrupt
        r = _B(s.enc, h); v = r.take('<I')
        bs = (v & 0x3f) << 11
        if v & 0x3f == 0x3f: bs = r.take('<I')
        nblk, enc, meth = v >> 6 & 0xffff, v >> 22 & 1, v >> 23 & 0x3f
        off = r.take('<I' if v >> 31 & 1 else '<Q'); raw = r.take('<I' if v >> 30 & 1 else '<Q')
        size = r.take('<I' if v >> 29 & 1 else '<Q') if meth else raw
        head = 53 + (4 + 16 * nblk if meth else 0); blocks = []
        if meth:
            if nblk == 1: bs = max(bs, raw)   # 单块文件那一块装下全部原长：编码的块大小只有 6 位、以 2048 为单位（FINAL FANTASY RESONANCE 记 0，GTA3 最终版记下取整）
            if nblk == 1 and not enc: blocks = [(head, size)]
            else:
                a = head
                for _ in range(nblk): n = r.take('<I'); blocks.append((a, n)); a += (n + 15) & ~15 if enc else n
        return dict(off=off, raw=raw, size=size, method=(s.methods[meth - 1] if meth <= len(s.methods) else f'方式 {meth}') if meth else '',
                    encrypted=enc, block_size=bs, blocks=blocks, head=head)
    def _block(s, start, size, enc):
        if enc and s.key is None: raise Unsupported('条目加密')
        data = s._read(start, (size + 15) & ~15 if enc else size)
        return aes_ecb(s.key, data)[:size] if enc else data
    def read(s, h, decode=None):
        e = s.entry(h)
        if not e['method']:
            data = s._block(e['off'] + e['head'], e['size'], e['encrypted'])[:e['raw']]
        else:
            m = e['method']
            if m in ('Zlib', 'Gzip'): dec = lambda b, k: zlib.decompress(b, 15 + 32)   # zlib / gzip 头由 zlib 自己分
            elif m == 'Zstd': dec = lambda b, k: zstd_lib.decompress(b)
            elif decode is not None: dec = decode
            else: raise Unsupported(f'压缩方式 {m}')
            out, left = [], e['raw']
            for a, n in e['blocks']:
                k = min(left, e['block_size']); out.append(dec(s._block(e['off'] + a, n, e['encrypted']), k)); left -= k
            data = b''.join(out)
        if len(data) != e['raw']: raise Corrupt(f'条目解压长度 {len(data)} 与索引原长 {e["raw"]} 不符')
        return data


def oodle_frames(d, at, n, raw):
    """Whether the n bytes at d[at:] are laid out as one Oodle stream of raw bytes (the new LZ formats: each 256 KiB block = 2-byte header (low nibble 0xC, bits 4-5 zero, bit 6 stored,
    second byte the compressor + bit 7 checksums), then a stored block's bytes, or a 3-byte big-endian quantum header (low 18 bits = compressed length - 1; all ones = a special block
    of 1 byte (bits 18+ = 1)), 3 checksum bytes if flagged, and the compressed bytes); the blocks must use one compressor and end exactly at n. The game's decoder can Break on a stream
    that is not one (Borderlands 3: 1120 bytes said to hold 6.6 MB), so a candidate is checked here first"""
    p, end, left, kind = at, at + n, raw, None
    while left > 0:
        if p + 2 > end: return False
        b0, b1 = d[p], d[p + 1]
        if b0 & 0xf != 0xc or b0 & 0x30 or kind not in (None, b1 & 0x7f): return False
        kind, ck, p, blk = b1 & 0x7f, b1 >> 7, p + 2, min(left, 0x40000)
        if b0 & 0x40: p += blk
        else:
            if p + 3 > end: return False
            v = int.from_bytes(d[p:p + 3], 'big')
            if v & 0x3ffff == 0x3ffff:
                if v >> 18 != 1: return False
                p += 4
            else:
                c = (v & 0x3ffff) + 1
                if c > blk: return False
                p += 3 + 3 * ck + c
        left -= blk
    return p == end

OODLE_HEADS = (b'\x8c\x0a', b'\x8c\x06', b'\x8c\x0c', b'\x8c\x05')   # Oodle 块头：Mermaid 0a、Kraken 0c、Selkie 05、Leviathan 06 / 0b 以外的两字节同族
def unpack_shader(b, raw, oodle=None):
    """着色器代码存档里一支压缩的着色器 → 原长 raw 的字节：Oodle 块头交给游戏自带解码器 oodle(压缩字节, 原长)，其余试 LZ4 块、zlib。
    出包抽取 pack/ue_pak.py 与直连抽取 nxsh_extract.scan_ue_archive 共用这一份（11-02 霍格沃茨之遗：后者原先只认 LZ4，Oodle 支整份判红）"""
    if b[:2] in OODLE_HEADS:
        if oodle is None: raise Unsupported('着色器是 Oodle 压缩（只有游戏自带解码器能解）')
        b = oodle(b, raw)
    else:
        try:
            import lz4.block; b = lz4.block.decompress(b, uncompressed_size=raw)
        except Exception:
            try: b = zlib.decompress(b)
            except Exception: raise Unsupported('着色器压缩格式认不出（不是 LZ4 / zlib）')
    if len(b) != raw: raise Unsupported(f'解压后长 {len(b)} ≠ 原长 {raw}')
    return b


# 无版本号的旧布局（UE 4.2x 早期，Bloodstained 1.03：pak 版本 4，ShaderArchive-GLSL_SWITCH.ushaderbytecode）：u32 条数 n，n 个 32 字节条目
#   {着色器哈希 20、u32 偏移、u32 存储长、u32 原长}（没有阶段字节），代码区紧跟条目、偏移相对代码区。认定 = 自洽：条目区装得下、偏移从 0 起首尾相接、正好到文件尾
#   （版本 2 的首字 2 + 两组 20 字节哈希排不成这样）。阶段取 LSLG 记录自己的标签（shader_split.ue_shaders 也按它核阶段字节）。
#   出包抽取 pack/ue_pak.py 与直连抽取 nxsh_extract.scan_ue_archive 共用这一份（11-02 普查血污：后者原先只认版本 2，报「着色器存档版本不支持」）
LSLG_FREQ = {b'SV': 0, b'SH': 1, b'SD': 2, b'SP': 3, b'SG': 4, b'SC': 5}   # 标签 → EShaderFrequency（uepak.FREQ 的反表）
def legacy_layout(d):
    if len(d) < 4: return None
    n = struct.unpack_from('<I', d, 0)[0]; base = 4 + 32 * n
    if n == 0 or base > len(d): return None
    ents = [struct.unpack_from('<20sIII', d, 4 + 32 * i)[1:] for i in range(n)]
    at = 0
    for off, size, raw in ents:
        if off != at or size == 0 or size > raw: return None
        at += size
    return (base, ents) if base + at == len(d) else None

# 版本 1（UE 4.2x 中期，Minecraft Dungeons 1.16：pak 里 ShaderArchive-*-GLSL_SWITCH.ushaderbytecode 首字 1）：u32 版本 1、u32 支数 n，n 个 37 字节条目
#   {SHA-1 20, u64 偏移（相对代码区）, u32 存储长, u32 原长, u8 阶段}，之后直接是代码区；各支首尾相接、代码区末尾 = 文件尾（压缩是 zlib，unpack_shader 认）。
#   → (代码区起点, [(偏移, 存储长, 原长, 阶段)])，不是这个布局 → None。出包 pack/ue_pak.py 与 S2Arm 抽取 nxsh_extract.scan_ue_archive 共用（11-02 普查 Minecraft Dungeons）
def v1_layout(d):
    if len(d) < 8 or struct.unpack_from('<I', d, 0)[0] != 1: return None
    n = struct.unpack_from('<I', d, 4)[0]; base = 8 + 37 * n
    if n == 0 or base > len(d): return None
    ents = [struct.unpack_from('<20sQIIB', d, 8 + 37 * i)[1:] for i in range(n)]
    at = 0
    for off, size, raw, fr in ents:
        if off != at or size == 0 or size > raw or fr > 5: return None
        at += size
    return (base, ents) if base + at == len(d) else None
