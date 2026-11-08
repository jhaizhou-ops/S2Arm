#!/usr/bin/env python3
"""宽屏中间区逐像素一致（宽屏门禁 tests/visual/widen_gate.sh 用）。
期望只由几何推出、不跑被测实现：放宽 k 倍、视口同乘 k、投影 x 行乘 1/k ⇒ 出图区宽 W1，原图出图区宽 W0，
加宽图出图区中间 [(W1−W0)/2, (W1−W0)/2 + W0) 与原图出图区逐像素相同（k 吸附后偏移是整数：1080 高 213 列、720 高 142 列）。
输入是 galplay 存的 present_<帧>.png 与旁注 present_<帧>.json（raw = 录像原始裁剪，out = 实际交给出图层的裁剪）；只比出图区（屏幕上看得到的部分）。
用法：widen_mid.py <原图目录> <加宽图目录> <帧>
      widen_mid.py --scale <原图目录> <加宽图目录> <帧>   横向比例拟合（「游戏出宽缓冲、投影仍 16:9」的录像用：不放宽回放本身被横向拉伸，中间区逐像素不成立）：
        把原图出图区以加宽图出图区中心为轴横向缩放 s（0.70–1.30，步长 0.005），比两边重叠列的平均通道差，取最小的 s；
        期望由几何推出：靠包装层改写 16:9 投影成 Hor+ 的款 s = 1/k（0.818），游戏自己出宽投影的款 s = 1。输出机读行 SCALE<TAB>s<TAB>最小平均差<TAB>s=1 的平均差。
输出：一行读数（出图区尺寸、偏移、差异像素数（任一通道不同）、通道差总和、最大通道差、差异外接框）+ 一行机读 MID（末列 1 = 宽差为奇数、半像素偏移）；退出码 0 = 算出读数，2 = 输入缺 / 尺寸对不上（判据由调用方按容差定）。"""
import json, sys
import numpy as np
from PIL import Image


def load(d, f):
    m = json.load(open(f'{d}/present_{f}.json'))
    img = np.asarray(Image.open(f'{d}/present_{f}.png').convert('RGB'), dtype=np.int16)
    tw, th, x0, x1, y0, y1 = m['out']
    if img.shape[1] != tw or img.shape[0] != th:
        raise ValueError(f'{d} 帧 {f}：图 {img.shape[1]}×{img.shape[0]} 与旁注贴图 {tw}×{th} 不符')
    return img[y0:y1, x0:x1], m


def scale(a):
    try:
        b, _ = load(a[0], a[2]); w, _ = load(a[1], a[2])
    except (OSError, ValueError, KeyError) as e:
        print(f'输入错：{e}'); return 2
    h, w0 = b.shape[:2]; w1 = w.shape[1]
    if w.shape[0] != h: print(f'出图区高不同：原 {w0}×{h}，加宽 {w1}×{w.shape[0]}'); return 2
    B = Image.fromarray(b.astype(np.uint8)); W = w.astype(np.float32); cx = w1 / 2
    def err(s):
        nw = int(round(w0 * s)); x0 = int(round(cx - nw / 2))
        A = np.asarray(B.resize((nw, h), Image.BILINEAR), dtype=np.float32)
        lo, hi = max(0, x0), min(w1, x0 + nw)
        if hi - lo < w1 // 4: return 1e9
        return float(np.abs(A[:, lo - x0:hi - x0] - W[:, lo:hi]).mean())
    best = min((err(s), s) for s in np.arange(0.70, 1.3001, 0.005))
    e1 = err(1.0)
    print(f'原 {w0}×{h} → 加宽 {w1}×{h}：最佳横向比例 {best[1]:.3f}（平均通道差 {best[0]:.2f}；不缩 {e1:.2f}）')
    print(f'SCALE\t{best[1]:.3f}\t{best[0]:.3f}\t{e1:.3f}')
    return 0


def main(a):
    if a and a[0] == '--scale': return scale(a[1:])
    if len(a) < 3:
        print(__doc__); return 2
    try:
        b, _ = load(a[0], a[2])
        w, _ = load(a[1], a[2])
    except (OSError, ValueError, KeyError) as e:
        print(f'输入错：{e}'); return 2
    h0, w0 = b.shape[:2]; h1, w1 = w.shape[:2]
    if h0 != h1:
        print(f'出图区高不同：原 {w0}×{h0}，加宽 {w1}×{h1}'); return 2
    off = (w1 - w0) // 2; odd = (w1 - w0) % 2
    # 宽差为奇数：中间区落在半像素上，取左右两列平均再比（同 widen_cmp.py），并在机读行标出 —— 门禁对没登记的奇数偏移判红
    c = (w[:, off:off + w0] + w[:, off + 1:off + 1 + w0] + 1) // 2 if odd else w[:, off:off + w0]
    d = np.abs(c - b).max(axis=2)
    n = int((d > 0).sum()); mx = int(d.max()) if d.size else 0; sad = int(np.abs(c - b).sum())
    box = ''
    if n:
        ys, xs = np.nonzero(d)
        box = f'，差异外接框 x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}]，>8 的 {int((d > 8).sum())} 个'
    print(f'原 {w0}×{h0} → 加宽 {w1}×{h1}（偏移 {off}{".5，宽差为奇数，取两列平均" if odd else ""}）：中间区差异像素 {n}（{n * 100.0 / max(1, w0 * h0):.4f}%），通道差总和 {sad}，最大通道差 {mx}{box}')
    print(f'MID\t{w0}\t{w1}\t{h0}\t{off}\t{n}\t{sad}\t{mx}\t{odd}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
