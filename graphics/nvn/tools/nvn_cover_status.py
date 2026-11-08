#!/usr/bin/env python3
"""NVN 覆盖表与代码对账：从直连层的三种注册形态推出「代码实际覆盖」，再和 docs/直连_NVN覆盖表.tsv 比。

为什么需要它：表里的「未做」曾经有 45%（50/111）其实早已实现，认领时会白做一半；反向也有「已做」但精确名没实现的（变体存在、精确名没有，最容易漏）。见 docs/研究/NVN覆盖表核对_1500256797.md。

代码侧三种注册形态（少认一种都会误判）：
  · NVN(name, ret, …)         —— 有原型的实现
  · NVN_NOPROTO(name, ret, …) —— 无原型的实现
  · static const char *const g_nops[] = { "nvn…", … }; —— 空操作（只计数、或显式定义的 no-op）

用法：
  python3 graphics/nvn/tools/nvn_cover_status.py                     # 打印对账表与差异清单
  python3 graphics/nvn/tools/nvn_cover_status.py --json              # 机器可读
  python3 graphics/nvn/tools/nvn_cover_status.py --update            # 把 S2Arm 列改成代码事实（只改 已做/未做）
  python3 graphics/nvn/tools/nvn_cover_status.py --check             # 表与代码不一致时退出 1（门禁用）
  python3 graphics/nvn/tools/nvn_cover_status.py --src <c 文件> --table <tsv>   # 单测：换成合成输入

只做「有没有这个名字的实现」的判定，不判断语义正确性。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / 'graphics/nvn/gfx/nvn/hle_nvn.c'
TABLE = ROOT / 'docs/直连_NVN覆盖表.tsv'

MACRO = re.compile(r'NVN(?:_NOPROTO)?\(\s*(\w+)\s*,')
NOPS = re.compile(r'"(nvn\w+)"')


def code_surface(text):
    """{名字: '语义'|'空操作'}；宏实现优先（同一名字两处出现时按实现算）"""
    out = {}
    for name in MACRO.findall(text):
        if name != 'name':                      # 宏定义本身
            out[name] = '语义'
    for name in NOPS.findall(text):
        out.setdefault(name, '空操作')
    return out


def read_table(path):
    rows = []
    for ln in path.read_text(encoding='utf-8').splitlines():
        c = ln.split('\t')
        if len(c) < 3 or c[0] == '函数':
            continue
        rows.append({'name': c[0].strip(), 'direct': c[1].strip(), 's2arm': c[2].strip(), 'rest': c[3:]})
    return rows


def compare(rows, surface):
    res = {'agree_done': [], 'table_stale': [], 'table_overstated': [], 'gap': [], 'native': []}
    for r in rows:
        n, s = r['name'], r['s2arm']
        has = n in surface
        if s == '原生':
            res['native'].append(r)
        elif s == '已做' and has:
            res['agree_done'].append(r)
        elif s == '已做' and not has:
            res['table_overstated'].append(r)      # 表说已做、代码没有：最危险
        elif s == '未做' and has:
            res['table_stale'].append(r)           # 表说未做、代码有：认领会白做
        else:
            res['gap'].append(r)
    unknown = sorted({r['name'] for r in rows} - set(surface))
    extra = sorted(set(surface) - {r['name'] for r in rows})
    return res, unknown, extra


def main(argv):
    as_json = '--json' in argv
    update = '--update' in argv
    check = '--check' in argv
    src, table = SRC, TABLE
    if '--src' in argv:                       # 单测用：换一份合成的 C 源码 / 覆盖表
        src = Path(argv[argv.index('--src') + 1]).resolve()
    if '--table' in argv:
        table = Path(argv[argv.index('--table') + 1]).resolve()
    surface = code_surface(src.read_text(encoding='utf-8'))
    rows = read_table(table)
    res, unknown, extra = compare(rows, surface)
    summary = {
        'tableRows': len(rows), 'codeSurface': len(surface),
        'agreeDone': len(res['agree_done']), 'native': len(res['native']),
        'tableStale': len(res['table_stale']), 'tableOverstated': len(res['table_overstated']),
        'gap': len(res['gap']), 'codeNotInTable': len(extra),
    }
    if as_json:
        print(json.dumps({'summary': summary,
                          'tableStale': [r['name'] for r in res['table_stale']],
                          'tableOverstated': [r['name'] for r in res['table_overstated']],
                          'gap': [r['name'] for r in res['gap']],
                          'codeNotInTable': extra}, ensure_ascii=False, indent=1))
        return 0

    print(f"表 {summary['tableRows']} 行；代码侧 {summary['codeSurface']} 个名字（宏实现 + 名字表空操作）")
    print(f"  一致：已做 {summary['agreeDone']}、原生 {summary['native']}")
    print(f"  表落后（写未做、代码有）：{summary['tableStale']}")
    print(f"  表虚高（写已做、代码没有）：{summary['tableOverstated']}")
    print(f"  真实缺口：{summary['gap']}；代码有但表里没行：{summary['codeNotInTable']}")
    for label, key in (('表落后', 'table_stale'), ('表虚高', 'table_overstated'), ('真实缺口', 'gap')):
        if res[key]:
            print(f"    {label}：{'、'.join(r['name'] for r in res[key][:12])}" + (' …' if len(res[key]) > 12 else ''))
    if extra:
        print(f"    代码有、表里没行：{'、'.join(extra[:8])}" + (' …' if len(extra) > 8 else ''))

    if update:
        by = {r['name']: r for r in res['table_stale'] + res['table_overstated']}
        lines = table.read_text(encoding='utf-8').splitlines()
        fixed = 0
        for i, ln in enumerate(lines):
            c = ln.split('\t')
            if len(c) < 3 or c[0] not in by:
                continue
            want = '已做' if c[0] in surface else '未做'
            if c[2] != want:
                c[2] = want
                lines[i] = '\t'.join(c)
                fixed += 1
        table.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        print(f'已更新覆盖表 {fixed} 行（只改 S2Arm 列）')

    if check and (res['table_stale'] or res['table_overstated']):
        print('覆盖表与代码不一致（--check）', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
