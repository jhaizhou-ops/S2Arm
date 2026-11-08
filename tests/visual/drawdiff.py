#!/usr/bin/env python3
"""双后端逐绘制对拍定性（画面·着色器线 10-21）：同一录像、同一参数跑两遍 galplay --ref --diff --diff-all，逐次比对按两遍对齐定性。

用法：drawdiff.py <第 1 遍输出目录> <第 2 遍输出目录> [--known <已知分歧表>] [--tsv <定性明细输出>]
      drawdiff.py --gate <输出目录> --known <已知分歧「记录:槽:贴图:差异像素」分号分隔或 -> --compares <期望比对次数>   （门禁：一遍，段已验过两遍确定）
  每次比对（同一记录、同一槽、同一贴图）四类：
    同            两遍两边都在容差内
    确定分歧      两遍都超容差，且两遍我方哈希相同、参照哈希相同（同输入同输出，可复现——我方渲染器偏差或参照自身问题，要看图定）
    不确定·我方   两遍我方哈希不同、参照哈希相同（同输入我方出两种结果：回放 / 渲染器不确定性）
    不确定·参照   两遍我方相同、参照哈希不同
    GPU 不定      两遍我方、参照哈希都不同（两个独立后端在同一处同时不定：共同的只有 GPU 与录像输入，输入确定时即 GPU 自身不定；
                  10-23 怪猎村子 51 处全是这类，原先先判我方被全记成「不确定·我方」）
  重同步开着时每次比对后我方目标被写成参照那份，两遍的输入逐次对齐，所以「两遍哈希不同」= 这一通道本身不确定，不是上游传下来的。
  --known：已知分歧表（tests/visual/diff_list.tsv 的「已知」列展开，每行「记录:槽:贴图」）——确定分歧不在表里 = 新分歧（退出码 1）；表里有但这次没分歧 = 已修好（照报，退出码不变）。
输出：一行结论 + 前 10 处确定分歧；退出码 0 = 没有新的确定分歧且两遍比对数一致，1 = 有新分歧，2 = 输入错。
"""
import os
import sys


def load(d):
    p = os.path.join(d, 'diff.tsv')
    if not os.path.exists(p):
        sys.exit(f'🔴 {d} 没有 diff.tsv（galplay 没跑完，或没带 --ref --diff；两遍定性还要 --diff-all）')
    rows = [l.rstrip('\n').split('\t') for l in open(p, encoding='utf-8')]
    h = rows[0]
    return [dict(zip(h, r)) for r in rows[1:]]


def classify(x, y):
    """一次比对两遍对齐定性。哈希不同但两遍差异像素都是 0 = 位级不定（舍入翻转，在容差内），不算不确定。"""
    over = int(x['差异像素']) > 0 or int(y['差异像素']) > 0
    if x['我方哈希'] != y['我方哈希'] and x['参照哈希'] != y['参照哈希']:
        return 'GPU 不定' if over else '位级不定'
    if x['我方哈希'] != y['我方哈希']:
        return '不确定·我方' if over else '位级不定'
    if x['参照哈希'] != y['参照哈希']:
        return '不确定·参照' if over else '位级不定'
    return '确定分歧' if int(x['差异像素']) > 0 else '同'


def report_line(d):
    p = os.path.join(d, 'report.txt')
    if not os.path.exists(p):
        return {}
    t = open(p, encoding='utf-8').read()
    out = {}
    import re
    m = re.search(r'参照回放异常 (\d+) 条', t)
    out['refErr'] = int(m.group(1)) if m else -1
    m = re.search(r'回放错误 (\d+)', t)
    out['err'] = int(m.group(1)) if m else -1
    m = re.search(r'二进制载入 (\d+) 支', t)
    out['bin'] = int(m.group(1)) if m else -1
    m = re.search(r'：比对 (\d+) 次', t)
    out['cmp'] = int(m.group(1)) if m else -1
    m = re.search(r'总绘制 (\d+)', t)
    out['draws'] = int(m.group(1)) if m else -1
    return out


def gate(a):
    d = a[a.index('--gate') + 1]
    kn = a[a.index('--known') + 1] if '--known' in a else '-'
    # 已知分歧「记录:槽:贴图:差异像素」：同一处差异像素涨到 2 倍且多 64 个以上也算新分歧——新缺陷落在已知分歧的同一通道里不能被吞掉
    #   （10-21 正对照：改坏的程序画在暗黑3 已知分歧通道 3133 里，只按位置比时 0 新分歧）
    known = {}
    for k in ([] if kn in ('-', '') else kn.split(';')):
        q = k.split(':'); known[':'.join(q[:3])] = int(q[3]) if len(q) > 3 else -1
    want = int(a[a.index('--compares') + 1]) if '--compares' in a else -1
    r, i = load(d), report_line(d)
    div = [x for x in r if int(x['差异像素']) > 0]
    keys = [f"{x['记录']}:{x['槽']}:{x['贴图']}" for x in div]
    new = [k for k, x in zip(keys, div) if k not in known or (known[k] >= 0 and int(x['差异像素']) > max(2 * known[k], known[k] + 64))]
    fixed = sorted(set(known) - set(keys))
    bad = []
    if i.get('refErr') != 0: bad.append(f"参照回放异常 {i.get('refErr')} 条")
    if i.get('bin') != 0: bad.append(f"二进制程序 {i.get('bin')} 支（参照建不出，对拍无效）")
    if i.get('err') != 0: bad.append(f"回放错误 {i.get('err')}")
    if i.get('cmp', -1) <= 0: bad.append('没有比对（回放没跑到对拍段？）')
    if want >= 0 and i.get('cmp') != want: bad.append(f"比对 {i.get('cmp')} 次 ≠ 清单 {want} 次（射程变了：录像 / 回放流程变了要核）")
    for x in div:
        if f"{x['记录']}:{x['槽']}:{x['贴图']}" in new:
            print(f"  新分歧 记录 {x['记录']}（帧 {x['帧']}，{x['类']}起 {x['通道起']}，绘制 {x.get('通道绘制', '?')}）程序 {x['程序']} 槽 {x['槽']} 贴图 {x['贴图']} {x['格式']} {x['尺寸']}："
                  f"差异像素 {x['差异像素']}/{x['总像素']}，最大差 {x['最大差']} 级")
    print(f"比对 {i.get('cmp')} 次（清单 {want}）、分歧 {len(div)}（已知 {len(div) - len(new)}、新 {len(new)}）、已修好 {len(fixed)}{('：' + ' '.join(fixed)) if fixed else ''}、总绘制 {i.get('draws', '?')}"
          + (('；🔴 ' + '；'.join(bad)) if bad else ''))
    return 1 if new or bad else 0


def main(a):
    if '--gate' in a:
        return gate(a)
    if len(a) < 2:
        print(__doc__)
        return 2
    known = None
    if '--known' in a:
        known = set(l.strip() for l in open(a[a.index('--known') + 1], encoding='utf-8') if l.strip() and not l.startswith('#'))
    r1, r2 = load(a[0]), load(a[1])
    i1, i2 = report_line(a[0]), report_line(a[1])
    if len(r1) != len(r2):
        print(f'🔴 两遍比对数不同：{len(r1)} / {len(r2)}（录像或参数不同？）')
        return 1
    cls = {'同': 0, '确定分歧': 0, '不确定·我方': 0, '不确定·参照': 0, 'GPU 不定': 0, '位级不定': 0}
    det, nd = [], []
    for x, y in zip(r1, r2):
        if (x['记录'], x['槽'], x['贴图']) != (y['记录'], y['槽'], y['贴图']):
            print(f"🔴 两遍比对对不齐：{x['记录']}:{x['槽']}:{x['贴图']} / {y['记录']}:{y['槽']}:{y['贴图']}")
            return 1
        c = classify(x, y)
        cls[c] += 1
        if c == '确定分歧':
            det.append(x)
        elif c.startswith('不确定') or c == 'GPU 不定':
            nd.append((c, x, y))
    passes = sum(1 for x in r1 if x['类'] == '通道')
    draws_in = sum(int(x.get('通道绘制') or 0) for x in {(d['记录']): d for d in det}.values())
    keys = [f"{x['记录']}:{x['槽']}:{x['贴图']}" for x in det]
    new = [k for k in keys if known is not None and k not in known]
    fixed = sorted(known - set(keys)) if known is not None else []
    tot = len(r1)
    head = (f"比对 {tot} 次：同 {cls['同']}、确定分歧 {cls['确定分歧']}、不确定·我方 {cls['不确定·我方']}、不确定·参照 {cls['不确定·参照']}、GPU 不定 {cls['GPU 不定']}（另有两遍哈希不同但都在容差内的「位级不定」{cls['位级不定']}）；"
            f"确定分歧涉及通道 {len(set(x['记录'] for x in det))}（其中绘制 {draws_in}，总绘制 {i1.get('draws', '?')}）；"
            f"参照回放异常 {i1.get('refErr', '?')}/{i2.get('refErr', '?')}、二进制程序 {i1.get('bin', '?')}")
    print(head)
    for x in det[:10]:
        print(f"  确定分歧 记录 {x['记录']}（帧 {x['帧']}，{x['类']}起 {x['通道起']}，绘制 {x.get('通道绘制', '?')}）程序 {x['程序']} 槽 {x['槽']} 贴图 {x['贴图']} {x['格式']} {x['尺寸']}："
              f"差异像素 {x['差异像素']}/{x['总像素']}，最大差 {x['最大差']} 级，{x['首个差异像素']} {x['差异框']}")
    for c, x, y in nd[:10]:
        print(f"  {c} 记录 {x['记录']} 槽 {x['槽']} 贴图 {x['贴图']} {x['格式']} {x['尺寸']}：第 1 遍差异像素 {x['差异像素']} / 第 2 遍 {y['差异像素']}，最大差 {x['最大差']} / {y['最大差']}")
    if '--tsv' in a:
        with open(a[a.index('--tsv') + 1], 'w', encoding='utf-8') as f:
            f.write('定性\t' + '\t'.join(r1[0].keys()) + '\n' if r1 else '')
            for x, y in zip(r1, r2):
                c = classify(x, y)
                f.write(c + '\t' + '\t'.join(x.values()) + '\n')
    if known is not None:
        print(f"对已知分歧表：新分歧 {len(new)}{('：' + ' '.join(new[:8])) if new else ''}；已修好 {len(fixed)}{('：' + ' '.join(fixed[:8])) if fixed else ''}")
    bad = i1.get('refErr', 0) != 0 or i1.get('bin', 0) != 0 or i1.get('err', 0) != 0
    if bad:
        print('🔴 参照回放异常 / 二进制程序 / 回放错误不为 0：对拍无效')
    return 1 if (new or bad or (known is None and det)) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
