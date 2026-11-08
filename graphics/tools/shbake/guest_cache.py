#!/usr/bin/env python3
# 社区 / 用户自带的客体着色器缓存 → 客体代码包（10-27 jhz「社区资源要认真对待，在能力 / 功能 / 产品上集成好」；总指挥：王国之泪 yuzu v10 缓存入库并产品化）。
# 认的输入：yuzu 系（yuzu / Eden / suyu / sudachi 等，文件头 8 字节 "yuzucach"，vulkan.bin / opengl.bin）。只解析数据，不执行输入里的任何东西。
# 布局（与 grokbot 工具 s2rl_extract.py 同一份认法，源码依据见其 README：Software Heritage 存档的 yuzu-mainline）：
#   "yuzucach" | u32 缓存版本 | 逐条记录：u32 阶段数（1–6）| 每阶段一份环境 | 管线键（计算 / 图形各一个定长，长度随版本，见下）
#   环境：u64 代码字节 | u64 贴图类型数 | [u64 贴图像素格式数] | u64 常量数 | [u64 常量替换数] | u32 本地内存 | u32 贴图绑定 | u32 起点 | u32 缓存下界 | u32 缓存上界
#        | [u32 视口变换] | u32 阶段 | 代码 | 贴图类型（u32 键 + u32 值）× n | 像素格式（8 字节）× n | 常量（u64 键 = 常量段 << 32 | 偏移，u32 值）× n | 常量替换（12 字节）× n
#        | 计算：u32 × 3 线程组 + u32 共享内存；图形：SPH 0x50 字节（几何着色器另有 32 字节直通掩码）
#   方括号里的字段随版本有无：按「整份恰好解到文件尾」选布局，不按版本号猜；两种管线键长度同样按「下一条记录头对得上」探出（v10 实测：计算 24、图形 1032）。
#   阶段（yuzu Shader::Stage）：0 顶点 B、1 细分控制、2 细分求值、3 几何、4 片元、5 计算、6 顶点 A。
# 产物（.s2gb，ShaderBake --ref-bundle 读）：'S2GB' | u32 版本 1 | u64 程序号 | u32 来源格式（0xFFFF0000 | 缓存版本）| u32 程序数 | 每程序：
#   u8 是否计算 | u8 阶段数 | 每阶段：u8 槽（Ryujinx 口径 0 顶点 A、1 顶点、2 细分控制、3 细分求值、4 几何、5 片元；计算恒 0）| u32 代码长 | 代码
#   （图形从 SPH 起、计算从第一条指令起，同 Ryujinx 客体缓存）| u32 常量段 1 长 | 常量段 1（缓存里记下的常量段 1 取值铺回原偏移，没记到的字节为 0）
#   同一份代码 + 常量段 1 的程序在 ShaderBake 里按代码去重（只差管线键的变体只烘一个），这里照原样全写。
# 用法：guest_cache.py bundle <缓存文件> <输出 .s2gb> --title <程序号>   退出 0 = 写出；1 = 认不出 / 解不到文件尾（打【红】行与原因）
#       guest_cache.py stat <缓存文件>                                  只打统计（程序数、各阶段数、不同代码数）
import argparse, hashlib, struct, sys

MAGIC = b'yuzucach'
SLOT = {6: 0, 0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 5: 0}   # yuzu 阶段 → Ryujinx 客体缓存槽（计算单独一槽）

class Bad(ValueError): pass
# 已核过的版本：管线键长度定死（是否计算 → 字节）。只有一条计算记录时「解到文件尾」分不出截断（截掉的键尾也能被探成更短的键），已知版本不探
KEYLEN = {10: {True: 24, False: 1032}}   # v10：王国之泪社区缓存 443884488 字节整份解到文件尾实测

def layouts():   # 随版本有无的四个字段：像素格式数、常量替换数、视口变换、几何直通掩码；先试字段最全的（新版本）
    for tpf in (1, 0):
        for repl in (1, 0):
            for vts in (1, 0):
                for gp in (1, 0): yield dict(tpf=tpf, repl=repl, vts=vts, gp=gp)

def env(b, q, L):
    """一份环境 → (下一偏移, yuzu 阶段, 客体代码, 常量段 1 字节)；布局不对抛 Bad"""
    n = 3 + L['tpf'] + L['repl']
    if q + 8 * n > len(b): raise Bad('截断')
    h = struct.unpack_from('<' + 'Q' * n, b, q); q += 8 * n
    size, ntt = h[0], h[1]; i = 2
    ntpf = h[i] if L['tpf'] else 0; i += L['tpf']
    ncb = h[i]; i += 1
    nrp = h[i] if L['repl'] else 0
    k = 6 + L['vts']
    if q + 4 * k > len(b): raise Bad('截断')
    u = struct.unpack_from('<' + 'I' * k, b, q); q += 4 * k
    start, lo, hi, stage = u[2], u[3], u[4], u[-1]
    if stage > 6 or size % 8 or size > (1 << 22) or max(ntt, ntpf, ncb, nrp) > (1 << 16) or not (lo <= start <= hi + 8): raise Bad('环境头不合理')
    code = b[q:q + size]; q += size
    if len(code) != size: raise Bad('截断')
    q += ntt * 8 + ntpf * 8
    cb1 = {}
    for j in range(ncb):
        if q + 12 > len(b): raise Bad('截断')
        key, val = struct.unpack_from('<QI', b, q); q += 12
        if key >> 32 == 1: cb1[key & 0xffffffff] = val
    q += nrp * 12
    sph = None
    if stage == 5: q += 16
    else:
        sph = b[q:q + 0x50]; q += 0x50
        if stage == 3 and L['gp']: q += 32
    if q > len(b): raise Bad('截断')
    off = start - lo
    guest = code[off:] if stage == 5 or code[off:off + 0x50] == sph else sph + code[off:]
    # 入口之后至少一条指令（8 字节），图形还要在 SPH 之后（审计 #846 F-guest-env-empty：头里只核 lo <= start <= hi + 8，起点 - 下界 超出代码区时
    #   计算阶段切出空代码、图形只剩 0x50 字节 SPH，照样解到文件尾、退出 0 写进包）。盖不住 = 这个布局不对，同「环境头不合理」
    if len(guest) < (8 if stage == 5 else 0x50 + 8): raise Bad(f'代码窗口盖不住入口（起点 - 下界 = {off:#x}，代码区 {size:#x} 字节）')
    cb = bytearray(max([o + 4 for o in cb1] or [0]))
    for o, v in cb1.items(): struct.pack_into('<I', cb, o, v)
    return q, stage, bytes(guest), bytes(cb)

def record(b, q, L):
    if q + 4 > len(b): raise Bad('截断')
    ne = struct.unpack_from('<I', b, q)[0]; q += 4
    if not 1 <= ne <= 6: raise Bad('阶段数不合理')
    st = []
    for _ in range(ne): q, s, g, c = env(b, q, L); st.append((s, g, c))
    return q, st

def parse(b):
    """整份 yuzu 系缓存 → (版本, [(是否计算, [(槽, 代码, 常量段 1)])])；按「恰好解到文件尾」定布局与两种管线键长度"""
    if b[:8] != MAGIC: raise Bad('不是 yuzu 系缓存（文件头不是 yuzucach）')
    ver = struct.unpack_from('<I', b, 8)[0]
    for L in layouts():
        try: return ver, walk(b, L, KEYLEN.get(ver))
        except Bad: continue
    raise Bad(f'yuzu 系缓存版本 {ver}：已知各环境布局都解不到文件尾')

def walk(b, L, klen=None, q=12, progs=None):
    """从 q 解到文件尾。klen：是否计算 → 管线键长度；第一次遇到某种时逐个候选长度试（跳过后下一条记录能解开才算候选），
    每个候选都要整份解到文件尾才采纳，解不到就换下一个候选（只在这两处回溯）"""
    klen = dict(klen or {}); progs = list(progs or [])
    while q < len(b):
        q, st = record(b, q, L)
        comp = st[0][0] == 5
        progs.append((comp, [(SLOT[s], g, c) for s, g, c in st]))
        if comp not in klen:
            for c in range(4, 4097, 4):
                r = q + c
                if r > len(b): break
                if r < len(b):
                    try: record(b, r, L)
                    except Bad: continue
                try: return walk(b, L, {**klen, comp: c}, r, progs)
                except Bad: continue
            raise Bad('管线键长度探不出')
        q += klen[comp]
        if q > len(b): raise Bad('截断')
    return progs

def bundle(progs, ver, tid):
    out = [b'S2GB', struct.pack('<IQII', 1, int(tid, 16), 0xFFFF0000 | ver, len(progs))]
    for comp, st in progs:
        out.append(struct.pack('<BB', 1 if comp else 0, len(st)))
        for slot, code, cb in st: out += [struct.pack('<BI', slot, len(code)), code, struct.pack('<I', len(cb)), cb]
    return b''.join(out)

def stat(progs):
    n = [0] * 7; codes = set()
    for comp, st in progs:
        for slot, code, _ in st: n[6 if comp else slot] += 1; codes.add((comp, slot, hashlib.sha1(code).digest()))
    return f'程序 {len(progs)}（计算 {sum(1 for c, _ in progs if c)}）；各槽出现 顶点A {n[0]} 顶点 {n[1]} 细分控制 {n[2]} 细分求值 {n[3]} 几何 {n[4]} 片元 {n[5]} 计算 {n[6]}；不同代码 {len(codes)}'

def main():
    ap = argparse.ArgumentParser(description='社区 / 用户自带客体着色器缓存 → 客体代码包')
    sp = ap.add_subparsers(dest='cmd', required=True)
    a = sp.add_parser('bundle'); a.add_argument('src'); a.add_argument('out'); a.add_argument('--title', required=True)
    s = sp.add_parser('stat'); s.add_argument('src')
    args = ap.parse_args()
    b = open(args.src, 'rb').read()
    try: ver, progs = parse(b)
    except Bad as e: print(f'【红】guest_cache：{args.src}：{e}', file=sys.stderr); sys.exit(1)
    print(f'guest_cache：{args.src}：yuzu 系缓存版本 {ver}，{stat(progs)}')
    if args.cmd == 'bundle':
        d = bundle(progs, ver, args.title); tmp = args.out + '.tmp'
        open(tmp, 'wb').write(d); __import__('os').replace(tmp, args.out)
        print(f'guest_cache：写出 {args.out}（{len(d)} 字节）')

if __name__ == '__main__': main()
