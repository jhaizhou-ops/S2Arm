#!/usr/bin/env python3
"""宽屏第二层启用点的跨版本移植（直连线 10-26）：游戏一更新，主程序构建号变了，按构建号绑定的启用表就不生效（10-26 动森：表在 5d913cf7、
现行包 ff1d1c05，退回整套放宽出右侧 18% 拉丝）。这里给每个启用点存一份「前后指令特征的摘要」，新版本里按摘要找唯一匹配，移植出新偏移；
移植出的点照样要过闭环才启用。同上游参考实现的 MATCH_CUTS（按函数指纹跨版本找切点）思路。只存摘要和点本身那一条原字（候选表证据里本来就有），
不存游戏代码。

  widen_sig.py make <exefs 目录> <点集 m:o,…> <widen_sites.tsv> <输出 widen_sig.tsv>
      点集里每个点：按半窗口 n（HALF 各档）取前后各 n 字，代码点按指令类屏蔽随版本变的位（B / BL / B.cond / CBZ / TBZ 的跳转量、ADR / ADRP 的页地址、
      LDR 字面量偏移；数据点 f32 不屏蔽），记每档的 sha1 前 16 位，以及「在本模块里唯一」的最小一档
  widen_sig.py port <exefs 目录> <widen_sig.tsv> <widen_sites.tsv>
      逐点：新模块里屏蔽后与点本身相同的位置里，从最小一档起找摘要相同的，不唯一就换更宽的一档；唯一、原字相同、新偏移在候选表里且种类相同才算移植成功。
      标准输出：移植成功的点集（m:o,…，同 S2A_WIDEN_SITES 口径，可能为空）；标准错误：每点一行结论。退出码 0 = 全部成功，1 = 有点没移植成（成功的照样输出），2 = 输入错
widen_sig.tsv：模块 / 偏移 / 种类 / 最小半窗口 / 原字 / 各档摘要（n=摘要，空格分隔）
"""
import hashlib, os, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wide_scan import load   # 原版 NSO 按段解压铺成内存映像；已铺好的映像原样读

HALF = (2, 3, 4, 6, 8, 12, 16, 24)
DATA = {'f32', 'aspf', 'i32'}   # 数据点：不屏蔽


def mask(w):   # w：uint32 数组；同 mask_one，向量化
    w = w.astype(np.uint32); m = w.copy(); op = w >> 26
    for cond, keep in (((op == 0x05) | (op == 0x25), 0xFC000000),                  # B / BL
                       ((w & 0xFF000010) == 0x54000000, 0xFF00001F),             # B.cond
                       ((w & 0x7E000000) == 0x34000000, 0xFF00001F),             # CBZ / CBNZ
                       ((w & 0x7E000000) == 0x36000000, 0xFFF8001F),             # TBZ / TBNZ
                       ((w & 0x1F000000) == 0x10000000, 0x9F00001F),             # ADR / ADRP
                       ((w & 0x3B000000) == 0x18000000, 0xFF00001F)):            # LDR 字面量
        sel = cond & (m == w); m[sel] = w[sel] & np.uint32(keep)
    return m


def digest(a): return hashlib.sha1(a.astype('<u4').tobytes()).hexdigest()[:16]


def image(path, kind):
    raw = load(path); w = np.frombuffer(raw[:len(raw) // 4 * 4], dtype='<u4')
    return w, (w if kind in DATA else mask(w))


def modules(exefs):
    return {m: os.path.join(exefs, m) for m in os.listdir(exefs) if m != 'rtld' and not m.endswith('.npdm') and os.path.isfile(os.path.join(exefs, m))}


def sites(path):
    rows = [l.rstrip('\n').split('\t') for l in open(path)][1:]
    return {(r[0], int(r[1], 16)): r[2] for r in rows if len(r) >= 3}


def matches(mw, centre, n, want, limit=2):   # 屏蔽后中心字相同、半窗口 n 摘要等于 want 的位置
    out = []
    for j in np.nonzero(mw == centre)[0]:
        j = int(j)
        if j - n < 0 or j + n >= len(mw): continue
        if digest(mw[j - n:j + n + 1]) == want:
            out.append(j)
            if len(out) >= limit: break
    return out


def make(exefs, points, sites_tsv, out):
    cand, mods, cache, lines = sites(sites_tsv), modules(exefs), {}, ['模块\t偏移\t种类\t最小半窗口\t原字\t各档摘要']
    for p in points.split(','):
        m, o = p.split(':'); off = int(o, 16)
        if (m, off) not in cand: print(f'🔴 {p} 不在候选表里', file=sys.stderr); return 2
        kind = cand[(m, off)]; data = kind in DATA
        if (m, data) not in cache: cache[(m, data)] = image(mods[m], kind)
        w, mw = cache[(m, data)]; i = off // 4
        if off % 4 or i >= len(w): print(f'🔴 {p} 偏移越界 / 不对齐', file=sys.stderr); return 2
        ds = {n: digest(mw[i - n:i + n + 1]) for n in HALF if i - n >= 0 and i + n < len(mw)}
        n0 = next((n for n in sorted(ds) if len(matches(mw, mw[i], n, ds[n])) == 1), None)
        if n0 is None: print(f'🟡 {p}（{kind}）前后 {max(HALF)} 字在本模块里都不唯一，特征不可用，不记', file=sys.stderr); continue
        lines.append(f'{m}\t{off:#x}\t{kind}\t{n0}\t{int(w[i]):08x}\t' + ' '.join(f'{n}={d}' for n, d in sorted(ds.items())))
    open(out, 'w').write('\n'.join(lines) + '\n')
    print(f'特征 {len(lines) - 1} 个 → {out}', file=sys.stderr); return 0


def port(exefs, sig_tsv, sites_tsv):
    cand, mods, cache, got, bad = sites(sites_tsv), modules(exefs), {}, [], 0
    for r in [l.rstrip('\n').split('\t') for l in open(sig_tsv)][1:]:
        m, off, kind, n0, orig = r[0], int(r[1], 16), r[2], int(r[3]), int(r[4], 16)
        ds = {int(k): v for k, v in (x.split('=') for x in r[5].split())}
        tag = f'{m}:{off:#x}（{kind}）'
        if m not in mods: print(f'🟡 {tag}：新版本没有模块 {m}', file=sys.stderr); bad += 1; continue
        data = kind in DATA
        if (m, data) not in cache: cache[(m, data)] = image(mods[m], kind)
        w, mw = cache[(m, data)]
        centre = np.uint32(orig) if data else mask(np.array([orig], dtype=np.uint32))[0]
        hit, why = None, '找不到'
        for n in [n for n in sorted(ds) if n >= n0]:
            h = matches(mw, centre, n, ds[n])
            if len(h) == 1: hit = h[0]; break
            if not h: why = '找不到'; break
            why = '不唯一'
        if hit is None: print(f'🟡 {tag}：新版本里{why}', file=sys.stderr); bad += 1; continue
        no = hit * 4
        if int(w[hit]) != orig: print(f'🟡 {tag} → {no:#x}：原字 {int(w[hit]):08x} ≠ 旧 {orig:08x}', file=sys.stderr); bad += 1; continue
        if cand.get((m, no)) != kind: print(f'🟡 {tag} → {no:#x}：不在新候选表里（{cand.get((m, no), "无")}）', file=sys.stderr); bad += 1; continue
        print(f'🟢 {tag} → {m}:{no:#x}', file=sys.stderr); got.append(f'{m}:{no:#x}')
    print(','.join(got)); return 1 if bad else 0


def main():
    a = sys.argv[1:]
    if len(a) == 5 and a[0] == 'make': return make(*a[1:])
    if len(a) == 4 and a[0] == 'port': return port(*a[1:])
    print(__doc__, file=sys.stderr); return 2


if __name__ == '__main__':
    sys.exit(main())
