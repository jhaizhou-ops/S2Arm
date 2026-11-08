#!/usr/bin/env python3
"""验证账：贡献者 / 我方的快检报告入账（jhz 10-29：验证只做一次——键 = 程序号 + 构建号 + 能力 + 这项能力在包里的内容哈希；
信任规则与生态线定：工具生成、原始产物齐、指纹可复算 → 「贡献者验证」；同一「构建号 × 机型」两份独立报告结论一致，
或一份加维护方抽查原始产物通过 → 「已验证」）。账在仓库 docs/名单_验证账.tsv（能力卡读它；入账 = 一次 PR）：
  caps_ledger.py verify <报告目录>             复算：report.json 的工具名 / 每份证据 sha256 / 报告指纹都对得上 → 退出 0，否则打原因退出 1
  caps_ledger.py ingest <报告目录> [--repo <仓库>]   verify 通过才入账：五项各一行（能力 widen / fps60 带内容哈希，其余用 -）；
                                                     同键同机型已有别人一致的结论 → 两行都升「已验证」；结论相反 → 两行都记「冲突」
  caps_ledger.py confirm <报告指纹> [--repo <仓库>]   维护方抽查原始产物通过：这份报告的行升「已验证」
  caps_ledger.py seen <程序号> <构建号> <能力> <内容哈希> [--repo <仓库>]   排局前查：同键已有「过 / 不过」→ 打那一行、退出 0；没有 → 退出 1
账的列：程序号 / 构建号 / 能力 / 内容哈希 / 机型 / 结论 / 信任 / 报告指纹 / 贡献者 / 日期 / 实测帧率 / 实测瓦（HEAD 处注释）
口径（总指挥 10-29）：内容哈希 = 包里这项能力的数据 + 实现它的宿主代码（tools/caps_policy.py cap_hashes / IMPL），宿主实现一改就重验；
  账只用来跳过「能力验证」类局。崩溃 / 冷启 / 收局这类稳定性复验不走账，宿主或运行时每次改动都照常上真机（10-29 horizon-stop 收局崩修复）"""
import hashlib, json, os, sys

LEDGER = 'docs/名单_验证账.tsv'
HEAD = ['程序号', '构建号', '能力', '内容哈希', '机型', '结论', '信任', '报告指纹', '贡献者', '日期', '实测帧率', '实测瓦', '60档占比', '本局满屏']   # 本局满屏：这份报告那局宽屏放没放（开 / 关 / -），caps_policy.widen_measured 配对照用
# 实测帧率 / 实测瓦：只填 fps60 行、且这局包内能力清单 60 帧开（report.json metrics.fps60 = 开）；其余 -。tools/caps_policy.py fps60_measured 读这两列
#   判「60 帧开了达不到 / 能耗爆线 → 退回原帧率」（10-29 总指挥）
CAPS = {'画面': '画面', '帧率': 'fps60', '满屏': 'widen', '直连默认启动': '直连启动', '能耗': '能耗'}   # 快检五项 → 账里的能力名
TOOL = 'tools/quality_check.py'


def verify(d):
    """→ (报告 dict, 问题列表)；问题列表空 = 可信入账"""
    try: j = json.load(open(os.path.join(d, 'report.json'), encoding='utf-8'))
    except (OSError, ValueError) as e: return None, [f'report.json 读不出：{e}']
    bad = []
    if j.get('schema') != 's2a.quality-report.v1': bad.append(f'schema 不是 s2a.quality-report.v1：{j.get("schema")}')
    if (j.get('tool') or {}).get('name') != TOOL: bad.append('不是工具生成的报告（tool.name 不是 tools/quality_check.py）')
    if not j.get('evidence'): bad.append('没有证据清单')
    for e in j.get('evidence') or []:
        f = os.path.join(d, e.get('path', ''))
        if e.get('private') and not os.path.exists(f): continue   # 游戏截图只留贡献者本机（不随公开附件外发）：缺了不算缺证据，指纹照记
        if not os.path.isfile(f) or os.path.islink(f) or not os.path.realpath(f).startswith(os.path.realpath(d) + os.sep): bad.append(f'证据缺失、是链接或在报告目录外：{e.get("path")}'); continue
        if hashlib.sha256(open(f, 'rb').read()).hexdigest() != e.get('sha256'): bad.append(f'证据被改过（sha256 对不上）：{e["path"]}')
    fp = hashlib.sha256(json.dumps({k: j.get(k) for k in ('tool', 'game', 'checks', 'evidence', 'capHashes') + (('metrics',) if 'metrics' in j else ())},
                                   sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]   # 带 metrics 的新报告连读数一起复算（旧报告没有这键，照旧）
    if fp != j.get('fingerprint'): bad.append(f'报告指纹复算不一致（{fp} ≠ {j.get("fingerprint")}）')
    g = j.get('game') or {}
    if len(g.get('programId', '')) != 16 or len(g.get('buildId', '')) != 32: bad.append('缺程序号 / 构建号（host.log 里读不到身份，不能入账）')
    return j, bad


def load(repo):
    p = os.path.join(repo, LEDGER)
    if not os.path.exists(p): return []
    rows = [l.rstrip('\n').split('\t') for l in open(p, encoding='utf-8') if l.strip() and not l.startswith('#')]
    if not rows or rows[0] != HEAD[:len(rows[0])]: return []
    return [dict(dict.fromkeys(HEAD, '-'), **dict(zip(rows[0], r))) for r in rows[1:]]   # 旧表头（没有实测两列）照读，缺的列记 -


def save(repo, rows):
    p = os.path.join(repo, LEDGER); tmp = p + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('# 验证账（tools/caps_ledger.py 写；键 = 程序号 + 构建号 + 能力 + 内容哈希；信任：贡献者验证 / 已验证 / 冲突，规则见工具文件头）\n')
        f.write('\t'.join(HEAD) + '\n')
        for r in rows: f.write('\t'.join(r.get(k, '-') or '-' for k in HEAD) + '\n')
    os.replace(tmp, p)


def ingest(d, repo):
    j, bad = verify(d)
    if bad: print('🔴 不入账：' + '；'.join(bad)); return 1
    rows = load(repo); g = j['game']; dev = (j.get('run') or {}).get('device') or '-'; who = j.get('contributor') or '-'
    rows = [r for r in rows if r['报告指纹'] != j['fingerprint']]   # 同一份报告重复入账 = 覆盖
    for item, cap in CAPS.items():
        res = j['checks'].get(item, '没数据')
        if res == '没数据': continue   # 没数据不是结论，不入账（不挡下一次验证）
        h = (j.get('capHashes') or {}).get(cap, '-')
        row = {'程序号': g['programId'], '构建号': g['buildId'], '能力': cap, '内容哈希': h, '机型': dev, '结论': res, '信任': '贡献者验证',
               '报告指纹': j['fingerprint'], '贡献者': who, '日期': j.get('created', '-'), '实测帧率': '-', '实测瓦': '-', '60档占比': '-', '本局满屏': (j.get('metrics') or {}).get('widen', '-')}
        mt = j.get('metrics') or {}
        if cap == 'fps60' and mt.get('fps60') == '开':
            row.update({'实测帧率': f"{mt['fpsAvg']:.2f}" if mt.get('fpsAvg') is not None else '-', '实测瓦': f"{mt['watts']:.2f}" if mt.get('watts') is not None else '-',
                        '60档占比': f"{mt['hold60']:.3f}" if mt.get('adaptive') and mt.get('hold60') is not None else '-'})   # 自适应局才填：fps60_measured 按主档位选能耗线
        peers = [r for r in rows if (r['程序号'], r['构建号'], r['能力'], r['内容哈希'], r['机型']) == (row['程序号'], row['构建号'], cap, h, dev) and r['贡献者'] != who]
        if any(r['结论'] != res for r in peers):
            row['信任'] = '冲突'
            for r in peers: r['信任'] = '冲突'
        elif peers:   # 两份独立报告一致 → 已验证
            row['信任'] = '已验证'
            for r in peers: r['信任'] = '已验证'
        rows.append(row)
    save(repo, rows); print(f'入账 {j["game"].get("name")}（指纹 {j["fingerprint"]}）：' + '　'.join(f'{k} {j["checks"][k]}' for k in CAPS)); return 0


def confirm(fp, repo):
    rows = load(repo); hit = [r for r in rows if r['报告指纹'] == fp and r['信任'] != '冲突']
    for r in hit: r['信任'] = '已验证'
    save(repo, rows); print(f'维护方抽查通过：{len(hit)} 行升「已验证」'); return 0 if hit else 1


def seen(pid, bid, cap, h, repo):
    hit = [r for r in load(repo) if (r['程序号'].upper(), r['构建号'].lower(), r['能力'], r['内容哈希']) == (pid.upper(), bid.lower(), cap, h) and r['结论'] in ('过', '不过')]
    for r in hit: print('\t'.join(r[k] for k in HEAD))
    return 0 if hit else 1


if __name__ == '__main__':
    a = sys.argv[1:]; repo = a[a.index('--repo') + 1] if '--repo' in a else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    a = [x for i, x in enumerate(a) if x != '--repo' and (i == 0 or a[i - 1] != '--repo')]
    if len(a) == 2 and a[0] == 'verify':
        j, bad = verify(a[1]); print('可入账' if not bad else '🔴 ' + '；'.join(bad)); sys.exit(0 if not bad else 1)
    if len(a) == 2 and a[0] == 'ingest': sys.exit(ingest(a[1], repo))
    if len(a) == 2 and a[0] == 'confirm': sys.exit(confirm(a[1], repo))
    if len(a) == 5 and a[0] == 'seen': sys.exit(seen(*a[1:], repo))
    print(__doc__.strip().splitlines()[0]); sys.exit(2)
