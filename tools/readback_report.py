#!/usr/bin/env python3
"""读回归因报告（#203 / L01）：按局目录出「谁让 CPU 等 GPU 读回」的排行。

用法：readback_report.py <局目录> [--json]

数据源（都是现有产物，不改运行时）：
  frames.tsv  rb_us      每帧读回 / 同步号阻塞（微秒）；gpuq_us 是分配器环反压，单独算，不混进读回
              wall_us    帧间隔；draw_n / pso_n / pso_us 辅助列
  host.log    READFLUSH  写跟踪的读回计数（宿主不经保护读、游戏读写不可读页先回写等）

分段：以 host.log 里「S2A 标记 MARK」为界，分加载期 / 可操作期——读回集中在加载期还是玩的时候，结论完全不同。

归因：运行时已有现成打点 NXGAL_WAIT_SITE=1（graphics/metal/gal_core.m 的 wait_site_note，缺省关），
  它按「调用链 + 线程 + rb/bp」累计 CPU 等 GPU 的毫秒 / 次数 / 单次最长，每 5 秒打一行 [waitsite]。
  局里带这个开关跑过，本工具就把这些行解析成来源排行；没带就如实标 not_instrumented，不假装有归因。
"""
import csv, json, os, re, statistics, sys

def read_frames(d):
    p = os.path.join(d, 'frames.tsv')
    if not os.path.isfile(p): return []
    return list(csv.DictReader(open(p, errors='replace'), delimiter='\t'))

def mark_frame(d):
    p = os.path.join(d, 'host.log')
    if not os.path.isfile(p): return None
    for l in open(p, errors='replace'):
        m = re.search(r'S2A 标记 MARK：帧 (\d+)', l)
        if m: return int(m.group(1))
    return None

WAITSITE = re.compile(r'\[waitsite\] (rb|bp) ([\d.]+) ms ×(\d+) 最长 ([\d.]+) ms 线程 (.*?)（(录制|非录制)）(.*)$')

def read_waitsites(d):
    """解析 NXGAL_WAIT_SITE=1 打出的 [waitsite] 行：按「调用链 + 线程 + 类型」去重，取最后一次累计值（它是累计量）。"""
    p = os.path.join(d, 'host.log')
    if not os.path.isfile(p): return []
    seen = {}
    for l in open(p, errors='replace'):
        m = WAITSITE.search(l.rstrip('\n'))
        if not m: continue
        kind, total, cnt, mx, thread, rec, chain = m.groups()
        chain = chain.strip()
        key = (kind, thread.strip(), chain)
        seen[key] = {'kind': '读回/同步号' if kind == 'rb' else '分配器环反压',
                     'total_ms': float(total), 'count': int(cnt), 'max_ms': float(mx),
                     'thread': thread.strip(), 'recorded': rec, 'chain': chain}
    return sorted(seen.values(), key=lambda x: -x['total_ms'])

def readflush(d):
    p = os.path.join(d, 'host.log')
    if not os.path.isfile(p): return []
    return [l.strip() for l in open(p, errors='replace') if 'READFLUSH' in l]

def stats(xs):
    if not xs: return {'n': 0}
    s = sorted(xs)
    q = lambda p: s[min(len(s) - 1, int(len(s) * p))]
    return {'n': len(s), 'sum_us': sum(s), 'max_us': s[-1], 'mean_us': round(statistics.mean(s), 1),
            'p50': q(.5), 'p90': q(.9), 'p99': q(.99)}

def segment(rows, mf):
    out = {}
    for name, sel in (('加载期', lambda f: mf is None or f < mf), ('可操作期', lambda f: mf is not None and f >= mf)):
        rb = [int(r['rb_us']) for r in rows if r.get('rb_us', '').strip() and sel(int(r['frame']))]
        wall = [int(r['wall_us']) for r in rows if r.get('wall_us', '').strip() and sel(int(r['frame']))]
        out[name] = {'rb': stats([x for x in rb if x > 0]), 'rb_all_us': sum(rb),
                     'frames': len(rb), 'wall_us': sum(wall),
                     'rb_share_of_wall': round(sum(rb) / sum(wall) * 100, 2) if wall and sum(wall) else None}
    return out

def main(argv):
    if len(argv) < 2: print(__doc__); return 2
    d = argv[1]; as_json = '--json' in argv
    rows = read_frames(d); mf = mark_frame(d); rf = readflush(d)
    rep = {'dir': os.path.abspath(d), 'frames': len(rows), 'mark_frame': mf,
           'segments': segment(rows, mf), 'readflush_lines': len(rf),
           'readflush_last': rf[-1] if rf else None,
           'waitsites': read_waitsites(d),
           'attribution': 'waitsite' if read_waitsites(d) else 'not_instrumented'}
    if as_json: print(json.dumps(rep, ensure_ascii=False, indent=1)); return 0
    print(f"局目录 {rep['dir']}")
    print(f"帧数 {rep['frames']}   MARK 帧 {mf if mf is not None else '（没有 MARK）'}   READFLUSH 行 {len(rf)}")
    print()
    print(f"{'分段':<8} {'非零帧':>6} {'合计ms':>8} {'最长ms':>8} {'均值ms':>8} {'P90us':>8} {'P99us':>8} {'占墙钟%':>8}")
    for name, s in rep['segments'].items():
        rb = s['rb']
        print(f"{name:<8} {rb.get('n',0):>6} {s['rb_all_us']/1000:>8.1f} {rb.get('max_us',0)/1000:>8.2f} "
              f"{rb.get('mean_us',0)/1000:>8.2f} {rb.get('p90',0):>8} {rb.get('p99',0):>8} "
              f"{(s['rb_share_of_wall'] if s['rb_share_of_wall'] is not None else 0):>8.2f}")
    print()
    ws = rep['waitsites']
    if ws:
        print(f"来源排行（NXGAL_WAIT_SITE=1，按累计阻塞降序，共 {len(ws)} 条）")
        print(f"{'类型':<14} {'累计ms':>8} {'次数':>6} {'最长ms':>8} {'线程':<14} 调用链")
        for x in ws[:15]:
            print(f"{x['kind']:<14} {x['total_ms']:>8.1f} {x['count']:>6} {x['max_ms']:>8.2f} {x['thread'][:14]:<14} {x['chain'][:60]}")
    else:
        print('来源归因：本局没带 NXGAL_WAIT_SITE=1（缺省关），只有每帧读回总量。')
        print('  要看来源排行，起局时加 NXGAL_WAIT_SITE=1 再跑一遍。')
    if rf: print(f"READFLUSH 末行：{rf[-1][:160]}")
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
