// 本次提交已用区间（gal_buf.m use_add / use_hit，精确区间集）单测：大于 4 MB 的缓冲（没有影子 / 补丁兜底）上，
// 写到已用区间之间没人用过的空隙走预载（不录进在录流、不切遍），写到用过的区间才录进在录流。期望按定义手算：
// 20 段互不相邻的读（超过旧实现的 8 段外包）→ 空隙写：预载 +1、在录流 +0；读过的段上写：在录流 +1；紧贴已用段的写（不相交）：预载；
// 跨两段的写：在录流。最后等 GPU 做完读回，各段内容 = 按命令顺序写进去的值
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
uint64_t gal_buf_read_gpu(uint32_t bid, int32_t offset, int32_t len);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { KB = 1024, SZ = 16 << 20, STEP = 64 * KB };
static uint8_t g_d[4 * KB];
static void put(uint32_t b, int off, int len, uint8_t v) { memset(g_d, v, (size_t)len); nxgal_buf_set_data(b, off, g_d, len); }
static void counts(uint64_t *pre, uint64_t *inl) { *pre = g_gp_n[GP_PRELOAD]; *inl = g_gp_n[GP_INLINEUP]; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    printf("· 16 MB 缓冲，20 段互不相邻的读：空隙写走预载、读过的段上写录进在录流；紧贴不相交走预载、跨两段录进在录流；读回按命令顺序\n");
    uint32_t b = nxgal_buf_create(SZ, 0);
    put(b, 0, 4 * KB, 0x01);
    nxgal_flush();
    gal_buf_read_gpu(b, 0, 4 * KB);   // 交出过地址：之后的写不再直写 CPU
    nxgal_flush();
    for (int k = 0; k < 20; k++) gal_buf_read_gpu(b, k * STEP, 4 * KB);   // 本次提交已用：[k·64K, k·64K + 4K)，k = 0..19
    uint64_t p0, i0, p1, i1;
    counts(&p0, &i0); put(b, 10 * STEP + 16 * KB, 4 * KB, 0x22); counts(&p1, &i1);
    CHECK(p1 - p0 == 1 && i1 - i0 == 0, "空隙写（第 10 段后 16 KB 处）：期望预载 +1 / 在录流 +0，实得 +%llu / +%llu", (unsigned long long)(p1 - p0), (unsigned long long)(i1 - i0));
    counts(&p0, &i0); put(b, 3 * STEP, 4 * KB, 0x33); counts(&p1, &i1);
    CHECK(p1 - p0 == 0 && i1 - i0 == 1, "读过的第 3 段上写：期望预载 +0 / 在录流 +1，实得 +%llu / +%llu", (unsigned long long)(p1 - p0), (unsigned long long)(i1 - i0));
    counts(&p0, &i0); put(b, 5 * STEP + 4 * KB, 4 * KB, 0x44); counts(&p1, &i1);
    CHECK(p1 - p0 == 1 && i1 - i0 == 0, "紧贴第 5 段之后（不相交）写：期望预载 +1 / 在录流 +0，实得 +%llu / +%llu", (unsigned long long)(p1 - p0), (unsigned long long)(i1 - i0));
    counts(&p0, &i0); memset(g_d, 0x55, sizeof g_d); nxgal_buf_set_data(b, 7 * STEP + 2 * KB, g_d, 4 * KB); counts(&p1, &i1);
    CHECK(p1 - p0 == 0 && i1 - i0 == 1, "跨进第 7 段尾的写：期望在录流 +1，实得预载 +%llu / 在录流 +%llu", (unsigned long long)(p1 - p0), (unsigned long long)(i1 - i0));
    nxgal_create_sync(1, 1); nxgal_wait_sync(1);
    uint8_t r[4 * KB];
    struct { int off; uint8_t v; const char *what; } ex[] = {{10 * STEP + 16 * KB, 0x22, "空隙"}, {3 * STEP, 0x33, "第 3 段"}, {5 * STEP + 4 * KB, 0x44, "紧贴第 5 段"}, {7 * STEP + 2 * KB, 0x55, "跨第 7 段尾"}, {0, 0x01, "第 0 段（只读过）"}};
    for (int k = 0; k < 5; k++) {
        nxgal_buf_get_data(b, ex[k].off, 4 * KB, r); int bad = 0; for (int i = 0; i < 4 * KB; i++) bad += r[i] != ex[k].v;
        CHECK(!bad, "读回 %s：期望全 %#x，%d 字节不符", ex[k].what, ex[k].v, bad);
    }
    nxgal_buf_delete(b);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
