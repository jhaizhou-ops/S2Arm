// 满屏判据（取数无关部分；10-26 直连线从 graphics/metal/gal_present.m 抽出）：通用模式出图层 gal_present.m 与直连上屏 graphics/nvn/gfx/nvn/nvn_mtl.m 共用同一套判法与日志行
//   （真机 / 本机局执行器 tools/dev_run.sh 按「【红】出图未满屏」判）。判法、阈值、例外的来历见 gal_present.m 文件头「满屏判据」。
// 取数由调用方给（fj_src）：通用 = 定格贴图 getBytes；直连 = 截图通路读回的整屏 BGRA8。包含前定义 FJ_LOG(...)（一行日志，不带换行）。
#pragma once
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct fj_src {
    int w, h; void *ctx;
    void (*col)(void *ctx, int x, uint8_t *buf);   // 第 x 列整列，BGRA8 / RGBA8 每像素 4 字节（buf 至少 h × 4）
    void (*row)(void *ctx, int y, uint8_t *px);    // 第 y 行整行（px 至少 w × 4）
} fj_src;
typedef struct fj_state {   // 一个出图层一份
    _Atomic int st[2], nred, nok;          // 几何 / 内容各自的满屏状态；红 / 恢复行计数（限频）
    _Atomic uint64_t n_unfit, n_pillar;    // 判为没铺满 / 判为原比例页的次数（单测读）
    _Atomic int last_kind;                 // 最近一次内容判定（原始样本，不经连续两次的迟滞）：0 正常 / 1 黑带 / 2 接缝 / 3 暗带 / 4 几何 / 5 免判（原比例页 / 回退 / 两侧是游戏画的）
    _Atomic uint64_t last_seq, last_n;     // 内容判定次数 / 那次判的是第几次出图（11-02 体验线：局内扩展区异常累计 20 秒问玩家是否退回 16:9，读 1–3）
    int streak, pst;                       // 内容判据连续没铺满次数；上次记日志的原比例种类
    uint8_t *buf; int cap;
    uint8_t *rbuf; int rcap;               // 整行缓冲（竖向判据，w × 4）
} fj_state;
static void fj_note(fj_state *S, int kind, int bad, const char *why, uint64_t n) {
    if (bad) atomic_fetch_add(&S->n_unfit, 1);
    if (atomic_exchange(&S->st[kind], bad) == bad) return;
    // 限频（10-20 测试设备2 巫师3：两套出图参数每帧来回切，这两行每秒约 45 行、200 秒 1 万行，设备拷 host.log 拷不完）：前 32 次照记，之后每 1000 次记一行带累计
    if (bad) { int k = atomic_fetch_add(&S->nred, 1); if (k < 32 || k % 1000 == 0) FJ_LOG("【红】出图未满屏（%s，第 %llu 次出图起，累计第 %d 次）：%s", kind ? "内容" : "几何", (unsigned long long)n, k + 1, why); }
    else { int k = atomic_fetch_add(&S->nok, 1); if (k < 32 || k % 1000 == 0) FJ_LOG("出图恢复满屏（%s，第 %llu 次出图起，累计第 %d 次）", kind ? "内容" : "几何", (unsigned long long)n, k + 1); }
}
static int fj_col_black(const fj_src *t, int x, uint8_t *buf) {   // BGRA8 定格图第 x 列整列 RGB 全 0
    int h = t->h; t->col(t->ctx, x, buf);
    for (int y = 0; y < h; y++) if (buf[4 * y] | buf[4 * y + 1] | buf[4 * y + 2]) return 0;
    return 1;
}
static int fj_row_black(const fj_src *t, int y, uint8_t *px) {   // 第 y 行整行 RGB 全 0（px 至少 w × 4）
    int w = t->w; t->row(t->ctx, y, px);
    for (int x = 0; x < w; x++) if (px[4 * x] | px[4 * x + 1] | px[4 * x + 2]) return 0;
    return 1;
}
static int fj_dark_band(const fj_src *t, int *right, int *pct) {
    static uint8_t *px; static uint32_t *pre; static size_t cap, capr; int w = t->w, h = t->h;
    int step = h > 64 ? h / 64 : 1, nr = (h + step - 1) / step;
    if (cap < (size_t)w * 4) { free(px); px = malloc((size_t)w * 4); cap = px ? (size_t)w * 4 : 0; }
    if (capr < (size_t)nr * (w + 1)) { free(pre); pre = malloc((size_t)nr * (w + 1) * 8); capr = pre ? (size_t)nr * (w + 1) : 0; }
    if (!cap || !capr) return -1;
    for (int r = 0; r < nr; r++) {   // 每抽样行的亮度前缀和（BGRA，取 RGB 平均 ×3）
        t->row(t->ctx, r * step, px);
        uint32_t *q = pre + (size_t)r * (w + 1), *g = pre + (size_t)(nr + r) * (w + 1); q[0] = g[0] = 0; int last = 0;
        for (int x = 0; x < w; x++) { int v = px[4 * x] + px[4 * x + 1] + px[4 * x + 2]; q[x + 1] = q[x] + v; g[x + 1] = g[x] + (uint32_t)abs(v - (x ? last : v)); last = v; }   // g：横向相邻差的绝对值前缀和
    }
    int s = w / 32 > 2 ? w / 32 : 2, minb = w / 50 > 4 ? w / 50 : 4;
    #define RSUM(r, a, b) ((double)(pre[(size_t)(r) * (w + 1) + (b)] - pre[(size_t)(r) * (w + 1) + (a)]))
    for (int side = 0; side < 2; side++)
        for (int b = minb; b <= w / 2 - s; b++) {   // 带宽 b：右侧 [w−b, w)，左侧 [0, b)
            int x0 = side ? w - b : b;   // 断口列（右侧 = 带起点；左侧 = 带终点）
            // 逐行：带外紧挨 s 列平均 ≥ 8 且整段暗带平均 < 它 × 0.4 的行 ≥ 50%；断口：紧挨两侧各 4 列有台阶（带内 < 带外 × 0.6）的行 ≥ 40%（渐暗 / 暗角没有台阶）
            int ia = side ? x0 - s : x0, ib = side ? x0 : x0 + s, da = side ? x0 : 0, db = side ? w : x0;   // 带外（内侧）[ia,ib)、整段暗带 [da,db)
            int na = side ? x0 - 4 : x0, nb = side ? x0 : x0 + 4, ea = side ? x0 : x0 - 4, eb = side ? x0 + 4 : x0;   // 断口两侧各 4 列
            int ok = 0, edge = 0;
            for (int r = 0; r < nr; r++) {
                double o = RSUM(r, ia, ib) / s, d = RSUM(r, da, db) / b;
                if (o >= 24 && d < 0.4 * o) ok++;
                if (RSUM(r, ea, eb) < 0.6 * RSUM(r, na, nb)) edge++;
            }
            if (ok * 2 < nr || edge * 5 < nr * 2) continue;
            double band = 0, inner = 0; int ba = side ? w - b : 0, bb = side ? w : b, ka = side ? w - 2 * b : b, kb = side ? w - b : 2 * b;
            for (int r = 0; r < nr; r++) { band += RSUM(r, ba, bb); inner += RSUM(r, ka, kb); }
            // 只认一侧：对侧同宽一段要明显亮——逐行比，对侧 ≥ 暗带 × 1.5 且平均 ≥ 8 的行 ≥ 50%（10-22 八方2 M3 截图左侧暗水面 2.17 倍）。黑底正中一块 logo 的页两侧都暗，是原比例图片，不是某一遍没铺满；
            // 按行数而不按整段总和：暗黑3 读盘页（游戏自己出宽图，16:9 外的原画居中、两侧各 253 列纯黑）右侧黑区里有个喇叭小图标，旧判法「对侧总和 ≥ 暗带 × 1.5 + 1」在暗带全黑时被一个小图标就满足、报左侧暗带（10-22 每局第 810–1020 次出图）
            int mbright = 0; int ma = side ? 0 : w - b, mb = side ? b : w;
            for (int r = 0; r < nr; r++) { double mr = RSUM(r, ma, mb) / b, br = RSUM(r, ba, bb) / b; if (mr >= 24 && mr >= 1.5 * br) mbright++; }
            // 带内平滑：平均横向相邻差 < 带均值 × 0.08（下限按均值 1 算）——没铺满的那块是空的（近黑底 + 零星亮点、雾），贴脸的暗物体（10-22 怪猎村口门柱）有纹理
            double grad = 0; for (int r = 0; r < nr; r++) grad += (double)pre[(size_t)(nr + r) * (w + 1) + bb] - pre[(size_t)(nr + r) * (w + 1) + ba + 1];
            grad /= (double)nr * (b - 1); double mean = band / ((double)nr * b);
            if (band < 0.4 * inner && mbright * 2 >= nr && grad < 0.08 * (mean > 3 ? mean : 3)) { *right = side; *pct = ok * 100 / nr; return x0; }
        }
    #undef RSUM
    return -1;
}
// 中间整列纯黑（11-09 质量线，哈迪斯 II 强制整套放宽：画面中段 291 / 1280 列整列 RGB 全 0、两侧都是场景，旧判据只扫贴边的带和 16:9 边界，宿主报满屏 0 红）：
//   第一 / 最后一列有内容的列之间，最长一段整列纯黑 ≥ max(宽 / 50, 8) 列，且 ① 这段两侧紧挨各 8 列的平均亮度（RGB 和）≥ 12——真露空是断崖，游戏自己的暗角是渐暗
//   （丝之歌右侧暗角里零星萤火虫：紧挨列 0–0.2）；② 这段以外的画面里纯黑像素 < 50%——黑底页上左右各摆一块内容（动森对话页 89%）不算。
//   标定（11-09，S2A_2T 盘上 815 张自动玩家截图 + 哈迪斯三张）：命中哈迪斯 ap_mid / ap_mark（紧挨列 101–127）与超级马力欧奥德赛放宽实验坏图（15.5–17.8），丝之歌 / 动森 / 其余 0 张。
//   返回黑段起点列（*len = 列数），没有返回 -1
static int fj_mid_black(const fj_src *t, uint8_t *buf, int *len) {
    int w = t->w, h = t->h, lo = -1, hi = -1;
    for (int x = 0; x < w; x++) if (!fj_col_black(t, x, buf)) { if (lo < 0) lo = x; hi = x; }
    if (lo < 0 || hi - lo < 2) return -1;
    int best = 0, bs = -1, cur = 0;
    for (int x = lo + 1; x < hi; x++) { if (fj_col_black(t, x, buf)) { if (++cur > best) { best = cur; bs = x - cur + 1; } } else cur = 0; }
    int need = w / 50 > 8 ? w / 50 : 8;
    if (best < need) return -1;
    double side[2] = {0, 0}; int nside[2] = {0, 0};
    for (int k = 1; k <= 8; k++) {
        int xs[2] = {bs - k, bs + best - 1 + k};
        for (int j = 0; j < 2; j++) { if (xs[j] < 0 || xs[j] >= w) continue; t->col(t->ctx, xs[j], buf); for (int y = 0; y < h; y++) side[j] += buf[4 * y] + buf[4 * y + 1] + buf[4 * y + 2]; nside[j] += h; }
    }
    if (!nside[0] || !nside[1] || side[0] / nside[0] < 12 || side[1] / nside[1] < 12) return -1;
    uint64_t blk = 0, tot = 0;
    for (int x = lo; x <= hi; x++) { if (x >= bs && x < bs + best) continue; t->col(t->ctx, x, buf); for (int y = 0; y < h; y++) blk += !(buf[4 * y] | buf[4 * y + 1] | buf[4 * y + 2]); tot += (uint64_t)h; }
    if (!tot || blk * 2 >= tot) return -1;
    *len = best; return bs;
}
// 两侧带与中间不连续（10-29 马车8 选轮胎页：两侧留旧帧 / 铺满画布的底纹只画了中间，整列不黑、暗带判据也不认）：16:9 边界 b0 左右各 ±3 列里找接缝最强的一列 b，
//   逐行比跨边台阶 |I[b] − I[b−1]|（RGB 和）与它两侧各 7 列相邻台阶的中位数：台阶 > max(3 × 中位, 24) 的行 = 接缝行；返回接缝行占比最大的那列的占比（百分数），*col = 那列。
//   这一侧带除接缝搜索窗（边界 ±R+1 列）外整列纯黑（RGB 全 0，同本文件黑带口径；原比例页 / 黑边，归黑带判据管）返回 -1：上屏双线性放大时边界那一列混进内容、不再纯黑
//   （10-30 普查 c1029c：1564 宽原比例页放大到 2346，第 212 列约 17% 内容，6 款黑边与内容的交界被判成「接缝贯穿 100% 行」），窗外全黑时窗里能找到的台阶只可能是黑边本身。tools/widen_accept.py measure_side_seam 同一判法、同一阈值（FJ_SEAM_PCT）；
//   标定（10-29 真截图）：反例 马车8 轮胎页 48–91%，正例 马车8 赛道 / 八方2 读档等 9 张 ≤ 15%
#define FJ_SEAM_PCT 30
static int fj_seam(const fj_src *t, int b0, int band0, int band1, int *col) {
    enum { R = 3, N = 7 };   // 搜索半径、单侧邻列数：台阶要 [b0 − R − N − 2, b0 + R + N + 1] 共 2(R + N) + 4 列
    int h = t->h, w = t->w, x0 = b0 - R - N - 2, nc = 2 * (R + N) + 4;
    if (x0 < 0 || x0 + nc > w || h < 2) return -1;
    static uint8_t *cb; static size_t cap; size_t need = (size_t)nc * h * 4;
    if (cap < need) { free(cb); cb = malloc(need); cap = cb ? need : 0; }
    if (!cb) return -1;
    { int allblack = 1; uint8_t *tmp = cb; for (int x = band0; x < band1 && allblack; x++) if (x < b0 - R - 1 || x > b0 + R) allblack = fj_col_black(t, x, tmp); if (allblack) return -1; }
    for (int i = 0; i < nc; i++) t->col(t->ctx, x0 + i, cb + (size_t)i * h * 4);
    #define PX(i, y) (cb + ((size_t)(i) * h + (y)) * 4)
    #define STEP(i, y) (abs(PX(i, y)[0] - PX((i) - 1, y)[0]) + abs(PX(i, y)[1] - PX((i) - 1, y)[1]) + abs(PX(i, y)[2] - PX((i) - 1, y)[2]))   // 第 i 列与第 i−1 列的台阶
    int best = 0, bestb = b0;
    for (int b = b0 - R; b <= b0 + R; b++) {
        int bi = b - x0, hit = 0, rows = 0;
        for (int y = 0; y < h; y++) {
            int nb[2 * N], k = 0;
            for (int d = -N - 1; d <= -2; d++) nb[k++] = STEP(bi + d, y);
            for (int d = 2; d <= N + 1; d++) nb[k++] = STEP(bi + d, y);
            for (int i = 1; i < 2 * N; i++) for (int j = i; j > 0 && nb[j - 1] > nb[j]; j--) { int v = nb[j]; nb[j] = nb[j - 1]; nb[j - 1] = v; }   // 插入排序取中位
            int med2 = nb[N - 1] + nb[N], thr2 = 3 * med2 > 48 ? 3 * med2 : 48;   // 两倍口径比：台阶 > max(3 × 中位, 24)，中位 = 第 7、8 小的平均（不取整，同 NumPy median）
            hit += 2 * STEP(bi, y) > thr2; rows++;
        }
        int pct = hit * 100 / rows; if (pct > best) { best = pct; bestb = b; }
    }
    #undef STEP
    #undef PX
    *col = bestb; return best;
}
// 竖向接缝（11-05，fj_seam 转 90°）：上下带与中间不连续——16:9 边界行 b0 上下各 ±3 行里找接缝最强的一行 b，逐列比跨边台阶 |I[b] − I[b−1]| 与它上下各 7 行
//   相邻台阶的中位数，台阶 > max(3 × 中位, 24) 的列 = 接缝列；返回占比最大的那行的占比（百分数），*row = 那行。这一侧带（搜索窗外）整行纯黑返回 -1（归黑带判据，同 fj_seam）。
//   反例 11-05 哆啦A梦牧场 Duo 剧情对话框（1280×900）：页内压暗层只盖 [90, 810) 行，上下带里是没压暗的磨砂边框，第 90 / 810 行整宽亮度台阶
//   门限单独定 FJ_SEAM_ROW_PCT 50（横向 30 不动）。标定（11-05 Duo 1280×900 真截图 57 张）：层不一致的反例 71%（旷野之息标题：背景图只盖 16:9 行、右侧悬崖层伸进上带）、
//   100%（哆啦A梦剧情 / 同意页：页内层只盖中间、上下露另一层）；正常画面 0%（标题 / 加载页、我的世界自己画的高屏）；游戏自己的排版边缘碰巧落在边界行附近 42%
//   （哆啦A梦条款页页签上沿在第 92 行、只占左边约 45% 宽）——30% 会误报它
#define FJ_SEAM_ROW_PCT 50
static int fj_seam_row(const fj_src *t, int b0, int band0, int band1, int *row) {
    enum { R = 3, N = 7 };
    int h = t->h, w = t->w, y0 = b0 - R - N - 2, nr = 2 * (R + N) + 4;
    if (y0 < 0 || y0 + nr > h || w < 2) return -1;
    static uint8_t *rb; static size_t cap; size_t need = (size_t)nr * w * 4;
    if (cap < need) { free(rb); rb = malloc(need); cap = rb ? need : 0; }
    if (!rb) return -1;
    { int allblack = 1; for (int y = band0; y < band1 && allblack; y++) if (y < b0 - R - 1 || y > b0 + R) allblack = fj_row_black(t, y, rb); if (allblack) return -1; }
    for (int i = 0; i < nr; i++) t->row(t->ctx, y0 + i, rb + (size_t)i * w * 4);
    #define PX(i, x) (rb + ((size_t)(i) * w + (x)) * 4)
    #define STEP(i, x) (abs(PX(i, x)[0] - PX((i) - 1, x)[0]) + abs(PX(i, x)[1] - PX((i) - 1, x)[1]) + abs(PX(i, x)[2] - PX((i) - 1, x)[2]))
    int best = 0, bestb = b0;
    for (int b = b0 - R; b <= b0 + R; b++) {
        int bi = b - y0, hit = 0, cols = 0;
        for (int x = 0; x < w; x++) {
            int nb[2 * N], k = 0;
            for (int d = -N - 1; d <= -2; d++) nb[k++] = STEP(bi + d, x);
            for (int d = 2; d <= N + 1; d++) nb[k++] = STEP(bi + d, x);
            for (int i = 1; i < 2 * N; i++) for (int j = i; j > 0 && nb[j - 1] > nb[j]; j--) { int v = nb[j]; nb[j] = nb[j - 1]; nb[j - 1] = v; }
            int med2 = nb[N - 1] + nb[N], thr2 = 3 * med2 > 48 ? 3 * med2 : 48;
            hit += 2 * STEP(bi, x) > thr2; cols++;
        }
        int pct = hit * 100 / cols; if (pct > best) { best = pct; bestb = b; }
    }
    #undef STEP
    #undef PX
    *row = bestb; return best;
}
// geo = 几何判据此前判过没满屏（why = 原因）：这张有内容才报；g = 出图层被告知的原比例种类（0–4，见 gal_present.m）；n = 第几次出图（日志用）
static void fj_judge(fj_state *S, const fj_src *qt, int geo, const char *geo_why, int g, uint64_t n) {
    int h = qt->h, w = qt->w;
    if (S->cap < h * 4) { free(S->buf); S->buf = malloc((size_t)h * 4); S->cap = S->buf ? h * 4 : 0; }
    uint8_t *buf = S->buf; int kind = 0, geobad = 0;
    // 几何（见 fit_geom）：钉住时与现在都没满屏、这张有内容才报
    if (buf && geo) {
        int any = 0; for (int k = 1; k <= 5 && !any; k++) any = !fj_col_black(qt, (int)((long)w * k / 6), buf);
        if (any) { fj_note(S, 0, 1, geo_why, n); geobad = 1; }
    }
    // 只认「游戏只画了中间 16:9、宽出图两侧空着」：内缩量 in = (宽 − 高×16/9)/2；外侧黑带（第 0 列与第 in−2 列）整列纯黑、带内侧第 in+1 列有内容。
    // 出图不比 16:9 宽（in < 4，如 Mac 回归 1920×1080）不判；开机 logo / 读盘黑底页带内侧也是黑的，不算（10-19 m4 回归 6 款 13 行误报）
    int in = (w - (int)lround(h * 16.0 / 9.0)) / 2;
    // 几何已判没满屏（画面本身比屏窄、出图层居中留边）：两侧那条边是出图层留的，不是放宽区没画到 / 接缝 / 暗带，只记几何（种类 4）。
    //   11-02 维护者 测试设备1 饥荒：交换链放不宽、稳定 16:9 居中，真机整屏截图两侧留边被判成黑带（种类 1）→ 累计 20 秒误弹「自适应满屏不稳定」
    if (buf && in >= 4 && in + 2 < w / 2 && !geo) {
        int lb = fj_col_black(qt, 0, buf) && fj_col_black(qt, in - 2, buf), rb = fj_col_black(qt, w - 1, buf) && fj_col_black(qt, w - in + 1, buf);
        int l = lb && !fj_col_black(qt, in + 1, buf);
        int rr = rb && !fj_col_black(qt, w - in - 2, buf);
        // 原比例页 / 两侧是放宽内容画的黑：两侧外侧都是黑带（居中）且包装层标了。只看外侧黑带、不要求两边带内都有内容——
        // 页内容贴不贴 16:9 内沿是图片自己的事（10-22 怪猎开场 logo 视频：带内只有左内沿一列有暗像素，旧判法 l && rr 不成立，标了原比例页照报未满屏）
        // 两侧是游戏画的（2：放宽内容画过两侧 / 游戏自己出宽图的纯 2D 合成帧，见 WidenRenderer Bands / Scene3D）：黑不黑、单侧双侧都是游戏的画面，不判（10-22 塞尔达标题页：
        // 16:9 原画居中、菜单衬底贴右缘 → 左侧纯黑、右侧极暗非 0，旧判法报「左侧黑带」）
        // 没有可扩视野的内容（3，见 WidenTexture.CamContent）/ 游戏自己出宽图的纯 2D 合成（4）：同 2，不论单侧双侧
        int c = l || rr, pil = c && (g >= 2 || lb && rb) ? g : 0;
        if (pil) { c = 0; kind = 5; atomic_fetch_add(&S->n_pillar, 1); }
        if (c) kind = 1;
        { if (pil != S->pst) { S->pst = pil; FJ_LOG("%s（第 %llu 次出图起）：画面 %dx%d 两侧各 %d 像素黑边%s", pil == 2 ? "出图两侧黑是游戏画的（宽屏包装层认定两侧本帧被放宽内容画过，如转场压黑的场景上盖 16:9 读盘页，不判未满屏）"
            : pil == 4 ? "出图两侧不判（游戏自己出宽图、这一帧全是 2D 合成，排版归游戏）"
            : pil == 5 ? "出图原比例回退（纯 2D 帧放宽后两侧游戏都没画到，整帧退回 16:9 居中；五问记「原比例回退」、不记满屏过）"
            : pil == 3 ? "出图没有可扩视野的内容（宽屏包装层认定上屏内容里没有读到改写镜头的绘制，如读盘页，按 维护者 规则留黑边，不判未满屏）"
            : pil ? "出图原比例居中（16:9 原比例页，宽屏包装层认定纯 CPU 供图、没有更宽内容可补，按 维护者 规则留黑边，不判未满屏）" : "出图离开原比例页",
            (unsigned long long)n, w, h, in, pil ? "" : "（之后黑带照常判）"); } }
        char why[256]; snprintf(why, sizeof why, "画面 %dx%d %s 16:9 外侧 %d 像素黑带、带内有内容", w, h, l && rr ? "左右两边" : l ? "左侧" : "右侧", in);
        // 贴边暗带：黑带没判出、也不是原比例页 / 两侧是游戏画的（g 非 0：纯 2D 页、菜单衬底贴边本来就暗，10-22 塞尔达标题页右侧极暗）
        int rs, pc, dx = !c && (g == 0 || g == 2) ? fj_dark_band(qt, &rs, &pc) : -1;   // 原比例回退（5）两侧本就是黑带，不判暗带 / 接缝
        if (dx >= 0) { c = 1; kind = 3; snprintf(why, sizeof why, "画面 %dx%d %s第 %d 列起明显变暗、断口贯穿 %d%% 行（某一遍没铺满放宽宽度）", w, h, rs ? "右侧" : "左侧到", rs ? dx : dx - 1, pc); }
        // 中间整列纯黑（fj_mid_black）：只在常规帧判（g 0）；原比例页 / 两侧是游戏画的 / 纯 2D 合成 / 回退的排版归游戏
        if (!c && g == 0) { int ml = 0, mx = fj_mid_black(qt, buf, &ml);
            if (mx >= 0) { c = 1; kind = 1; snprintf(why, sizeof why, "画面 %dx%d 中间第 %d–%d 列整列纯黑（%d 列，两侧紧挨都是画面：放宽后中间一块没画到）", w, h, mx, mx + ml - 1, ml); } }
        // 两侧带与中间不连续（fj_seam）：黑带 / 暗带都没判出时再看；游戏自己出宽图的纯 2D 合成帧（4）排版归游戏，不判
        //   两侧是放宽内容画的（2：铺满画布的层按放宽画过两侧，见 WidenFrame.MarkBands）也不判：接缝判据的两个前提「两侧留旧帧」「铺满画布的层没铺满」都被这个结论否掉，
        //   剩下的跨边台阶是游戏自己的排版（11-02 植物大战僵尸协议页：压暗层已推满整幅、两侧同乘 0.32，游戏在压暗之后又在画布外画侧饰，第 213 列接缝 99% 行）
        if (!c && g != 2 && g != 4 && g != 5) {
            int lc = 0, rc = 0, lp = fj_seam(qt, in, 0, in, &lc), rp = fj_seam(qt, w - in, w - in, w, &rc);
            if (lp >= FJ_SEAM_PCT || rp >= FJ_SEAM_PCT) { c = 1; kind = 2; int r = rp > lp;
                snprintf(why, sizeof why, "画面 %dx%d %s 16:9 边界第 %d 列接缝贯穿 %d%% 行（两侧带与中间不连续：旧帧残留 / 铺满画布的界面层没铺满）", w, h, r ? "右侧" : "左侧", r ? rc : lc, r ? rp : lp); }
        }
        S->streak = c ? S->streak + 1 : 0;
        if (!c || S->streak >= 2) fj_note(S, 1, c, why, n);
    }
    // 竖向（比 16:9 高的屏，Duo 内屏 1.42 等）：内缩量 iny = (高 − 宽×9/16)/2，同横向判法换成行。11-05 前这里没有分支：高屏内容判据整段不跑、几何因出图层宽高比 = 屏比也过，
    //   旷野之息 Duo 局内场景只占 2007 行里的 [200,1409)、底部 268 行纯黑，宿主报红 0（满屏补丁线 11-05，证据 run/s2arm/evidence/hzline_1105/botw_duo）。
    // 原比例页 / 回退（g 1 / 5）上下黑带照免判，但页内容要铺满页：一侧内沿有内容、另一侧内沿起纯黑行 ≥ 页高 10% = 页里的场景没铺满（旷野之息 Duo：上沿有内容、
    //   下沿起 268 行纯黑 = 16.7%）。两侧内沿都黑（黑底居中的 logo 页）不判——同横向「页内容贴不贴内沿是图片自己的事」
    int iny = (h - (int)lround(w * 9.0 / 16.0)) / 2;
    if (S->rcap < w * 4) { free(S->rbuf); S->rbuf = malloc((size_t)w * 4); S->rcap = S->rbuf ? w * 4 : 0; }
    uint8_t *rb = S->rbuf;
    if (rb && in < 4 && iny >= 4 && iny + 2 < h / 2 && !geo) {
        int tb = fj_row_black(qt, 0, rb) && fj_row_black(qt, iny - 2, rb), bb = fj_row_black(qt, h - 1, rb) && fj_row_black(qt, h - iny + 1, rb);
        int ti = !fj_row_black(qt, iny + 1, rb), bi = !fj_row_black(qt, h - iny - 2, rb);
        int t = tb && ti, b = bb && bi, c = t || b, pil = c && (g >= 2 || tb && bb) ? g : 0;
        if (pil) { c = 0; kind = 5; atomic_fetch_add(&S->n_pillar, 1); }
        if (c) kind = 1;
        if (pil != S->pst) { S->pst = pil; FJ_LOG("%s（第 %llu 次出图起）：画面 %dx%d 上下各 %d 像素黑边%s", pil == 5 ? "出图原比例回退（上下）" : pil ? "出图原比例居中（16:9 原比例页，上下留黑边，不判未满屏）" : "出图离开原比例页",
            (unsigned long long)n, w, h, iny, pil ? "" : "（之后黑带照常判）"); }
        char why[256]; snprintf(why, sizeof why, "画面 %dx%d %s 16:9 外侧 %d 像素黑带、带内有内容", w, h, t && b ? "上下两边" : t ? "上侧" : "下侧", iny);
        if (!c && (pil == 1 || pil == 5) && ti != bi) {
            int y = ti ? h - iny - 2 : iny + 1, d = ti ? -1 : 1, k = 0, ch = h - 2 * iny;
            while (k < ch && fj_row_black(qt, y, rb)) { y += d; k++; }
            if (k * 10 >= ch) { c = 1; kind = 1; snprintf(why, sizeof why, "画面 %dx%d 原比例页内容没铺满页：%s内沿起 %d 行纯黑（占页 %d%%）、%s内沿有内容（页里的场景只画了一部分）",
                w, h, ti ? "下" : "上", k, k * 100 / ch, ti ? "上" : "下"); }
        }
        // 上下带与中间不连续（fj_seam_row，同横向 fj_seam 的免判口径：两侧是游戏画的 2 / 纯 2D 合成 4 / 回退 5 不判）
        if (!c && g != 2 && g != 4 && g != 5) {
            int tr = 0, br = 0, tp = fj_seam_row(qt, iny, 0, iny, &tr), bp = fj_seam_row(qt, h - iny, h - iny, h, &br);
            if (tp >= FJ_SEAM_ROW_PCT || bp >= FJ_SEAM_ROW_PCT) { c = 1; kind = 2; int bo = bp > tp;
                snprintf(why, sizeof why, "画面 %dx%d %s 16:9 边界第 %d 行接缝贯穿 %d%% 列（上下带与中间不连续：某层只盖中间 16:9 / 旧帧残留）", w, h, bo ? "下侧" : "上侧", bo ? br : tr, bo ? bp : tp); }
        }
        S->streak = c ? S->streak + 1 : 0;
        if (!c || S->streak >= 2) fj_note(S, 1, c, why, n);
    }
    if (!kind && geobad) kind = 4;
    atomic_store(&S->last_kind, kind); atomic_store(&S->last_n, n); atomic_fetch_add(&S->last_seq, 1);
}
