#!/usr/bin/python3
"""宽屏真值：把第二层启用的宽屏点按原生层同一规则（runtime/src/widen.c）静态打进 NSO，给 Ryujinx 真值起局用（同样的输入比同样的输出）。

用法：truth_nso.py <原 NSO> <模块名> <产物根> <屏幕宽 W（1080 高对应）> <输出 NSO> <档位 handheld|docked>
  读 <产物根>/<模块名>.widen.tsv（候选：序号 / 偏移 / 种类 / 原指令字）与 <产物根>/widen_enable.<档位>.tsv（启用列，装载器同一张），只改启用的点：
  · movz：16:9 档宽立即数 → scale_w（档宽 × W ÷ 1920 四舍五入，原生层值槽同值），直接改指令立即数；
  · f32：从锚点 (1920, 1080) 起前后连续的 16:9 浮点分辨率对，x 改成 scale_w(x)、y 不动（只读数据段，原生层同一扫描规则）；
  · aspdiv（FDIV Sd, Sn, Sm）：原指令改成跳到代码段末空隙里的跳板——跳板先做原 FDIV，结果与 16/9 差 < 2e-3 时换成 W ÷ 1080（NaN 不换），
    借用的 x16 / x17 / d16 / d17 与条件标志压栈恢复，再跳回下一条（原生层门：同一条件、同一替换值）；
  · asp / aspstr：还没有用到它们的款，遇到报错退出（不静默跳过）。
输出 NSO 三段都不压缩、不带段哈希校验位（Ryujinx 照常装载），代码段长度延到跳板末尾（不越过只读段起点）。
跳板生成后用 capstone 反汇编自检，打印给人核。"""
import struct, sys
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
import lz4.block
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

K_CLS = (1920, 1280, 1600, 960, 2560, 3840, 1024, 640)   # movz 认的 16:9 档宽（runtime/src/widen.c k_cls）


def scale_w(v, W): return (v * W + 960) // 1920   # 与 runtime/src/widen.c scale_w 同一规则：x × W ÷ 1920 四舍五入、不取偶（取偶破坏档间比例，10-20 暗黑3 右缘少 1 列）


def load_sites(root, mod, mode):
    sites = []
    for l in open(f'{root}/{mod}.widen.tsv'):
        i, off, kind, word = l.split()
        sites.append((int(off, 16), kind, int(word, 16)))
    on = set()
    for l in open(f'{root}/widen_enable.{mode}.tsv'):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 4 and f[0] == mod and f[3] == '1': on.add(int(f[1], 16))
    return [s for s in sites if s[0] in on]


# ---- AArch64 编码（只用到的几条） ----
def b(frm, to): return 0x14000000 | (((to - frm) >> 2) & 0x3ffffff)
def ldr_s_lit(rt, frm, to): return 0x1C000000 | ((((to - frm) >> 2) & 0x7ffff) << 5) | rt
def fsub_s(rd, rn, rm): return 0x1E203800 | (rm << 16) | (rn << 5) | rd
def fabs_s(rd, rn): return 0x1E20C000 | (rn << 5) | rd
def fcmp_s(rn, rm): return 0x1E202000 | (rm << 16) | (rn << 5)
def bcond(frm, to, cond): return 0x54000000 | ((((to - frm) >> 2) & 0x7ffff) << 5) | cond
PL = 5
STP_X16_X17_PRE, STP_D16_D17_PRE = 0xA9BF47F0, 0x6DBF47F0   # stp x16,x17,[sp,#-16]! / stp d16,d17,[sp,#-16]!
LDP_D16_D17_POST, LDP_X16_X17_POST = 0x6CC147F0, 0xA8C147F0  # ldp d16,d17,[sp],#16 / ldp x16,x17,[sp],#16
MRS_X16_NZCV, MSR_NZCV_X16 = 0xD53B4210, 0xD51B4210


def aspdiv_cave(site, word, at, W):
    """跳板（从 at 起）：原 FDIV；|r − 16/9| < 2e-3 → r = W / 1080（NaN 不换）；回 site + 4。返回指令字列表（末尾 3 字是字面量）。"""
    d = word & 31
    if (word & 0xFFE0FC00) != 0x1E201800: sys.exit(f'【红】{site:#x} 不是 FDIV Sd（单精度）：{word:#010x}')
    N = 15   # 指令条数（字面量池紧随其后）
    lit = at + 4 * N
    pc = lambda k: at + 4 * k
    code = [word, STP_X16_X17_PRE, STP_D16_D17_PRE, MRS_X16_NZCV,
            ldr_s_lit(16, pc(4), lit),            # s16 = 16/9
            fsub_s(16, d, 16), fabs_s(16, 16),    # s16 = |r − 16/9|
            ldr_s_lit(17, pc(7), lit + 4),        # s17 = 2e-3
            fcmp_s(16, 17),
            bcond(pc(9), pc(11), PL),             # 不小于或无序 → 跳过替换
            ldr_s_lit(d, pc(10), lit + 8),        # r = W / 1080
            MSR_NZCV_X16, LDP_D16_D17_POST, LDP_X16_X17_POST,
            b(pc(14), site + 4)]
    assert len(code) == N
    f = lambda x: struct.unpack('<I', struct.pack('<f', x))[0]
    return code + [f(16.0 / 9.0), f(2e-3), f(W / 1080.0)]


def main():
    src, mod, root, W, out, mode = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6]
    assert mode in ('handheld', 'docked'), f'档位只认 handheld / docked：{mode}'
    d = bytearray(_nso_plain(open(src, 'rb').read(), src)); assert d[:4] == b'NSO0', '不是 NSO'
    flags = struct.unpack_from('<I', d, 0xc)[0]
    segs = [list(struct.unpack_from('<III', d, 0x10 + i * 0x10)) for i in range(3)]
    csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        if flags >> i & 1: raw = lz4.block.decompress(bytes(raw), uncompressed_size=sz)
        img[mo:mo + sz] = raw
    text_end, ro_off = segs[0][2], segs[1][1]
    cave = (text_end + 15) & ~15; md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); n = 0
    for off, kind, word in load_sites(root, mod, mode):
        cur = struct.unpack_from('<I', img, off)[0]
        if kind != 'f32' and cur != word: sys.exit(f'【红】{mod}+{off:#x} 指令字 {cur:#010x} 与表里 {word:#010x} 不符（表与 NSO 不是同一版）')
        if kind == 'movz':
            imm, hw = (word >> 5) & 0xffff, (word >> 21) & 3
            if hw or imm not in K_CLS: print(f'【红】{mod}+{off:#x} movz 立即数 {imm} 不是 16:9 档宽，按原值（同原生层）'); continue
            v = scale_w(imm, W); struct.pack_into('<I', img, off, (word & ~(0xffff << 5)) | (v << 5)); print(f'{mod}+{off:#x} movz {imm} → {v}')
        elif kind == 'f32':
            a = struct.unpack_from('<ff', img, off)
            if a != (1920.0, 1080.0): print(f'【红】{mod}+{off:#x} f32 锚点 {a} 不是 (1920, 1080)，未改'); continue
            ok = lambda o: (lambda x, y: y > 0 and x == int(x) and abs(x / y - 16 / 9) < 1e-3)(*struct.unpack_from('<ff', img, o))
            lo = (text_end + 0x3FFF) & ~0x3FFF; o = off
            if off < lo: print(f'【红】{mod}+{off:#x} f32 锚点不在代码段之后，未改（同原生层，审计 #829）'); continue
            while o >= lo + 8 and ok(o - 8): o -= 8
            k = 0
            while o + 8 <= len(img) and ok(o):
                x, y = struct.unpack_from('<ff', img, o); struct.pack_into('<f', img, o, float(scale_w(int(x), W))); o += 8; k += 1
            print(f'{mod}+{off:#x} f32 表 {k} 项按屏幕宽放大（宽 {W}）')
        elif kind == 'aspdiv':
            code = aspdiv_cave(off, word, cave, W)
            if cave + 4 * len(code) > ro_off: sys.exit(f'【红】代码段末空隙不够放跳板（{cave:#x} + {4 * len(code)} > 只读段 {ro_off:#x}）')
            for i, c in enumerate(code): struct.pack_into('<I', img, cave + 4 * i, c)
            struct.pack_into('<I', img, off, b(off, cave))
            print(f'{mod}+{off:#x} aspdiv → 跳板 {cave:#x}（{len(code)} 字）：')
            for ins in md.disasm(bytes(img[cave:cave + 4 * (len(code) - 3)]), cave): print(f'    {ins.address:#x}  {ins.mnemonic} {ins.op_str}')
            print(f'    字面量 16/9、2e-3、{W}/1080 = {W / 1080:.6f}；原址 {off:#x}：' + ' '.join(f'{i.mnemonic} {i.op_str}' for i in md.disasm(bytes(img[off:off + 4]), off)))
            cave += 4 * len(code); cave = (cave + 15) & ~15
        else: sys.exit(f'【红】{mod}+{off:#x} 种类 {kind} 还不支持静态打进 NSO（真值宽屏）')
        n += 1
    new_text = max(text_end, cave)
    # 输出：头（到第一段文件偏移，含模块名）+ 三段原文，不压缩、清段哈希校验位
    hdr_len = segs[0][0]; o = bytearray(d[:hdr_len])
    struct.pack_into('<I', o, 0xc, flags & ~0x3f)
    segs[0][2] = new_text; fo = hdr_len; body = bytearray()
    for i in range(3):
        mo, sz = segs[i][1], segs[i][2]
        struct.pack_into('<III', o, 0x10 + i * 0x10, fo, mo, sz); struct.pack_into('<I', o, 0x60 + 4 * i, sz)
        body += img[mo:mo + sz]; fo += sz
    open(out, 'wb').write(bytes(o + body))
    print(f'🟢 {mod}：改 {n} 个点，写 {out}（不压缩，{len(o) + len(body)} 字节，代码段 {text_end:#x} → {new_text:#x}）')


if __name__ == '__main__':
    main()
