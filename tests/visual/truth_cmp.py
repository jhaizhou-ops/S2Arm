#!/usr/bin/env python3
"""检查点对比（M1–M4 验收尺子）：我方截图 vs Ryujinx 真值，逐区域结构相似度（SSIM）。
自旧库 S2A 497552d tools/truth_cmp.py 迁入；改动：真值根目录可配（S2A_TRUTH，缺省 ~/.s2arm/run/s2arm/visual/truth/<游戏>/<检查点>，真值是游戏截图、不进仓库），
加 --center16x9：我方图比 16:9 宽时先取中间 16:9 区再比——只用于回放（16:9 录像只经界面层加宽，中间区应与基线一致，tests/visual/gate.sh）；
  游戏局的宽屏截图比宽屏真值（检查点 <检查点>_w<屏幕宽>，Ryujinx 打同一组宽屏补丁出的宽图），整帧同一判据（10-20 起，过渡判据已撤）。

用法：
  truth_cmp.py <游戏> <检查点> <我方截图.png> [--json 输出.json] [--heat 热图.png]
  truth_cmp.py --self <游戏> <检查点>           # 只看真值两局自比（定剔除区，不需要我方图）
真值目录 <S2A_TRUTH>/<游戏>/<检查点>/：ryu_*.png（≥2 张，Ryujinx 同存档同路线不同局，compat/truth/run_truth.sh 出）+ point.env（说明）。

口径（期望值只来自 Ryujinx 截图，不取我方输出）：
  * 两边先转亮度（BT.601）并缩到 960×540；SSIM 用 11 点高斯窗（σ=1.5）、C1=(0.01·255)²、C2=(0.03·255)²（Wang 2004 原式）。
  * 画面切成 8×6 = 48 格。某格在真值各局两两自比的 SSIM 最小值 < SELF_MIN（= 判据 0.95）⇒ 该格同构建两局就不稳（天空、粒子、光束），剔除不判。
  * 留下的每格：我方 vs 各张真值取最高分（任何一局 Ryujinx 都是合法真值）；每格 ≥ 0.95 才算过。
  * 亮度 / 色偏另判（SSIM 对整体明暗不敏感：整图压暗 15% 仍有 0.95）：每格 R/G/B 三通道均值，我方与最近一张真值的最大通道差
    ≤ max(LUM_ABS 2.0 级, 2 × 真值各局该格的最大自差)。
  * 锐度另判：逐格梯度能量与最近真值的相对差 ≤ max(5%, 2 × 真值自差)（SSIM 对轻微模糊不敏感）。
  * 留下的格占全图 < 50% ⇒ 尺子本身不够用，报红（检查点要换或真值要重出），不出「过」。
  * 窗内最优帧（10-19 总指挥裁定，画面线）：真值目录另有 win_*.png（真值侧在检查点前后连续截的一段帧，覆盖动画一个周期以上）时，
    剔除区与亮度 / 锐度容差仍只按 ryu_*.png（同一时刻、不同局）定；win_*.png 只当比对候选——逐张整帧判，取不达标格最少的一张
    （并列取 SSIM 均值高的）。动画相位只差一个时间偏移，窗内总有一帧对得上；渲染真有错时整段都对不上，照样判红。
"""
import argparse, glob, json, os, re, sys
import numpy as np
from PIL import Image

W, H, GX, GY = 960, 540, 8, 6
PASS, MIN_KEPT, LUM_ABS = 0.95, 0.5, 2.0
GE_REL, GE_MIN = 0.05, 1.0
SELF_MIN = PASS   # 剔除口径 = 判据本身：Ryujinx 同存档同检查点两局自己都到不了 0.95 的格，不能要求我方到；到得了的格我方必须到
TRUTH = os.environ.get('S2A_TRUTH', os.path.expanduser('~/.s2arm/run/s2arm/visual/truth'))
CENTER = False   # --center16x9


def rgb(path, ours=False):
    im = Image.open(path).convert('RGB')
    if ours and CENTER and im.width * 9 > im.height * 16 + 9:   # 加宽图取中间 16:9（偏移取整，与宽屏层「多出偶数列、整数居中偏移」一致）
        w = round(im.height * 16 / 9); x0 = (im.width - w) // 2; im = im.crop((x0, 0, x0 + w, im.height))
    if im.size != (W, H): im = im.resize((W, H), Image.LANCZOS)   # 与真值图同一种缩法（truth_pick.py 用 LANCZOS）：缩法不同，同一张图梯度能量差 30%（10-18 动森「偏软」即此）
    return np.asarray(im, dtype=np.float64)


def luma(a): return a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114


def chan_means(a):   # 每格三通道均值 → (GY, GX, 3)
    cw, ch = W // GX, H // GY
    return a[:GY * ch, :GX * cw].reshape(GY, ch, GX, cw, 3).mean(axis=(1, 3))


def _blur(x):
    k = np.exp(-0.5 * (np.arange(-5, 6) / 1.5) ** 2); k /= k.sum()
    p = np.pad(x, 5, mode='reflect')
    y = np.zeros((p.shape[0], x.shape[1]))
    for i in range(11): y += k[i] * p[:, i:i + x.shape[1]]
    z = np.zeros(x.shape)
    for i in range(11): z += k[i] * y[i:i + x.shape[0], :]
    return z


def ssim_map(a, b):
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    ma, mb = _blur(a), _blur(b)
    va, vb, cv = _blur(a * a) - ma * ma, _blur(b * b) - mb * mb, _blur(a * b) - ma * mb
    return ((2 * ma * mb + c1) * (2 * cv + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))


def cells(m):
    cw, ch = W // GX, H // GY
    return np.array([[m[y * ch:(y + 1) * ch, x * cw:(x + 1) * cw].mean() for x in range(GX)] for y in range(GY)])


def load_truth(game, point):
    d = os.path.join(TRUTH, game, point)
    fs = sorted(glob.glob(os.path.join(d, 'ryu_*.png')))
    if len(fs) < 2: sys.exit(f'🔴 真值不足：{d} 下 ryu_*.png 只有 {len(fs)} 张（至少 2 局，才能定剔除区）')
    wide_truth(fs[0])
    rs = [rgb(f) for f in fs]
    return d, fs, [luma(r) for r in rs], [chan_means(r) for r in rs]


def ref_errors(game, point):   # games/truth_ref_errors.tsv：参照（Mac 版 Ryujinx）已知错误格，经 Windows 原生版仲裁确认，比图时剔除
    m = np.zeros((GY, GX), bool); p = os.path.join(TRUTH, 'truth_ref_errors.tsv')
    # point.env 的 MASK=行,列;…：测试设定造成的差异格（例：我方时钟冻结、真值时钟在走 ⇒ 时钟角标），point.env 里必须写明原因
    for c in filter(None, point_env(os.path.join(TRUTH, game, point)).get('MASK', '').split(';')):
        r, k = map(int, c.split(',')); m[r, k] = True
    for ln in open(p) if os.path.exists(p) else []:
        if ln.startswith('#') or not ln.strip(): continue
        f = ln.rstrip('\n').split('\t')
        if f[0] == game and f[1] == point:
            for c in f[2].split(';'): r, k = map(int, c.split(',')); m[r, k] = True
    return m


def self_grid(ts):
    g = np.full((GY, GX), 1.0)
    for i in range(len(ts)):
        for j in range(i + 1, len(ts)): g = np.minimum(g, cells(ssim_map(ts[i], ts[j])))
    return g


def seq_lum(d):   # 序列目录里 t<秒>.png（或 s<序号>.png） → {秒: 平均亮度}
    fs = {int(re.findall(r'[ts](\d+)\.png$', f)[0]): f for f in glob.glob(os.path.join(d, 't*.png')) + glob.glob(os.path.join(d, 's*.png')) if re.search(r'/[ts]\d+\.png$', f)}
    return fs, {t: float(np.asarray(Image.open(f).convert('L').resize((240, 135)), dtype=np.float64).mean()) for t, f in fs.items()}


def arrival(lum, after=0, dark=20, bright=50, bright_max=255):
    """到达 = after 秒之后最后一次「暗帧（< dark）之后第一张亮帧（bright ≤ 亮度 ≤ bright_max）」；真值侧（truth_pick.py）与我方序列共用这一条规则。
    bright_max 排除读盘提示页一类更亮的过渡画面（塞尔达读盘提示页 ≈98、神庙内 ≈45–55）"""
    arr, seen_dark = None, False   # 淡入可能跨好几帧（1 秒一张时 0 → 24 → 42）：暗帧之后第一张落进亮度区间的就算，取最后一次
    for t in sorted(lum):
        if t <= after: continue
        if lum[t] < dark: seen_dark = True
        elif seen_dark and bright <= lum[t] <= bright_max: arr, seen_dark = t, False
    return arr


def pick_after(fs, arr, off):   # 到达后 off 秒那张（没有恰好那秒取之后最近一张）
    c = [t for t in sorted(fs) if t >= arr + off]
    return c[0] if c else None


def point_env(d):
    kv = {}
    for ln in open(os.path.join(d, 'point.env')) if os.path.exists(os.path.join(d, 'point.env')) else []:
        ln = ln.split('#')[0].strip()
        if '=' in ln: k, v = ln.split('=', 1); kv[k.strip()] = v.strip()
    return kv


# 统计型（point.env 写 MODE=stats）：画面每帧都在动的检查点（塞尔达户外草随风摆、云在走），逐格 SSIM 原理上不成立（Ryujinx 自比 2%）；
# 改比每格的统计量——同一检查点下它们稳定：RGB 三通道均值（亮度 / 色偏）、亮度标准差（对比度）、亮度梯度能量（草 / 岩壁纹理在不在、细不细）。
# 允许范围 = 真值各张该量的 [最小, 最大] 两头各外扩 max(下限, 半个范围宽)；下限：通道均值 2 级、标准差 1 级、梯度能量 5%。
# 可判格：真值范围本身不宽（通道均值范围 ≤ 24 级、梯度能量范围 ≤ 均值的 40%），否则剔除（天气、云、Ryujinx 自身天空瑕疵）。
STAT_NAMES = ('R 均值', 'G 均值', 'B 均值', '亮度标准差', '梯度能量')


def stat_feats(a):
    cw, ch = W // GX, H // GY; L = luma(a)
    gx = np.zeros_like(L); gy = np.zeros_like(L); gx[:, 1:-1] = L[:, 2:] - L[:, :-2]; gy[1:-1, :] = L[2:, :] - L[:-2, :]
    g = np.hypot(gx, gy) / 2
    blk = lambda m: m[:GY * ch, :GX * cw].reshape(GY, ch, GX, cw)
    mean = chan_means(a); sd = blk(L).std(axis=(1, 3)); ge = blk(g).mean(axis=(1, 3))
    return np.concatenate([mean, sd[..., None], ge[..., None]], axis=2)   # (GY, GX, 5)


def main_stats(a, d, fs):
    tf = np.array([stat_feats(rgb(f)) for f in fs]); lo, hi = tf.min(axis=0), tf.max(axis=0); span = hi - lo
    floor = np.empty_like(span); floor[..., :3] = 2.0; floor[..., 3] = 1.0; floor[..., 4] = 0.05 * tf[..., 4].mean(axis=0)
    m = np.maximum(floor, span / 2); alo, ahi = lo - m, hi + m
    keep = (span[..., :3].max(axis=2) <= 24) & (span[..., 4] <= 0.4 * tf[..., 4].mean(axis=0)) & ~ref_errors(a.game, a.point); kept = keep.mean()
    print(f'真值 {len(fs)} 张（{d}），统计型；可判 {int(keep.sum())}/{GX * GY} 格（{kept:.0%}）')
    if a.self or not a.ours:
        for y in range(GY): print('  ' + ' '.join(f'{span[y, x, :3].max():4.0f}/{span[y, x, 4] / max(tf[:, y, x, 4].mean(), 1e-6):.2f}' + ('' if keep[y, x] else '×') for x in range(GX)))
        return 0
    of = stat_feats(rgb(a.ours, True)); bad = (of < alo) | (of > ahi)   # (GY, GX, 5)
    fail = keep & bad.any(axis=2); ok = kept >= MIN_KEPT and not fail.any()
    print(f'\n{a.game} / {a.point}：我方 {a.ours}')
    print('| 项 | 期望 | 真结果 |\n|---|---|---|')
    print(f'| 可判区域 | ≥ {MIN_KEPT:.0%} | {kept:.0%}（{int(keep.sum())}/{GX * GY} 格） |')
    for k, nm in enumerate(STAT_NAMES): print(f'| {nm}出界格 | 0 | {int((keep & bad[..., k]).sum())} |')
    print(f'| 总判 | 过 | {"过" if ok else "不过"} |')
    print('\n逐格（× = 剔除；. = 过；其余字母 = 出界的量：R G B 通道均值、s 标准差、g 梯度能量）：')
    for y in range(GY):
        print('  ' + ' '.join('  ×  ' if not keep[y, x] else ''.join('RGBsg'[k] for k in range(5) if bad[y, x, k]).ljust(5, '.') if fail[y, x] else '  .  ' for x in range(GX)))
    if a.json:
        json.dump(dict(game=a.game, point=a.point, mode='stats', ours=a.ours, truth=fs, kept=float(kept), keep=keep.tolist(),
                       ours_feats=of.round(2).tolist(), allow_lo=alo.round(2).tolist(), allow_hi=ahi.round(2).tolist(), fail=int(fail.sum()), passed=bool(ok)),
                  open(a.json, 'w'), ensure_ascii=False, indent=1)
    return 0 if ok else 1


def wide_truth(f):
    """宽屏真值（Ryujinx 打同一组宽屏补丁出的宽图，见 graphics/widen/scan/truth_nso.py、compat/truth/truth-wide.patch）：按真值自身宽高比比整帧——
    比较尺寸高 540、宽按比例取偶，格数按宽度同比加（格子仍近正方）；不再取中间 16:9（过渡判据随之不用）。"""
    global W, GX, CENTER
    w, h = Image.open(f).size
    if w * 9 > h * 16 + 9:
        W = round(H * w / h / 2) * 2; GX = round(8 * W / 960); CENTER = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--self', action='store_true'); ap.add_argument('game'); ap.add_argument('point'); ap.add_argument('ours', nargs='?')
    ap.add_argument('--json'); ap.add_argument('--heat'); ap.add_argument('--center16x9', action='store_true', help='我方图比 16:9 宽时先取中间 16:9 区')
    a = ap.parse_args()
    global CENTER; CENTER = a.center16x9
    d = os.path.join(TRUTH, a.game, a.point); pe = point_env(d)
    if a.ours and os.path.isdir(a.ours):   # 我方给的是逐秒序列目录：按 point.env 的 ARRIVE_DARK / ARRIVE_BRIGHT / OFFSET 用与真值同一条规则挑帧
        fs, lum = seq_lum(a.ours); arr = arrival(lum, 0, float(pe.get('ARRIVE_DARK', 20)), float(pe.get('ARRIVE_BRIGHT', 50)), float(pe.get('ARRIVE_BRIGHT_MAX', 255)))
        if arr is None: print(f'🔴 我方序列 {a.ours} 找不到黑场 → 亮起（亮度 {[round(lum[t]) for t in sorted(lum)]}）'); return 1
        t = pick_after(fs, arr, int(pe.get('OFFSET', 10)))
        if t is None: print(f'🔴 我方序列到达 t{arr} 后 {pe.get("OFFSET", 10)} 秒没有截图'); return 1
        print(f'我方序列：到达 t{arr}（亮度 {lum[arr]:.0f}）+{pe.get("OFFSET", 10)}s → t{t}'); a.ours = fs[t]
    if pe.get('MODE') == 'stats':
        fs = sorted(glob.glob(os.path.join(d, 'ryu_*.png')))
        if len(fs) < 2: sys.exit(f'🔴 真值不足：{d} 下 ryu_*.png 只有 {len(fs)} 张')
        return main_stats(a, d, fs)
    d, fs, ts, tm = load_truth(a.game, a.point)
    if a.ours and W != 960:   # 宽屏真值：我方图宽高比必须一致（同一屏幕宽出的图），不一致不比
        ow, oh = Image.open(a.ours).size
        if abs(ow / oh - W / H) > 0.01 * W / H: print(f'🔴 我方图 {ow}×{oh} 与宽屏真值宽高比 {W / H:.3f} 不一致（屏幕宽不同？）'); return 1
    sg = self_grid(ts); refbad = ref_errors(a.game, a.point); keep = (sg >= SELF_MIN) & ~refbad; kept = keep.mean()
    lself = np.zeros((GY, GX))
    for i in range(len(tm)):
        for j in range(i + 1, len(tm)): lself = np.maximum(lself, np.abs(tm[i] - tm[j]).max(axis=2))
    lbound = np.maximum(LUM_ABS, 2 * lself)
    # 锐度（细节）另判：SSIM 对轻微模糊不敏感（平涂界面 / 偏暗场景上模糊 1.2 像素仍判过）——逐格梯度能量与最近一张真值的相对差
    # ≤ max(GE_REL 5%, 2 × 真值各张的最大相对自差)；真值梯度能量 < GE_MIN（近乎平坦的格）不判锐度
    tg = np.array([stat_feats(rgb(f))[..., 4] for f in fs]); tgm = tg.mean(axis=0)
    gself = (tg.max(axis=0) - tg.min(axis=0)) / np.maximum(tgm, 1e-6); gbound = np.maximum(GE_REL, 2 * gself); gjudge = tgm >= GE_MIN
    print(f'真值 {len(fs)} 张（{d}）；自比每格最小 SSIM：中位 {np.median(sg):.3f}，剔除 {int((~keep).sum())}/{GX * GY} 格（其中参照已知错误 / MASK {int(refbad.sum())} 格），留 {kept:.0%}')
    if a.self or not a.ours:
        for y in range(GY): print('  ' + ' '.join(f'{v:.2f}' + ('' if k else '×') for v, k in zip(sg[y], keep[y])))
        return 0
    orgb = rgb(a.ours, True); o = luma(orgb); om = chan_means(orgb); og_e = stat_feats(orgb)[..., 4]

    def judge(cl, cm, cg):   # 候选真值（亮度图列表、通道均值列表、梯度能量数组）→ 每格最好值与不达标
        og = np.max([cells(ssim_map(o, t)) for t in cl], axis=0)
        ld = np.min([np.abs(om - m).max(axis=2) for m in cm], axis=0)   # 每格：与最近一张真值的最大通道均值差
        gd = np.min(np.abs(og_e[None] - cg) / np.maximum(cg, 1e-6), axis=0)   # 每格：与最近一张真值的梯度能量相对差
        fail, lfail, gfail = keep & (og < PASS), keep & (ld > lbound), keep & gjudge & (gd > gbound)
        return og, ld, gd, fail, lfail, gfail, int(fail.sum() + lfail.sum() + gfail.sum())
    og, ld, gd, fail, lfail, gfail, nbad = judge(ts, tm, tg); best = '同时刻各局（ryu_*）'
    wf = sorted(glob.glob(os.path.join(d, 'win_*.png')))
    for f in wf if nbad else []:   # 窗内最优帧：逐张整帧判，取不达标格最少的一张（并列取 SSIM 均值高的）
        w = rgb(f); r = judge([luma(w)], [chan_means(w)], stat_feats(w)[None, ..., 4])
        if r[6] < nbad or (r[6] == nbad and r[0][keep].mean() > og[keep].mean()): og, ld, gd, fail, lfail, gfail, nbad = r; best = os.path.basename(f)
    if wf: print(f'窗内候选 {len(wf)} 张（win_*）；取 {best}')
    ok = kept >= MIN_KEPT and not fail.any() and not lfail.any() and not gfail.any()
    vals = og[keep]
    print(f'\n{a.game} / {a.point}：我方 {a.ours}')
    print('| 项 | 期望 | 真结果 |\n|---|---|---|')
    print(f'| 可判区域 | ≥ {MIN_KEPT:.0%} | {kept:.0%}（{int(keep.sum())}/{GX * GY} 格） |')
    print(f'| 每格 SSIM 最低 | ≥ {PASS} | {vals.min():.3f} |' if vals.size else '| 每格 SSIM 最低 | ≥ 0.95 | 无可判格 |')
    print(f'| 每格 SSIM 中位 | — | {np.median(vals):.3f} |' if vals.size else '')
    print(f'| 结构不达标格（SSIM < {PASS}） | 0 | {int(fail.sum())} |')
    print(f'| 亮度 / 色偏不达标格 | 0 | {int(lfail.sum())}（最大通道均值差 {ld[keep].max():.1f} 级，该格上限 {lbound[keep][np.argmax(ld[keep])]:.1f}） |' if keep.any() else '')
    print(f'| 锐度不达标格（梯度能量相对差） | 0 | {int(gfail.sum())}（最大 {gd[keep & gjudge].max() if (keep & gjudge).any() else 0:.0%}） |')
    print(f'| 总判 | 过 | {"过" if ok else "不过"} |')
    print('\n逐格 SSIM / 通道均值差（行 = 自上而下，× = 剔除格；! = 结构不达标，# = 亮度 / 色偏不达标）：')
    for y in range(GY):
        print('  ' + ' '.join(('     ×     ' if not keep[y, x] else f'{og[y, x]:.2f}' + ('!' if fail[y, x] else ' ') + f'/{ld[y, x]:4.1f}' + ('#' if lfail[y, x] else ' ')) for x in range(GX)))
    if a.heat:
        cw, ch = W // GX, H // GY
        base = Image.fromarray(orgb.astype(np.uint8)); ov = np.asarray(base, dtype=np.float64).copy()
        for y in range(GY):
            for x in range(GX):
                col = (128, 128, 128) if not keep[y, x] else ((220, 40, 40) if fail[y, x] else (230, 160, 0) if lfail[y, x] or gfail[y, x] else (40, 200, 60))
                sl = ov[y * ch:(y + 1) * ch, x * cw:(x + 1) * cw]; sl[:] = sl * 0.6 + np.array(col) * 0.4
        Image.fromarray(ov.astype(np.uint8)).save(a.heat)
    if a.json:
        json.dump(dict(game=a.game, point=a.point, ours=a.ours, truth=fs, kept=float(kept), self=sg.round(4).tolist(),
                       ours_cells=og.round(4).tolist(), lum_diff=ld.round(2).tolist(), lum_bound=lbound.round(2).tolist(), keep=keep.tolist(),
                       fail=int(fail.sum()), lum_fail=int(lfail.sum()), sharp_fail=int(gfail.sum()), best=best, passed=bool(ok)),
                  open(a.json, 'w'), ensure_ascii=False, indent=1)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
