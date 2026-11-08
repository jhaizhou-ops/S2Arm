#!/usr/bin/env python3
# 金样 jsonl 合法性检查（11-05）：python3 tools/golden_lint.py <金样.jsonl>…
#   每行合法 JSON 对象、有 fn / args / want；同一 (fn, args) 不得有两个不同的 want。完全相同的重复行无害，只计数。
#   这些金样设了 merge=union（.gitattributes），两支改到相邻行时 git 两边都留，本检查拦「合坏」。
#   红行格式「文件:行号: 原因」，列车按 union 文件的新增行归因到加了那一行的分支（tools/train.sh ulines / hitsfor）。
import json, sys

def lint(path):
    errs, seen, dup, n = [], {}, 0, 0
    with open(path, encoding='utf-8') as f:
        for i, line in enumerate(f, 1):
            if not line.strip():
                continue
            n += 1
            try:
                o = json.loads(line)
            except ValueError as e:
                errs.append(f'{path}:{i}: 不是合法 JSON（{e.msg}）'); continue
            if not isinstance(o, dict) or not {'fn', 'args', 'want'} <= o.keys():
                errs.append(f'{path}:{i}: 缺 fn / args / want'); continue
            key = (o['fn'], json.dumps(o['args'], sort_keys=True))
            want = json.dumps(o['want'], sort_keys=True)
            if key in seen:
                j, w = seen[key]
                if w != want:
                    errs.append(f'{path}:{i}: 用例 {o["fn"]} 与第 {j} 行参数相同、期望不同（union 合并留下了两版）')
                else:
                    dup += 1
            else:
                seen[key] = (i, want)
    return errs, n, dup

bad = 0
for p in sys.argv[1:]:
    errs, n, dup = lint(p)
    for e in errs:
        print(e)
    bad |= bool(errs)
    print(f'{p}：{n} 例，{"红 " + str(len(errs)) + " 处" if errs else "合法、无矛盾期望"}，完全相同的重复 {dup} 行')
sys.exit(1 if bad else 0)
