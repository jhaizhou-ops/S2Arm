#!/usr/bin/env python3
"""宽屏「两侧缺渲染」判据（10-30 #996 + 画面线：Hor+ 第三层放开后，引擎按 16:9 在 CPU 侧剔除，16:9 以外两条什么都不画）：
纯像素规则，不用 AI。截图宽高比明显宽于 16:9（两侧扩出 ≥ 宽 4%）时，看中间 16:9 区域的左右边界：
边界外侧几列「近乎纯黑且没有细节」（亮度 < 12、边缘强度 < 6）的占比，减去边界内侧几列的占比 = 断崖。
真缺渲染时黑区恰好从 16:9 边界起（Bare Knuckle IV 右 +0.84、CATASTRONAUTS! 右 +0.94）；
关卡本身的暗处 / 边界不对齐 16:9 边界（Kirby、Octopath、Chippy&Noppo、Moving Out 等 11 款 ≤ +0.06）。断崖 ≥ CLIFF_BAD（0.5）判坏。
  widen_cliff.py <截图.png>…   → 每张一行：断崖（左右较大值，没加宽 = -）<TAB>路径
单测：tests/widen_cliff_test.py"""
import sys
from PIL import Image, ImageFilter

CLIFF_BAD = 0.5


def cliff(path):
    """→ 左右断崖较大值；截图没有明显加宽（两侧扩出 < 宽 4%）或读不出 = None"""
    try: im = Image.open(path).convert('L')
    except Exception: return None
    W, H = im.size; side = (W - round(H * 16 / 9)) // 2
    if side < W * 0.04: return None
    a = im.load(); b = im.filter(ImageFilter.FIND_EDGES).load(); w = max(4, W // 200)
    def flat(x0, x1):
        n = f = 0
        for x in range(max(0, x0), min(W, x1)):
            for y in range(0, H, 2): n += 1; f += a[x, y] < 12 and b[x, y] < 6
        return f / max(n, 1)
    return max(flat(side - w, side) - flat(side + 1, side + 1 + w), flat(W - side, W - side + w) - flat(W - side - 1 - w, W - side - 1))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        c = cliff(p); print(f'{"-" if c is None else f"{c:.2f}"}\t{p}')
