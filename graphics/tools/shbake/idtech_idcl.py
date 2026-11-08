# id Tech 7 资源包（*.resources，魔数 IDCL、版本 12；DOOM Eternal，11-02 着色器容器族 A 组）：nxsh_extract.visit 认出后只把着色器条目（类型 renderProgResource）逐条交回 visit。
# 头（0x7C）：'IDCL' u32 版本 12，u32 标志，u32 段数，u64 段长，u64 元数据哈希，+0x20 起 u32 {条目数, 依赖数, 依赖索引数, 字符串索引数, 特殊哈希数, 元数据数}，
#   +0x38 起 u64 {字符串表长, 字符串表偏移, 依赖表偏移, 条目表偏移, 特殊哈希偏移, 依赖索引偏移, 数据区偏移}；
#   字符串表 = u64 个数 + 个数 × u64 偏移 + 0 结尾字符串；字符串索引表（u64）紧跟在依赖索引（u32）之后。
# 条目 0x90 字节：+0x20 字符串索引起点（[类型, 名字]），+0x38 数据偏移，+0x40 存储长，+0x48 原长，+0x70 压缩方式 u8（0 = 不压缩；2 = Oodle Kraken，压缩段以 8C 06 开头）。
# Oodle 由调用方给解码器（nxsh_extract.pkz_oodle：游戏自带 OodleLZ_Decompress 跑在宿主工具模式，同 PKZ / UE pak）；没有宿主时解码器抛错，计「读不了」。
# 依据：公开的 DOOM Eternal 模组工具（EternalModLoader）对 IDCL 的描述 + 11-02 对 DOOM Eternal Switch 版 51 个 .resources 逐个核（renderProgResource 4403 条，全是 Kraken）。
# 着色器条目内层格式（11-02）还没读过（需要游戏解码器解出来才看得到），交回 visit 按相邻 / 容器扫描；扫不出就是 0 支，不猜。
import struct

TYPES = ('renderProgResource',)


def recognize(data):
    return len(data) >= 8 and bytes(data[:4]) == b'IDCL' and struct.unpack_from('<I', data, 4)[0] == 12


def entries(d):
    """→ [(类型, 名字, 数据偏移, 存储长, 原长, 压缩方式)]；任何表越界抛 ValueError"""
    n, _, ndi, nsi = struct.unpack_from('<4I', d, 0x20)
    _, o_str, _, o_ent, _, o_di, _ = struct.unpack_from('<7Q', d, 0x38)
    if o_str + 8 > len(d) or o_ent + 0x90 * n > len(d): raise ValueError('IDCL 条目表 / 字符串表越界')
    ns = struct.unpack_from('<Q', d, o_str)[0]; base = o_str + 8 + 8 * ns; si_at = o_di + 4 * ndi
    if base > len(d) or si_at + 8 * nsi > len(d): raise ValueError('IDCL 字符串索引越界')
    offs = struct.unpack_from(f'<{ns}Q', d, o_str + 8); si = struct.unpack_from(f'<{nsi}Q', d, si_at)
    def s(k):
        if k + 1 > nsi or si[k] >= ns: raise ValueError(f'IDCL 字符串号 {k} 越界')
        a = base + offs[si[k]]; e = d.find(b'\0', a)
        if e < 0: raise ValueError('IDCL 字符串没有结尾')
        return bytes(d[a:e]).decode('latin-1')
    out = []
    for i in range(n):
        e = o_ent + 0x90 * i; k = struct.unpack_from('<Q', d, e + 0x20)[0]
        off, csz, usz = struct.unpack_from('<3Q', d, e + 0x38); how = d[e + 0x70]
        if off + csz > len(d): raise ValueError(f'IDCL 第 {i} 条数据越界')
        out.append((s(k), s(k + 1), off, csz, usz, how))
    return out


def members(d, oodle):
    """着色器条目 → (名字, 原文) 的生成器；oodle(压缩段, 原长) → 原文（游戏解码器）"""
    want = [e for e in entries(d) if e[0] in TYPES]
    def gen():
        for _, nm, off, csz, usz, how in want:
            raw = bytes(d[off:off + csz])
            if how == 0 and csz == usz: yield nm, raw
            elif how == 2:
                out = oodle(raw, usz)
                if out is None or len(out) != usz: raise ValueError(f'IDCL {nm} Oodle 解出长度不符')
                yield nm, out
            else: raise ValueError(f'IDCL {nm} 压缩方式 {how} 不认识')
    return gen()
