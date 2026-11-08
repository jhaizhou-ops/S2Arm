#!/bin/bash
# 门禁只看：tests/visual/widen_cmp.py
# 宽屏出图判据单测（约 2 秒）：bash tests/widen_cmp_test.sh
# 期望由构造推出、不跑被测实现：原图 = 平滑渐变 + 轻噪声；加宽图中间区 = 原图，两侧带有纹理。
#   ① 中间区与原图逐像素相同 → 过；② 只给 8×6 里的一格加标准差 38 的噪声（整幅约 33 dB 仍 ≥30、该格约 16 dB）→ 不过（11-01 审计 P2-74：分格最差原先只打印不判）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PYV=$HOME/.s2arm/venv/bin/python; [ -x "$PYV" ] || PYV=python3
"$PYV" - "$T" <<'PY'
import sys, numpy as np
from PIL import Image
T = sys.argv[1]; rng = np.random.default_rng(1); h, w0, w1 = 360, 640, 800
y, x = np.mgrid[0:h, 0:w0]
base = np.stack([x * 255 / w0, y * 255 / h, (x + y) * 127 / (w0 + h)], -1) + rng.normal(0, 2, (h, w0, 3))
base = np.clip(base, 0, 255).astype(np.uint8)
side = (rng.integers(40, 200, (h, (w1 - w0) // 2, 3))).astype(np.uint8)
wide = np.concatenate([side, base, side], 1)
Image.fromarray(base).save(f'{T}/base.png'); Image.fromarray(wide).save(f'{T}/ok.png')
bad = wide.copy(); cy, cx = h // 6, w0 // 8; off = (w1 - w0) // 2
c = bad[2 * cy:3 * cy, off + 3 * cx:off + 4 * cx].astype(np.float64)   # 一格加噪（标准差 38 → 该格均方误差约 1400、约 16.6 dB；整幅 = 1400 / 48 ≈ 30 → 约 33 dB）
bad[2 * cy:3 * cy, off + 3 * cx:off + 4 * cx] = np.clip(c + rng.normal(0, 38, c.shape), 0, 255).astype(np.uint8)
Image.fromarray(bad).save(f'{T}/cell.png')
PY
o=$("$PYV" "$H/tests/visual/widen_cmp.py" "$T/base.png" "$T/ok.png"); r=$?
ck "① 中间区逐像素相同 → 过（rc=${r}）" '[ $r = 0 ]'
o=$("$PYV" "$H/tests/visual/widen_cmp.py" "$T/base.png" "$T/cell.png"); r=$?
p=$(grep -o '中间区 PSNR [0-9.]*' <<< "$o" | grep -o '[0-9.]*$'); c=$(grep -o '分格最差 [0-9.]*' <<< "$o" | grep -o '[0-9.]*$')
ck "② 一格加噪：整幅 ${p} dB 仍 ≥30、分格最差 ${c} dB → 不过（rc=${r}）" '[ $r = 1 ] && awk -v p="$p" -v c="$c" "BEGIN{exit !(p >= 30 && c < 20)}"'
[ $bad = 0 ] && echo "宽屏出图判据单测全过" || { echo "宽屏出图判据单测有不通"; exit 1; }
