#!/usr/bin/env python3
# 门禁手动：要传参数：两份 galplay --drawbox 回放产物 drawbox.tsv（来自私有游戏录像）
# 逐绘制比屏幕位置：同一录像 k=1 / 放宽各放一遍（galplay --trace F --drawbox T），按记录号对齐每次绘制改动像素的包围盒。
# 放宽后画面中间 16:9 区与 k=1 逐点相同（平移 pad = (宽1 − 宽0)/2），所以 k=1 里整个落在画面内（离左右边 > --margin）的绘制，放宽后包围盒应是 k=1 的平移：
#   左右边各偏 pad、上下边不变（容差 --tol 像素）。偏离的就是没跟着宽屏改的绘制（特效 / 粒子 / 公告板读了没认出的矩阵、屏幕空间偏移按旧宽高比算）。
# 碰到画面边的绘制（场景铺满、远景）放宽后本来就更宽，不比。整帧差分抓不到小目标错位（10-22 暗黑2 火把火苗），这里逐个绘制量。
# 放宽框包含「k=1 框平移 pad」（容差内）的记「延伸」、不判红：放宽后看见的更多（k=1 里被遮罩 / 模板挡住的部分，10-22 暗黑2 人物界面左侧菜单底下的场景）；
# 平移后的 k=1 框不在放宽框里（被挪走 / 缩小）才是错位。
# 位图（drawbox.tsv 旁的 drawmask/<记录>.bin）：一次绘制画很多小东西（火苗 / 粒子合批）时包围盒看不出谁挪了——逐像素比：k=1 改动像素平移 pad 后落在放宽改动像素上（放宽位图膨胀 1 像素）的比例 = 重合率，
#   < --overlap（缺省 0.9）且 k=1 改动 ≥ --minpix 像素的记「位图错位」，并在 ±40 像素里找最佳横 / 纵偏移（10-22 暗黑2 营地火把火苗：包围盒全对上、火苗挪了十几像素）。
# 用法：drawbox_cmp.py <k=1 的 drawbox.tsv> <放宽的 drawbox.tsv> [--tol 2] [--margin 8] [--overlap 0.9] [--minpix 20]；退出码 0 = 没有错位的绘制，1 = 有
import sys, os, argparse, csv
import numpy as np


def load(p):
    rows = {}
    with open(p, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if int(r["改动像素"]) > 0: rows[int(r["记录"])] = r
    return rows


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("k"); ap.add_argument("w"); ap.add_argument("--tol", type=float, default=2); ap.add_argument("--margin", type=int, default=8); ap.add_argument("--overlap", type=float, default=0.9); ap.add_argument("--minpix", type=int, default=20)
    a = ap.parse_args(); K, Wd = load(a.k), load(a.w)
    if not K or not Wd: print("🔴 没有可比的绘制"); return 2
    w0 = int(next(iter(K.values()))["宽"]); w1 = int(next(iter(Wd.values()))["宽"]); pad = (w1 - w0) / 2
    n = bad = 0; out = []
    for rec, k in sorted(K.items()):
        w = Wd.get(rec)
        if w is None: continue
        kx0, kx1, ky0, ky1 = (int(k[c]) for c in ("x0", "x1", "y0", "y1"))
        if kx0 <= a.margin or kx1 >= w0 - a.margin: continue
        n += 1
        d = [int(w["x0"]) - (kx0 + pad), int(w["x1"]) - (kx1 + pad), int(w["y0"]) - ky0, int(w["y1"]) - ky1]
        if max(abs(v) for v in d) > a.tol:
            # 放宽框包含平移后的 k=1 框 = 延伸（左上不右移 / 不下移、右下不左移 / 不上移）
            both = not (d[0] <= a.tol and d[1] >= -a.tol and d[2] <= a.tol and d[3] >= -a.tol)
            bad += both; out.append((both, rec, k["程序"], (kx0, kx1, ky0, ky1), (int(w["x0"]), int(w["x1"]), int(w["y0"]), int(w["y1"])), d))
    print(f"逐绘制屏幕位置：k=1 宽 {w0} / 放宽 {w1}（平移 {pad:g}）；两边都有改动且 k=1 里不碰左右边的绘制 {n} 次，错位（平移后的 k=1 框不在放宽框里，容差 {a.tol:g} 像素）{bad} 次、延伸 {len(out) - bad} 次")
    for both, rec, prog, kb, wb, d in sorted(out, key=lambda o: not o[0])[:40]:
        print(f"  {'【错位】' if both else '延伸'} 记录 {rec} 程序 {prog}：k=1 x[{kb[0]},{kb[1]}) y[{kb[2]},{kb[3]}) → 放宽 x[{wb[0]},{wb[1]}) y[{wb[2]},{wb[3]})，偏离 左 {d[0]:+g} 右 {d[1]:+g} 上 {d[2]:+g} 下 {d[3]:+g}")
    mk, mw = os.path.join(os.path.dirname(a.k), "drawmask"), os.path.join(os.path.dirname(a.w), "drawmask")
    mbad = 0
    if os.path.isdir(mk) and os.path.isdir(mw):
        h = int(next(iter(K.values()))["高"]); p = int(pad); nm = 0; rows = []
        def mask(d, rec, w): return np.unpackbits(np.fromfile(os.path.join(d, f"{rec}.bin"), np.uint8), bitorder="little")[:w * h].reshape(h, w).astype(bool)
        for rec, k in sorted(K.items()):
            if rec not in Wd or not os.path.exists(os.path.join(mk, f"{rec}.bin")) or not os.path.exists(os.path.join(mw, f"{rec}.bin")): continue
            km, wm = mask(mk, rec, w0), mask(mw, rec, w1)
            ks = np.zeros_like(wm); ks[:, p:p + w0] = km
            if ks.sum() < a.minpix: continue
            nm += 1
            wd = wm.copy(); wd[1:] |= wm[:-1]; wd[:-1] |= wm[1:]; wd[:, 1:] |= wd[:, :-1]; wd[:, :-1] |= wd[:, 1:]
            ov = (ks & wd).sum() / ks.sum()
            if ov >= a.overlap: continue
            # 没对上的 k=1 像素：在 ±40 像素里找让它们落到放宽位图上最多的偏移
            miss = ks & ~wd; best = (0, 0, 0)
            ys, xs = np.nonzero(miss)
            for dy in range(-12, 13, 2):
                for dx in range(-40, 41, 2):
                    yy, xx = ys + dy, xs + dx; ok = (yy >= 0) & (yy < h) & (xx >= 0) & (xx < w1)
                    c = int(wd[yy[ok], xx[ok]].sum())
                    if c > best[0]: best = (c, dx, dy)
            mbad += 1; rows.append((rec, k["程序"], ov, int(ks.sum()), int(miss.sum()), best, (xs.min() - p, xs.max() - p, ys.min(), ys.max())))
        print(f"逐绘制位图：比了 {nm} 次（k=1 改动 ≥ {a.minpix} 像素），重合率 < {a.overlap:g} 的 {mbad} 次")
        for rec, prog, ov, nk, nmiss, (c, dx, dy), bb in rows[:40]:
            print(f"  【位图错位】记录 {rec} 程序 {prog}：重合 {ov:.2f}（k=1 {nk} 像素、没对上 {nmiss}，在 k=1 x[{bb[0]},{bb[1]}] y[{bb[2]},{bb[3]}]）；没对上的部分最可能挪了 横 {dx:+d} 纵 {dy:+d} 像素（对上 {c}/{nmiss}）")
    return 1 if bad or mbad else 0


if __name__ == "__main__":
    sys.exit(main())
