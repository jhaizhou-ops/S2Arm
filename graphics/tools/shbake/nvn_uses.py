#!/usr/bin/env python3
# 游戏会不会设 NVN 透明测试（静态，零游戏配置；10-20 透明测试 A）：扫 exefs 下每个 NSO 模块，按「名字串引用 → 其后第一次调用（取函数地址）
# → 再后第一条 STR X0 的目标」认出函数表槽位：目标寄存器由 ldr [ADRP 页 + 偏移] 取来 = 经 GOT 项间接存（动森写法），槽位键 = GOT 项；
# 目标是 [ADRP 页 + 偏移] = 直接存全局（暗黑2 写法）。再数全部代码里 ldr 读这个键的地方（加载器的存入是写，不算）。
# 正对照：nvnCommandBufferBindProgram 至少一个模块读取 > 0（必然被调用），不过 = 识别不可靠、结论作废（ok = false，调用方照旧出两份）。
# 目标寄存器是函数开头就定好的表基址（adrp + add，怪猎 RE 引擎：一个函数里整串取几百个函数存进同一张表）：往回解出基址，槽位键 = 基址 + 偏移（10-21 pair）。
# 直接存进全局的槽，调用处经 GOT 项读（八方2 UE4）：按重定位表把指向槽的 GOT 项的读点也算上（10-21 pair）。
# 第一版（按「str x0 存进 ADRP 定页的全局」认槽位）在动森上把一串函数都认成同一个页、在暗黑2 上漏读，10-20 弃用。
# 输出一行 JSON：{"BindProgram": N, "SetAlphaTest": N, "SetAlphaRef": N, "ok": bool}；用法：nvn_uses.py <exefs 目录>
import sys, os, json, struct, re, lz4.block

def load(path):
    raw = open(path, 'rb').read()
    if raw[:4] != b'NSO0': return None
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段（tools/nso_plain.py）；用时才导：单测 exec 本文件前半段时没有 __file__
    raw = plain(raw, path)
    segs = []
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
        segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
    buf = bytearray(max(m + len(d) for m, d in segs))
    for m, d in segs: buf[m:m + len(d)] = d
    return bytes(buf), segs[0][0] + len(segs[0][1])

def got_of(img):
    """相对重定位（R_AARCH64_RELATIVE）的「目标地址 → 存它的指针槽」：模块头 MOD0 → .dynamic 的 DT_RELA / DT_RELASZ。读不出返回空表"""
    try:
        mod = struct.unpack_from('<I', img, 4)[0]
        if img[mod:mod + 4] != b'MOD0': return {}
        p = mod + struct.unpack_from('<i', img, mod + 4)[0]; D = {}
        while p + 16 <= len(img):
            t, v = struct.unpack_from('<qQ', img, p); p += 16
            if t == 0: break
            D.setdefault(t, v)
        out = {}
        for i in range(0, D.get(8, 0), 24):
            off, info, add = struct.unpack_from('<QQq', img, D[7] + i)
            if info & 0xffffffff == 1027: out.setdefault(add, []).append(off)
        return out
    except (struct.error, KeyError): return {}

def adrp(w, pc):
    if w & 0x9f000000 != 0x90000000: return None
    imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3); imm -= (1 << 21) if imm & (1 << 20) else 0
    return w & 31, (pc & ~0xfff) + (imm << 12)

def resolve(W, i, r, depth=0):
    """第 i 条之前寄存器 r 的值：往回找最近一次写 r 的指令，只认 adrp / add 立即数 / mov 寄存器 链，别的写法或越过 ret（函数开头之前）= 认不出（None）"""
    j = i - 1
    while j >= 0 and i - j < 4096:
        w = W[j]
        if w == 0xd65f03c0: return None
        a = adrp(w, j * 4)
        if a and a[0] == r: return a[1]
        if w & 0xffc00000 == 0x91000000 and w & 31 == r:
            b = resolve(W, j, (w >> 5) & 31, depth + 1) if depth < 4 else None
            return None if b is None else b + ((w >> 10) & 0xfff)
        if w & 0xffe0ffe0 == 0xaa0003e0 and w & 31 == r: return resolve(W, j, (w >> 16) & 31, depth + 1) if depth < 4 else None
        if w & 31 == r and (w >> 24) in (0xf9, 0xb9, 0x52, 0xd2, 0x8b, 0xaa, 0x91, 0xd1, 0xcb): return None
        j -= 1
    return None

def scan(img, te, names, got=None):
    got = got_of(img) if got is None else got
    W = struct.unpack_from(f'<{te // 4}I', img, 0)
    page = {}; reads = {}
    for i, w in enumerate(W):   # 读点：ldr Xt, [Xn, #imm]，Xn 由 64 条内的 ADRP 定页
        a = adrp(w, i * 4)
        if a: page[a[0]] = (a[1], i); continue
        if w & 0xffc00000 == 0xf9400000:
            n = (w >> 5) & 31
            if n in page and i - page[n][1] < 64: reads[page[n][0] + ((w >> 10) & 0xfff) * 8] = reads.get(page[n][0] + ((w >> 10) & 0xfff) * 8, 0) + 1
        if w & 0xffc00000 == 0x91000000: page.pop(w & 31, None)
    out = {}
    for name in names:
        sa = {m.start() for m in re.finditer(re.escape(name.encode() + b'\0'), img) if img[m.start() - 1] == 0}
        if not sa: out[name] = 0; continue
        pg = {}; slots = set()
        for i, w in enumerate(W):
            a = adrp(w, i * 4)
            if a: pg[a[0]] = a[1]; continue
            if not (w & 0xffc00000 == 0x91000000 and (w >> 5) & 31 in pg and pg[(w >> 5) & 31] + ((w >> 10) & 0xfff) in sa): continue
            k = i + 1
            while k < min(i + 40, len(W)) and not (W[k] >> 26 == 0b100101 or W[k] & 0xfffffc1f == 0xd63f0000): k += 1
            regs, p2 = {}, {}
            for q in range(k + 1, min(k + 20, len(W))):
                x = W[q]; a2 = adrp(x, q * 4)
                if a2: p2[a2[0]] = a2[1]; continue
                if x & 0xffc00000 == 0xf9400000 and (x >> 5) & 31 in p2:
                    regs[x & 31] = p2[(x >> 5) & 31] + ((x >> 10) & 0xfff) * 8; continue
                if (x & 0xffc0001f) == 0xf9000000:
                    n = (x >> 5) & 31; off = ((x >> 10) & 0xfff) * 8
                    if n in regs and off == 0: slots.add((regs[n], 1))      # 经 GOT：加载器自己 ldr 过一次 GOT 项
                    elif n in p2: slots.add((p2[n] + off, 0))               # 直接存：加载器不读
                    else:   # 存进函数开头就定好的表基址（RE 引擎：adrp x21 + add x21 #0x180 后整串 blr / str x0,[x21,#槽]）：往回解出基址
                        b0 = resolve(W, q, n)
                        if b0 is not None: slots.add((b0 + off, 0))
                    break
        # 读点减去加载器自己那一次；直接存进全局的槽，别处可能经 GOT 取它的地址再读（八方2 UE4：加载器 adrp 直存，调用处 adrp+ldr GOT 项 → ldr 函数指针），GOT 项的读点也算
        out[name] = sum(max(0, reads.get(s, 0) - own) + (sum(reads.get(g, 0) for g in got.get(s, [])) if not own else 0) for s, own in slots)
    return out

names = {'BindProgram': 'nvnCommandBufferBindProgram', 'SetAlphaTest': 'nvnColorStateSetAlphaTest', 'SetAlphaRef': 'nvnCommandBufferSetAlphaRef'}
tot = {k: 0 for k in names}
for f in sorted(os.listdir(sys.argv[1])):
    r = load(os.path.join(sys.argv[1], f)) if os.path.isfile(os.path.join(sys.argv[1], f)) else None
    if not r: continue
    for k, v in scan(r[0], r[1], list(names.values())).items():
        tot[[a for a, b in names.items() if b == k][0]] += v
tot['ok'] = tot['BindProgram'] > 0
print(json.dumps(tot))
