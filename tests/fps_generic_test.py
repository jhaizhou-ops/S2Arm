#!/usr/bin/env python3
"""tools/fps_generic.py 单测（引擎判断与按名定位替成假的，不读游戏数据；八方2 真实正对照另记在提交说明）：
  ⑥ ue4_rows：t.MaxFPS 必需、r.VSync / 动态分辨率预算可选（10-30）
  ① UE4 且两个变量都唯一找到 → 写 fps.tsv：build <构建号前 16 位> / present display / 两行 w，退出 0
  ② 不是 UE4 → 不写、退出 1   ③ UE4 但有一个变量找不到 → 不写、退出 1
  ④ 已收了社区帧率补丁（cpatch.tsv 有 fps: 行）→ 不写、退出 1（不叠两套）   ⑤ 输入读不出（没有 main.patched.bin）→ 退出 2"""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import fps_generic as fg
REAL = fg.ue4_rows

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"🟢" if ok else "🔴"} {name}' + ('' if ok else f'：期望「{want}」→ 真结果「{got}」'))

def root():
    d = tempfile.mkdtemp(); open(os.path.join(d, 'main.patched.bin'), 'wb').write(b'\0' * 64); return d
BID = '0d9649011312f62e93f6a5673a09d7e9'
fg.is_ue4 = lambda r: True
fg.ue4_rows = lambda img: (['w main 0x76fef68 f32 60 *0   # t.MaxFPS', 'w main 0x6f017e8 i32 0 *0   # r.VSync'], '')
r = root(); rc = fg.main([r, BID]); t = open(os.path.join(r, 'fps.tsv')).read().splitlines() if os.path.exists(os.path.join(r, 'fps.tsv')) else []
chk('① UE4 两变量唯一 → 写表、退出 0', (0, 'build 0d9649011312f62e', 'present display', 2), (rc, t[0] if t else '', t[1] if len(t) > 1 else '', sum(l.startswith('w ') for l in t)))
fg.is_ue4 = lambda r: False
r = root(); chk('② 不是 UE4 → 不写、退出 1', (1, False), (fg.main([r, BID]), os.path.exists(os.path.join(r, 'fps.tsv'))))
fg.is_ue4 = lambda r: True; fg.ue4_rows = lambda img: (None, 'r.VSync：没找到注册处')
r = root(); chk('③ 变量找不到 → 不写、退出 1', (1, False), (fg.main([r, BID]), os.path.exists(os.path.join(r, 'fps.tsv'))))
fg.ue4_rows = lambda img: (['w main 0x1 f32 60 *0'], '')
r = root(); open(os.path.join(r, 'cpatch.tsv'), 'w').write('编号\t模块\nfps:abc\tmain\n')
chk('④ 已有社区帧率补丁 → 不写、退出 1', (1, False), (fg.main([r, BID]), os.path.exists(os.path.join(r, 'fps.tsv'))))
r = tempfile.mkdtemp(); chk('⑤ 没有 main.patched.bin → 退出 2', 2, fg.main([r, BID]))
# ⑥ 按名定位结果 → 行（10-30 放宽）。期望手写：t.MaxFPS 唯一、r.VSync 找不到、预算唯一 → 2 行（MaxFPS 60、预算 16.6667），不写 VSync；
#   t.MaxFPS 多处 → 不写；三项都唯一 → 3 行
import ue_cvar_loc
def fake(h): ue_cvar_loc.locate = lambda img, names: {n: h.get(n, []) for n in names}
fake({'t.MaxFPS': [(0x10, 0x4dce7f0)], 'r.DynamicRes.FrameTimeBudget': [(0x20, 0x4dd0000)]})
rows, _ = REAL(b'')
chk('⑥ 只有 t.MaxFPS + 预算 → 2 行，没有 VSync', (2, True, True, False), (len(rows), any('0x4dce7f0 f32 60 ' in r for r in rows), any('0x4dd0000 f32 16.6667 ' in r for r in rows), any('i32 0' in r for r in rows)))
fake({'t.MaxFPS': [(0x10, 0x1), (0x18, 0x2)], 'r.VSync': [(0x30, 0x3)]})
chk('⑥ t.MaxFPS 多处 → 不写', None, REAL(b'')[0])
fake({'t.MaxFPS': [(0x10, 0x1)], 'r.VSync': [(0x30, 0x3)], 'r.DynamicRes.FrameTimeBudget': [(0x40, 0x5)]})
chk('⑥ 三项都唯一 → 3 行', 3, len(REAL(b'')[0]))
print('通用帧率表单测全绿' if not bad else '通用帧率表单测有红'); sys.exit(1 if bad else 0)
