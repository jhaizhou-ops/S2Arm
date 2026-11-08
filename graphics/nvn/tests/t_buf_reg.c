// nvn_buf_reg（graphics/nvn/gfx/nvn/nvn_buf_reg.h，活 nvnBuffer 区间表）对拍。
//   ① 对拍：小地址空间里随机登记 / 同起点改长度 / 注销（含注销不存在的起点、起点 0、长度 0），区间大量重叠；每轮对全部候选地址查询，
//      与朴素模型（线性数组：所有包含该地址的活项里取起点最大的）逐个比。期望只由模型的数组扫描得出，不跑被测实现。
//   ② 定点用例：嵌套 / 首尾边界 / 终点饱和 / 改长度后旧范围不再命中。
//   性能（增长率）回归在 t_nvn_bufreg_rate.m：经 hle_nvn.c 公开入口量 N / 4N 耗时比，不设绝对耗时上限。
#include "../gfx/nvn/nvn_buf_reg.h"
#include <stdio.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; if (fails < 20) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } } while (0)
static uint64_t rng = 0x243f6a8885a308d3ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

enum { MK = 160 };   // 模型最多活项数（起点取 1..MK*4 的小空间，保证大量重叠）
static struct { uint64_t base, size; } model[MK * 4 + 1]; static int mn;
static void m_put(uint64_t b, uint64_t n) {
    if (!b || !n) return;
    for (int i = 0; i < mn; i++) if (model[i].base == b) { model[i].size = n; return; }
    model[mn].base = b; model[mn].size = n; mn++;
}
static void m_del(uint64_t b) { for (int i = 0; i < mn; i++) if (model[i].base == b) { model[i] = model[--mn]; return; } }
static int m_find(uint64_t a, uint64_t *b, uint64_t *n) {
    int best = -1;
    for (int i = 0; i < mn; i++) {
        uint64_t e = model[i].base + model[i].size; if (e < model[i].base) e = UINT64_MAX;
        if (a >= model[i].base && a < e && (best < 0 || model[i].base > model[best].base)) best = i;
    }
    if (best < 0) return 0;
    *b = model[best].base; *n = model[best].size; return 1;
}

static void fuzz(void) {
    nvn_breg t; nvn_breg_init(&t);
    const uint64_t SPACE = MK * 4;
    for (int round = 0; round < 300; round++) {
        for (int op = 0; op < 200; op++) {
            uint64_t r = rnd() % 10, b = rnd() % (SPACE + 1);   // b 可能为 0：起点 0 不登记
            if (r < 5 && mn < MK) { uint64_t n = rnd() % 8 ? rnd() % 64 : rnd() % 600; CHECK(nvn_breg_put(&t, b, n), "put 失败"); m_put(b, n); }   // n 可能为 0：长度 0 不登记
            else if (r < 6 && mn) { int i = (int)(rnd() % (uint64_t)mn); uint64_t n = 1 + rnd() % 64; nvn_breg_put(&t, model[i].base, n); m_put(model[i].base, n); }   // 同起点改长度
            else { nvn_breg_del(&t, b); m_del(b); }   // 含注销不存在的起点
        }
        CHECK(t.n == (uint32_t)mn, "第 %d 轮项数 %u ≠ 模型 %d", round, t.n, mn);
        for (uint64_t a = 0; a <= SPACE + 700; a++) {
            uint64_t eb = 0, en = 0, gb = 7, gn = 7;
            int e = m_find(a, &eb, &en), g = nvn_breg_find(&t, a, &gb, &gn);
            CHECK(e == g && (!e || (eb == gb && en == gn)), "第 %d 轮地址 %llu：期望 %d{%llu,%llu} 实得 %d{%llu,%llu}", round,
                  (unsigned long long)a, e, (unsigned long long)eb, (unsigned long long)en, g, (unsigned long long)gb, (unsigned long long)gn);
        }
        if (round == 150) { while (mn) { nvn_breg_del(&t, model[0].base); m_del(model[0].base); } CHECK(t.n == 0 && t.root == 0, "清空后不空"); }
    }
    nvn_breg_free(&t);
}

static void fixed(void) {
    nvn_breg t; nvn_breg_init(&t); uint64_t b, n;
    nvn_breg_put(&t, 0x1000, 0x10000);   // 大缓冲
    nvn_breg_put(&t, 0x2000, 0x100);     // 嵌在里面的小缓冲
    CHECK(nvn_breg_find(&t, 0x2080, &b, &n) && b == 0x2000 && n == 0x100, "嵌套：应取起点最近的小缓冲");
    CHECK(nvn_breg_find(&t, 0x2100, &b, &n) && b == 0x1000 && n == 0x10000, "小缓冲终点（开区间）应落回大缓冲");
    CHECK(nvn_breg_find(&t, 0x1000, &b, &n) && b == 0x1000, "起点本身命中");
    CHECK(!nvn_breg_find(&t, 0x11000, &b, &n), "大缓冲终点不命中");
    CHECK(!nvn_breg_find(&t, 0xfff, &b, &n), "起点前一字节不命中");
    nvn_breg_put(&t, 0x2000, 0x10);      // 同起点改短
    CHECK(nvn_breg_find(&t, 0x2080, &b, &n) && b == 0x1000, "改短后旧范围应落回大缓冲");
    nvn_breg_del(&t, 0x1000);
    CHECK(!nvn_breg_find(&t, 0x2080, &b, &n) && nvn_breg_find(&t, 0x2008, &b, &n) && b == 0x2000 && n == 0x10, "注销大缓冲后只剩小缓冲");
    nvn_breg_del(&t, 0x9999);            // 不存在：无事
    CHECK(t.n == 1, "注销不存在的项改了项数");
    nvn_breg_put(&t, UINT64_MAX - 4, 100);   // 终点饱和
    CHECK(nvn_breg_find(&t, UINT64_MAX - 1, &b, &n) && b == UINT64_MAX - 4 && n == 100, "终点溢出应饱和");
    nvn_breg_put(&t, 0, 100); nvn_breg_put(&t, 0x50, 0);
    CHECK(t.n == 2 && !nvn_breg_find(&t, 0x50, &b, &n), "起点 0 / 长度 0 不应登记");
    nvn_breg_free(&t);
}

int main(void) {
    fixed(); fuzz();
    if (fails) { printf("✗ t_buf_reg：%d 处不符\n", fails); return 1; }
    printf("✓ t_buf_reg：定点用例与 300 轮随机对拍全符\n");
    return 0;
}
