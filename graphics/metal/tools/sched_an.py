#!/usr/bin/env python3
# 帧级调度测算：读 NXGAL_PSTAT_DUMP 导出流（E 行带切遍原因 / 依赖，见 graphics/metal/gal_pstat.h SW_*），按帧算现状与两层重排后的遍数、附件读写
# 用法：python3 graphics/metal/tools/sched_an.py <NXGAL_PSTAT_DUMP 导出文件> [起始帧，缺省 11]
import sys, collections
WHY = ['其他', '换目标组', '写缓冲', '填缓冲', '拷缓冲', '贴图上传', '贴图拷贝', '派发', '本遍自采样', '内存屏障', '隐藏附件', '落实清屏', '读回', '出图', '游戏提交', '索引转换']
DEP = {0: '可重排', 1: '真依赖', 2: '遍边界', 3: '游戏提交', 4: '未登记'}
f = sys.argv[1]; lo = int(sys.argv[2]) if len(sys.argv) > 2 else 11
frames = []; cur = None
for l in open(f, encoding='utf-8', errors='replace'):
    t = l.split()
    if not t: continue
    k = t[0]
    if k == 'F': cur = {'n': int(t[1]), 'ev': []}; frames.append(cur); continue
    if cur is None or k == 'L': continue
    cur['ev'].append(t)
frames = [fr for fr in frames if fr['n'] >= lo]
def passes_of(ev):
    ps = []; p = None; pend_reads = set(); gap_cs = False
    for t in ev:
        k = t[0]
        if k == 'P':
            p = {'att': {}, 'rd': set(pend_reads), 'end': None, 'cs_before': gap_cs}; ps.append(p); pend_reads = set(); gap_cs = False
        elif k == 'A' and p is not None: p['att'][t[1]] = (int(t[2]), int(t[3]))
        elif k == 'S':
            root, inpass, cs = t[1], int(t[2]), int(t[3])
            if cs: gap_cs = True
            elif inpass and p is not None: p['rd'].add(root)
            else: pend_reads.add(root)
        elif k == 'R':
            if p is not None and p['end'] is None: p['rd'].add(t[1])
            else: pend_reads.add(t[1])
        elif k == 'E' and p is not None and p['end'] is None:
            p['end'] = (int(t[3]), int(t[4])) if len(t) > 4 and not t[3].startswith('0x') else (0, 1)
        elif k == 'C': gap_cs = True if p is None or p['end'] is not None else gap_cs
    return ps
def traffic(groups):
    st = ld = 0
    for g in groups:
        for root, (clr, b) in g['att'].items():
            st += b
            if not clr: ld += b
    return st, ld
tot = collections.Counter(); n = 0
cnt = collections.Counter(); cntb = collections.Counter()
for fr in frames:
    ps = passes_of(fr['ev'])
    if not ps: continue
    n += 1
    tot['遍'] += len(ps); st, ld = traffic(ps); tot['存回'] += st; tot['读入'] += ld
    # 切遍分账（最后一遍的结束是出图 / 帧尾，不算切遍）
    for i, p in enumerate(ps[:-1]):
        w, d = p['end'] or (0, 1); cnt[(w, d)] += 1
        q = ps[i + 1]
        if set(q['att']) == set(p['att']):
            cntb[(w, d)] += sum(b for r, (c, b) in p['att'].items()) + sum(b for r, (c, b) in q['att'].items() if not c)
    # 第一层：可重排的切遍、前后同一组附件 → 合成一遍
    g1 = []
    for i, p in enumerate(ps):
        if g1 and (ps[i - 1]['end'] or (0, 1))[1] == 0 and set(p['att']) == set(g1[-1]['att']):
            g = g1[-1]; g['rd'] |= p['rd']
            for r, (c, b) in p['att'].items():
                if r not in g['att']: g['att'][r] = (c, b)
            g['end'] = p['end']; continue
        g1.append({'att': dict(p['att']), 'rd': set(p['rd']), 'end': p['end'], 'cs_before': p['cs_before']})
    tot['遍1'] += len(g1); st, ld = traffic(g1); tot['存回1'] += st; tot['读入1'] += ld
    # 第二层（上限估计）：同组附件的遍跨中间遍合并——中间各遍不读它的附件、不写它读的、不写它的附件，中间没有计算派发
    g2 = []
    for p in g1:
        merged = False
        for i in range(len(g2) - 1, -1, -1):
            q = g2[i]
            if set(q['att']) == set(p['att']):
                mid = g2[i + 1:]; wp = set(p['att'])
                ok = not p['cs_before'] and all(not (m['cs_before']) and not (p['rd'] & set(m['att'])) and not (wp & (m['rd'] | set(m['att']))) for m in mid)
                if ok:
                    q['rd'] |= p['rd']
                    for r, (c, b) in p['att'].items():
                        if r not in q['att']: q['att'][r] = (c, b)
                    merged = True
                break
        if not merged: g2.append({'att': dict(p['att']), 'rd': set(p['rd']), 'cs_before': p['cs_before']})
    tot['遍2'] += len(g2); st, ld = traffic(g2); tot['存回2'] += st; tot['读入2'] += ld
if not n: print('没有帧'); sys.exit()
M = 1048576
print(f'帧 {n}（第 {lo} 帧起）；每帧：现状 遍 {tot["遍"]/n:.1f}、存回 {tot["存回"]/n/M:.1f} MB、读入 {tot["读入"]/n/M:.1f} MB')
print(f'  第一层（去掉可重排的切遍）：遍 {tot["遍1"]/n:.1f}、存回 {tot["存回1"]/n/M:.1f} MB、读入 {tot["读入1"]/n/M:.1f} MB')
print(f'  第二层（另加同组遍跨遍合并，上限估计）：遍 {tot["遍2"]/n:.1f}、存回 {tot["存回2"]/n/M:.1f} MB、读入 {tot["读入2"]/n/M:.1f} MB')
print('  切遍分账（每帧次数 / 前后同组时的存回 + 读入 MB）：')
for (w, d), c in sorted(cnt.items(), key=lambda x: -x[1]):
    print(f'    {WHY[w] if w < len(WHY) else w}·{DEP.get(d, d)}：{c/n:.1f} 次 / {cntb[(w, d)]/n/M:.1f} MB')
