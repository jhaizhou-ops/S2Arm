#!/usr/bin/env python3
"""普查计分（一次成功正式口径）：python3 tools/census/score.py [--census <普查目录>] [--out <latest.tsv>]
  原先是运行区手跑脚本（census/handover_1105/score_1106/score.py），分母靠人对账：打「有结论款 211」，报告写 205，
  差的 6 款（原件坏 4、要架构 2）靠人记得扣（11-06 总指挥：score.py 直接读不计入名单，输出就是正式口径）。
口径：
  ① 各款取主批 / 复判批总表最新一行（同 tools/census/hand_test_list.py 的 load_rows / latest，实验批不算）
  ② 状态：一次成功 = 是，或 jhz 手测（普查目录 手测结果.tsv，同键以最后一行为准）= 是 → 成功；手测 = 否 → 手测否；
     一次成功 = 待手测 → 待手测；其余 → 未成功
  ③ 不计入分母：普查目录 不计入分母.tsv（键 / 类 / 依据；类 = 原件坏 | 要架构）里的键不进分母、不进各状态计数，另列「不计入」
  ④ 分母 = 有结论款 − 不计入；上线线 = ⌈分母 × 95%⌉（jhz：原生档一次成功 ≥95%、分母全库）；差 = 上线线 − 成功（不小于 0）
标准输出：第一行「一次成功 <成功> / <分母> = <百分比>%｜上线线 <n>（95%）差 <k>」，第二行各状态计数，第三行不计入款数与清单键；
  --out 写每款一行（状态、键、名称、批次、日期、结论、崩溃、进局、第一个失败点；不计入的状态写「不计入：<类>」）。"""
import argparse, collections, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hand_test_list as htl

EXCL_KINDS = ('原件坏', '要架构')


def launch_line(den):
    """上线线 = ⌈分母 × 95%⌉（整数运算，不受浮点误差影响）。"""
    return (den * 95 + 99) // 100


def load_excluded(C):
    """不计入分母.tsv → {键: 类}；没有文件 = 空；类不认得的行打【红】并照算进分母（不悄悄扣）。"""
    p = os.path.join(C, '不计入分母.tsv'); out = {}; reds = []
    if not os.path.exists(p): return out, reds
    for r in htl.read_tsv(p):
        k = (r.get('键') or '').strip().upper(); kind = (r.get('类') or '').strip()
        if not k: continue
        if kind not in EXCL_KINDS: reds.append(f'【红】不计入分母.tsv：{k} 的类「{kind}」不是 {"/".join(EXCL_KINDS)}，照算进分母'); continue
        out[k] = kind
    return out, reds


def score(C):
    reds = []; last = htl.latest(htl.load_rows(C, reds))
    man = {}
    p = os.path.join(C, '手测结果.tsv')
    if os.path.exists(p):
        for r in htl.read_tsv(p): man[(r.get('键') or '').upper()] = r.get('手测', '')   # 同键最后一行为准（追加式登记）
    excl, r2 = load_excluded(C); reds += r2
    rows = []
    for k, r in last.items():
        m = man.get(k, '')
        if k in excl: s = '不计入：' + excl[k]
        elif r.get('一次成功') == '是' or m == '是': s = '成功'
        elif m == '否': s = '手测否'
        elif r.get('一次成功') == '待手测': s = '待手测'
        else: s = '未成功'
        rows.append((s, k, (r.get('名称') or '')[:34], r['_b'], r.get('日期', ''), r.get('结论', ''), r.get('崩溃', ''), r.get('进局', ''), (r.get('第一个失败点') or '')[:90]))
    c = collections.Counter(x[0] for x in rows if not x[0].startswith('不计入'))
    den = sum(c.values()); line = launch_line(den); ok = c.get('成功', 0)
    missing = sorted(k for k in excl if k not in last)   # 名单里有、总表里没有：照实打出，不影响分母
    return {'rows': sorted(rows), 'counts': c, 'den': den, 'ok': ok, 'line': line, 'gap': max(line - ok, 0),
            'excluded': sorted(k for k in excl if k in last), 'missing': missing, 'reds': reds}


def main(argv):
    ap = argparse.ArgumentParser(); ap.add_argument('--census', default=htl.census_dir()); ap.add_argument('--out')
    a = ap.parse_args(argv); r = score(a.census)
    pct = 100.0 * r['ok'] / r['den'] if r['den'] else 0.0
    print(f"一次成功 {r['ok']} / {r['den']} = {pct:.1f}%｜上线线 {r['line']}（95%）差 {r['gap']}")
    print('　'.join(f'{k} {r["counts"].get(k, 0)}' for k in ('成功', '手测否', '待手测', '未成功')))
    print(f"不计入 {len(r['excluded'])} 款：{' '.join(r['excluded']) or '无'}" + (f"；名单里有、总表没有 {len(r['missing'])} 款：{' '.join(r['missing'])}" if r['missing'] else ''))
    for x in r['reds']: print(x)
    if a.out:
        with open(a.out + '.new', 'w', encoding='utf-8') as f:
            for x in r['rows']: f.write('\t'.join(x) + '\n')
        os.replace(a.out + '.new', a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
