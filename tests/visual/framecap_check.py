#!/usr/bin/env python3
# 门禁手动：要传参数：真机出图层写的 framecap.bin
# 真机逐帧存图判读（出图层 NXGAL_FRAME_CAP 写的 framecap.bin，见 graphics/metal/gal_present.m）：静止场景里逐帧量
#   ① 亮度跳变：整幅平均亮度相对前后两帧均值偏 > 阈值（缺省 1.5%）且又跳回 = 闪一帧；
#   ② 贴图位移：画面切成 64×64 网格块，每块对「全窗口逐像素时间中位图」做相位相关求亚像素位移，|位移| ≥ 阈值（缺省 0.5 像素）记一块错位。
#      会动的东西（人物 / 火 / 粒子）所在块帧帧都偏、和中位图对不上：整窗一半以上帧都偏的块算「动块」，不计；
#      同一帧 ≥ --minblocks（缺省 3）块同时偏才判错位（渲染时序 / 常量错位是成片的；单块多是待机动画的人物、走进画面的怪，10-22 暗黑2 Mac 静置局 19 帧各 1 块全是人物），零星的只列位置。
#   --motion（镜头在动，如人物走动、镜头跟随）：② 改成逐对相邻帧求每块位移，取全部块的中位数当本帧主运动，偏离主运动 ≥ --shift（此模式缺省 1.5 像素）的块记错位；
#      一半以上帧对都偏离的块（人物、走动的怪）算动块不计；镜头动时屏幕上静止的块（界面栏、被跟随的玩家）不计；同帧 ≥ --minblocks 块才判成片错位（贴图跟场景对不上 = 错位，整体平移不算）。
# 用法：framecap_check.py <framecap.bin> [--luma 0.015] [--shift 0.5] [--motion] [--png <目录>]（--png：位移 / 闪的帧各存一张标了块的图）
# 退出码：0 = 亮度跳变 0 帧且成片错位 0 帧；1 = 有；2 = 读不了
import sys, argparse
import numpy as np


def load(p):
    b = open(p, "rb").read(); o = 0; fr = []
    while o + 12 <= len(b):
        n, w, h = (int(x) for x in np.frombuffer(b[o:o + 12], np.uint32)); o += 12
        if o + w * h > len(b): break
        fr.append((n, np.frombuffer(b[o:o + w * h], np.uint8).reshape(h, w).astype(np.float32))); o += w * h
    return fr


def shift(a, b):
    """b 相对 a 的位移（像素，亚像素：峰值处抛物线插值）；纹理太弱返回 None"""
    if a.std() < 4 or b.std() < 4: return None
    win = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))
    A = np.fft.fft2((a - a.mean()) * win); B = np.fft.fft2((b - b.mean()) * win)
    R = A.conj() * B; R /= np.abs(R) + 1e-9
    c = np.fft.ifft2(R).real; h, w = c.shape
    y, x = np.unravel_index(np.argmax(c), c.shape)
    def sub(m, p, q): d = m - 2 * p + q; return 0.0 if abs(d) < 1e-12 else 0.5 * (m - q) / d
    dy = y + sub(c[(y - 1) % h, x], c[y, x], c[(y + 1) % h, x]); dx = x + sub(c[y, (x - 1) % w], c[y, x], c[y, (x + 1) % w])
    if dy > h / 2: dy -= h
    if dx > w / 2: dx -= w
    return dx, dy


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("bin"); ap.add_argument("--luma", type=float, default=0.015); ap.add_argument("--shift", type=float, default=None); ap.add_argument("--motion", action="store_true"); ap.add_argument("--png"); ap.add_argument("--minblocks", type=int, default=3)
    a = ap.parse_args()
    if a.shift is None: a.shift = 1.5 if a.motion else 0.5
    fr = load(a.bin)
    if len(fr) < 3: print(f"🔴 {a.bin}：只有 {len(fr)} 帧"); return 2
    ns = [n for n, _ in fr]; gaps = [ns[i] for i in range(1, len(ns)) if ns[i] != ns[i - 1] + 1]
    F = np.stack([g for _, g in fr]); T, H, W = F.shape
    L = F.reshape(T, -1).mean(1)
    flick = [ns[t] for t in range(1, T - 1) if abs(L[t] - (L[t - 1] + L[t + 1]) / 2) > a.luma * (L[t - 1] + L[t + 1]) / 2 and abs(L[t + 1] - L[t - 1]) < a.luma * L[t - 1]]
    S = 64
    blocks = [(y, x) for y in range(0, H - S + 1, S) for x in range(0, W - S + 1, S)]
    off = np.full((T, len(blocks)), np.nan)
    if a.motion:   # 第 t 行 = 第 t−1 → t 帧对（第 0 行留空）
        for t in range(1, T):
            v = np.full((len(blocks), 2), np.nan)
            for j, (y, x) in enumerate(blocks):
                s = shift(F[t - 1, y:y + S, x:x + S], F[t, y:y + S, x:x + S])
                if s is not None: v[j] = s
            ok = ~np.isnan(v[:, 0])
            if ok.sum() < 8: continue
            m = np.median(v[ok], 0); off[t, ok] = np.hypot(v[ok, 0] - m[0], v[ok, 1] - m[1])
            # 屏幕上不动的块（界面栏、血球、被镜头跟随的玩家：自身位移 < 0.5 像素）在镜头动（主运动 ≥ 1 像素）时本来就偏离主运动，不算错位（10-22 暗黑2 走动段 36 帧各约 31 块全是这类）
            if np.hypot(*m) >= 1: off[t, ok & (np.hypot(v[:, 0], v[:, 1]) < 0.5)] = 0
    else:
        med = np.median(F, 0)
        for j, (y, x) in enumerate(blocks):
            r = med[y:y + S, x:x + S]
            for t in range(T):
                s = shift(r, F[t, y:y + S, x:x + S])
                if s is not None: off[t, j] = np.hypot(*s)
    bad = off >= a.shift
    moving = np.nanmean(np.where(np.isnan(off), 0, bad), 0) > 0.5
    used = ~moving & ~np.all(np.isnan(off), 0)
    hit = bad & used[None, :]
    per = hit.sum(1)
    wide = per >= a.minblocks
    print(f"{a.bin}：{T} 帧（第 {ns[0]}..{ns[-1]} 次出图，缺 {len(gaps)} 处{('：' + str(gaps[:8])) if gaps else ''}），{W}×{H}")
    print(f"  亮度：中位 {np.median(L):.2f}，最小 {L.min():.2f}，最大 {L.max():.2f}；跳变又跳回（>{a.luma * 100:.1f}%）{len(flick)} 帧 {flick[:20]}")
    print(f"  位移{'（相邻帧，偏离主运动）' if a.motion else ''}：网格 {len(blocks)} 块（动块 {int(moving.sum())}、无纹理 {int(np.all(np.isnan(off), 0).sum())}、计入 {int(used.sum())}）；|位移| ≥ {a.shift} 像素 {int(hit.sum())} 块次，出现在 {int((per > 0).sum())} 帧")
    worst = sorted(((int(per[t]), ns[t], float(np.nanmax(np.where(hit[t], off[t], np.nan))) if per[t] else 0.0) for t in range(T)), reverse=True)[:8]
    print(f"  成片错位（同帧 ≥ {a.minblocks} 块）{int(wide.sum())} 帧 {[ns[t] for t in range(T) if wide[t]][:20]}")
    if hit.any(): print("  错位最多的帧（块数, 出图序号, 最大位移像素）:", [(k, n, round(m, 2)) for k, n, m in worst if k])
    lone = sorted({blocks[j] for t in range(T) if not wide[t] for j in np.nonzero(hit[t])[0]})
    if lone: print(f"  零星块（不判红，左上角 x,y）：{[(x, y) for y, x in lone][:12]}")
    if a.png and (flick or hit.any()):
        from PIL import Image, ImageDraw
        import os; os.makedirs(a.png, exist_ok=True)
        for t in range(T):
            if ns[t] not in flick and not per[t]: continue
            im = Image.fromarray(F[t].astype(np.uint8)).convert("RGB"); dr = ImageDraw.Draw(im)
            for j in np.nonzero(hit[t])[0]: y, x = blocks[j]; dr.rectangle([x, y, x + S - 1, y + S - 1], outline=(255, 0, 0), width=2)
            im.save(f"{a.png}/f{ns[t]}.png")
    return 0 if not flick and not wide.any() else 1


if __name__ == "__main__":
    sys.exit(main())
