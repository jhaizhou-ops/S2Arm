#!/usr/bin/env python3
"""Ryujinx 真值 ↔ S2Arm 的 IPC 调用流对拍（全仓唯一一份；与服务接入线 compat/truth/ipc_diff.py 合并，五类输出 + 它的定性口径）：
  ipc_diff.py <真值记录> <我方记录> [--out 差异全表.tsv] [--skip 正则] [-n 每节最多列几种]
  ipc_diff.py --selftest
输入：两边同一份记录代码（S2A_IPC_RECORD，补丁 0038）写的文本，每行制表符分隔：
  序号  框架(HLE / HLE-TIPC / HZN)  服务  命令号  键=值…（in x a h rc out b w c oh obj，缺的键当空）
  命令号写 close 的是关会话 / 关句柄记录，和普通命令一起对齐。
算法：两边线程交错不同，全局序号不能直接比；按（服务, 命令）分组，第 i 次对第 i 次（服务内按服务分桶做 LCS 在多线程服务上会造出假缺多，已弃）。
  多出的次数：在本边全局最后一个对齐点之后的算「尾部」（两局时长 / 进度不同，不计）；其余及整种只一边有的算缺 / 多。
  对上的一对逐类比：返回码 rc；出参 out b w c obj；入参 in x a；句柄数 h oh。各类独立计数。
输出（标准输出 Markdown，按真值首次出现排序，按（服务, 命令）归并）：
  缺调用（真值有、我方没有）／多调用（我方有、真值没有）／返回码不同／出参与输出缓冲不同／入参与输入缓冲不同／句柄不同（句柄数、关句柄缺多）
  对上的类每种写「第 N 次起（共比 M 次，不同 K 次）」+ 第一处分歧的字段两边值；N 是该（服务, 命令）在真值里的第几次。
  --out 写逐条全表（类别 服务 命令 说明 真值序号 我方序号 真值原始行 我方原始行）。
退出码：0 无差异；3 有差异；2 输入问题。"""
import argparse, collections, os, re, sys, tempfile

CAT = ('缺调用', '多调用', '返回码不同', '出参与输出缓冲不同', '入参与输入缓冲不同', '句柄不同')
CHECKS = (('返回码不同', ('rc',)), ('出参与输出缓冲不同', ('out', 'b', 'w', 'c', 'obj')),
          ('入参与输入缓冲不同', ('in', 'x', 'a')), ('句柄不同', ('h', 'oh')))


def load(path, skip):
    rows, nth = [], collections.Counter()
    try:
        fh = open(path, encoding='utf-8', errors='replace')
    except OSError as e:
        print(f'【红】读不了 {path}：{e}', file=sys.stderr); sys.exit(2)
    with fh:
        for raw in fh:
            p = raw.rstrip('\n').split('\t')
            if len(p) < 4 or not p[0].isdigit(): continue
            if skip and re.search(skip, p[2]): continue
            close = p[3].strip().lower() in ('close', 'closehandle')
            rows.append({'seq': int(p[0]), 'svc': p[2], 'cmd': 'close' if close else p[3].strip(), 'close': close,
                         'kv': dict(it.partition('=')[::2] for it in p[4:]), 'raw': raw.rstrip('\n')})
    if not rows:
        print(f'【红】{path} 里没有一条记录', file=sys.stderr); sys.exit(2)
    rows.sort(key=lambda r: r['seq'])
    for r in rows:
        nth[(r['svc'], r['cmd'])] += 1; r['nth'] = nth[(r['svc'], r['cmd'])]
    return rows


def compare(A, B):
    """按（服务, 命令）逐次对齐（第 i 次对第 i 次；线程交错两边不同，同一（服务, 命令）内的先后次序两边应一致）。
    返回 (逐条差异 [(类别, x, y, 说明)], 对齐对数, 尾部 [真值, 我方], 共比次数 {(服务, 命令): n})"""
    ga, gb = collections.defaultdict(list), collections.defaultdict(list)
    for r in A: ga[(r['svc'], r['cmd'])].append(r)
    for r in B: gb[(r['svc'], r['cmd'])].append(r)
    keys = sorted(set(ga) | set(gb), key=str)
    ncmp = collections.Counter({k: min(len(ga[k]), len(gb[k])) for k in keys})
    # 「尾部」：两边都有的（服务, 命令）多出的次数，在本边全局最后一个对齐点之后的算两局进度差、不计；在之前的是真缺 / 多
    maxa = max((ga[k][n - 1]['seq'] for k, n in ncmp.items() if n), default=-1)
    maxb = max((gb[k][n - 1]['seq'] for k, n in ncmp.items() if n), default=-1)
    diffs, ntail = [], [0, 0]
    for k in keys:
        a, b, n = ga[k], gb[k], ncmp[k]
        for x, y in zip(a, b):
            for cat, fields in CHECKS:
                d = [f for f in fields if x['kv'].get(f, '') != y['kv'].get(f, '')]
                if d: diffs.append((cat, x, y, '；'.join(f"{f} 我方 {y['kv'].get(f) or '—'} / 真值 {x['kv'].get(f) or '—'}" for f in d)))
        for side, extra, lim in ((0, a[n:], maxa), (1, b[n:], maxb)):
            for r in extra:
                if n and r['seq'] > lim: ntail[side] += 1; continue
                x, y = (r, None) if side == 0 else (None, r)
                cat = '句柄不同' if r['close'] else ('缺调用' if side == 0 else '多调用')
                diffs.append((cat, x, y, '真值有、我方没有' if side == 0 else '我方有、真值没有'))
    return diffs, sum(ncmp.values()), ntail, ncmp


def report(A, B, diffs, npair, ntail, ncmp, n):
    first = {}
    for r in A: first.setdefault((r['svc'], r['cmd']), r['seq'])
    off = A[-1]['seq'] + 1
    for r in B: first.setdefault((r['svc'], r['cmd']), off + r['seq'])   # 只我方有的排在真值之后，按我方次序
    cnt_a, cnt_b = collections.Counter((r['svc'], r['cmd']) for r in A), collections.Counter((r['svc'], r['cmd']) for r in B)
    by = collections.defaultdict(dict)
    for cat, x, y, why in diffs:
        r = x or y; by[cat].setdefault((r['svc'], r['cmd']), []).append((x, y, why))
    print(f'# IPC 对拍差异清单\n\n真值 {len(A)} 条 / {len(cnt_a)} 种（服务, 命令）；我方 {len(B)} 条 / {len(cnt_b)} 种；'
          f'对齐 {npair} 对；尾部未对上 真值 {ntail[0]} / 我方 {ntail[1]} 条（两局进度差，不计）\n')
    print('差异：' + ('，'.join(f'{c} {len(by[c])} 种 {sum(map(len, by[c].values()))} 条' for c in CAT if by[c]) or '无') + '\n')
    for cat in CAT:
        gs = sorted(by[cat].items(), key=lambda kv: first[kv[0]])
        print(f'## {cat}（{len(gs)} 种，按真值首次出现排序）\n')
        if not gs: print('（无）\n'); continue
        for (svc, cmd), items in gs[:n]:
            x, y, why = items[0]
            if x is None or y is None:
                side, e = ('真值', x) if y is None else ('我方', y)
                whole = '整种只一边有' if (cnt_b if y is None else cnt_a)[(svc, cmd)] == 0 else f'真值共 {cnt_a[(svc, cmd)]} / 我方共 {cnt_b[(svc, cmd)]} 次'
                print(f"- {svc} #{cmd}：{side}多出 {len(items)} 次（{whole}），第一处为{side}第 {e['nth']} 次、序号 {e['seq']}，rc={e['kv'].get('rc')}")
            else:
                print(f"- {svc} #{cmd}：第 {x['nth']} 次起（共比 {ncmp[(svc, cmd)]} 次，不同 {len(items)} 次）：{why}")
        if len(gs) > n: print(f'- ……另 {len(gs) - n} 种见 --out 全表')
        print()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('truth', nargs='?'); ap.add_argument('ours', nargs='?')
    ap.add_argument('--out'); ap.add_argument('--skip', default='')
    ap.add_argument('-n', type=int, default=50); ap.add_argument('--selftest', action='store_true')
    o = ap.parse_args(argv)
    if o.selftest: return selftest()
    if not (o.truth and o.ours): ap.error('要两份记录：<真值> <我方>')
    A, B = load(o.truth, o.skip), load(o.ours, o.skip)
    diffs, npair, ntail, ncmp = compare(A, B)
    report(A, B, diffs, npair, ntail, ncmp, o.n)
    if o.out:
        with open(o.out, 'w', encoding='utf-8') as f:
            f.write('类别\t服务\t命令\t说明\t真值序号\t我方序号\t真值原始行\t我方原始行\n')
            for c, x, y, why in diffs:
                r = x or y
                f.write('\t'.join([c, r['svc'], r['cmd'], why, str(x['seq']) if x else '-', str(y['seq']) if y else '-',
                                   (x['raw'] if x else '-').replace('\t', ' ¦ '), (y['raw'] if y else '-').replace('\t', ' ¦ ')]) + '\n')
    return 3 if diffs else 0


def selftest():
    """造两份调用流，六类各一处 + 尾部 + 整种只一边有，期望值按规则手写"""
    def text(rows):
        out = ''
        for s, (svc, cmd, kv) in enumerate(rows, 1):
            d = {'in': '8:aa', 'h': '0/0', 'rc': '0', 'out': '4:bb', 'oh': '0/0'}; d.update(kv)
            out += '\t'.join([str(s), 'HLE', svc, str(cmd)] + [f'{k}={v}' for k, v in d.items()]) + '\n'
        return out
    truth = [('I', 0, {}), ('I', 1, {}), ('I', 2, {'out': '4:cc'}), ('I', 3, {'x': '8:11'}), ('S', 0, {}),
             ('S', 'close', {}), ('I', 4, {'oh': '1/0'}), ('I', 9, {}), ('OnlyT', 0, {}), ('I', 0, {})]
    ours = [('I', 0, {}), ('I', 1, {'rc': '2a'}), ('I', 2, {'out': '4:cd'}), ('I', 3, {'x': '8:12'}), ('S', 0, {}),
            ('I', 7, {}), ('I', 4, {'oh': '0/0'})]
    # 期望：I#1 返回码；I#2 出参；I#3 入参；I#4 句柄数；S close 我方没有 → 句柄不同；I#7 我方多；OnlyT、I#9 整种只真值有 → 缺；
    #       尾部：真值再多一次 I#0（序号 10 > 真值最后对齐点 7）
    d = tempfile.mkdtemp(); pt, po, pr = (os.path.join(d, x) for x in ('t.txt', 'o.txt', 'r.tsv'))
    open(pt, 'w').write(text(truth)); open(po, 'w').write(text(ours))
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): rc = main([pt, po, '--out', pr])
    got = collections.Counter(l.split('\t')[0] for l in open(pr).read().splitlines()[1:])
    want = {'返回码不同': 1, '出参与输出缓冲不同': 1, '入参与输入缓冲不同': 1, '句柄不同': 2, '多调用': 1, '缺调用': 2}
    t = buf.getvalue()
    ok = (rc == 3 and dict(got) == want and '尾部未对上 真值 1 / 我方 0' in t and '- OnlyT #0：真值多出 1 次（整种只一边有）' in t
          and '- I #1：第 1 次起（共比 1 次，不同 1 次）：rc 我方 2a / 真值 0' in t)
    # 中间缺一条普通命令（真值 I#5 插在 I#1 之后，不是尾部）
    open(pt, 'w').write(text(truth[:2] + [('I', 5, {})] + truth[2:]))
    with contextlib.redirect_stdout(io.StringIO()): main([pt, po, '--out', pr])
    got2 = collections.Counter(l.split('\t')[0] for l in open(pr).read().splitlines()[1:])
    ok = ok and got2.get('缺调用') == 3
    print('ipc_diff 自测 ' + ('通过' if ok else f'不通过：{dict(got)} / {dict(got2)}\n{t}'))
    return 0 if ok else 1


if __name__ == '__main__': sys.exit(main())
