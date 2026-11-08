#!/usr/bin/env python3
# 扁平 CASC 归档（暴雪游戏 Switch 版：romfs/data 下 build_manifest.psv + <chunk>-<archive>.data）的条目读取，通用容器层之一（同 Yaz0 / SARC / zstd）。
# 清单每行给条目在归档里的位置（EKey 末 7 字节 = chunk / archive / 40 位偏移）、编码长度与编码方式：n 原样、z 裸 zlib、b:… 分块 BLTE（N / Z / F 嵌套）。
# 解码失败一律抛异常，不回半截数据。取自小菠萝 xbl/data/reference/tools/swcasc.py（同一项目），改成按目录传参。
import os, struct, zlib


def entries(d):
    """[(路径, chunk, archive, 偏移, 编码长度, 原长, 编码)]；编码 n 原样 / z 裸 zlib / b:… 分块 BLTE"""
    out = []
    with open(os.path.join(d, 'build_manifest.psv'), encoding='utf-8', errors='replace') as f:
        f.readline()
        for line in f:
            if line.startswith('##'): continue
            c = line.rstrip('\n').split('|')
            if len(c) < 11: continue
            ek = bytes.fromhex(c[6]); t = ek[9:]
            if len(t) != 7 or (t[0], t[1]) != (int(c[2]), int(c[3])): raise ValueError('EKey 定位与清单列不一致：' + c[9])
            out.append((c[9], t[0], t[1], int.from_bytes(t[2:7], 'big'), int(c[7]), int(c[5]), c[8]))
    return out

def _block(b):
    m, body = b[:1], b[1:]
    if m == b'N': return body
    if m == b'Z': return zlib.decompress(body)
    if m == b'F': return blte(body)
    raise ValueError('BLTE 块模式 %r 不支持' % m)

def blte(b):
    if b[:4] != b'BLTE': raise ValueError('不是 BLTE')
    hs = struct.unpack_from('>I', b, 4)[0]
    if hs == 0: return _block(b[8:])
    if not 12 <= hs <= len(b): raise ValueError('BLTE 头长度越界')
    n = int.from_bytes(b[9:12], 'big'); p = 12; o = hs; out = []
    if hs != 12 + 24 * n: raise ValueError('BLTE 头长度与块表不符')
    for _ in range(n):
        es, ds = struct.unpack_from('>II', b, p); p += 24
        if es > len(b) - o: raise ValueError('BLTE 块编码长度越界')
        x = _block(b[o:o + es]); o += es
        if len(x) != ds: raise ValueError('BLTE 块解出长度不符')
        out.append(x)
    return b''.join(out)

def read(d, e):
    path, ch, ar, off, es, cs, enc = e
    with open(os.path.join(d, '%02d-%08d.data' % (ch, ar)), 'rb') as f: f.seek(off); raw = f.read(es)
    if len(raw) != es: raise IOError('读不满：' + path)
    x = raw if enc == 'n' else zlib.decompress(raw) if enc == 'z' else blte(raw) if enc.startswith('b:') else None
    if x is None: raise ValueError('编码 %r 不支持：%s' % (enc, path))
    if len(x) != cs: raise ValueError('解出长度 %d 与清单 %d 不符：%s' % (len(x), cs, path))
    return x
