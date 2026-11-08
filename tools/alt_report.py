#!/usr/bin/env python3
"""同局交替开关的窗口报表（帧率能耗线 10-24；runtime/src/alt.c、tools/dev_run.sh 按段采功耗）。

用法：python3 tools/alt_report.py <局目录> [--fps=30|60]
  局目录里要有 frames.tsv（末列 alt：0 不交替、1 关段、2 开段），可选 pwalt_<k>a.plist / pwalt_<k>b.plist（执行器在第 k 段里护边后采的两次整机功耗，
  见 tools/dev_run.sh）。第 k 段功耗只用这两次之间的读数，缺一次就算未测。
输出：逐段一行（段号、开 / 关、帧数、时长、读回、帧时中位 / p95、慢帧、每帧绘制中位、功耗），再按开 / 关汇总，
以及「开段 − 前后两个关段平均」的相邻差（抵消场景慢漂移）。只认 MARK 后（alt > 0）的帧。
"""
import csv, os, plistlib, statistics, sys


def segments(rows):
    """按 alt 列切段：相邻同值的帧归一段；alt = 0（MARK 前 / 不交替）的帧跳过"""
    segs, cur, last = [], None, None
    for r in rows:
        try:
            a = int(r.get('alt') or 0)
        except ValueError:
            continue
        if a <= 0:
            continue
        if a != last:
            cur = {'on': a == 2, 'rows': []}
            segs.append(cur)
            last = a
        cur['rows'].append(r)
    return segs


def seg_stats(seg, period_us):
    w = [int(r['wall_us']) for r in seg['rows'] if r.get('wall_us')]
    rb = sum(int(r.get('rb_us') or 0) for r in seg['rows'])
    dr = [int(r.get('draw_n') or 0) for r in seg['rows']]
    if not w:
        return None
    ws = sorted(w)
    return {'on': seg['on'], 'n': len(w), 'dur_s': sum(w) / 1e6, 'rb_ms': rb / 1000,
            'med_ms': statistics.median(w) / 1000, 'p95_ms': ws[min(len(ws) - 1, int(len(ws) * 0.95))] / 1000,
            'slow': sum(1 for x in w if x > 1.5 * period_us), 'draw_med': statistics.median(dr) if dr else 0}


def _pw(f):
    try:
        t = plistlib.load(open(f, 'rb'))['IORegistry']['PowerTelemetryData']
        return t['AccumulatedSystemLoad'], t['SystemLoadAccumulatorCount']
    except Exception:
        return None


def powers(o, nseg):
    """各段整机功率（瓦）：第 k 段 = pwalt_<k>a → pwalt_<k>b 的 AccumulatedSystemLoad 差 / 采样次数差 / 1000；缺一次 → None"""
    out = []
    for k in range(nseg):
        a, b = _pw(os.path.join(o, f'pwalt_{k}a.plist')), _pw(os.path.join(o, f'pwalt_{k}b.plist'))
        out.append((b[0] - a[0]) / (b[1] - a[1]) / 1000 if a and b and b[1] > a[1] else None)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    o = sys.argv[1]
    fps = next((int(a.split('=')[1]) for a in sys.argv[2:] if a.startswith('--fps=')), 30)
    rows = list(csv.DictReader(open(os.path.join(o, 'frames.tsv'), errors='replace'), delimiter='\t'))
    st = [s for s in (seg_stats(g, 1e6 / fps) for g in segments(rows)) if s]
    pw = powers(o, len(st))
    if not st:
        print('没有交替段（frames.tsv 没有 alt 列，或 alt 全是 0：没设 S2A_ALT / 没到 MARK）'); return 1
    print(f'段 开/关  帧数  时长s  读回ms  帧时中位ms  p95ms  慢帧  每帧绘制中位  功耗W')
    for i, s in enumerate(st):
        p = pw[i] if i < len(pw) and pw[i] is not None else None
        s['w'] = p
        print(f'{i:>2} {"开" if s["on"] else "关"}  {s["n"]:>5} {s["dur_s"]:>6.1f} {s["rb_ms"]:>7.0f} {s["med_ms"]:>10.2f} {s["p95_ms"]:>6.2f} {s["slow"]:>5} {s["draw_med"]:>12.0f}  {p if p is None else round(p, 2)}')
    def agg(on):
        g = [s for s in st if s['on'] == on]
        if not g: return None
        dur = sum(s['dur_s'] for s in g)
        ws = [s['w'] for s in g if s['w'] is not None]
        return {'k': len(g), 'rb_per_s': sum(s['rb_ms'] for s in g) / dur, 'fps': sum(s['n'] for s in g) / dur,
                'med': statistics.median([s['med_ms'] for s in g]), 'slow_per_s': sum(s['slow'] for s in g) / dur,
                'draw': statistics.median([s['draw_med'] for s in g]), 'w': statistics.mean(ws) if ws else None}
    for on in (False, True):
        a = agg(on)
        if a: print(f'汇总 {"开" if on else "关"}：{a["k"]} 段，读回 {a["rb_per_s"]:.1f} ms/秒，帧率 {a["fps"]:.2f}，帧时中位 {a["med"]:.2f} ms，慢帧 {a["slow_per_s"]:.2f} /秒，每帧绘制中位 {a["draw"]:.0f}，功耗 {a["w"] if a["w"] is None else round(a["w"], 2)} W')
    # 相邻差：每个开段 − 它前后关段的平均（只算两侧都有关段的开段）
    d = []
    for i, s in enumerate(st):
        if s['on'] and 0 < i < len(st) - 1 and not st[i - 1]['on'] and not st[i + 1]['on']:
            nb = (st[i - 1], st[i + 1])
            rb = s['rb_ms'] / s['dur_s'] - sum(x['rb_ms'] / x['dur_s'] for x in nb) / 2
            fr = s['n'] / s['dur_s'] - sum(x['n'] / x['dur_s'] for x in nb) / 2
            wd = s['w'] - sum(x['w'] for x in nb) / 2 if s['w'] is not None and all(x['w'] is not None for x in nb) else None
            d.append((rb, fr, wd))
    if d:
        ws = [x[2] for x in d if x[2] is not None]
        print(f'相邻差（开段 − 前后关段平均，{len(d)} 组）：读回 {statistics.mean(x[0] for x in d):+.1f} ms/秒，帧率 {statistics.mean(x[1] for x in d):+.2f}，'
              f'功耗 {"未测" if not ws else f"{statistics.mean(ws):+.2f} W"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
