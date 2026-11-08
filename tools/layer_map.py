#!/usr/bin/env python3
# 分层地图查询与覆盖检查（架构梳理阶段一 S1，11-06）。地图本体 tools/layer_map.tsv，格式见其文件头；日摘、分层检查、安卓 #1580 都经这里读，不另抄一份前缀表。
#   python3 tools/layer_map.py which <路径>…   每个路径打印「路径<TAB>层<TAB>模块<TAB>跟进<TAB>命中前缀」；匹配不到打印「路径<TAB>未覆盖」，退出码 1
#   python3 tools/layer_map.py check [<仓库根>]  R-00：每个 git 跟踪文件都要匹配到一行；表里匹配不到任何文件的行（目录删了 / 改名了）也报红。退出码 0 / 1
#   作为模块：load(表路径) → 行列表；lookup(行列表, 路径) → 行或 None（最长前缀）
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = 'tools/layer_map.tsv'
LAYERS = ('核心', '图形后端', '平台接口', '平台壳', '工具与测试', '文档与约定')
FOLLOW = ('共用层', '直连Vulkan', 'Metal档', '按补丁分类', '按目标', '安卓自己', '终端壳', '工具与文档')


def load(path=None):
    """→ [(前缀, 层, 模块, 跟进, 行号)]；格式错（列数、层 / 跟进不在枚举里、前缀重复）抛 ValueError，信息带行号"""
    rows, seen = [], set()
    with open(path or os.path.join(ROOT, TABLE), encoding='utf-8') as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip('\n')
            if not line or line.startswith('#'): continue
            p = line.split('\t')
            if len(p) != 4 or not all(p): raise ValueError(f'{TABLE}:{n} 要四列且都不空（前缀 / 层 / 模块 / 跟进），实际 {len(p)} 列')
            if p[1] not in LAYERS: raise ValueError(f'{TABLE}:{n} 层「{p[1]}」不在 {"/".join(LAYERS)} 里')
            if p[3] not in FOLLOW: raise ValueError(f'{TABLE}:{n} 跟进「{p[3]}」不在 {"/".join(FOLLOW)} 里')
            if p[0] in seen: raise ValueError(f'{TABLE}:{n} 前缀 {p[0]} 重复')
            seen.add(p[0]); rows.append((p[0], p[1], p[2], p[3], n))
    return rows


def match(prefix, path):
    return path.startswith(prefix) if prefix.endswith('/') else path == prefix


def lookup(rows, path):
    best = None
    for r in rows:
        if match(r[0], path) and (best is None or len(r[0]) > len(best[0])): best = r
    return best


def check(repo, rows):
    """→ (未覆盖的文件, 匹配不到任何文件的行)"""
    out = subprocess.run(['git', '-C', repo, 'ls-files', '-z'], capture_output=True, check=True).stdout
    files = [f for f in out.decode('utf-8', 'surrogateescape').split('\0') if f]
    used, miss = set(), []
    for f in files:
        r = lookup(rows, f)
        if r: used.add(r[0])
        else: miss.append(f)
    return miss, [r for r in rows if r[0] not in used]


def main(a):
    if not a or a[0] not in ('which', 'check'): print('用法：tools/layer_map.py which <路径>… | check [<仓库根>]', file=sys.stderr); return 2
    try: rows = load(os.path.join(os.path.abspath(a[1]) if a[0] == 'check' and len(a) > 1 else ROOT, TABLE))
    except ValueError as e: print(f'【红】{e}', file=sys.stderr); return 1
    if a[0] == 'which':
        rc = 0
        for p in a[1:]:
            r = lookup(rows, p)
            if r: print(f'{p}\t{r[1]}\t{r[2]}\t{r[3]}\t{r[0]}')
            else: print(f'{p}\t未覆盖'); rc = 1
        return rc
    repo = os.path.abspath(a[1]) if len(a) > 1 else ROOT
    miss, stale = check(repo, rows)
    tops = sorted({f.split('/', 1)[0] + ('/' if '/' in f else '') for f in miss})
    for t in tops: print(f'【红】分层地图没有覆盖 {t}（{sum(1 for f in miss if f == t or f.startswith(t))} 个文件，如 {next(f for f in miss if f == t or f.startswith(t))}）。在 {TABLE} 加一行')
    for r in stale: print(f'【红】{TABLE}:{r[4]} 前缀 {r[0]} 匹配不到任何仓库文件（删了 / 改名了），删掉或改正这一行')
    print(f'分层地图：{len(rows)} 行，仓库文件未覆盖 {len(miss)} 个，空行 {len(stale)} 行')
    return 1 if miss or stale else 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    sys.exit(main(sys.argv[1:]))
