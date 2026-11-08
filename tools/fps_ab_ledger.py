#!/usr/bin/env python3
"""60 帧逻辑速度同局 A/B 入账（11-02 原生崩溃线）：python3 tools/fps_ab_ledger.py merge <仓库> <批次逻辑速度.tsv>…
普查每款把自动玩家「逻辑速度同局 A/B：绿|红|判不出」那一行写进 <批次>/逻辑速度.tsv（tools/census/census.py fps_ab_note）；本工具把「绿 / 红」合进
仓库按款登记表 docs/名单_60帧逻辑速度/<程序号>.tsv（tools/reglist.py），同款同构建号新结论覆盖旧的（日期新的赢），判不出里「原生 60 / 帧率没涨」入账为「无风险」（开 60 帧不会倍速；同构建号已判红不覆盖，11-04 满屏补丁线），其余判不出不入账。
读者 tools/caps_policy.py：红 = 强信号关 60 帧，立即生效；绿写进来源说明；无风险只作核验记录、不改开关（11-02 起 60 帧全引擎默认开，绿不改开关）。
放行列（11-02 早先绿要放行才开；全引擎默认开后只作核验记录，不改开关）：本工具写空，AI 看开段截图核过的绿改「是」；同款同构建号改判时清空重核。打一行：新增 / 改判 / 未变 / 跳过判不出 各几款"""
import csv, os, sys

HEAD = ['程序号', '构建号', '款', '结论', 'ρ', 'q', '依据', '日期', '放行']
D = 'docs/名单_60帧逻辑速度'


def read(path):
    with open(path, encoding='utf-8') as f: return list(csv.DictReader((l for l in f if not l.startswith('#')), delimiter='\t'))


def no_risk(r):   # 判不出里的「原生 60」（关段已 ≥ 55 帧）/「帧率没涨」（q < 1.15）：开 60 帧不会倍速（同下面拆分与 tests/autoplay sp_verdict 门槛）
    num = lambda c: float(r.get(c) or 0)
    return r.get('结论') == '判不出' and (num('关段帧率') >= 55 or 0 < num('q') < 1.15)


def merge(repo, batches):
    got = {}
    for b in batches:
        for r in read(b):
            pid, bid, v = (r.get('键') or '').upper(), (r.get('构建号') or '').lower(), r.get('结论', '')
            if len(pid) != 16 or len(bid) != 32: continue
            k = (pid, bid)
            if k not in got or (r.get('日期', '') >= got[k].get('日期', '')): got[k] = dict(r, 批次=os.path.dirname(os.path.abspath(b)))
    n = {'新增': 0, '改判': 0, '未变': 0, '跳过判不出': 0}
    for (pid, bid), r in sorted(got.items()):
        v = r['结论'] if r['结论'] in ('绿', '红') else '无风险' if no_risk(r) else None
        if not v: n['跳过判不出'] += 1; continue
        f = os.path.join(repo, D, pid + '.tsv'); old = read(f) if os.path.exists(f) else []
        if v == '无风险' and any((o.get('构建号') or '').lower() == bid and o.get('结论') == '红' for o in old): n['未变'] += 1; continue   # 同构建号已判红：无风险不覆盖（只有真判绿 / 复测才改）
        row = {'程序号': pid, '构建号': bid, '款': r.get('名称', ''), '结论': v, 'ρ': r.get('ρ', ''), 'q': r.get('q', ''),
               '依据': f"普查同局 A/B {os.path.basename(r['批次'])}/{pid}（{r.get('量法', '')}画面运动 关 {r.get('关段像素每秒', '')} → 开 {r.get('开段像素每秒', '')}，出图 {r.get('关段帧率', '')} → {r.get('开段帧率', '')}）",
               '日期': r.get('日期', '')}
        keep = [o for o in old if (o.get('构建号') or '').lower() != bid]
        same = [o for o in old if (o.get('构建号') or '').lower() == bid]
        if same and same[-1].get('结论') == row['结论'] and same[-1].get('日期', '') >= row['日期']: n['未变'] += 1; continue
        if same and same[-1].get('结论') == row['结论']: row['放行'] = same[-1].get('放行', '')   # 结论没变：保留已核的放行；改判（绿 ↔ 红）清空
        n['改判' if same else '新增'] += 1
        with open(f, 'w', encoding='utf-8') as o:
            o.write('\t'.join(HEAD) + '\n')
            for x in keep + [row]: o.write('\t'.join(str(x.get(h, '')).replace('\t', ' ') for h in HEAD) + '\n')
    print('逻辑速度同局 A/B 入账：' + '、'.join(f'{k} {v}' for k, v in n.items()) + f'（{len(got)} 款，{len(batches)} 个批次文件）')
    # 每批三个数（11-02 总指挥：每批报「绿 / 判红 / 判不了」）：60 帧全引擎默认开，只有判红改开关（开 → 关）
    c = {v: sum(1 for r in got.values() if (r['结论'] if r['结论'] in ('绿', '红') else '判不了') == v) for v in ('绿', '红', '判不了')}
    print(f"本批结论：绿 {c['绿']}（保持 60 帧）、判红 {c['红']}（强信号关回原帧率）、判不了 {c['判不了']}（保持 60 帧，玩家可在设置里关）")
    # 判不了按说明拆（11-02 收紧，tests/autoplay sp_verdict）：原生 60 / 帧率没涨 无倍速风险；量不出 / 场景不一致 / 其他 才是真缺口（帧率涨了却没判出）
    sub = {}
    for r in got.values():
        if r['结论'] in ('绿', '红'): continue
        num = lambda c: float(r.get(c) or 0)   # 按读数分（同 sp_verdict 的门槛），旧批次的说明文字是旧口径
        t = '原生 60' if num('关段帧率') >= 55 else '帧率没涨' if num('q') < 1.15 else '量不出' if num('关段像素每秒') < 2 else '其他'
        sub[t] = sub.get(t, 0) + 1
    if sub: print('判不了拆分：' + '、'.join(f'{k} {sub.get(k, 0)}' for k in ('原生 60', '帧率没涨', '量不出', '其他')) + '（前两类开 60 帧不会倍速；后两类是帧率涨了却没判出）')
    return 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == 'merge': sys.exit(merge(a[1], a[2:]))
    print(__doc__.strip()); sys.exit(2)
