"""LZ4 块解压（NSO 段用）：装了 python-lz4 就用它（快），没装用这里的纯 Python 解码（格式公开：字面量长度 / 匹配长度令牌 + 2 字节小端回看距离）。
10-25 #220 入列车红在 mini 的 direct_profile_test「No module named 'lz4'」：本机与 mini 的 Homebrew python3 都没装 lz4，贡献者机器也一样，所以工具不硬依赖 C 扩展。"""


def lz4_block(src, size):
    """src 解成 size 字节；长度对不上 / 回看越界抛 ValueError"""
    try:
        import lz4.block
        return lz4.block.decompress(src, uncompressed_size=size)
    except ImportError:
        pass
    out = bytearray(); i, n = 0, len(src)
    while i < n:
        t = src[i]; i += 1; ln = t >> 4
        if ln == 15:
            while True:
                b = src[i]; i += 1; ln += b
                if b != 255: break
        out += src[i:i + ln]; i += ln
        if i >= n: break
        off = src[i] | src[i + 1] << 8; i += 2; ml = (t & 15) + 4
        if (t & 15) == 15:
            while True:
                b = src[i]; i += 1; ml += b
                if b != 255: break
        if not 0 < off <= len(out): raise ValueError(f'LZ4 块：第 {len(out)} 字节处回看距离 {off} 越界')
        st = len(out) - off
        if off >= ml: out += out[st:st + ml]
        else:
            for k in range(ml): out.append(out[st + k])
    if len(out) != size: raise ValueError(f'LZ4 块：解出 {len(out)} 字节，应为 {size}')
    return bytes(out)
