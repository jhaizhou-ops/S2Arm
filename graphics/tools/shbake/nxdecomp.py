# 通用解压表（nxsh_extract 用，10-22 第 3 项）：每种格式 = 认法（开头魔数 / 帧魔数）+ 解法 + 自洽核对；解不开或不自洽一律返回 None，不猜。
#   整文件（叶子开头就是这种格式）：gzip / xz / LZMA（.lzma 独立格式）/ LZ4 帧 / Yay0 / 任天堂 LZ10 / LZ11 / BLZ（倒序 LZ，尾部 8 字节头）
#   内嵌流（认不出容器的顶层文件里按魔数找）：gzip / xz / LZ4 帧——与 zstd 帧、zlib 流、CRILAYLA 一样解开后再走 visit
#   许可：gzip / xz / LZMA 用 Python 标准库；LZ4 帧用 python-lz4（BSD-3）；Yay0 / LZ10 / LZ11 / BLZ 按公开格式手写（无第三方代码）。
#   Oodle（Kraken / Mermaid / Selkie / Leviathan）不在表里：没有魔数，只能由知道它的容器（如 UE pak 的压缩方式字段）点名调用 oodle()；
#     解码器走插件 NXSH_OODLE=<动态库>（如自行编译的 ooz，GPL-3.0，不进仓库），没有就报「Oodle 插件缺」
import os, zlib, lzma, struct

MAX_OUT = 512 << 20   # 单段解压上限（防坏数据把内存吃满）

def gzip_dec(b, i=0):
    """b[i:] 起一个 gzip 成员 → (内容, 压缩长度)；头校验 + 整段 deflate + CRC32 / ISIZE 都由 zlib 核"""
    if b[i:i + 3] != b'\x1f\x8b\x08': return None
    d = zlib.decompressobj(31)
    try: out = d.decompress(bytes(b[i:i + MAX_OUT]), MAX_OUT)
    except zlib.error: return None
    if not d.eof or not out: return None
    return out, min(len(b) - i, MAX_OUT) - len(d.unused_data)

def xz_dec(b, i=0):
    if b[i:i + 6] != b'\xfd7zXZ\x00': return None
    d = lzma.LZMADecompressor(lzma.FORMAT_XZ)
    try: out = d.decompress(bytes(b[i:i + MAX_OUT]), MAX_OUT)
    except lzma.LZMAError: return None
    if not d.eof or not out: return None
    return out, min(len(b) - i, MAX_OUT) - len(d.unused_data)

def lzma_alone_dec(b):
    """.lzma 独立格式：属性字节 + 字典大小 u32 + 原长 u64（全 F = 未知）；只认整文件、属性 < 225、字典 2^n 或 2^n+2^(n-1)"""
    if len(b) < 13 or b[0] >= 225: return None
    dsz, usz = struct.unpack_from('<IQ', b, 1)
    if dsz < 4096 or (dsz & (dsz - 1) and dsz & (dsz - 1) & ((dsz & (dsz - 1)) - 1)): return None
    if usz != 0xFFFFFFFFFFFFFFFF and usz > MAX_OUT: return None
    try: out = lzma.LZMADecompressor(lzma.FORMAT_ALONE).decompress(bytes(b), MAX_OUT)
    except lzma.LZMAError: return None
    if usz != 0xFFFFFFFFFFFFFFFF and len(out) != usz: return None
    return out or None

def lz4f_dec(b, i=0):
    if b[i:i + 4] != b'\x04\x22\x4d\x18': return None
    try:
        import lz4.frame
        d = lz4.frame.LZ4FrameDecompressor(); out = d.decompress(bytes(b[i:i + MAX_OUT]), MAX_OUT)
    except Exception: return None
    if not d.eof or not out: return None
    return out, min(len(b) - i, MAX_OUT) - len(d.unused_data or b'')   # python-lz4 解完整帧、后面没有多余字节时 unused_data 是 None

def yay0_dec(b):
    """Yay0（任天堂）：'Yay0' 原长 u32 BE、回指表偏移 u32、字面量表偏移 u32；位流 32 位一组，1 = 字面量、0 = 回指（16 位：长度 4 位 + 距离 12 位，长度 0 再读 1 字节 + 18）"""
    if b[:4] != b'Yay0' or len(b) < 16: return None
    usz, lo, co = struct.unpack_from('>III', b, 4)
    if usz > MAX_OUT or not 16 <= lo <= co <= len(b): return None
    out = bytearray(); mp = 16; bits = 0; nb = 0
    try:
        while len(out) < usz:
            if nb == 0: bits = struct.unpack_from('>I', b, mp)[0]; mp += 4; nb = 32
            if bits & 0x80000000: out.append(b[co]); co += 1
            else:
                v = struct.unpack_from('>H', b, lo)[0]; lo += 2; dist = (v & 0xfff) + 1; n = v >> 12
                if n == 0: n = b[co] + 18; co += 1
                else: n += 2
                if dist > len(out): return None
                for _ in range(n): out.append(out[-dist])
            bits = (bits << 1) & 0xffffffff; nb -= 1
    except (IndexError, struct.error): return None
    return bytes(out[:usz])

def lz1x_dec(b):
    """任天堂 LZ10（0x10）/ LZ11（0x11）：头 1 字节类型 + 3 字节原长（为 0 时再读 4 字节）；只认解出长度正好 = 原长、输入用完（允许 3 字节对齐填充）"""
    if len(b) < 8 or b[0] not in (0x10, 0x11): return None
    t = b[0]; usz = b[1] | b[2] << 8 | b[3] << 16; p = 4
    if usz == 0: usz = struct.unpack_from('<I', b, 4)[0]; p = 8
    if usz == 0 or usz > MAX_OUT or usz > len(b) * 9: return None
    out = bytearray()
    try:
        while len(out) < usz:
            flags = b[p]; p += 1
            for k in range(8):
                if len(out) >= usz: break
                if not flags & (0x80 >> k): out.append(b[p]); p += 1; continue
                if t == 0x10:
                    v = b[p] << 8 | b[p + 1]; p += 2; n = (v >> 12) + 3; d = (v & 0xfff) + 1
                else:
                    x = b[p] >> 4
                    if x == 0: n = ((b[p] & 0xf) << 4 | b[p + 1] >> 4) + 0x11; d = ((b[p + 1] & 0xf) << 8 | b[p + 2]) + 1; p += 3
                    elif x == 1: n = ((b[p] & 0xf) << 12 | b[p + 1] << 4 | b[p + 2] >> 4) + 0x111; d = ((b[p + 2] & 0xf) << 8 | b[p + 3]) + 1; p += 4
                    else: n = x + 1; d = ((b[p] & 0xf) << 8 | b[p + 1]) + 1; p += 2
                if d > len(out): return None
                for _ in range(n): out.append(out[-d])
    except IndexError: return None
    if len(out) != usz or len(b) - p > 3: return None
    return bytes(out)

def blz_dec(b):
    """BLZ（倒序 LZ，3DS / Switch 模块常见）：尾部 8 字节 = 压缩段长 u24 + 头长 u8 + 原长增量 u32；从尾往前解。只认头长 8–11、段长 ≤ 文件长"""
    if len(b) < 12: return None
    enc_len = b[-8] | b[-7] << 8 | b[-6] << 16; hdr = b[-5]; inc = struct.unpack_from('<I', b, len(b) - 4)[0]
    if not 8 <= hdr <= 11 or enc_len > len(b) or enc_len < hdr or len(b) + inc > MAX_OUT: return None
    pre = bytes(b[:len(b) - enc_len]); src = b[len(b) - enc_len:len(b) - hdr]
    out = bytearray(len(src) + inc); op = len(out); sp = len(src)
    try:
        while op > 0:
            sp -= 1; flags = src[sp]
            for k in range(8):
                if op <= 0: break
                if not flags & (0x80 >> k):
                    sp -= 1; op -= 1; out[op] = src[sp]
                else:
                    sp -= 2; v = src[sp] | src[sp + 1] << 8; n = (v >> 12) + 3; d = (v & 0xfff) + 3
                    for _ in range(n):
                        if op <= 0: break
                        op -= 1
                        if op + d >= len(out): return None
                        out[op] = out[op + d]
            if sp < 0: return None
    except IndexError: return None
    if sp != 0: return None
    return pre + bytes(out)

def head(b):
    """叶子开头就是某种压缩格式 → (格式名, 解开的内容)；认不出 → None"""
    m = bytes(b[:6])
    if m[:3] == b'\x1f\x8b\x08': r = gzip_dec(b); return ('gzip', r[0]) if r else None
    if m == b'\xfd7zXZ\x00': r = xz_dec(b); return ('xz', r[0]) if r else None
    if m[:4] == b'\x04\x22\x4d\x18': r = lz4f_dec(b); return ('LZ4 帧', r[0]) if r else None
    if m[:4] == b'Yay0': r = yay0_dec(b); return ('Yay0', r) if r else None
    if m[:1] in (b'\x10', b'\x11'): r = lz1x_dec(b); return (f'LZ{m[0]:x}', r) if r else None
    if m[:1] == b'\x5d' and m[1:5] != b'\0\0\0\0': r = lzma_alone_dec(b); return ('LZMA', r) if r else None
    return None

STREAMS = ((b'\x1f\x8b\x08', 'gzip', gzip_dec), (b'\xfd7zXZ\x00', 'xz', xz_dec), (b'\x04\x22\x4d\x18', 'LZ4 帧', lz4f_dec))

_oo = None
def oodle(src, usz):
    """Oodle 一段（容器点名用）：NXSH_OODLE 插件的 Kraken_Decompress(src, n, dst, usz) 约定（ooz 的导出名）；没插件抛 RuntimeError"""
    global _oo
    import ctypes
    if _oo is None:
        lib = os.environ.get('NXSH_OODLE')
        if not lib: raise RuntimeError('Oodle 插件缺（NXSH_OODLE 没设）')
        _oo = ctypes.CDLL(lib); _oo.Kraken_Decompress.restype = ctypes.c_int
        _oo.Kraken_Decompress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
    dst = ctypes.create_string_buffer(usz + 64); r = _oo.Kraken_Decompress(bytes(src), len(src), dst, usz)
    return dst.raw[:usz] if r == usz else None
