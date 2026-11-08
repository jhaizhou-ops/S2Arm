#!/usr/bin/env python3
"""tools/caps_ledger.py 单测（合成报告，不调 AI、不碰游戏数据）：
  ① 完整报告 verify 通过；改一个字节的证据 → 「sha256 对不上」；删一份证据 → 「证据缺失」；改结论不改指纹 → 「指纹复算不一致」；tool.name 不对 → 拒
  ② ingest：五项里「没数据」不入账；widen / fps60 带内容哈希，其余 -；信任「贡献者验证」
  ③ 同键同机型、另一位贡献者结论一致 → 两份都升「已验证」；结论相反 → 都记「冲突」；同一位贡献者重复交不算独立
  ④ confirm <指纹> → 升「已验证」；seen 查得到「过 / 不过」退出 0，查不到退出 1；同一份报告重复入账覆盖不重复"""
import hashlib, json, os, shutil, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import caps_ledger as L

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"🟢" if ok else "🔴"} {name}' + ('' if ok else f'：期望「{want}」→ 真结果「{got}」'))

PID, BID = '0100152000022000', '158c0c7399aabd7bf83795c2ef3484c7'
T = tempfile.mkdtemp(); REPO = os.path.join(T, 'repo'); os.makedirs(os.path.join(REPO, 'docs'))

def mk(name, who, checks, caps=None, device='iPhone 16 Pro'):
    d = os.path.join(T, name); os.makedirs(os.path.join(d, 'evidence', 'shots_ap'))
    open(os.path.join(d, 'evidence', 'host.log'), 'w').write(f'程序号 {PID}\n构建号 {BID}\n')
    open(os.path.join(d, 'evidence', 'shots_ap', 'ap_mark.png'), 'wb').write(name.encode())
    ev = [{'path': p, 'sha256': hashlib.sha256(open(os.path.join(d, p), 'rb').read()).hexdigest(), 'bytes': os.path.getsize(os.path.join(d, p))}
          for p in ('evidence/host.log', 'evidence/shots_ap/ap_mark.png')]
    j = {'schema': 's2a.quality-report.v1', 'created': '2026-10-29', 'tool': {'name': 'tools/quality_check.py', 'sha256': 'x', 'judge': 'openrouter'},
         'game': {'name': 'mk8d', 'programId': PID, 'buildId': BID}, 'run': {'kind': 'iphone', 'device': device}, 'contributor': who,
         'capHashes': caps or {'widen': 'aaaa', 'fps60': 'bbbb'}, 'checks': dict(checks), 'reading': '', 'evidence': ev}
    j['fingerprint'] = hashlib.sha256(json.dumps({k: j[k] for k in ('tool', 'game', 'checks', 'evidence', 'capHashes')}, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]
    json.dump(j, open(os.path.join(d, 'report.json'), 'w'), ensure_ascii=False)
    return d, j

C = {'画面': '过', '帧率': '过', '满屏': '不过', '直连默认启动': '过', '能耗': '没数据'}
d1, j1 = mk('r1', 'alice', C)
chk('① 完整报告可入账', [], L.verify(d1)[1])
d2, _ = mk('r2', 'alice', C); open(os.path.join(d2, 'evidence', 'host.log'), 'a').write('x')
chk('① 证据改一个字节 → 拒', True, any('sha256 对不上' in b for b in L.verify(d2)[1]))
d3, _ = mk('r3', 'alice', C); os.remove(os.path.join(d3, 'evidence', 'shots_ap', 'ap_mark.png'))
chk('① 删一份证据 → 拒', True, any('证据缺失' in b for b in L.verify(d3)[1]))
d4, j4 = mk('r4', 'alice', C); j4['checks']['满屏'] = '过'; json.dump(j4, open(os.path.join(d4, 'report.json'), 'w'), ensure_ascii=False)
chk('① 改结论不改指纹 → 拒', True, any('指纹复算不一致' in b for b in L.verify(d4)[1]))
d5, j5 = mk('r5', 'alice', C); j5['tool']['name'] = 'my_script.py'; json.dump(j5, open(os.path.join(d5, 'report.json'), 'w'), ensure_ascii=False)
chk('① 不是工具生成 → 拒', True, any('不是工具生成' in b for b in L.verify(d5)[1]))
chk('① 被拒的报告 ingest 退出 1、不写账', (1, False), (L.ingest(d2, REPO), os.path.exists(os.path.join(REPO, L.LEDGER))))

L.ingest(d1, REPO); rows = L.load(REPO)
chk('② 没数据（能耗）不入账，入 4 行', ['画面', 'fps60', 'widen', '直连启动'], [r['能力'] for r in rows])
chk('② 内容哈希：widen / fps60 带，其余 -', ['-', 'bbbb', 'aaaa', '-'], [r['内容哈希'] for r in rows])
chk('② 信任「贡献者验证」', {'贡献者验证'}, {r['信任'] for r in rows})
L.ingest(d1, REPO); chk('④ 同一份报告重复入账覆盖不重复', 4, len(L.load(REPO)))
d6, j6 = mk('r6', 'alice', C); L.ingest(d6, REPO)
chk('③ 同一位贡献者再交不算独立', {'贡献者验证'}, {r['信任'] for r in L.load(REPO)})
d7, j7 = mk('r7', 'bob', C); L.ingest(d7, REPO)
chk('③ 另一位贡献者结论一致 → 已验证', {'已验证'}, {r['信任'] for r in L.load(REPO) if r['能力'] == 'widen'})
d8, j8 = mk('r8', 'carol', dict(C, 画面='不过')); L.ingest(d8, REPO)
chk('③ 结论相反 → 冲突', {'冲突'}, {r['信任'] for r in L.load(REPO) if r['能力'] == '画面'})
d9, j9 = mk('r9', 'dave', C, caps={'widen': 'cccc', 'fps60': 'dddd'}, device='iPhone 15'); L.ingest(d9, REPO)
L.confirm(j9['fingerprint'], REPO)
chk('④ confirm → 已验证', {'已验证'}, {r['信任'] for r in L.load(REPO) if r['报告指纹'] == j9['fingerprint']})
chk('④ seen 查得到 widen cccc（不过）→ 0', 0, L.seen(PID, BID, 'widen', 'cccc', REPO))
chk('④ seen 内容哈希变了 → 1', 1, L.seen(PID, BID, 'widen', 'eeee', REPO))
# ⑤ 实测两列（10-29 总指挥 60 帧退回规则）：带 metrics 的报告，指纹连 metrics 一起算；fps60 行写实测帧率 / 瓦（那局 60 帧开），其余行 -
R2 = os.path.join(T, 'repo2'); os.makedirs(os.path.join(R2, 'docs'))
def mkm(name, mt):
    d, j = mk(name, 'carol', {'画面': '过', '帧率': '不过', '满屏': '过', '直连默认启动': '过', '能耗': '不过'}); j['metrics'] = mt
    j['fingerprint'] = hashlib.sha256(json.dumps({k: j[k] for k in ('tool', 'game', 'checks', 'evidence', 'capHashes', 'metrics')}, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]
    json.dump(j, open(os.path.join(d, 'report.json'), 'w'), ensure_ascii=False); return d, j
dm, jm = mkm('m1', {'fps60': '开', 'fpsAvg': 32.0, 'watts': 7.29})
chk('⑤ 带 metrics 的报告可入账', [], L.verify(dm)[1])
jm['metrics']['fpsAvg'] = 60.0; json.dump(jm, open(os.path.join(dm, 'report.json'), 'w'), ensure_ascii=False)
chk('⑤ 改读数不改指纹 → 拒', True, any('指纹复算不一致' in b for b in L.verify(dm)[1]))
dm, jm = mkm('m2', {'fps60': '开', 'fpsAvg': 32.0, 'watts': 7.29}); L.ingest(dm, R2)
rows = {r['能力']: r for r in L.load(R2)}
chk('⑤ fps60 行写实测 32.00 / 7.29，别的行 -', (('32.00', '7.29'), ('-', '-')), ((rows['fps60']['实测帧率'], rows['fps60']['实测瓦']), (rows['能耗']['实测帧率'], rows['能耗']['实测瓦'])))
dm, jm = mkm('m3', {'fps60': '关', 'fpsAvg': 30.0, 'watts': 3.1}); L.ingest(dm, R2)
chk('⑤ 那局 60 帧关 → fps60 行实测 -', ('-', '-'), next((r['实测帧率'], r['实测瓦']) for r in L.load(R2) if r['报告指纹'] == jm['fingerprint'] and r['能力'] == 'fps60'))
dm, jm = mkm('m4', {'fps60': '开', 'fpsAvg': 35.0, 'watts': 4.2, 'adaptive': True, 'hold60': 0.2}); L.ingest(dm, R2)
chk('⑤ 自适应局 fps60 行填 60档占比 0.200（非自适应局 -）', ('0.200', '-'), (next(r['60档占比'] for r in L.load(R2) if r['报告指纹'] == jm['fingerprint'] and r['能力'] == 'fps60'),
    next(r['60档占比'] for r in L.load(R2) if r['能力'] == 'fps60' and r['实测帧率'] == '32.00')))
dw, jw = mkm('m5', {'fps60': '关', 'widen': '开'}); L.ingest(dw, R2)
chk('⑥ 本局满屏按报告 metrics.widen 填进这份报告的每一行（10-30 #996 对照用）', {'开'}, {r['本局满屏'] for r in L.load(R2) if r['报告指纹'] == jw['fingerprint']})
# ⑥ 旧表头（没有实测两列）照读、缺列记 -，保存后不丢行
R3 = os.path.join(T, 'repo3'); os.makedirs(os.path.join(R3, 'docs'))
open(os.path.join(R3, L.LEDGER), 'w').write('\t'.join(L.HEAD[:10]) + '\n' + '\t'.join([PID, BID, 'widen', 'aaaa', 'x', '过', '贡献者验证', 'fp', 'a', '2026-10-29']) + '\n')
old = L.load(R3); chk('⑥ 旧表头照读 1 行、实测列 -', (1, '-'), (len(old), old[0]['实测帧率'] if old else None))
L.ingest(dm, R3); chk('⑥ 旧账入新报告后旧行还在', True, any(r['报告指纹'] == 'fp' for r in L.load(R3)))
shutil.rmtree(T)
print('验证账单测全绿' if not bad else '验证账单测有红'); sys.exit(1 if bad else 0)
