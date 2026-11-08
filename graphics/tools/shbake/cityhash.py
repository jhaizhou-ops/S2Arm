# CityHash64 v1.1 纯 Python（UE4 Core/Private/Hash/CityHash.cpp 同版本；10-21 pair 与 Google 参考实现逐值对拍：""、"hello"、72 字节串、带种子两例）
import struct
M = 0xffffffffffffffff
k0, k1, k2 = 0xc3a5c85c97cb3127, 0xb492b66fbe98f273, 0x9ae16a3b2f90404f
def f64(s, i): return struct.unpack_from('<Q', s, i)[0]
def f32(s, i): return struct.unpack_from('<I', s, i)[0]
def rot(v, s): return v if s == 0 else ((v >> s) | (v << (64 - s))) & M
def smix(v): return (v ^ (v >> 47)) & M
def h128to64(u, v):
    kMul = 0x9ddfea08eb382d69
    a = ((u ^ v) * kMul) & M; a ^= a >> 47
    b = ((v ^ a) * kMul) & M; b ^= b >> 47; b = (b * kMul) & M
    return b
def hlen16(u, v, mul=None):
    if mul is None: return h128to64(u, v)
    a = ((u ^ v) * mul) & M; a ^= a >> 47
    b = ((v ^ a) * mul) & M; b ^= b >> 47; return (b * mul) & M
def hlen0to16(s):
    n = len(s)
    if n >= 8:
        mul = (k2 + n * 2) & M; a = (f64(s, 0) + k2) & M; b = f64(s, n - 8)
        c = (rot(b, 37) * mul + a) & M; d = ((rot(a, 25) + b) * mul) & M
        return hlen16(c, d, mul)
    if n >= 4:
        mul = (k2 + n * 2) & M; a = f32(s, 0)
        return hlen16((n + (a << 3)) & M, f32(s, n - 4), mul)
    if n > 0:
        a, b, c = s[0], s[n >> 1], s[n - 1]
        y = (a + (b << 8)) & 0xffffffff; z = (n + (c << 2)) & 0xffffffff
        return (smix(((y * k2) ^ (z * k0)) & M) * k2) & M
    return k2
def hlen17to32(s):
    n = len(s); mul = (k2 + n * 2) & M
    a = (f64(s, 0) * k1) & M; b = f64(s, 8); c = (f64(s, n - 8) * mul) & M; d = (f64(s, n - 16) * k2) & M
    return hlen16((rot((a + b) & M, 43) + rot(c, 30) + d) & M, (a + rot((b + k2) & M, 18) + c) & M, mul)
def wh32(w, x, y, z, a, b):
    a = (a + w) & M; b = rot((b + a + z) & M, 21); c = a; a = (a + x) & M; a = (a + y) & M; b = (b + rot(a, 44)) & M
    return ((a + z) & M, (b + c) & M)
def wh(s, i, a, b): return wh32(f64(s, i), f64(s, i + 8), f64(s, i + 16), f64(s, i + 24), a, b)
def hlen33to64(s):
    n = len(s); mul = (k2 + n * 2) & M
    a = (f64(s, 0) * k2) & M; b = f64(s, 8); c = f64(s, n - 24); d = f64(s, n - 32); e = (f64(s, 16) * k2) & M; f = (f64(s, 24) * 9) & M
    g = f64(s, n - 8); h = (f64(s, n - 16) * mul) & M
    u = (rot((a + g) & M, 43) + (rot(b, 30) + c) * 9) & M; v = (((a + g) ^ d) + f + 1) & M
    w = (bswap(((u + v) * mul) & M) + h) & M; x = (rot((e + f) & M, 42) + c) & M
    y = ((bswap(((v + w) * mul) & M) + g) * mul) & M; z = (e + f + c) & M
    a = (bswap(((x + z) * mul + y) & M) + b) & M; b = (smix(((z + a) * mul + d + h) & M) * mul) & M
    return (b + x) & M
def bswap(v): return int.from_bytes(v.to_bytes(8, 'little'), 'big')
def city64(s):
    n = len(s)
    if n <= 32: return hlen0to16(s) if n <= 16 else hlen17to32(s)
    if n <= 64: return hlen33to64(s)
    x = f64(s, n - 40); y = (f64(s, n - 16) + f64(s, n - 56)) & M; z = h128to64((f64(s, n - 48) + n) & M, f64(s, n - 24))
    v = wh(s, n - 64, n, z); w = wh(s, n - 32, (y + k1) & M, x)
    x = (x * k1 + f64(s, 0)) & M
    m = (n - 1) & ~63; i = 0
    while True:
        x = (rot((x + y + v[0] + f64(s, i + 8)) & M, 37) * k1) & M
        y = (rot((y + v[1] + f64(s, i + 48)) & M, 42) * k1) & M
        x ^= w[1]; y = (y + v[0] + f64(s, i + 40)) & M
        z = (rot((z + w[0]) & M, 33) * k1) & M
        v = wh(s, i, (v[1] * k1) & M, (x + w[0]) & M); w = wh(s, i + 32, (z + w[1]) & M, (y + f64(s, i + 16)) & M)
        z, x = x, z
        i += 64; m -= 64
        if m == 0: break
    return h128to64((h128to64(v[0], w[0]) + smix(y) * k1 + z) & M, (h128to64(v[1], w[1]) + x) & M)
def city64_seed(s, seed): return city64_seeds(s, k2, seed)
def city64_seeds(s, s0, s1): return h128to64((city64(s) - s0) & M, s1)
