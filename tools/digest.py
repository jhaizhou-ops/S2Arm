#!/usr/bin/env python3
# 共用层日摘（架构梳理阶段一 S2，11-06；修订稿 4.4）：把一天里合进 main 的非合并提交按路径分成「要跟 / Metal 档」两组，安卓 / 鸿蒙开发者只读这几笔。
#   python3 tools/digest.py day <YYYY-MM-DD> [--repo <仓库>] [--ref origin/main] [--tz -0800] [--gh]   → stdout 一份 Markdown
#   python3 tools/digest.py replay --days 7 --out <目录> [--end <YYYY-MM-DD>] [同上选项]              → <目录>/digest_<日期>.md 各一份
# 规则（只看路径，作者零标签；不进门禁、不挡合入，生成失败只在调用方日志留一行）：
#   分类：读 tools/layer_map.tsv 的「跟进」列（tools/layer_map.py 同一张表）。一笔提交碰到多类时按 共用层 > 直连Vulkan > Metal档 取最高；
#     compat/patches/*.patch 看补丁改到的路径：含 Backends.Apple / Nvdec/Apple / VideoToolbox / ImageIO 的算平台补丁（不进日摘），其余算共用层；
#     pack/targets/<目标>/：android → 安卓自己，ios → 终端壳，其他目标算共用层；Metal 档的提交同时改了 graphics/nvn/gfx/nvn/nvn_mtl.h 或 platform/plat.h 时升为共用层。
#     安卓自己 / 终端壳 / 工具与文档 不写进日摘，只在末尾计数。
#   说明：取提交正文（去掉 Co-Authored-By 等尾注）前 3 行；正文为空且给了 --gh 时用合入它的 PR 正文前 3 行；同一提交改了 docs/坑记录.md 时摘出新增的 ## 标题。
#     都没有就写「说明不足，只列路径」。冷：提交说明里有「🧊」或「冷改动」记「是」，否则「否」（不重算 coldcheck）。
#   附加提示：改到 launchers/shared/ → 「接界面时读这份规格」；只改了 MSL 出口（Dsh.cs / spirv_msl.py / ShaderBake.cs 里含 Msl、没改含 Vulkan 的行）→ 「安卓 SPIR-V 出口未动」。
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import layer_map  # noqa: E402

RANK = {'共用层': 3, '直连Vulkan': 2, 'Metal档': 1}
TITLE = {'共用层': '共用层', '直连Vulkan': '直连 Vulkan / 平台原语（今天在安卓壳，将来鸿蒙共用）', 'Metal档': 'Metal 后端（苹果用户路径，一般不用跟）'}
APPLE_PATCH = re.compile(r'Backends\.Apple|Nvdec/Apple|VideoToolbox|ImageIO')
IFACE = re.compile(r'^(platforms/plat(_asm)?\.h|runtime/include/|graphics/nvn/gfx/nvn/include/|graphics/metal/gal_abi\.h|graphics/nvn/gfx/nvn/nvn_(mtl|backend)\.h)|_abi\.h$')   # 跨层接口头：平台契约、原生对外头、NVN 公开头、图形 ABI、直连下沿
TRAILER = re.compile(r'^(Co-Authored-By|Signed-off-by|Reviewed-by|🤖)', re.I)


def git(repo, *a):
    return subprocess.run(['git', '-C', repo, '-c', 'core.quotepath=off', *a], capture_output=True, text=True, check=True).stdout


TESTISH = re.compile(r'(^|/)(tests?|testdata|fixtures?|golden)(/|$)|(^|/)t_[^/]*\.py$|_test\.(c|cc|cpp|m|py|sh|cs)$|Tests?\.cs$|\.md$|golden[^/]*\.jsonl?$')


def follow_of(repo, rows, sha, path):
    """→ 这个文件在本提交里的跟进类别（补丁、终端出包按细则再分）；共用目录里的单测 / 夹具 / 金样 / 文档不算共用层（运行时不跟它走）"""
    if TESTISH.search(path): return '工具与文档'
    r = layer_map.lookup(rows, path)
    f = r[3] if r else '未覆盖'
    if f == '按补丁分类':
        if not path.endswith('.patch'): return '共用层'
        try: body = git(repo, 'show', f'{sha}:{path}')
        except subprocess.CalledProcessError: return '工具与文档'   # 删掉的补丁
        touched = re.findall(r'^\+\+\+ b/(\S+)', body, re.M)
        return '平台补丁' if touched and all(APPLE_PATCH.search(t) for t in touched) else '共用层'
    if f == '按目标':
        t = path.split('/')[2] if path.count('/') >= 2 else ''
        return {'android': '安卓自己', 'ios': '终端壳'}.get(t, '共用层')
    return f


def classify(repo, rows, sha, files):
    """→ (类别, 各文件类别) ；类别取「共用层 > 直连Vulkan > Metal档」里最高的，都不沾返回 None"""
    per = {p: follow_of(repo, rows, sha, p) for p in files}
    best = max((RANK.get(v, 0) for v in per.values()), default=0)
    cat = next((k for k, v in RANK.items() if v == best), None) if best else None
    if cat == 'Metal档' and any(p in ('graphics/nvn/gfx/nvn/nvn_mtl.h', 'platform/plat.h') for p in files): cat = '共用层'
    return cat, per


def summary(body):
    lines = [l.strip() for l in body.splitlines() if l.strip() and not TRAILER.match(l.strip())]
    return lines[:3]


def pr_body(repo, sha):
    try:
        out = subprocess.run(['gh', 'api', f'repos/{{owner}}/{{repo}}/commits/{sha}/pulls', '--jq', '.[0].body // ""'],
                             cwd=repo, capture_output=True, text=True, timeout=20).stdout
        return summary(out)
    except (OSError, subprocess.TimeoutExpired): return []


def pit_titles(repo, sha):
    try: d = git(repo, 'show', '--format=', '-U0', sha, '--', 'docs/坑记录.md')
    except subprocess.CalledProcessError: return []
    return [l[1:].lstrip('# ').strip() for l in d.splitlines() if l.startswith('+## ')]


def commits(repo, ref, since, until):
    out = git(repo, 'log', '--no-merges', f'--since={since}', f'--until={until}', '--format=%x00%H%x01%h%x01%ad%x01%s%x01%b%x02', '--date=format:%H:%M %z', '--numstat', ref)
    res = []
    for chunk in out.split('\0')[1:]:
        head, _, names = chunk.partition('\x02')
        full, short, date, subj, body = head.split('\x01')
        files, lines = [], {}
        for n in names.split('\n'):
            p = n.split('\t')
            if len(p) != 3: continue
            files.append(p[2]); lines[p[2]] = (int(p[0]) if p[0].isdigit() else 0) + (int(p[1]) if p[1].isdigit() else 0)
        res.append({'sha': full, 'short': short, 'date': date, 'subject': subj, 'body': body, 'files': files, 'lines': lines})
    return res


def day(repo, ref, date, tz, use_gh):
    rows = layer_map.load(os.path.join(repo, layer_map.TABLE))
    d0 = datetime.date.fromisoformat(date)
    since, until = f'{d0} 00:00:00 {tz}', f'{d0 + datetime.timedelta(days=1)} 00:00:00 {tz}'
    groups, skipped, uncovered = {k: [] for k in RANK}, {}, set()
    cs = commits(repo, ref, since, until); seen_subj = {}
    for c in cs:
        if c['subject'] in seen_subj:   # 同标题的重复提交（同一修复进了两条支 / 重放）只列一次，附上另一个提交号
            seen_subj[c['subject']]['dup'].append(c['short']); continue
        c['dup'] = []; seen_subj[c['subject']] = c
        cat, per = classify(repo, rows, c['sha'], c['files'])
        uncovered |= {p for p, v in per.items() if v == '未覆盖'}
        if cat is None:
            k = max(set(per.values()) or {'空提交'}, key=list(per.values()).count) if per else '空提交'
            skipped[k] = skipped.get(k, 0) + 1; continue
        groups[cat].append((c, per))
    head = git(repo, 'rev-parse', '--short', ref).strip()
    out = [f'# 共用层日摘 {date}（{tz}，{ref} {head}）', '',
           f'当天非合并提交 {len(cs)} 笔；要看的 {sum(len(v) for v in groups.values())} 笔。分类只看路径（tools/layer_map.tsv），说明取自提交 / PR / 坑记录。', '']
    def why(c):   # 逐笔列出的理由（11-06 总指挥定 ≤60 行/天；实测「任意 .h」每天 30–44 笔、「带坑记录」11-05 一天 130 笔，作理由会撑爆，
        #   收成两类：改了跨层接口头文件、冷改动；坑记录 / 体验规格只作标签）
        f = []
        if any(IFACE.search(p) for p in c['files']): f.append('改接口头')
        if '🧊' in c['subject'] + c['body'] or '冷改动' in c['body']: f.append('🧊冷')
        return f
    def tags(c):
        return (['坑记录'] if 'docs/坑记录.md' in c['files'] else []) + (['体验规格，接界面时读'] if any(p.startswith('launchers/shared/') for p in c['files']) else []) \
            + ([f'同改动 {" ".join(c["dup"])}'] if c['dup'] else [])
    for cat, items in groups.items():
        if not items: continue
        listed = [(c, per, why(c)) for c, per in items] if cat != 'Metal档' else []
        listed = [x for x in listed if x[2]]
        out += [f'## {TITLE[cat]}：{len(items)} 笔，逐笔列 {len(listed)} 笔（改接口头 / 冷改动）', '']
        for c, per, fl in listed:
            out.append(f'- `{c["short"]}` {c["date"][:5]} {c["subject"][:110]}（{"；".join(fl + tags(c))}）')
        rest = [(c, per) for c, per in items if c['sha'] not in {x[0]['sha'] for x in listed}]
        if rest:
            by = {}
            for c, per in rest:
                mods = sorted({(layer_map.lookup(rows, p) or ('?',))[0] for p, v in per.items() if v == cat or (cat == '共用层' and v in RANK)})
                by.setdefault(mods[0] if mods else '?', []).append(c)
            out.append(f'- 其余 {len(rest)} 笔按模块：' + '、'.join(f'{m} {len(v)}' for m, v in sorted(by.items(), key=lambda x: -len(x[1]))))
            big = max(rest, key=lambda x: sum(x[0]['lines'].values()))[0]
            out.append(f'  改动最大的一笔：`{big["short"]}` {big["subject"][:100]}（{sum(big["lines"].values())} 行）')
            np_ = sum(1 for c, _ in rest if 'docs/坑记录.md' in c['files'])
            if np_: out.append(f'  其中带坑记录 {np_} 笔（标题见 docs/坑记录.md 当天新增）')
        out.append('')
    out += ['## 不用跟（只计数）', '', '、'.join(f'{k} {v} 笔' for k, v in sorted(skipped.items(), key=lambda x: -x[1])) or '无', '']
    if uncovered: out += [f'【黄】分层地图没覆盖的路径 {len(uncovered)} 个（tools/layer_map.py check 查）：' + ' '.join(sorted(uncovered)[:10]), '']
    return '\n'.join(out)


def main(a):
    ap = argparse.ArgumentParser(prog='digest.py'); sub = ap.add_subparsers(dest='cmd', required=True)
    for n in ('day', 'replay'):
        p = sub.add_parser(n); p.add_argument('--repo', default=ROOT); p.add_argument('--ref', default='origin/main'); p.add_argument('--tz', default='-0800'); p.add_argument('--gh', action='store_true')
        if n == 'day': p.add_argument('date')
        else: p.add_argument('--days', type=int, default=7); p.add_argument('--out', required=True); p.add_argument('--end')
    o = ap.parse_args(a)
    if o.cmd == 'day':
        sys.stdout.write(day(o.repo, o.ref, o.date, o.tz, o.gh)); return 0
    end = datetime.date.fromisoformat(o.end) if o.end else datetime.date.today() - datetime.timedelta(days=1)
    os.makedirs(o.out, exist_ok=True); bad = 0
    for i in range(o.days - 1, -1, -1):
        d = (end - datetime.timedelta(days=i)).isoformat()
        try:
            with open(os.path.join(o.out, f'digest_{d}.md'), 'w', encoding='utf-8') as f: f.write(day(o.repo, o.ref, d, o.tz, o.gh))
            print(f'日摘 {d} → {o.out}/digest_{d}.md')
        except Exception as e:   # 生成失败不挡任何东西，只留一行
            print(f'【黄】日摘 {d} 生成失败：{e}'); bad += 1
    return 1 if bad else 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    sys.exit(main(sys.argv[1:]))
