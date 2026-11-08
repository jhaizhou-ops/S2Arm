#!/usr/bin/env python3
"""Game Freak「Trinity」容器只读（宝可梦传说 Z-A 的 arc/data.trpfs + data.trpfd）。

格式事实来自上游参考实现（MIT，仓库内 translator/shader_split.py 的 trpfs_jobs / trinity_shaders，上游 86d9ba12）：
  · data.trpfd 与 data.trpfs 都是 FlatBuffers。
  · 描述表（.trpfd）根表：0 文件哈希 [u64]、1 包名 [string]、2 文件信息 [{0 包序号 u64}]（按文件哈希顺序）、3 包信息 [{0 包大小 u64, 1 文件数 u64}]。
  · 文件系统（.trpfs）：'ONEPACK\\0' + u64 根表偏移；根表 {0 包名哈希 [u64], 1 包偏移 [u64]}，每个包在自己偏移处再是一张表。
  · 包表：0 文件哈希 [u64]、1 文件条目 [{1 压缩 i8（3 = Oodle；其余按存储）, 2 等级 u8, 3 长度 u64, 4 数据 [u8]}]。

本模块只做**枚举**：列出每个文件条目的 (包偏移, 包名, 文件哈希, 压缩方式, 长度, 数据偏移)。
枚举不需要 Oodle 解码器；只有要取压缩条目的内容时才需要（那一步走游戏自带解码器，见 shader_split.oodle）。
"""
import mmap
import struct

ONEPACK = b'ONEPACK\0'
COMP_STORED = 0
COMP_OODLE = 3


def fb_root(d, at=0):
    """FlatBuffers：根表偏移"""
    return at + struct.unpack_from('<I', d, at)[0]


def fb_field(d, t, i):
    """FlatBuffers：表 t 的第 i 个字段的绝对偏移；没有这个字段为 None"""
    vt = t - struct.unpack_from('<i', d, t)[0]
    if 4 + 2 * i >= struct.unpack_from('<H', d, vt)[0]:
        return None
    off = struct.unpack_from('<H', d, vt + 4 + 2 * i)[0]
    return t + off if off else None


def fb_vec(d, t, i):
    """FlatBuffers：第 i 个字段那个向量的 (起始, 个数)"""
    p = fb_field(d, t, i)
    if p is None:
        return 0, 0
    p += struct.unpack_from('<I', d, p)[0]
    return p + 4, struct.unpack_from('<I', d, p)[0]


def fb_refs(d, t, i):
    """FlatBuffers：偏移向量指向的表 / 字符串"""
    st, n = fb_vec(d, t, i)
    return [st + 4 * k + struct.unpack_from('<I', d, st + 4 * k)[0] for k in range(n)]


def fb_string(d, s):
    return d[s + 4:s + 4 + struct.unpack_from('<I', d, s)[0]].decode('utf-8', 'replace')


def describe(desc):
    """描述表 .trpfd → {'names': [包名], 'sizes': [包字节], 'pack_of': {文件哈希: 包序号}}"""
    d = desc
    if len(d) < 8:
        raise ValueError('trpfd 太短')
    fr = fb_root(d)
    hashes_at, hashes_n = fb_vec(d, fr, 0)
    hashes = struct.unpack_from(f'<{hashes_n}Q', d, hashes_at) if hashes_n else ()
    names = [fb_string(d, s) for s in fb_refs(d, fr, 1)]
    pack_of = {}
    for h, t in zip(hashes, fb_refs(d, fr, 2)):
        p = fb_field(d, t, 0)
        pack_of[h] = struct.unpack_from('<Q', d, p)[0] if p is not None else 0
    sizes = []
    for t in fb_refs(d, fr, 3):
        p = fb_field(d, t, 0)
        sizes.append(struct.unpack_from('<Q', d, p)[0] if p is not None else 0)
    return {'names': names, 'sizes': sizes, 'pack_of': pack_of}


def packs(path, desc):
    """从 .trpfs 头读包表 → [(包偏移, 包名, 描述表里的包字节)]"""
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as d:
        if len(d) < 16 or d[:8] != ONEPACK:
            raise ValueError(f'{path}: 不是 ONEPACK（前 8 字节 {bytes(d[:8])!r}）')
        sr = fb_root(d, struct.unpack_from('<Q', d, 8)[0])
        st, n = fb_vec(d, sr, 1)
        out = []
        for i in range(n):
            off = struct.unpack_from(f'<Q', d, st + 8 * i)[0]
            pr = fb_root(d, off)
            h0, hn = fb_vec(d, pr, 0)
            first = struct.unpack_from('<Q', d, h0)[0] if hn else None
            idx = desc['pack_of'].get(first)
            name = desc['names'][idx] if idx is not None and idx < len(desc['names']) else f'#{i}'
            out.append((off, name, desc['sizes'][idx] if idx is not None and idx < len(desc['sizes']) else 0))
        return out


def entries(path, off):
    """一个包的文件条目 → [(文件哈希, 压缩方式, 长度, 数据偏移)]"""
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as d:
        pr = fb_root(d, off)
        hat, hn = fb_vec(d, pr, 0)
        hashes = struct.unpack_from(f'<{hn}Q', d, hat) if hn else ()
        refs = fb_refs(d, pr, 1)
        if len(refs) != hn:
            raise ValueError(f'包 @{off:#x}：文件哈希 {hn} 个、文件条目 {len(refs)} 个，长度不自洽（不猜）')
        out = []
        for h, t in zip(hashes, refs):
            cp = fb_field(d, t, 1)
            lp = fb_field(d, t, 3)
            dp = fb_field(d, t, 4)
            comp = struct.unpack_from('<b', d, cp)[0] if cp is not None else COMP_STORED
            ln = struct.unpack_from('<Q', d, lp)[0] if lp is not None else 0
            if dp is not None:            # 4 是 ubyte 向量：字段偏移指向长度前缀
                doff = dp + struct.unpack_from('<I', d, dp)[0]
            else:
                doff = None
            out.append((h, comp, ln, doff))
        return out


def walk(path, desc_path, limit=None):
    """逐包产出 (包偏移, 包名, [条目…])；limit 只走前 N 个包（大文件排查用）"""
    desc = describe(open(desc_path, 'rb').read())
    for i, (off, name, size) in enumerate(packs(path, desc)):
        if limit is not None and i >= limit:
            return
        yield off, name, size, entries(path, off)


def main(argv):
    if len(argv) < 2:
        print('用法：trpfs.py <data.trpfs> [data.trpfd] [--limit N] [--hist]'); return 2
    p = argv[0]
    d = argv[1] if len(argv) > 1 and not argv[1].startswith('--') else p[:-1] + 'd'
    limit = None
    if '--limit' in argv:
        limit = int(argv[argv.index('--limit') + 1])
    hist = '--hist' in argv
    total = 0; bycomp = {}
    for off, name, size, ents in walk(p, d, limit):
        total += len(ents)
        for h, comp, ln, doff in ents:
            bycomp[comp] = bycomp.get(comp, 0) + 1
        if hist:
            print(f'  包 {name} @{off:#x} 声明 {size} B：{len(ents)} 条')
    print(f'包数 {"(前 %d)" % limit if limit else "全部"}，文件条目 {total}，压缩方式分布 {bycomp}')
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main(sys.argv[1:]))
