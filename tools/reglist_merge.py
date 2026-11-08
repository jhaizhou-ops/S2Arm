#!/usr/bin/env python3
"""按款登记表的 git 合并器（11-06 总指挥：普查收批 c1105_mc_flk1 / flk2 都登记 Minecraft，后合的那支在
docs/名单_60帧逻辑速度/0100D71004694000.tsv 等文件上文本冲突、整支退回让人手修）。
.gitattributes 把 docs/名单_*/*.tsv 交给它（merge=s2a-reglist）；列车启动时在仓库配置里登记：
  git config merge.s2a-reglist.driver 'python3 tools/reglist_merge.py %O %A %B'
规则（与 tools/census/census.py 各写入函数同一口径）：
  - 文件 = 若干 # 说明行 + 表头行 + 数据行（tools/reglist.py 按款文件 / _表头.tsv）。两边表头不同 → 不合，退出 1（留给人）。
  - 行键按表取（KEYS）；没登记的表整行当键（只并集去重）。
  - 键只在一边 → 留；两边相同 → 留一份；两边不同 → 有「日期」列取日期大的，日期相同或没有日期取 %B（正在合入的那支 = 后一批）。
  - 输出顺序：%A 原有行按原序（被换的行原位替换），%B 新增的行接在后面。写回 %A，退出 0。"""
import os, sys

KEYS = {'名单_60帧逻辑速度': ('程序号', '构建号'), '名单_直连实测': ('程序号', '构建号', '平台'),
        '名单_60帧能力覆盖': ('程序号', '构建号'), '名单_能力强信号': ('程序号', '构建号', '能力')}


def split(text):
    lines = text.splitlines(); i = 0
    while i < len(lines) and (lines[i].startswith('#') or not lines[i].strip()): i += 1
    return lines[:i], (lines[i] if i < len(lines) else None), [l for l in lines[i + 1:] if l.strip()]


def main(o, a, b, path=''):
    ta, tb = (open(p, encoding='utf-8').read() for p in (a, b))
    ca, ha, ra = split(ta); cb, hb, rb = split(tb)
    if ha is None or hb is None or ha != hb: return 1
    cols = ha.split('\t'); table = os.path.basename(os.path.dirname(path)) if path else ''
    kc = [cols.index(c) for c in KEYS.get(table, ()) if c in cols]
    di = cols.index('日期') if '日期' in cols else None
    key = (lambda l: tuple((l.split('\t') + [''] * len(cols))[i] for i in kc)) if kc else (lambda l: l)
    date = (lambda l: (l.split('\t') + [''] * len(cols))[di]) if di is not None else (lambda l: '')
    pick = {}
    for l in rb: pick[key(l)] = l
    out, seen = [], set()
    for l in ra:
        k = key(l)
        if k in seen: continue
        seen.add(k); r = pick.get(k, l)
        out.append(l if (r != l and date(l) > date(r)) else r)
    out += [l for l in rb if key(l) not in seen and not seen.add(key(l))]
    open(a, 'w', encoding='utf-8').write('\n'.join(ca + [ha] + out) + '\n')
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 4: sys.exit('用法：reglist_merge.py <基> <本侧（写回）> <对侧> [路径]')
    sys.exit(main(*sys.argv[1:5]))
