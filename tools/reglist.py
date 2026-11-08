#!/usr/bin/env python3
"""按款登记表（10-30 总指挥：人人都改的大表结构上必冲突，拆成按款一文件，读取端合并）。
登记表 docs/<表名>.tsv → 目录 docs/<表名>/：
  _表头.tsv          表的说明（# 行）+ 表头行（原文件表头前的全部内容，原样）
  <程序号>.tsv       这一款的行：第一行是表头，下面是本款的数据行（原表行原样、原顺序）
  _无程序号.tsv      程序号列为空的行（直连缺陷上游的「关键词」行）
不同款的改动落在不同文件，永远不冲突；同一款两支同时改仍冲突（那是真冲突）。
读取端合并 = _表头.tsv 全文 + 各款文件的数据行（按文件名排序）——与原单文件同形，旧的逐行解析不用改；
合并文本每一行对应哪个文件第几行另给（locate），能力卡的证据定位指到按款文件。
用法：python3 tools/reglist.py migrate <仓库>        把五张旧单文件拆成目录（只在迁移那次用）
      python3 tools/reglist.py cat <仓库> <表名>     打合并文本（给 shell 读者：awk / grep）"""
import os, sys

TABLES = ('名单_能力强信号', '名单_60帧能力覆盖', '名单_60帧', '名单_满屏比例', '名单_直连缺陷上游', '名单_直连实测', '名单_输入能力', '名单_60帧逻辑速度')
HEAD, NOPID = '_表头.tsv', '_无程序号.tsv'


def name_of(path):
    """'docs/名单_能力强信号.tsv'（逻辑路径，各读者沿用的常量）→ '名单_能力强信号'；不是登记表 → None"""
    b = os.path.basename(path)
    return b[:-4] if b.endswith('.tsv') and b[:-4] in TABLES and os.path.dirname(path).endswith('docs') else None


def dir_of(name): return f'docs/{name}'


def _merge(head, parts):
    """head：_表头.tsv 文本；parts：[(相对路径, 文本)] → (合并文本, [每行对应 (相对路径, 文件内行号)])"""
    lines, loc = [], []
    hl = head.splitlines()
    for i, l in enumerate(hl, 1): lines.append(l); loc.append((None, i))
    hdr = next((l for l in hl if l.strip() and not l.startswith('#')), None)
    for p, t in sorted(parts):
        seen = False
        for i, l in enumerate(t.splitlines(), 1):
            if not l.strip() or l.startswith('#'): continue
            if not seen:
                seen = True
                if hdr is not None and l == hdr: continue   # 各款文件第一行是表头
            lines.append(l); loc.append((p, i))
    return '\n'.join(lines) + ('\n' if lines else ''), loc


def read(repo, name):
    """工作树读 → (合并文本, 定位表)；目录不在 → ('', [])"""
    d = os.path.join(repo, dir_of(name))
    if not os.path.isdir(d): return '', []
    head = open(os.path.join(d, HEAD), encoding='utf-8').read() if os.path.exists(os.path.join(d, HEAD)) else ''
    parts = [(f'{dir_of(name)}/{f}', open(os.path.join(d, f), encoding='utf-8').read()) for f in os.listdir(d) if f.endswith('.tsv') and f != HEAD]
    return _merge(head, parts)


def text(repo, name): return read(repo, name)[0]


def read_at(show, ls, name):
    """按提交读（能力卡）：show(相对路径) → bytes / None，ls(目录) → [相对路径] → (合并文本, 定位表)"""
    files = [p for p in ls(dir_of(name)) if p.endswith('.tsv')]
    head = next((show(p) for p in files if os.path.basename(p) == HEAD), b'') or b''
    parts = [(p, show(p).decode('utf-8')) for p in files if os.path.basename(p) != HEAD]
    return _merge(head.decode('utf-8'), parts)


def write(repo, name, merged):
    """合并文本 → 拆回目录（写者：读合并文本、改行、写回；只改动到的款的文件内容变）。没有行的款删文件"""
    d = os.path.join(repo, dir_of(name)); os.makedirs(d, exist_ok=True)
    L = merged.splitlines()
    i = next((k for k, l in enumerate(L) if l.strip() and not l.startswith('#')), None)
    if i is None: raise ValueError(f'{name}: 合并文本没有表头')
    hdr = L[i]; key = hdr.split('\t').index('程序号') if '程序号' in hdr.split('\t') else 0
    by = {}
    for l in L[i + 1:]:
        if not l.strip() or l.startswith('#'): continue
        pid = l.split('\t')[key].strip().upper()
        by.setdefault(f'{pid}.tsv' if pid else NOPID, []).append(l)
    new = {HEAD: '\n'.join(L[:i + 1]) + '\n', **{f: hdr + '\n' + '\n'.join(rs) + '\n' for f, rs in by.items()}}
    for f in os.listdir(d):
        if f.endswith('.tsv') and f not in new: os.remove(os.path.join(d, f))
    for f, t in new.items():
        p = os.path.join(d, f)
        if not os.path.exists(p) or open(p, encoding='utf-8').read() != t:
            with open(p, 'w', encoding='utf-8') as fh: fh.write(t)


def migrate(repo):
    for n in TABLES:
        old = os.path.join(repo, 'docs', f'{n}.tsv')
        if not os.path.exists(old): continue
        t = open(old, encoding='utf-8').read(); write(repo, n, t); m = text(repo, n)
        split = lambda x: (lambda L, i: (L[:i + 1], [l for l in L[i + 1:] if l.strip()]))(x.splitlines(), next(k for k, l in enumerate(x.splitlines()) if l.strip() and not l.startswith('#')))
        (h0, r0), (h1, r1) = split(t), split(m)
        key = lambda l: l.split('\t')[0].upper()
        assert h0 == h1 and sorted(r0) == sorted(r1) and all([l for l in r0 if key(l) == k] == [l for l in r1 if key(l) == k] for k in {key(l) for l in r0}), f'{n}: 拆分后合并与原文件不一致'
        os.remove(old); print(f'{n}：拆成 {len([f for f in os.listdir(os.path.join(repo, dir_of(n))) if f != HEAD])} 个文件；表头逐字一致、{len(r0)} 行数据一行不差（同款内顺序不变，款之间按程序号排）')


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == 'migrate': migrate(a[1])
    elif len(a) == 3 and a[0] == 'cat': sys.stdout.write(text(a[1], a[2]))
    else: print(__doc__.strip().splitlines()[0]); sys.exit(2)
