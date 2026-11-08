#!/usr/bin/env python3
# Mii 资源系统数据 0100000000000802（MiiModel）的合成与校验：sysdata_mii.py synth <输出目录> | check <目录>
# 合成（10-25 jhz 定：玩家任何情况下都不面对缺系统数据）：格式合法的最小资源——形状每个条目 3 个重合顶点（零面积，画不出东西）、贴图每个条目 1×1 全 0、
#   变换 / 包围盒全 0。可以显示成空白，不可以崩（马车8 开局即读这份，缺了开局 Break：sysdata_need.tsv）。同输入逐字节同输出。
# 格式（Switch 版 FFL 资源，各部件条目数同 Wii U FFL：公开反编译 github.com/aboood40091/ffl 的 FFLiResourceHeader / FFLiResourceShape；
#   Switch 版布局 10-25 对本机真数据逐字段核对，只取结构，不取内容）：
#   形状 Shape{High,Mid}.dat：'NFSR'、u32 版本 1、u32 文件长、u32 各部件最大解压长 [12]、u32 对齐 [12]（4）、条目 [857] × 88 字节、
#     头发变换 [132] × 0x48、脸型变换 [12] × 0x24、数据块。条目 = 数据位置、解压长、压缩长、压缩参数 0x806（zlib），
#     顶点属性（位置 / 法线 / 贴图坐标 / 切线 / 颜色，步长 8 / 4 / 4 / 4 / 4）的块内偏移 [5]、长度 [5]，索引偏移、长度，包围盒 6 个 float。解压长 0 = 该部件没有
#   贴图 NXTexture{Low,Mid}{Linear,SRGB}.dat：'NFTR'、1、文件长、最大解压长 [11]、对齐 [11]（0x200）、条目 [327] × 28 字节、数据块。
#     条目 = 数据位置、解压长、压缩长、0x806、对齐 0x200、u16 宽、u16 高、u8 格式、u8 mip 级数、2 字节 0
# 条目有无、每个形状条目带哪组顶点属性、每个贴图条目的格式码（真数据四个贴图文件一致）是结构，记在下面两张表里：
#   SHAPE：. = 没有 / u = 位置 + 法线 + 贴图坐标 / t = 位置 + 法线 + 切线 + 颜色（High 与 Mid 的并集）；TEX：. = 没有 / 格式码
import os, struct, sys, zlib

SHAPE = (
    '.uuuuuuuuuuuuuuuuuuuuuuuuuuu.........u................u.......u...........u..........u...u...............uu...'
    '..u............u...........u....u...........u...u..........u..................................................'
    '........................u............u................................u.uuuuuuuuuuuuu.uuuuuuuuuuuuuuuuuuu..uu.'
    'uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu.uuuuuu.uuuu.uu.uuu..uuuuuuuuuuuuuuuuuuuuuuuu.uu'
    'uuuuuuuuuuuuuuuuu.uuu.uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu.uuuuuuuuuuu.uuuuuuuu.uuuuuu.uuuu.uu.uuu..uuuuu'
    'uuuuuutttttttttttttttttttttttttttttt.ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt'
    'tttttttttttttttttttttttttttttttttttttttttttttttttttttttttt.ttttttttttttttttttttttttttttttttttttttttttttttttttt'
    'ttttttttttttttttttttttttttttttttttttttttttttttttttu.u.uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu')
TEX = (
    '.........3................3.......3...........3..........3...3...............33.....3............3...........3'
    '....3...........3...3.6666666666666666666666666666666666666666666666666666666666666633333333333333333333333.33'
    '.33333333333.66666666666.4444444444444444444.36666666666666666666666666666666666666.33333333333333333333333')
SHAPES = ('ShapeHigh.dat', 'ShapeMid.dat')
TEXTURES = ('NXTextureLowLinear.dat', 'NXTextureLowSRGB.dat', 'NXTextureMidLinear.dat', 'NXTextureMidSRGB.dat')
NS, NT, NHAIR, NFACE = 857, 327, 132, 12
SHDR = 0x6c + NS * 88 + NHAIR * 0x48 + NFACE * 0x24; THDR = 0x64 + NT * 28
STRIDE = (8, 4, 4, 4, 4)
ATTRS = {'u': (1, 1, 1, 0, 0), 't': (1, 1, 0, 1, 1)}
FLAGS = 0x806
assert len(SHAPE) == NS and len(TEX) == NT


def a16(n): return (n + 15) & ~15


def shape_file():
    ents, blobs, pos, mx = [], [], SHDR, 0
    for c in SHAPE:
        if c == '.': ents.append(bytes(88)); continue
        off, sz, o = [0] * 5, [0] * 5, 0
        for i, on in enumerate(ATTRS[c]):
            if on: off[i], sz[i] = o, 3 * STRIDE[i]; o += sz[i]
        ip, isz = o, 12; raw = bytes(a16(o + isz)); mx = max(mx, len(raw))   # 索引 12 字节全 0：按 u16 是 6 个、按 u32 是 3 个，都是退化三角形
        z = zlib.compress(raw, 6)
        ents.append(struct.pack('<4I5I5I2I6f', pos, len(raw), len(z), FLAGS, *off, *sz, ip, isz, *([0.0] * 6)))
        blobs.append(z); pos += len(z)
    head = b'NFSR' + struct.pack('<2I', 1, pos) + struct.pack('<12I', *([mx] * 12)) + struct.pack('<12I', *([4] * 12))
    return head + b''.join(ents) + bytes(NHAIR * 0x48 + NFACE * 0x24) + b''.join(blobs)


def tex_file():
    raw = bytes(0x200); z = zlib.compress(raw, 6)   # 1×1 一级，按对齐占 0x200
    ents, blobs, pos = [], [], THDR
    for c in TEX:
        if c == '.': ents.append(bytes(28)); continue
        ents.append(struct.pack('<5I2H2B2x', pos, len(raw), len(z), FLAGS, 0x200, 1, 1, int(c), 1))
        blobs.append(z); pos += len(z)
    head = b'NFTR' + struct.pack('<2I', 1, pos) + struct.pack('<11I', *([len(raw)] * 11)) + struct.pack('<11I', *([0x200] * 11))
    return head + b''.join(ents) + b''.join(blobs)


def synth(out):
    os.makedirs(out, exist_ok=True); s, t = shape_file(), tex_file()
    for n in SHAPES: open(os.path.join(out, n), 'wb').write(s)
    for n in TEXTURES: open(os.path.join(out, n), 'wb').write(t)


def unz(b, e, n, k, bad):
    if e[0] + e[2] > len(b): bad.append(f'{n} 条目 {k}：数据越出文件'); return None
    d = zlib.decompressobj()
    try: raw = d.decompress(b[e[0]:e[0] + e[2]]) + d.flush()
    except zlib.error as x: bad.append(f'{n} 条目 {k}：解压失败（{x}）'); return None
    if not d.eof or d.unused_data: bad.append(f'{n} 条目 {k}：压缩长与压缩流不符（没读完或有多余）'); return None
    if len(raw) != e[1]: bad.append(f'{n} 条目 {k}：解压长 {len(raw)} ≠ 条目里的 {e[1]}'); return None
    return raw


def check_shape(b, n):
    mx = struct.unpack_from('<12I', b, 0x0c); bad, cnt = [], 0
    for k in range(NS):
        e = struct.unpack_from('<4I5I5I2I6f', b, 0x6c + k * 88)
        if not e[1]: continue
        cnt += 1
        if e[0] < SHDR: bad.append(f'{n} 条目 {k}：数据块压进了条目 / 变换区'); continue
        raw = unz(b, e, n, k, bad)
        if raw is None: continue
        off, sz, ip, isz = e[4:9], e[9:14], e[14], e[15]
        if e[1] > max(mx): bad.append(f'{n} 条目 {k}：解压长超过头里的最大值')
        if len({s // STRIDE[i] for i, s in enumerate(sz) if s}) != 1 or any(s % STRIDE[i] for i, s in enumerate(sz)): bad.append(f'{n} 条目 {k}：各属性顶点数不一致')
        if any(o + s > len(raw) for o, s in zip(off, sz)) or ip + isz > len(raw) or not isz or isz % 2: bad.append(f'{n} 条目 {k}：元素越出数据块 / 没有索引')
    return bad, cnt


def check_tex(b, n):
    bad, cnt = [], 0
    for k in range(NT):
        e = struct.unpack_from('<5I2H2B2x', b, 0x64 + k * 28)
        if not e[1]: continue
        cnt += 1
        if e[0] < THDR: bad.append(f'{n} 条目 {k}：数据块压进了条目区'); continue
        raw = unz(b, e, n, k, bad)
        if raw is None: continue
        if e[1] % 0x200 or not (e[5] and e[6] and e[8]): bad.append(f'{n} 条目 {k}：长度不按 0x200 对齐 / 宽高或 mip 为 0')
        if TEX[k] == '.' or e[7] != int(TEX[k]): bad.append(f'{n} 条目 {k}：格式码 {e[7]} 与结构表（{TEX[k]}）不符')
    return bad, cnt


def check(d):
    ok = True
    for n in SHAPES + TEXTURES:
        p = os.path.join(d, n)
        if not os.path.isfile(p): print(f'✗ 缺 {n}'); ok = False; continue
        b = open(p, 'rb').read(); mg = b'NFSR' if n in SHAPES else b'NFTR'
        if b[:4] != mg or struct.unpack_from('<I', b, 4)[0] != 1: print(f'✗ {n}：魔数 / 版本不对'); ok = False; continue
        bad, cnt = (check_shape if n in SHAPES else check_tex)(b, n)
        if struct.unpack_from('<I', b, 8)[0] != len(b): bad.insert(0, f'{n}：头里的文件长 ≠ 实际')
        if bad: print('\n'.join(f'✗ {x}' for x in bad[:5]) + (f'\n  …共 {len(bad)} 处' if len(bad) > 5 else '')); ok = False
        else: print(f'✓ {n}：{cnt} 个条目解析通过')
    return ok


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'synth': synth(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == 'check': sys.exit(0 if check(sys.argv[2]) else 1)
    else: sys.exit('用法：sysdata_mii.py synth <输出目录> | check <目录>')
