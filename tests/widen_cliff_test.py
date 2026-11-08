#!/usr/bin/env python3
"""tools/widen_cliff.py 单测（合成图，不用游戏截图）。期望手算：
  ① 2346×1080、16:9 区域（x 213–2132）外整片纯黑、区域内是纹理 → 断崖 ≈ 1.0（≥ 0.5 判坏）
  ② 全幅纹理 → ≈ 0
  ③ 黑区从 x 0 到 400（跨过边界 213，关卡本身的暗处）、其余纹理 → 边界两侧都黑，≈ 0，不误判
  ④ 1920×1080（没加宽）→ None"""
import os, random, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
from PIL import Image
import widen_cliff as wc

bad = 0
def chk(name, ok, got):
    global bad
    bad += not ok; print(f'{"🟢" if ok else "🔴"} {name}（{got}）')

rnd = random.Random(7); T = tempfile.mkdtemp()
def img(W, H, black):
    im = Image.new('L', (W, H)); px = im.load()
    for y in range(H):
        for x in range(W): px[x, y] = 0 if black(x) else 40 + rnd.randrange(180)
    p = os.path.join(T, f'{W}_{rnd.randrange(1 << 30)}.png'); im.save(p); return p
W, H = 2346, 1080; side = (W - round(H * 16 / 9)) // 2
c = wc.cliff(img(W, H, lambda x: x < side or x >= W - side)); chk('① 16:9 外整片纯黑 → 断崖 ≥ 0.9', c is not None and c >= 0.9, c)
c = wc.cliff(img(W, H, lambda x: False)); chk('② 全幅纹理 → 断崖 ≤ 0.05', c is not None and abs(c) <= 0.05, c)
c = wc.cliff(img(W, H, lambda x: x < 400)); chk('③ 黑区跨过 16:9 边界（关卡暗处）→ 断崖 ≤ 0.05', c is not None and abs(c) <= 0.05, c)
c = wc.cliff(img(1920, 1080, lambda x: False)); chk('④ 没加宽 → None', c is None, c)
print('widen_cliff 单测全绿' if not bad else 'widen_cliff 单测有红'); sys.exit(1 if bad else 0)
