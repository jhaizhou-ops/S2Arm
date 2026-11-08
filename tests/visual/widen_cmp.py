#!/usr/bin/env python3
"""宽屏出图判据：原图（16:9）对加宽图（Hor+）。期望值只由几何推出、不跑被测实现：
   Hor+ 下原图像素 x 落在加宽图 x + (W1 − W0)/2（半像素时取两侧平均），所以加宽图中间 W0 列 ≈ 原图；两侧新增带应有画面（非黑、有纹理）。
用法：widen_cmp.py <原图.png> <加宽图.png> [--psnr-min 30] [--cell-min 20] [--side-min 0.9]
   分格最差也进过线（11-01 审计 P2-74：一格差到约 13 dB 整幅仍能过 30 dB）：门槛 20 dB，历史 8 组通过记录的分格最差最低 26.20 dB。
输出：中间区 PSNR、8×6 分格最差 PSNR、两侧带非黑占比与标准差；退出码 0 = 过，1 = 不过。"""
import sys
import numpy as np
from PIL import Image

def psnr(a, b):
    m = np.mean((a - b) ** 2)
    return 99.0 if m == 0 else 10 * np.log10(255.0 ** 2 / m)

a = sys.argv[1:]
base = np.asarray(Image.open(a[0]).convert('RGB'), dtype=np.float64)
wide = np.asarray(Image.open(a[1]).convert('RGB'), dtype=np.float64)
pmin = float(a[a.index('--psnr-min') + 1]) if '--psnr-min' in a else 30.0
smin = float(a[a.index('--side-min') + 1]) if '--side-min' in a else 0.9
cmin = float(a[a.index('--cell-min') + 1]) if '--cell-min' in a else 20.0
h, w0, _ = base.shape; w1 = wide.shape[1]
assert wide.shape[0] == h, '高度不同'
off = (w1 - w0) / 2
lo = int(np.floor(off)); hi = int(np.ceil(off))
center = (wide[:, lo:lo + w0] + wide[:, hi:hi + w0]) / 2   # 半像素偏移：两列平均
p = psnr(center, base)
cells = [psnr(center[y * h // 6:(y + 1) * h // 6, x * w0 // 8:(x + 1) * w0 // 8], base[y * h // 6:(y + 1) * h // 6, x * w0 // 8:(x + 1) * w0 // 8]) for y in range(6) for x in range(8)]
left, right = wide[:, :lo], wide[:, hi + w0:]
nb = lambda s: float(np.mean(s.max(axis=2) > 8)) if s.size else 0.0
ok = p >= pmin and min(cells) >= cmin and nb(left) >= smin and nb(right) >= smin
print(f'原 {w0}×{h} → 加宽 {w1}×{h}（偏移 {off}）：中间区 PSNR {p:.2f} dB（门槛 {pmin}），8×6 分格最差 {min(cells):.2f} dB（门槛 {cmin}）；'
      f'左带 {lo} 列非黑 {nb(left):.3f}、标准差 {left.std():.1f}；右带 {w1 - hi - w0} 列非黑 {nb(right):.3f}、标准差 {right.std():.1f}（门槛非黑 ≥{smin}）→ {"过" if ok else "【红】"}')
sys.exit(0 if ok else 1)
