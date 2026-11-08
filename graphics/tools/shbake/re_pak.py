# RE 引擎 .pak（魔数 KPKA）只读（nxsh_extract.py 用）：读条目表、按补丁链解出「游戏实际会读的那一版」文件、解压条目。
# 怪猎崛起（re_chunk_000.pak + re_chunk_000.pak.patch_001…017.pak，KPKA 4.0、特性位 0）10-21 起用。
# 布局：头 16 字节 = 魔数 + 主版本 u8 + 次版本 u8 + 特性位 u16 + 条目数 u32 + 校验 u32；随后条目数 × 48 字节
#   {路径哈希低 u32（小写 UTF-16 路径的 murmur3）, 高 u32（大写）, 数据偏移 i64, 存储长 i64, 原长 i64, 属性 i64（低 4 位 = 压缩：0 原样 / 1 deflate / 2 zstd）, 校验 u64}。
# 补丁链：<基名>.pak 先读，<基名>.pak.patch_<号>.pak 按号升序后读，同一路径哈希后读的盖掉先读的（引擎打补丁就是这样换文件的）。
#   10-21 怪猎：18 个 pak 共 12.7 万条、9.2 万个路径，3.5 万条是被后续补丁换掉的旧版；旧版着色器游戏读不到，不该进包（旧做法整包盲扫 zstd 帧，旧版也配出程序）。
# 特性位非 0（条目表加密等）/ 主版本不是 4 / 不认识的压缩方式一律抛 Unsupported，由调用方计数报出，不猜。
import os, re, struct, zlib
class Unsupported(Exception): pass
def is_pak(path):
    try:
        with open(path, 'rb') as f: return f.read(4) == b'KPKA'
    except OSError: return False
def entries(path):
    """[(路径哈希 u64 = 高 << 32 | 低, 偏移, 存储长, 原长, 属性)]"""
    with open(path, 'rb') as f:
        h = f.read(16)
        if h[:4] != b'KPKA': raise Unsupported('不是 KPKA')
        maj, mnr, feat, n = struct.unpack_from('<BBHI', h, 4)
        if maj != 4 or feat != 0: raise Unsupported(f'KPKA {maj}.{mnr} 特性位 {feat:#x}')
        E = f.read(n * 48)
    if len(E) != n * 48: raise Unsupported('条目表截断')
    out = []
    for i in range(n):
        lo, hi, off, csz, usz, attr, _ = struct.unpack_from('<IIqqqqQ', E, i * 48)
        out.append((hi << 32 | lo, off, csz, usz, attr))
    return out
_PATCH = re.compile(r'^(.*\.pak)\.patch_(\d+)\.pak$', re.I)
def chains(paths):
    """把一批 KPKA 文件按补丁链分组：{基名: [基础包, 补丁 1, 补丁 2…]}（补丁按号升序；只有补丁没有基础包的也成一组）"""
    g = {}
    for p in paths:
        m = _PATCH.match(os.path.basename(p))
        base, no = (m.group(1), int(m.group(2))) if m else (os.path.basename(p), -1)
        g.setdefault(os.path.join(os.path.dirname(p), base), []).append((no, p))
    return {b: [p for _, p in sorted(v)] for b, v in sorted(g.items())}
def resolve(chain):
    """补丁链上每个路径哈希取最后一版：[(pak 路径, 路径哈希, 偏移, 存储长, 原长, 属性)]，以及被盖掉的旧版条数"""
    last = {}; shadowed = 0
    for p in chain:
        for h, off, csz, usz, attr in entries(p):
            if h in last: shadowed += 1
            last[h] = (p, h, off, csz, usz, attr)
    return list(last.values()), shadowed
def read(f, off, csz, usz, attr):
    """f = 已打开的 pak 文件对象"""
    f.seek(off); raw = f.read(csz)
    if len(raw) != csz: raise ValueError('条目越过文件尾')
    c = attr & 0xf
    if c == 0: d = raw
    elif c == 1: d = zlib.decompress(raw, -15)
    elif c == 2:
        import nxsh_extract
        d = nxsh_extract.zstd_dec(raw)
    else: raise Unsupported(f'压缩方式 {c}')
    if len(d) != usz: raise ValueError('解压长度与条目表不符')
    return d

