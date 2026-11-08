#!/usr/bin/env python3
"""Metal 3 归档组合数测算（#116 / M3-9 验收第 1 条：纯数据，先交）。

用法：m3_combo.py <shcollect 根 | 单款目录…> [--per-arch N] [--per-os N] [--bytes-per-pipe N]

每款算四件事：
  1. 程序数（programs.tsv 里的图形程序）与 spec_pipes.tsv 行数（v2 完整 / b2 基础）
  2. 每程序平均颜色组合数 = (v2 + b2) / 图形程序数
  3. 按完整描述出归档的条数 = 基础管线（每图形程序 1 条）+ v2 + b2
  4. 体积估算 + 按「设备系统版本数 × GPU 架构数」乘出去的总条数与总体积

体积用 --bytes-per-pipe 拟合（缺省 13520：一次实测的 1 条管线归档字节，Mac / applegpu_g16g / macOS 27.0）。
把「系统版本数」乘进来是 10-23/10-24 两条实测结论的直接后果：归档最低系统版本必须与运行时系统一致
（27.0 命中、26.0 / 15.0 不命中），所以一份归档不能通吃多个系统大版本。

--self-test：用造的样本自证算法（不读真实数据），打印期望 → 真结果。
"""
import os, sys, json

def read_tsv(p):
    rows = []
    if not os.path.isfile(p): return rows
    for l in open(p, encoding='utf-8', errors='replace'):
        if l.startswith('#') or not l.strip(): continue
        rows.append(l.rstrip('\n').split('\t'))
    return rows

def count_spec(p):
    v2 = b2 = 0
    for l in open(p, encoding='utf-8', errors='replace'):
        if l.startswith('#') or not l.strip(): continue
        f = l.split('#')[0].split()
        if not f: continue
        if f[0] == 'v2': v2 += 1
        elif f[0] == 'b2': b2 += 1
    return v2, b2

def graphics_programs(p):
    n = 0
    for r in read_tsv(p):
        if len(r) < 6: continue
        if r[0] == 'idx': continue          # 表头
        if r[3] != 'graphics': continue     # 只算图形程序（计算管线不吃颜色组合）
        if r[2] not in ('ok', ''): continue # 编库失败的跳过，与 pso_gen 口径一致
        n += 1
    return n

def one_game(d, bpp):
    spec = os.path.join(d, 'spec_pipes.tsv')
    prog = os.path.join(d, 'programs.tsv')
    v2, b2 = count_spec(spec) if os.path.isfile(spec) else (0, 0)
    g = graphics_programs(prog)
    base = g                                  # 每个图形程序一条基础管线（颜色留空）
    total = base + v2 + b2
    avg = (v2 + b2) / g if g else 0.0
    return {'game': os.path.basename(d.rstrip('/')), 'graphics': g, 'v2': v2, 'b2': b2,
            'base': base, 'total': total, 'avg_per_program': round(avg, 2),
            'bytes': total * bpp}

def main(argv):
    if '--self-test' in argv:
        # 造 3 个图形程序 + 5 行 v2 + 2 行 b2 → 基础 3 + 5 + 2 = 10 条，平均 (5+2)/3 = 2.33
        import tempfile
        d = tempfile.mkdtemp()
        open(os.path.join(d, 'programs.tsv'), 'w').write(
            'idx\torigin\tstatus\tkind\tsource\tstages\n'
            '0\tt\tok\tgraphics\tt\tt\n1\tt\tok\tgraphics\tt\tt\n2\tt\tok\tgraphics\tt\tt\n'
            '3\tt\tok\tcompute\tt\tt\n4\tt\tbad\tgraphics\tt\tt\n')
        open(os.path.join(d, 'spec_pipes.tsv'), 'w').write(
            '# 表\n' + ''.join('v2 s1 s2 3 1 0 0 1 \n' for _ in range(5)) + ''.join('b2 s1 s2 0 1 0 0 1\n' for _ in range(2)))
        r = one_game(d, 1000)
        exp = {'graphics': 3, 'v2': 5, 'b2': 2, 'base': 3, 'total': 10, 'avg_per_program': 2.33, 'bytes': 10000}
        ok = all(r[k] == exp[k] for k in exp)
        print('自测：%s' % ('通过' if ok else '失败'))
        for k in exp:
            print('  %-16s 期望 %-8s → 真结果 %s' % (k, exp[k], r[k]))
        return 0 if ok else 1
    args = [a for a in argv[1:] if not a.startswith('--')]
    bpp = 13520; per_arch = 1; per_os = 1
    for i, a in enumerate(argv):
        if a == '--bytes-per-pipe': bpp = int(argv[i + 1])
        if a == '--per-arch': per_arch = int(argv[i + 1])
        if a == '--per-os': per_os = int(argv[i + 1])
    if not args:
        print(__doc__); return 2
    games = []
    for a in args:
        if os.path.isdir(os.path.join(a, 'spec_pipes.tsv')) or os.path.isfile(os.path.join(a, 'programs.tsv')):
            games.append(a)
        elif os.path.isdir(a):
            games += [os.path.join(a, x) for x in sorted(os.listdir(a)) if os.path.isdir(os.path.join(a, x))]
    res = [one_game(g, bpp) for g in games]
    tot = sum(r['total'] for r in res)
    print('%-24s %8s %6s %6s %6s %8s %10s' % ('款', '图形程序', 'v2', 'b2', '平均组合', '归档条数', '体积MB'))
    for r in res:
        print('%-24s %8d %6d %6d %6.2f %8d %10.1f' % (r['game'], r['graphics'], r['v2'], r['b2'],
                                                      r['avg_per_program'], r['total'], r['bytes'] / 1e6))
    print('---')
    print('九款合计（单系统 × 单架构）：%d 条，%.1f MB' % (tot, tot * bpp / 1e6))
    print('按 %d 个系统大版本 × %d 个 GPU 架构展开：%d 条，%.1f MB' % (per_os, per_arch, tot * per_os * per_arch,
                                                              tot * per_os * per_arch * bpp / 1e6))
    print(json.dumps({'games': res, 'total': tot, 'per_os': per_os, 'per_arch': per_arch,
                      'expanded': tot * per_os * per_arch}, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
