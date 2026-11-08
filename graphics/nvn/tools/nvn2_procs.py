#!/usr/bin/env python3
"""NVN2（Switch 2）驱动按名可取的入口全集：从游戏自带的 sdk 模块读 nvnDeviceGetProcAddress 的查找表（11-04）。
NVN2 驱动整个编进每款游戏的 sdk；GetProcAddress（经 nvnBootstrapLoaderInternal → 函数指针）的做法与 Switch 1 驱动相同：
  ① 名字以 "nvn" 开头 → 去掉前缀，在有序名字表里二分查找（u32 偏移数组 + 字符串基址，表项数是 mov wN, #(项数-1) 的立即数），
     命中返回同下标的函数指针表项（GOT 里的一个 8 字节槽，指向 .data.rel.ro 的指针数组）；
  ② 表里没有 / 不以 nvn 开头 → 一段逐个 strcmp 的链（NVX / 互操作 / 两个不带 nvn 前缀的私有入口）。
名字是明文，只是去掉了 "nvn" 前缀存放，所以按 "nvn" 搜 sdk 字符串只看得到 42 个。
用法：nvn2_procs.py <sdk 文件（NSO）>[=标签] ...   每个 sdk 出一列；输出 TSV：名字、各 sdk 的驱动函数地址（-- = 该版没有；chain = 在 strcmp 链里）
     加 --names 只出名字并集（每行一个，供 graphics/nvn/gfx/nvn/nvn2_drv_names.txt）
纯 Python：只解码用到的几条 AArch64 指令（adrp / add / movz / ldr 立即数 / bl / cbz），不依赖 capstone。"""
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nso_syms import load   # 解压后的模块映像（偏移 0 = 基址）

def u32(img, o): return struct.unpack_from('<I', img, o)[0]
def u64(img, o): return struct.unpack_from('<Q', img, o)[0]
def cstr(img, o): return img[o:img.index(b'\0', o)].decode('latin1')
def sx(v, bits): return v - (1 << bits) if v & (1 << (bits - 1)) else v

def relocate(img):
    """只应用 R_AARCH64_RELATIVE（基址 0：槽 = 加数）；RELR 在基址 0 时是空操作。函数指针表与 GOT 槽都靠它填"""
    img = bytearray(img)
    mod0 = u32(img, 4); dyn = mod0 + struct.unpack_from('<i', img, mod0 + 4)[0]; tags = {}
    for i in range(4096):
        t, v = struct.unpack_from('<qQ', img, dyn + i * 16)
        if t == 0: break
        tags.setdefault(t, v)
    for o in range(tags[7], tags[7] + tags.get(8, 0), 24):
        off, info, add = struct.unpack_from('<QQq', img, o)
        if info & 0xffffffff == 1027: struct.pack_into('<Q', img, off, add & (2 ** 64 - 1))
    return bytes(img)

def adrp(w, pc): return (pc & ~0xfff) + (sx(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21) << 12) if (w & 0x9f000000) == 0x90000000 else None
def add_imm(w): return ((w >> 5) & 31, w & 31, (w >> 10) & 0xfff) if (w & 0xffc00000) == 0x91000000 else None   # (rn, rd, imm)
def ldr_x_imm(w): return ((w >> 5) & 31, w & 31, ((w >> 10) & 0xfff) * 8) if (w & 0xffc00000) == 0xf9400000 else None

def find_lookup(img, text_end):
    """二分查找段：ldrb w8, [xS] ; cmp w8, #'n' ; b.ne ; ldrb w8, [xS, #1] ; cmp w8, #'v' …；之后若干条里有 mov wN, #hi 与两对 adrp/add（偏移数组、字符串基址）。
    同一段在 GetProcAddress 和另一处各有一份，取后面跟着函数指针表（ldr x8, [xK] ; cbnz x8 ; adrp x8 ; ldr x8, [x8, #got]）的那份"""
    for o in range(0, text_end - 0x200, 4):
        if u32(img, o) != 0x7101b91f or u32(img, o + 12) != 0x7101d91f: continue   # cmp w8, #0x6e … cmp w8, #0x76
        regs, page, hi = {}, {}, None
        for p in range(o, o + 0x60, 4):
            w = u32(img, p); a = adrp(w, p)
            if a is not None: page[w & 31] = a; continue
            ai = add_imm(w)
            if ai and ai[0] in page and ai[0] == ai[1]: regs[ai[1]] = page.pop(ai[0]) + ai[2]; continue
            if (w & 0xffe0001f) & 0xff800000 == 0x52800000 and hi is None: hi = (w >> 5) & 0xffff   # movz w, #imm
            if (w & 0xfc000000) == 0x94000000: break   # bl strcmp
        if hi is None or len(regs) != 2: continue
        a, b = regs.values(); names = None
        for offs, base in ((a, b), (b, a)):
            try:
                nm = [cstr(img, base + u32(img, offs + 4 * i)) for i in range(hi + 1)]
                if nm[0].startswith('BlendState') and nm == sorted(nm): names = nm
            except (struct.error, ValueError, IndexError): pass
        if not names: continue
        for p in range(o, o + 0x200, 4):   # 函数指针表
            if (u32(img, p) & 0xff00001f) == 0xb5000008:   # cbnz x8
                pa = adrp(u32(img, p + 4), p + 4); l = ldr_x_imm(u32(img, p + 8))
                if pa is not None and l and l[0] == 8: return o, names, u64(img, pa + l[2])
    raise SystemExit('没认出 GetProcAddress 的有序名字表')

def find_chain(img, lookup, text_end):
    """表外的 strcmp 链：从二分查找段往后的直接跳转（b）目标里，取连续 adrp/add x1 + bl 同一函数 最长的那个函数"""
    best = (0, [])
    for p in range(lookup, lookup + 0x200, 4):
        w = u32(img, p)
        if (w & 0xfc000000) != 0x14000000: continue
        t = p + 4 * sx(w & 0x3ffffff, 26); names, page, cur, callee = [], None, None, None
        for q in range(t, min(t + 0x1000, text_end), 4):
            w2 = u32(img, q); a = adrp(w2, q)
            if a is not None and (w2 & 31) == 1: page = a; continue
            ai = add_imm(w2)
            if ai and ai[0] == 1 and ai[1] == 1 and page is not None: cur = page + ai[2]; continue
            if (w2 & 0xfc000000) == 0x94000000:
                c = q + 4 * sx(w2 & 0x3ffffff, 26)
                if callee is None: callee = c
                if c != callee or cur is None: break
                names.append(cstr(img, cur)); cur = None
            if w2 in (0xd65f03c0, 0xd65f0fff): break   # ret / retab
        if len(names) > len(best[1]): best = (t, names)
    return best[1]

def scan(path):
    img = relocate(load(path))
    d = open(path, 'rb').read(); text_end = struct.unpack_from('<III', d, 0x10)[2]
    o, names, table = find_lookup(img, text_end)
    procs = {'nvn' + n: u64(img, table + 8 * i) for i, n in enumerate(names)}
    chain = find_chain(img, o, text_end)
    return procs, chain

def main(argv):
    only_names = '--names' in argv; args = [a for a in argv if a != '--names']
    cols = []
    for a in args:
        path, _, tag = a.partition('='); procs, chain = scan(path)
        cols.append((tag or os.path.basename(os.path.dirname(os.path.dirname(path))), procs, chain))
        print(f'# {cols[-1][0]}：有序表 {len(procs)} 项 + strcmp 链 {len(chain)} 个 = {len(set(procs) | set(chain))}', file=sys.stderr)
    allnames = sorted(set().union(*[set(p) | set(c) for _, p, c in cols]), key=lambda n: (not n.startswith('nvn'), n))
    if only_names:
        for n in allnames: print(n)
        return
    print('名字\t' + '\t'.join(t for t, _, _ in cols))
    for n in allnames:
        print(n + '\t' + '\t'.join(hex(p[n]) if n in p else 'chain' if n in c else '--' for _, p, c in cols))

if __name__ == '__main__': main(sys.argv[1:])
