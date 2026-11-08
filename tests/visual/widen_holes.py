#!/usr/bin/env python3
"""宽屏露空量化：Hor+ 加宽后两侧新视野里，游戏 CPU 按 16:9 视锥剔除掉的物体留下的空洞。
输入 galplay --depth 导出的场景深度（depth_<帧>.f32 + .json：加宽宽 w、客体宽 w0、清屏值）与同帧加宽出图。
判法（不靠人眼、不按游戏）：「没画东西」= 深度等于清屏值。同一行里，两侧带「没画」的比例超出中间 16:9 区「没画」的比例的部分算露空
——天空 / 远景整行都没画，中间区同样没画，不算；地面在中间有、到两侧突然没了，算。逐像素标记：两侧带没画、且该行中间区有画的比例 ≥ 95%（「地面行」：中间整行画满，两侧却空——远景背景层常不写深度，中间行本身有天空空隙时不判，10-19 动森原生加宽实测 50% 门槛把不写深度的远景树误判成洞）。
用法：widen_holes.py <depth_N.json> [--w0 1920] [--img 加宽出图.png --mark 标红图.png]（--w0：游戏自己出宽图时 json 里的客体宽就是全宽，手给中间参照区宽度）；输出一行：两侧露空面积占两侧带 X%、占全图 Y%、露空行数。"""
import json, sys
import numpy as np
from PIL import Image

a = sys.argv[1:]
meta = json.load(open(a[0]))
w, h, w0, clear = meta['w'], meta['h'], meta['w0'], meta['clear']
if '--w0' in a: w0 = int(a[a.index('--w0') + 1])
d = np.fromfile(a[0][:-5] + '.f32', dtype=np.float32).reshape(h, w)
if clear is None: clear = float(np.median(np.concatenate([d[0], d[-1]])))   # 没录到清屏值：取首末行中位数（一般是远平面）
empty = np.abs(d - clear) <= 1e-6
pad = (w - w0) // 2
if pad <= 0: print('不是加宽图（w == w0）'); sys.exit(2)
side = np.concatenate([empty[:, :pad], empty[:, pad + w0:]], axis=1)
center_drawn = 1 - empty[:, pad:pad + w0].mean(axis=1)          # 每行中间区「有画」的比例
row_hole = np.where(center_drawn >= 0.95, side.mean(axis=1), 0)
hole_px = side & (center_drawn[:, None] >= 0.95)                 # 逐像素：两侧没画、该行中间几乎画满
side_frac = hole_px.mean(); full_frac = hole_px.sum() / (w * h)
rows = int((row_hole > 0.05).sum())
print(f'加宽 {w}×{h}（客体 {w0}，两侧各 {pad} 列）：露空面积占两侧带 {side_frac:.1%}、占全图 {full_frac:.1%}；按行口径平均 {row_hole.mean():.1%}，露空 >5% 的行 {rows}/{h}；'
      f'深度 {meta.get("format")} 清屏值 {clear}，中间区没画 {empty[:, pad:pad + w0].mean():.1%}、两侧没画 {side.mean():.1%}')
if '--img' in a and '--mark' in a:
    im = np.asarray(Image.open(a[a.index('--img') + 1]).convert('RGB')).astype(np.float64)
    m = np.zeros((h, w), bool); m[:, :pad] = hole_px[:, :pad]; m[:, pad + w0:] = hole_px[:, pad:]
    im[m] = im[m] * 0.35 + np.array([255, 0, 0]) * 0.65
    im[:, pad - 1:pad + 1] = (255, 255, 0); im[:, pad + w0 - 1:pad + w0 + 1] = (255, 255, 0)   # 黄线 = 原 16:9 边界
    Image.fromarray(im.astype(np.uint8)).save(a[a.index('--mark') + 1])
