// D7 第二片：nvn_geometry.h 的图元装配是纯 C（只依赖 stdint/stddef），能在 Linux 上单独编译验证。
// 期望值按独立规则手算：点/线/三角形列表、strip 交替绕序、fan、quad 列表、restart 分段、短目标不半写。
#include "nvn_geometry.h"
#include <stdio.h>
#include <string.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static void eq_sz(const char *what, size_t got, size_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %zu，期望 %zu\n", what, got, want); }
}

static void eq_words(const char *what, const uint32_t *got, const uint32_t *want, size_t n) {
    checks++;
    if (memcmp(got, want, n * sizeof *got) != 0) {
        fails++;
        printf("FAIL %s：", what);
        for (size_t i = 0; i < n; i++) printf(" %u", got[i]);
        printf("，期望");
        for (size_t i = 0; i < n; i++) printf(" %u", want[i]);
        printf("\n");
    }
}


// 升序去重的参考做法（与被测实现无关）：插入排序后去重
static size_t ref_unique(const uint32_t *v, size_t n, uint32_t *out) {
    uint32_t t[4096]; size_t m = 0;
    for (size_t i = 0; i < n; i++) { size_t j = m++; while (j && t[j - 1] > v[i]) { t[j] = t[j - 1]; j--; } t[j] = v[i]; }
    size_t k = 0; for (size_t i = 0; i < m; i++) if (!i || t[i] != t[i - 1]) out[k++] = t[i];
    return k;
}
static int uq_case(const char *what, const uint32_t *in, size_t n, int want_bitmap) {
    uint32_t lo = UINT32_MAX, hi = 0; for (size_t i = 0; i < n; i++) { if (in[i] < lo) lo = in[i]; if (in[i] > hi) hi = in[i]; }
    static uint32_t v[4096], got[4096], want[4096]; static uint64_t *bm; static size_t bw;
    memcpy(v, in, n * 4); size_t k = nvn_geo_unique_sorted(v, n, lo, hi, got, &bm, &bw), kw = ref_unique(in, n, want);
    int path = n ? nvn_geo_unique_bitmap_ok(n, lo, hi) : -1;
    checks++;
    int ok = k == kw && !memcmp(got, want, k * 4) && (want_bitmap < 0 || path == want_bitmap);
    if (!ok) { fails++; printf("FAIL 升序去重 %s：个数 %zu（期望 %zu），走位图 %d（期望 %d）\n", what, k, kw, path, want_bitmap); }
    return ok;
}

int main(void) {
    eq_i("topology 点", nvn_geo_topology(0), 0);
    eq_i("topology 线", nvn_geo_topology(1), 1);
    eq_i("topology 线带", nvn_geo_topology(2), 1);
    eq_i("topology 线环", nvn_geo_topology(3), 1);
    eq_i("topology 三角形", nvn_geo_topology(4), 3);
    eq_i("topology 三角形带", nvn_geo_topology(5), 3);
    eq_i("topology 三角形扇", nvn_geo_topology(6), 3);
    eq_i("topology quad", nvn_geo_topology(7), 3);
    eq_i("topology 邻接线", nvn_geo_topology(10), 2);
    eq_i("topology patch", nvn_geo_topology(12), 4);
    eq_i("topology 未支持", nvn_geo_topology(9), -1);
    eq_i("width 点", nvn_geo_width(0), 1);
    eq_i("width 线", nvn_geo_width(1), 2);
    eq_i("width 邻接线", nvn_geo_width(2), 4);
    eq_i("width 三角形", nvn_geo_width(3), 3);
    eq_i("width patch", nvn_geo_width(4), 6);
    eq_i("width 未支持", nvn_geo_width(-1), 0);

    uint32_t out[32];

    // 点列表：3 个点，宽度 1
    uint32_t pts[] = {10, 11, 12};
    memset(out, 0, sizeof out);
    eq_sz("点列表字数", nvn_geo_assemble(0, pts, 3, 0, 0, out, 32), 3);
    eq_words("点列表内容", out, pts, 3);

    // 线列表：4 个索引 / 2 条线
    uint32_t lines[] = {0, 1, 2, 3};
    memset(out, 0, sizeof out);
    eq_sz("线列表字数", nvn_geo_assemble(1, lines, 4, 0, 0, out, 32), 4);
    eq_words("线列表内容", out, lines, 4);

    // 三角形列表：2 个三角形
    uint32_t tris[] = {0, 1, 2, 3, 4, 5};
    memset(out, 0, sizeof out);
    eq_sz("三角形列表字数", nvn_geo_assemble(4, tris, 6, 0, 0, out, 32), 6);
    eq_words("三角形列表内容", out, tris, 6);

    // 三角形带：{0,1,2} 与交换绕序的 {2,1,3}
    uint32_t strip[] = {0, 1, 2, 3};
    uint32_t strip_want[] = {0, 1, 2, 2, 1, 3};
    memset(out, 0, sizeof out);
    eq_sz("三角形带字数", nvn_geo_assemble(5, strip, 4, 0, 0, out, 32), 6);
    eq_words("三角形带内容", out, strip_want, 6);

    // 三角形扇：{0,1,2} 与 {0,2,3}
    uint32_t fan_want[] = {0, 1, 2, 0, 2, 3};
    memset(out, 0, sizeof out);
    eq_sz("三角形扇字数", nvn_geo_assemble(6, strip, 4, 0, 0, out, 32), 6);
    eq_words("三角形扇内容", out, fan_want, 6);

    // quad 列表：两个 quad 各拆两个三角形（保持绕序）
    uint32_t quads[] = {0, 1, 2, 3, 4, 5, 6, 7};
    uint32_t quads_want[] = {0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7};
    memset(out, 0, sizeof out);
    eq_sz("quad 列表字数", nvn_geo_assemble(7, quads, 8, 0, 0, out, 32), 12);
    eq_words("quad 列表内容", out, quads_want, 12);

    // restart：两段各 3 个索引，restart 索引被跳过
    uint32_t seg[] = {0, 1, 2, 0xFFFFFFFFu, 3, 4, 5};
    uint32_t seg_want[] = {0, 1, 2, 3, 4, 5};
    memset(out, 0, sizeof out);
    eq_sz("restart 分段字数", nvn_geo_assemble(4, seg, 7, 1, 0xFFFFFFFFu, out, 32), 6);
    eq_words("restart 分段内容", out, seg_want, 6);

    // 只计字数：dst = NULL 与写入结果一致
    eq_sz("只计字数", nvn_geo_assemble(4, tris, 6, 0, 0, NULL, 0), 6);

    // 短目标：返回 SIZE_MAX，且一个词都不写
    memset(out, 0xAA, sizeof out);
    eq_sz("短目标拒绝", nvn_geo_assemble(4, tris, 6, 0, 0, out, 5), SIZE_MAX);
    checks++;
    if (out[0] != 0xAAAAAAAAu) { fails++; printf("FAIL 短目标被部分写入：out[0] = 0x%08x\n", out[0]); }

    // 未支持图元：SIZE_MAX
    eq_sz("未支持图元", nvn_geo_assemble(9, tris, 6, 0, 0, out, 32), SIZE_MAX);

    // 列表图元不带 restart（11-06 快路）：结果按定义 = 前 ⌊count / 每图元顶点数⌋ × 每图元顶点数 个索引原样；余数丢弃；短目标拒绝且不写
    {
        static const int lp[] = {0, 1, 4, 10, 12}, per[] = {1, 2, 3, 4, 6};
        uint32_t src[64], got[64]; unsigned seed = 12345;
        for (int t = 0; t < 5; t++) for (size_t n = 0; n <= 40; n++) {
            for (size_t i = 0; i < n; i++) { seed = seed * 1103515245u + 12345u; src[i] = seed >> 8; }
            size_t want = n / (size_t)per[t] * (size_t)per[t];
            memset(got, 0xCD, sizeof got);
            char what[64]; snprintf(what, sizeof what, "列表快路 图元 %d 个数 %zu 字数", lp[t], n);
            eq_sz(what, nvn_geo_assemble(lp[t], src, n, 0, 0, got, 64), want);
            snprintf(what, sizeof what, "列表快路 图元 %d 个数 %zu 只计", lp[t], n);
            eq_sz(what, nvn_geo_assemble(lp[t], src, n, 0, 0, NULL, 0), want);
            snprintf(what, sizeof what, "列表快路 图元 %d 个数 %zu 内容", lp[t], n);
            if (want) eq_words(what, got, src, want);
            checks++; if (got[want] != 0xCDCDCDCDu) { fails++; printf("FAIL 列表快路 图元 %d 个数 %zu 写过界\n", lp[t], n); }
            if (want) { memset(got, 0xAA, sizeof got); snprintf(what, sizeof what, "列表快路 图元 %d 个数 %zu 短目标", lp[t], n);
                eq_sz(what, nvn_geo_assemble(lp[t], src, n, 0, 0, got, want - 1), SIZE_MAX);
                checks++; if (got[0] != 0xAAAAAAAAu) { fails++; printf("FAIL 列表快路短目标被部分写入\n"); } }
        }
        // 三角形列表 7 个索引：第 7 个丢弃；restart 开但没有 restart 值时与不开同结果（走原路）
        uint32_t t7[] = {9, 8, 7, 6, 5, 4, 3};
        eq_sz("三角形列表余数字数", nvn_geo_assemble(4, t7, 7, 0, 0, out, 32), 6); eq_words("三角形列表余数内容", out, t7, 6);
        eq_sz("restart 开无 restart 值字数", nvn_geo_assemble(4, t7, 7, 1, 0xFFFFFFFFu, out, 32), 6); eq_words("restart 开无 restart 值内容", out, t7, 6);
    }

    // 升序去重（nvn_geo_unique_sorted）：与「插入排序后去重」逐项相同；空 / 单个 / 全重复 / 跨大范围退回排序 / 位图边界 / 原地 / 随机
    {
        uq_case("空", NULL, 0, -1);
        const uint32_t one[] = {7}; uq_case("单个", one, 1, 1);
        const uint32_t dup[] = {5, 5, 5, 5, 5, 5}; uq_case("全重复", dup, 6, 1);
        const uint32_t wide[] = {0, 1u << 30, 5, 5, 1u << 30}; uq_case("跨大范围（退回排序）", wide, 5, 0);
        const uint32_t top[] = {UINT32_MAX, UINT32_MAX - 64, UINT32_MAX - 1}; uq_case("顶到 32 位上限", top, 3, 1);
        // 位图边界：字数 = 4n + 1024 恰好走位图，多 1 字退回排序（n = 2：最多 1032 字，跨度 1032 × 64）
        const uint32_t edge_ok[] = {100, 100 + 1032 * 64 - 1}; uq_case("位图边界恰好放得下", edge_ok, 2, 1);
        const uint32_t edge_no[] = {100, 100 + 1032 * 64}; uq_case("位图边界多一个字", edge_no, 2, 0);
        // 原地（dst = v）
        uint32_t inpl[] = {9, 3, 9, 1, 3, 200}, lo = 1, hi = 200; static uint64_t *bm2; static size_t bw2;
        size_t k = nvn_geo_unique_sorted(inpl, 6, lo, hi, inpl, &bm2, &bw2); const uint32_t w_in[] = {1, 3, 9, 200};
        eq_sz("升序去重 原地 个数", k, 4); eq_words("升序去重 原地 内容", inpl, w_in, 4);
        // 随机：2000 组，每组 1–3000 个、范围 1–200000（两条路都会走到）
        uint32_t seed = 12345, buf[3000]; int bad = 0, nbm = 0, nsort = 0;
        for (int r = 0; r < 2000; r++) {
            seed = seed * 1664525u + 1013904223u; size_t n = 1 + seed % 3000; seed = seed * 1664525u + 1013904223u; uint32_t span = 1 + seed % 200000, base = seed;
            for (size_t i = 0; i < n; i++) { seed = seed * 1664525u + 1013904223u; buf[i] = base + seed % span; if (buf[i] < base) buf[i] = base; }
            uint32_t l = UINT32_MAX, h = 0; for (size_t i = 0; i < n; i++) { if (buf[i] < l) l = buf[i]; if (buf[i] > h) h = buf[i]; }
            if (nvn_geo_unique_bitmap_ok(n, l, h)) nbm++; else nsort++;
            int before = fails; uq_case("随机", buf, n, -1); if (fails != before) bad++;
        }
        printf("升序去重随机 2000 组：位图 %d 组、排序 %d 组，不符 %d 组\n", nbm, nsort, bad);
    }
    if (fails) printf("✗ t_nvn_geometry_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_geometry_core：图元装配 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
