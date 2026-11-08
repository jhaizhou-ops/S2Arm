#!/usr/bin/env python3
# 直连缓存按容量预算淘汰（LRU；11-02 出包线，jhz「存储换时间」：缓存放 2T，超预算才删最久没用的，不按天数删）。tools/gc.sh 每轮调：
#   python3 tools/direct_cache_lru.py <cache/direct 目录> --budget-gb <预算> [--in-use <程序号,…>] [--dry]
# 统计：<目录>/<程序号>/ 下全部文件的字节（合计）；能淘汰的只有内容寻址仓条目 <程序号>/store/**/*.e（C# 出库链 Store，graphics/tools/direct/dsh/batch/Build.cs：
#   翻译结果与 Metal 库，删了下次按需重算；出库整理只给本次用到的条目刷新修改时间、不删——修改时间就是「最近用过」）。
# 合计不超预算 → 什么都不删；超了 → 按修改时间从旧到新删条目，直到回到预算以内。在跑的款（--in-use：调用方按进程命令行里出现的 cache/direct/<程序号> 认）整款不动。
# 标准输出一行结论：未超 / 删了几条几 GB、涉及哪几款 / 删到不在用的都删完仍超（【黄】）。--dry 只打「会删」不删
import argparse, os, sys


def scan(root):
    """→ (合计字节, [(修改时间, 字节, 路径, 程序号)] 仓条目)"""
    total, ents = 0, []
    for tid in sorted(os.listdir(root)):
        d = os.path.join(root, tid)
        if not os.path.isdir(d) or os.path.islink(d): continue
        for dp, dns, fns in os.walk(d):
            dns[:] = [n for n in dns if not os.path.islink(os.path.join(dp, n))]
            for fn in fns:
                p = os.path.join(dp, fn)
                try: st = os.lstat(p)
                except OSError: continue
                total += st.st_size
                if fn.endswith('.e') and os.sep + 'store' + os.sep in p[len(d):] + os.sep: ents.append((st.st_mtime, st.st_size, p, tid))
    return total, ents


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root'); ap.add_argument('--budget-gb', type=float, required=True)
    ap.add_argument('--in-use', default=''); ap.add_argument('--dry', action='store_true')
    a = ap.parse_args()
    if not os.path.isdir(a.root): print(f'直连缓存目录 {a.root} 不在，跳过'); return 0
    budget, busy = int(a.budget_gb * (1 << 30)), {t for t in a.in_use.split(',') if t}
    total, ents = scan(a.root)
    gb = lambda n: f'{n / (1 << 30):.1f} GB'
    if total <= budget: print(f'直连缓存 {gb(total)}，未超预算 {gb(budget)}，不淘汰'); return 0
    over, n, freed, games = total - budget, 0, 0, set()
    for mt, size, p, tid in sorted(ents):
        if freed >= over: break
        if tid in busy: continue
        if not a.dry:
            try: os.remove(p)
            except OSError: continue
        n += 1; freed += size; games.add(tid)
    verb = '会删' if a.dry else '删'
    tail = f'{verb} {n} 条最久没用的仓条目 {gb(freed)}（{len(games)} 款：{" ".join(sorted(games)[:8])}{" …" if len(games) > 8 else ""}）'
    if freed < over: print(f'【黄】直连缓存 {gb(total)} 超预算 {gb(budget)}：{tail}，不在用的都删完仍超 {gb(over - freed)}（在用 {len(busy)} 款不动）')
    else: print(f'直连缓存 {gb(total)} 超预算 {gb(budget)}：{tail}，回到 {gb(total - freed)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
