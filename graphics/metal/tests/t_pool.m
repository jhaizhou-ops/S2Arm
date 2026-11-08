// 线程自动释放池轮换（nxgal_pool_cycle）单测。C# 线程没有释放池，用新起的 pthread 模拟（主线程有隐式池且轮换不做事）。
// ① 正对照（不轮换）：线程里「建 2 MB 缓冲 → 清 16 字节 → 读回 4 字节 → 删」50 次、推进几次提交后，Metal 已分配 +100 MB（读回入口留下的自动释放引用让缓冲放不掉）
// ② 每次操作后在最外层轮换：同样 50 次，Metal 已分配增量 < 1 MB
// ③ 主线程上调：不做事（轮换计数不变）
// 期望值按 50 × 2 MB 手算。
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <pthread.h>
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
void gal_finish(void);
extern uint64_t g_pool_cycles;
static uint32_t g_st;
// 推进提交让延后释放落地（同 t_tex 租约用例的 SETTLE）：往 1×1 贴图（格式 36 = R8G8B8A8Unorm）传一个像素必进在录命令缓冲，再 gal_finish
static void settle(void) {
    nxgal_rect r1 = {0, 0, 1, 1}; uint8_t px[4] = {0};
    for (int i = 0; i < 10; i++) { nxgal_tex_set_data(g_st, 0, 0, &r1, px, 4); gal_finish(); }
}
static int64_t g_delta[2];
static void *worker(void *arg) {
    int cyc = (int)(intptr_t)arg; uint8_t got[4];
    settle(); if (cyc) nxgal_pool_cycle();
    int64_t m0 = (int64_t)g_gdev.currentAllocatedSize;
    for (int i = 0; i < 50; i++) {
        uint32_t t = nxgal_buf_create(2 << 20, 0); nxgal_buf_clear(t, 0, 16, 0); nxgal_buf_get_data(t, 0, 4, got); nxgal_buf_delete(t);
        if (cyc) nxgal_pool_cycle();
    }
    settle(); if (cyc) nxgal_pool_cycle(); settle();
    g_delta[cyc] = (int64_t)g_gdev.currentAllocatedSize - m0;
    return NULL;
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    nxgal_tex_info ti = {1, 1, 1, 1, 1, 1, 1, 4, 36, 0, 1, {2, 3, 4, 5}}; g_st = nxgal_tex_create(&ti);
    printf("· 线程释放池轮换：无池线程建 → 读回 → 删 50 个 2 MB 缓冲，不轮换漏 100 MB、每次操作后轮换不漏；主线程上不做事\n");
    for (int k = 0; k < 2; k++) { pthread_t th; pthread_create(&th, NULL, worker, (void *)(intptr_t)k); pthread_join(th, NULL); }
    CHECK(g_delta[0] >= (99 << 20) && g_delta[0] <= (101 << 20), "① 正对照（不轮换）期望 Metal 已分配 +100 MB（± 1），实得 %+.1f MB", g_delta[0] / 1048576.0);
    CHECK(g_delta[1] < (1 << 20), "② 轮换后期望增量 < 1 MB，实得 %+.1f MB", g_delta[1] / 1048576.0);
    uint64_t c0 = g_pool_cycles; nxgal_pool_cycle();
    CHECK(g_pool_cycles == c0, "③ 主线程上调期望不做事（计数不变），实得 +%llu", (unsigned long long)(g_pool_cycles - c0));
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail != 0;
}
