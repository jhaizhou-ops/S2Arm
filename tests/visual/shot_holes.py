#!/usr/bin/env python3
"""宽屏露空（截图版，10-20 总指挥定：不录像、不跨线）：在游戏场景截图（自动玩家 ap_mark.png / ap_end.png）上直接量两侧扩展带里没被绘制覆盖的区域。
没画到的地方是清屏色或纯色：按 8×8 块看，块内 RGB 各通道极差 ≤ FLAT（2 级）算「平块」；平块还要与同色（块均值各通道差 ≤ 1 级）相邻平块连成 ≥ MINC（16）块的整片才算没画
——清屏色连成一大片且颜色完全一样；暗部阴影 / 暗角的平块零散、块间均值有细微差（10-20 暗黑3 正常画面两侧边缘零散平块 14%，不连片）。
口径同 widen_holes.py「超出中间区的部分」：逐块行算 两侧平块比例 − 中间 16:9 区平块比例，只计正的超出量（暗部纯黑、天空纯色在中间同样有，相互抵消；两侧突然空了才算）。
不适用：清屏色与游戏自己画的颜色相同的暗场景（10-20 暗黑3 清屏 (0,0,0,1)，暗角 / 剪影同为近纯黑：正常画面读 4.85%，16:9 基线边带 2.1%，原理上分不开）——这类改用深度（galplay --depth + widen_holes.py）。
对照（10-20）：暗黑3 两侧 400 行涂清屏色 58.5%；正常画面 4.85% / 3.96%。
用法：shot_holes.py <截图.png> [--w0 中间区宽，缺省 高×16/9 取偶] [--mark 标红图.png]
输出一行：两侧露空占两侧带 X%（逐行超出量按两侧带块数加权）、两侧 / 中间平块比例；退出码 0 = ≤ 0.5%、1 = 超、2 = 不是加宽图。"""
import sys
import numpy as np
from PIL import Image

B, FLAT, MINC, LIMIT = 8, 2, 16, 0.5


def main():
    a = sys.argv[1:]
    if not a: print(__doc__); return 2
    im = np.asarray(Image.open(a[0]).convert('RGB')).astype(np.int16)
    h, w, _ = im.shape
    w0 = int(a[a.index('--w0') + 1]) if '--w0' in a else (round(h * 16 / 9) + 1) & ~1
    pad = (w - w0) // 2
    if pad < B: print(f'不是加宽图（宽 {w}，中间区 {w0}）'); return 2
    by, bx = h // B, w // B
    blk = im[:by * B, :bx * B].reshape(by, B, bx, B, 3)
    flat = (blk.max(axis=(1, 3)) - blk.min(axis=(1, 3))).max(axis=-1) <= FLAT   # (by, bx)
    mean = blk.mean(axis=(1, 3))   # (by, bx, 3)
    seen = np.zeros_like(flat); keep = np.zeros_like(flat)
    for y0, x0 in zip(*np.nonzero(flat)):   # 同色相邻平块连片（4 邻接），片 < MINC 块的丢掉
        if seen[y0, x0]: continue
        comp, st = [], [(y0, x0)]; seen[y0, x0] = True
        while st:
            y, x = st.pop(); comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < by and 0 <= nx < bx and flat[ny, nx] and not seen[ny, nx] and np.abs(mean[ny, nx] - mean[y, x]).max() <= 1:
                    seen[ny, nx] = True; st.append((ny, nx))
        if len(comp) >= MINC:
            for y, x in comp: keep[y, x] = True
    flat = keep
    side = np.zeros(bx, bool); side[:pad // B] = True; side[(pad + w0 + B - 1) // B:] = True
    center = np.zeros(bx, bool); center[(pad + B - 1) // B:(pad + w0) // B] = True
    sf, cf = flat[:, side].mean(axis=1), flat[:, center].mean(axis=1)   # 每块行两侧 / 中间平块比例
    excess = np.clip(sf - cf, 0, None); pct = 100.0 * excess.mean()
    rows = excess > 0
    print(f'两侧露空占两侧带 {pct:.2f}%（两侧平块 {100 * sf.mean():.1f}%、中间平块 {100 * cf.mean():.1f}%，有超出的块行 {int(rows.sum())}/{by}，中间区宽 {w0}，块 {B}×{B}，平块极差 ≤{FLAT}、连片 ≥{MINC} 块）')
    if '--mark' in a:
        o = im.astype(np.uint8).copy()
        for y in range(by):
            if not rows[y]: continue   # 只标有超出量的行里两侧的平块
            for x in np.where(flat[y] & side)[0]: o[y * B:(y + 1) * B, x * B:(x + 1) * B] = (255, 0, 0)
        Image.fromarray(o).save(a[a.index('--mark') + 1])
    return 0 if pct <= LIMIT else 1


if __name__ == '__main__':
    sys.exit(main())
