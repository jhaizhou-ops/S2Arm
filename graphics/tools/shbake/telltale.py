# Telltale Tool 归档（*.ttarch2，Minecraft: Story Mode 第一 / 二季，11-02 着色器容器族 A 组）：nxsh_extract.visit 认出后逐成员再走 visit。
# 着色器在 <游戏>_Shaders_mem.ttarch2 里的 *.t3fxpack 成员中，每支排成 [u32 机器码长][机器码][u32 控制段长][控制段]，
#   由 scan_adj 的「两段都带长度前缀」分支配对；本文件只管把归档解开（原先 0 支：ZCTT 外壳是裸 deflate 分块，zlib 流扫描认不出）。
# 外壳（文件开头 4 字节）：
#   'NCTT'：u64 内层长度 L，随后 L 字节就是内层；
#   'ZCTT'：u32 块原长 B，u32 块数 n，(n + 1) 个 u64 块边界（从外壳文件开头算），每块一条裸 deflate（窗口 -15），除末块外每块恰好解出 B 字节；拼起来是内层；
#   'ECTT'（Blowfish 加密）不解：返回 None 由调用方计数，不猜。
# 内层 '4ATT'：u32 名字区长 S，u32 文件数 n，n × 28 字节 {u64 名字 CRC64, u64 偏移, u32 长度, u32 0, u16 名字块号, u16 块内偏移}，
#   名字区 S 字节（每 0x10000 一块，名字以 0 结尾），数据区紧随名字区、偏移从数据区起点算。成员自己还可以再套一层外壳（t3fxpack 是 ZCTT）。
# 依据：公开的 TTArchive2 格式说明（ttarchext 等社区工具）+ 11-02 对 MCSM 84 个 ttarch2 逐个核过。任何字段越界 / 不自洽抛 ValueError。
import struct, zlib

SHELLS = (b'NCTT', b'ZCTT', b'ECTT')


def recognize(data):
    return bytes(data[:4]) in SHELLS + (b'4ATT',)


def unshell(d):
    """外壳 → 内层字节；ECTT（加密）返回 None"""
    m = bytes(d[:4])
    if m == b'NCTT':
        n = struct.unpack_from('<Q', d, 4)[0]
        if 12 + n > len(d): raise ValueError(f'NCTT 内层长 {n} 超出文件 {len(d)}')
        return bytes(d[12:12 + n])
    if m == b'ZCTT':
        bs, n = struct.unpack_from('<II', d, 4)
        if not (0 < bs <= 1 << 24) or 12 + 8 * (n + 1) > len(d): raise ValueError(f'ZCTT 块表越界（块长 {bs}，块数 {n}）')
        b = struct.unpack_from(f'<{n + 1}Q', d, 12)
        if b[0] != 12 + 8 * (n + 1) or b[-1] > len(d) or any(b[i] > b[i + 1] for i in range(n)): raise ValueError('ZCTT 块边界不自洽')
        out = []
        for i in range(n):
            z = zlib.decompressobj(-15); o = z.decompress(bytes(d[b[i]:b[i + 1]]))
            if (i < n - 1 and len(o) != bs) or len(o) > bs: raise ValueError(f'ZCTT 第 {i} 块解出 {len(o)} 字节（块长 {bs}）')
            out.append(o)
        return b''.join(out)
    if m == b'ECTT': return None
    raise ValueError(f'不是 Telltale 外壳：{m!r}')


def tta4_files(a):
    """内层 4ATT → [(名字, 内容)] 的生成器；目录先整个核完（越界就抛、一个都不交出），内容逐个切出（大归档不一次复制两份）"""
    if bytes(a[:4]) != b'4ATT': raise ValueError(f'不是 4ATT：{bytes(a[:4])!r}')
    S, n = struct.unpack_from('<II', a, 4)
    names = 12 + 28 * n; data = names + S; ents = []
    if data > len(a): raise ValueError(f'4ATT 目录越界（{n} 个文件，名字区 {S}）')
    for i in range(n):
        _, off, sz, _, blk, no = struct.unpack_from('<QQIIHH', a, 12 + 28 * i)
        p = names + blk * 0x10000 + no; e = a.find(b'\0', p, data)
        if not (names <= p < data) or e < 0 or data + off + sz > len(a): raise ValueError(f'4ATT 第 {i} 个文件越界')
        ents.append((bytes(a[p:e]).decode('latin-1'), data + off, sz))
    return ((nm, bytes(a[o:o + sz])) for nm, o, sz in ents)


def members(data, oodle=None):
    """nxsh_extract.visit 的接口：外壳 → [('', 内层)]（内层再进 visit 认 4ATT）；4ATT → [(名字, 内容)]；ECTT → None"""
    if bytes(data[:4]) == b'4ATT': return tta4_files(data)
    inner = unshell(data)
    return None if inner is None else [('', inner)]
