#!/usr/bin/env python3
# Monolith 着色器容器 SPCH 单测（nxsh_extract.scan_spch，11-07 异度神剑 3）：手搓 SPCH，期望值按格式定义手算（键 = sha256(控制段 ‖ 机器码) 前 16 位）。
# 布局：控制段集中在控制段区、机器码集中在代码区，相邻扫描配不上；SLCT 表首条偏移可为 0（SLCT 就在 SLCT 区起点）。
# 旧代码反证：旧抽取没有 scan_spch，第 1、2 项拿不到 #spch 来源（异度 3 读档首遇现编 32 支里 27 支即此）。
# 用法：t_spch.py [shbake 目录]（缺省本文件上一级）；退出 0 = 全过
import sys, os, struct, hashlib, zlib, collections
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12)
CN = 0x880
def shader(ty, seed, n):   # ty：1 vs / 5 ps
    code = bytearray(n); code[:16] = MG; struct.pack_into('<I', code, 0x30, ty << 10); code[0x40:0x48] = struct.pack('<Q', seed)
    ctl = bytearray(CN); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, CN); struct.pack_into('<I', ctl, 0x704, n); ctl[0x100] = seed & 0xff
    return bytes(ctl), bytes(code)
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
def spch(slcts):
    """slcts：[[程序, …], …]，程序 = [(控制段, 机器码), …]（按阶段顺序）。返回 SPCH 字节。
    头 12 个 u32：魔数、版本、SLCT 表偏移、条数、0、0、SLCT 区偏移、SLCT 区长、代码区偏移、长、控制段区偏移、长"""
    ctl_area = b''; code_area = b''; slct_blobs = []
    for progs in slcts:
        cr, dr = len(ctl_area), len(code_area); ent = []
        for prog in progs:
            ent.append((len(code_area) - dr, len(ctl_area) - cr))
            for ctl, code in prog: ctl_area += ctl; code_area += code
        pt = 0x40
        s = bytearray(pt + 8 * len(ent))
        s[:4] = b'SLCT'; struct.pack_into('<I', s, 4, 0x1003); struct.pack_into('<I', s, 0x10, len(ent)); struct.pack_into('<I', s, 0x1c, pt)
        struct.pack_into('<4I', s, 0x28, cr, len(ctl_area) - cr, dr, len(code_area) - dr)
        for i, (d, c) in enumerate(ent): struct.pack_into('<II', s, pt + 8 * i, d, c)
        slct_blobs.append(bytes(s) + bytes((-len(s)) % 16))
    to = 0x30; sb = to + 8 * len(slcts); sb += (-sb) % 16
    sl = b''; offs = []
    for b in slct_blobs: offs.append(len(sl)); sl += b
    co = sb + len(sl); co += (-co) % 0x100; xo = co + len(ctl_area); xo += (-xo) % 0x100
    out = bytearray(xo + len(code_area))
    struct.pack_into('<12I', out, 0, 0x53504348, 0x3f2, to, len(slcts), 0, 0, sb, len(sl), xo, len(code_area), co, len(ctl_area))
    for i, o in enumerate(offs): struct.pack_into('<II', out, to + 8 * i, o, 0)
    out[sb:sb + len(sl)] = sl; out[co:co + len(ctl_area)] = ctl_area; out[xo:] = code_area
    return bytes(out)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
V1, P1, V2, P2, V3, P3 = shader(1, 1, 0x200), shader(5, 2, 0x300), shader(1, 3, 0x100), shader(5, 4, 0x200), shader(1, 5, 0x200), shader(5, 6, 0x100)
# SLCT 0（偏移 0）：两个程序；SLCT 1：一个程序
S = spch([[[V1, P1], [V2, P2]], [[V3, P3]]])
pre = b'\xaa' * 0x40   # 嵌在别的数据后面（异度 3 .wipac 里一个文件嵌多个 SPCH）
blob = pre + S
want = sorted([(key(*V1), 'vs', 'f#spch0x40.0', 0), (key(*P1), 'ps', 'f#spch0x40.0', 0), (key(*V2), 'vs', 'f#spch0x40.0', 1), (key(*P2), 'ps', 'f#spch0x40.0', 1),
               (key(*V3), 'vs', 'f#spch0x40.1', 0), (key(*P3), 'ps', 'f#spch0x40.1', 0)])
# 1) 直接嵌在文件里：6 支，来源 <文件>#spch<偏移>.<SLCT 号>、变体号 = 程序号；机器码与控制段原样
rows, blobs, stat = [], {}, collections.Counter()
X._scan_blob('f', blob, rows, blobs, stat)
sp = sorted(r for r in rows if '#spch' in r[2])
check(sp == want, f'两 SLCT（首条偏移 0）三程序 → 6 条阶段记录（vs+ps ×3），来源 #spch0x40.<SLCT>、变体号 = 程序号：真结果 {len(sp)} 条，{"一致" if sp == want else sp}')
check(all(blobs.get(key(*s)) == (s[1], s[0]) for s in (V1, P1, V2, P2, V3, P3)), '落盘的机器码 / 控制段与原件逐字节相同')
# 2) 认领的控制段相邻扫描不再配（控制段后面紧跟的是下一支控制段，原先会被配成幽灵或丢弃）
adj = [r for r in rows if '@adj' in r[2]]
check(not adj, f'相邻扫描 0 条（控制段都被 SPCH 认领）：真结果 {len(adj)} 条')
# 3) 包在 zlib 流里（xbc1 zlib 条目解出 SPCH，走 scan_zlib）：同样 6 支，来源带 @z<流起点>
zb = b'\0' * 0x30 + zlib.compress(blob, 9) + b'\0' * 16
rows3, blobs3, stat3 = [], {}, collections.Counter()
X.scan_zlib('g', zb, rows3, blobs3, stat3)
k3 = sorted((r[0], r[1], r[3]) for r in rows3 if '#spch' in r[2])
check(k3 == sorted((k, s, v) for k, s, _, v in want) and all(r[2].startswith('g@z0x30#spch0x40.') for r in rows3 if '#spch' in r[2]),
      f'zlib 流里的 SPCH → 同样 6 支、来源 g@z0x30#spch…：真结果 {len(k3)} 条')
# 4) 坏一支控制段魔数：整个 SPCH 不认（不猜）、计红 1、不出 #spch
bad = bytearray(blob); c0 = 0x40 + struct.unpack_from('<I', S, 0x28)[0] + CN; bad[c0] ^= 0xff
rows4, stat4 = [], collections.Counter()
X._scan_blob('b', bytes(bad), rows4, {}, stat4)
check(not any('#spch' in r[2] for r in rows4) and stat4['【红】SPCH 结构对不上（不认，退回相邻扫描）'] == 1,
      f'坏控制段 → 整个 SPCH 不认、计红 1：真结果 #spch {sum("#spch" in r[2] for r in rows4)} 条、红 {stat4["【红】SPCH 结构对不上（不认，退回相邻扫描）"]}')
# 5) 假魔数（数据里碰巧出现 HCPS、头里的偏移越界）：不认、不计红
rows5, stat5 = [], collections.Counter()
X._scan_blob('h', b'HCPS' + b'\xff' * 0x60, rows5, {}, stat5)
check(not rows5 and not any('红' in k for k in stat5), f'假 HCPS → 0 条、不计红：真结果 {len(rows5)} 条、{dict(stat5)}')
print(f'SPCH 单测：{n - fail}/{n} 过')
sys.exit(1 if fail else 0)
