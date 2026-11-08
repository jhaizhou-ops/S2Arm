#!/usr/bin/env python3
"""tools/fps_warehouse.py 单测（合成社区条目，不读游戏数据、不带补丁原文）。期望按格式手算：
  ① 担架拍档形状（预算 TruncDec(FRAMETIME_TARGET, 1) + t.MaxFPS FPS_LOCK_TARGET + block timing）→ 2 行：预算 f32 16.6、t.MaxFPS f32 62
  ② r.VSync write int32 [0, 0] → i32 0
  ③ 指针链更深 [MAIN, X, 0x10, 0] → 不收；④ 有 MASTER_WRITE 段 → 不收；⑤ 项带 address_unsafe → 不收
  ⑥ 注释没点名控制台变量 → 不收；⑦ 值列表不一致 [30, 60] → 不收；⑧ 不认的全局量 → 不收
  ⑨ main：索引里同构建号「FPSLocker yaml」→ 写 fps.tsv（build 小写 16 位 / present display / 2 行 w），退出 0；
     构建号不同 → 不写、退出 1；已有 pchtxt 帧率补丁（cpatch.tsv fps:）→ 不写、退出 1"""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import fps_warehouse as fw

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"🟢" if ok else "🔴"} {name}' + ('' if ok else f'：期望「{want}」→ 真结果「{got}」'))

ST = '''# Game 1.0.0
# BID: 00112233445566AA

unsafeCheck: true

ALL_FPS:
  # r.DynamicRes.FrameTimeBudget (1000/FPS)
  -
    type: evaluate_write
    address: [MAIN, 0x5C63550, 0]
    value_type: float
    value: ["TruncDec(FRAMETIME_TARGET, 1)", "TruncDec(FRAMETIME_TARGET, 1)"]
  # t.MaxFPS
  -
    type: evaluate_write
    address: [MAIN, 0x5C880D8, 0]
    value_type: float
    value: [FPS_LOCK_TARGET, FPS_LOCK_TARGET]
  -
    type: block
    what: timing
'''
def addrs(text):
    r, w = fw.rows_of(text); return [' '.join(x.split()[2:5]) for x in r] if r else w
chk('① 担架拍档形状 → 预算 16.6、t.MaxFPS 62', ['0x5c63550 f32 16.6', '0x5c880d8 f32 62'], addrs(ST))
VS = 'ALL_FPS:\n  # r.VSync\n  -\n    type: write\n    address: [MAIN, 0x6F017E8, 0]\n    value_type: int32\n    value: [0, 0]\n'
chk('② r.VSync int32 → i32 0', ['0x6f017e8 i32 0'], addrs(VS))
no = lambda t: fw.rows_of(t)[0] is None
chk('③ 指针链更深 → 不收', True, no(VS.replace('[MAIN, 0x6F017E8, 0]', '[MAIN, 0x6F017E8, 0x10, 0]')))
chk('④ 有 MASTER_WRITE 段 → 不收', True, no(VS + 'MASTER_WRITE:\n  -\n    type: bytes\n    main_offset: 0x10\n    value_type: uint8\n    value: [1]\n'))
chk('⑤ 项带 address_unsafe → 不收', True, no(VS.replace('    value_type: int32\n', '    address_unsafe: true\n    value_type: int32\n')))
chk('⑥ 注释没点名控制台变量 → 不收', True, no(VS.replace('# r.VSync', '# frame limiter')))
chk('⑦ 值列表不一致 → 不收', True, no(VS.replace('value: [0, 0]', 'value: [30, 60]')))
chk('⑧ 不认的全局量 → 不收', True, no(VS.replace('value: [0, 0]', 'value: [SOME_GLOBAL, SOME_GLOBAL]')))
d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, 'p'))
open(os.path.join(d, 'p', 'a.yaml'), 'w').write(ST)
open(os.path.join(d, 'INDEX.tsv'), 'w').write('game\ttitle_id\tversion\tbuild_id\ttype\tpath\n g\t0100\t1.0\t00112233445566AA\tFPSLocker yaml\tp/a.yaml\n'.replace('\n g', '\ng'))
os.environ['S2A_CPATCH_DIRS'] = d
r = tempfile.mkdtemp(); rc = fw.main([r, '00112233445566aabbccddeeff001122'])
t = open(os.path.join(r, 'fps.tsv')).read().splitlines() if os.path.exists(os.path.join(r, 'fps.tsv')) else []
chk('⑨ 同构建号 → 写表、退出 0', (0, 'build 00112233445566aa', 'present display', 2), (rc, t[0] if t else '', t[1] if len(t) > 1 else '', sum(l.startswith('w ') for l in t)))
r = tempfile.mkdtemp(); chk('⑨ 构建号不同 → 不写、退出 1', (1, False), (fw.main([r, 'ffffffffffffffff0000000000000000']), os.path.exists(os.path.join(r, 'fps.tsv'))))
r = tempfile.mkdtemp(); open(os.path.join(r, 'cpatch.tsv'), 'w').write('编号\t模块\nfps:abc\tmain\n')
chk('⑨ 已有 pchtxt 帧率补丁 → 不写、退出 1', (1, False), (fw.main([r, '00112233445566aabbccddeeff001122']), os.path.exists(os.path.join(r, 'fps.tsv'))))
print('社区帧率条目单测全绿' if not bad else '社区帧率条目单测有红'); sys.exit(1 if bad else 0)
