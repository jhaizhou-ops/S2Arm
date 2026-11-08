// nvn_hmap（graphics/nvn/gfx/nvn/nvn_hmap.h）对拍：8 字节键（10-29 起 nvn_hm_get 走按字比较的快路）和 20 字节键，随机 put / 覆盖 / del / clear，
//   每步后对全部候选键查 get，与朴素模型（线性数组：有没有、值是多少）逐个比。期望不依赖被测实现：模型只做数组查找。
//   另测 8 字节键的「连续序号」形态（贴图序号集合 g_cpu_tex 的真实用法）：6442 个连续序号进表，100 万次查不在表里的序号全部未命中
#include "../gfx/nvn/nvn_hmap.h"
#include <stdio.h>

enum { NK = 512 };
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; if (fails < 20) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } } while (0)

static uint64_t rng = 0x243f6a8885a308d3ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static void run(uint32_t klen) {
    static uint8_t keys[NK][20]; static void *model[NK];
    for (int i = 0; i < NK; i++) { for (uint32_t b = 0; b < klen; b++) keys[i][b] = (uint8_t)rnd(); model[i] = NULL; }
    for (int i = 1; i < NK; i++) if (!memcmp(keys[i], keys[i - 1], klen)) keys[i][0] ^= 0x5a;   // 防随机撞键（撞了模型就不对）
    nvn_hmap m; nvn_hm_init(&m, klen); uint64_t steps = 0;
    for (int round = 0; round < 40; round++) {
        for (int op = 0; op < 400; op++, steps++) {
            int k = (int)(rnd() % NK); uint64_t r = rnd() % 10;
            if (r < 6) { void *v = (void *)(uintptr_t)(rnd() | 1); void *old = nvn_hm_put(&m, keys[k], v); CHECK(old == model[k], "klen %u put 旧值不符（键 %d）", klen, k); model[k] = v; }
            else { void *old = nvn_hm_del(&m, keys[k]); CHECK(old == model[k], "klen %u del 旧值不符（键 %d）", klen, k); model[k] = NULL; }
        }
        uint32_t n = 0;
        for (int k = 0; k < NK; k++) { CHECK(nvn_hm_get(&m, keys[k]) == model[k], "klen %u 第 %d 轮 get 不符（键 %d）", klen, round, k); n += model[k] != NULL; }
        CHECK(m.n == n, "klen %u 第 %d 轮项数 %u ≠ 模型 %u", klen, round, m.n, n);
        if (round == 20) { nvn_hm_clear(&m, NULL); for (int k = 0; k < NK; k++) model[k] = NULL; }
    }
    free(m.keys); free(m.vals);
    printf("  klen %u：%llu 步随机 put / del + 每轮全键对拍\n", klen, (unsigned long long)steps);
}

int main(void) {
    run(8); run(20);
    nvn_hmap s; nvn_hm_init(&s, 8);
    for (uint64_t v = 1000; v < 1000 + 6442; v++) nvn_hm_put(&s, &v, (void *)1);
    uint64_t hit = 0, miss_bad = 0;
    for (uint64_t v = 1000; v < 1000 + 6442; v++) hit += nvn_hm_get(&s, &v) != NULL;
    for (uint64_t i = 0; i < 1000000; i++) { uint64_t v = 1000 + 6442 + i; miss_bad += nvn_hm_get(&s, &v) != NULL; }
    CHECK(hit == 6442 && miss_bad == 0, "连续序号：命中 %llu（应 6442）、不在表里却命中 %llu（应 0）", (unsigned long long)hit, (unsigned long long)miss_bad);
    free(s.keys); free(s.vals);
    if (fails) { printf("✗ t_hmap：%d 处不符\n", fails); return 1; }
    printf("✓ t_hmap：8 / 20 字节键随机对拍全符；连续序号 6442 进表、100 万次未命中全对\n");
    return 0;
}
