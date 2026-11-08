// GPU 写按区间作废（gal_buf.m sx，缺省开，NXGAL_GW_RANGE=0 关）单测：同一块 768 KB 缓冲上，GPU 写 [64K, 128K)（在录流里的缓冲拷贝）之后，
// CPU 写别处已用区间：开着 → 走镜像（影子留着，在录流 +0）；关着 → 影子整块丢掉，录进在录流 +1（反证：去掉区间作废即失败）。
// 读回按命令顺序（期望手算）：GPU 写段 = 源的 0xAB（影子在那里是旧的 0，读到 0 即错）、CPU 写段 = 最后写进去的值；
// 只读绑定同时读到待拷回段与 GPU 写段 → 退影子，读回仍对。GPU 写都录在还没提交的在录命令缓冲里，读前必在途
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
uint64_t gal_buf_read_gpu(uint32_t bid, int32_t offset, int32_t len);
extern int gal_gwr_test;
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { KB = 1024, SZ = 768 * KB, WLO = 64 * KB, WN = 64 * KB };
static uint8_t g_d[WN];
static void put(uint32_t b, int off, int len, uint8_t v) { memset(g_d, v, (size_t)len); nxgal_buf_set_data(b, off, g_d, len); }
static int all(uint32_t b, int off, int len, uint8_t v) { static uint8_t r[WN]; nxgal_buf_get_data(b, off, len, r); int bad = 0; for (int i = 0; i < len; i++) bad += r[i] != v; return bad; }
static uint32_t g_sync = 1;
static void quiet(void) { nxgal_create_sync(g_sync, 1); nxgal_wait_sync(g_sync); g_sync++; }

// 一轮：返回 GPU 写之后那次 CPU 写的在录流增量
static uint64_t round_(int on, uint32_t S) {
    gal_gwr_test = on;
    put(S, 0, WN, 0xAB); nxgal_flush(); quiet();
    uint32_t B = nxgal_buf_create(SZ, 0);
    put(B, 0, WN, 0x00); put(B, WLO, WN, 0x00);
    gal_buf_read_gpu(B, 0, 4 * KB); nxgal_flush(); quiet();      // 交出过地址、GPU 做完：之后可建影子
    gal_buf_read_gpu(B, 0, 4 * KB);                               // 本次提交已用 [0, 4K)
    put(B, 0, 4 * KB, 0x11);                                      // 命中已用：建影子、走镜像
    gal_buf_read_gpu(B, WLO, WN);                                 // 已用 W：下面的拷贝不挪进预载，录在在录流
    nxgal_buf_copy(S, B, 0, WLO, WN);                             // GPU 写 [64K, 128K) = 0xAB
    gal_buf_read_gpu(B, 0, 4 * KB);
    uint64_t i0 = g_gp_n[GP_INLINEUP], m0 = g_gp_n[GP_MIRRORW];
    put(B, 16, 16, 0x22);                                         // CPU 写别处的已用区间
    uint64_t di = g_gp_n[GP_INLINEUP] - i0, dm = g_gp_n[GP_MIRRORW] - m0;
    if (on) CHECK(dm == 1, "开：GPU 写别段之后的 CPU 写期望走镜像 +1，实得 +%llu（在录流 +%llu）", (unsigned long long)dm, (unsigned long long)di);
    // 边界（区间半开）：紧贴 GPU 写段末尾 [128K, 128K + 16) 不相交 → 开时走镜像；跨进末字节 [128K − 1, 128K + 1) 相交 → 退影子、不走镜像
    gal_buf_read_gpu(B, WLO + WN, 4 * KB);
    m0 = g_gp_n[GP_MIRRORW]; put(B, WLO + WN, 16, 0x55); uint64_t dadj = g_gp_n[GP_MIRRORW] - m0;
    if (on) CHECK(dadj == 1, "开：紧贴 GPU 写段末尾（不相交）期望走镜像 +1，实得 +%llu", (unsigned long long)dadj);
    m0 = g_gp_n[GP_MIRRORW]; put(B, WLO + WN - 1, 2, 0x66); uint64_t dx = g_gp_n[GP_MIRRORW] - m0;
    CHECK(dx == 0, "%s：跨进 GPU 写段末字节（相交）期望不走镜像，实得镜像 +%llu", on ? "开" : "关", (unsigned long long)dx);
    // 同一绑定跨待拷回段（[16, 32)）与 GPU 写段：退影子
    gal_buf_read_gpu(B, 0, WLO + WN);
    nxgal_flush(); quiet();
    CHECK(!all(B, WLO, WN - 1, 0xAB) && !all(B, WLO + WN - 1, 2, 0x66) && !all(B, WLO + WN + 1, 15, 0x55), "%s：GPU 写段读回期望 0xAB（末字节被后写的 0x66 盖）、其后 0x66 / 0x55", on ? "开" : "关");
    CHECK(!all(B, 0, 16, 0x11) && !all(B, 16, 16, 0x22) && !all(B, 32, 4 * KB - 32, 0x11), "%s：CPU 写段读回期望 0x11 / [16,32) 0x22", on ? "开" : "关");
    // 第二轮：GPU 写段做完后影子回填，再读 / 写 GPU 写段按序
    gal_buf_read_gpu(B, 0, 4 * KB);
    uint64_t m1 = g_gp_n[GP_MIRRORW]; put(B, 0, 16, 0x33);         // 重建影子（前面退过）
    if (on) CHECK(g_gp_n[GP_MIRRORW] - m1 == 1, "开：退影子做完后重建、走镜像 +1，实得 +%llu", (unsigned long long)(g_gp_n[GP_MIRRORW] - m1));
    put(S, 0, WN, 0xCD); nxgal_flush(); quiet();                   // 源换值：读到旧影子（0xAB 或更早）即错
    gal_buf_read_gpu(B, 0, 4 * KB); put(B, 0, 16, 0x33);
    gal_buf_read_gpu(B, WLO, WN); nxgal_buf_copy(S, B, 0, WLO, WN);
    CHECK(!all(B, WLO, WN, 0xCD), "%s：影子在、GPU 写段在途时读这段，期望等 GPU 读到 0xCD（不读过期影子）", on ? "开" : "关");
    gal_buf_read_gpu(B, WLO, WN); nxgal_buf_copy(S, B, 0, WLO, WN);
    put(B, WLO + 8, 8, 0x44);                                     // 写进 GPU 写在途段：退影子、排在拷贝之后
    nxgal_flush(); quiet();
    CHECK(!all(B, WLO, 8, 0xCD) && !all(B, WLO + 8, 8, 0x44) && !all(B, WLO + 16, WN - 16, 0xCD), "%s：GPU 写段里后写的 CPU 值期望盖在拷贝之上", on ? "开" : "关");
    CHECK(!all(B, 0, 16, 0x33), "%s：重建影子后的 CPU 写读回期望 0x33", on ? "开" : "关");
    nxgal_buf_delete(B);
    return di;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    printf("· 768 KB 缓冲：GPU 写 [64K, 128K) 后 CPU 写 [16, 32)：区间作废开走镜像、关录进在录流；读回按命令顺序；GPU 写都在未提交的在录命令缓冲里（在途）\n");
    uint32_t S = nxgal_buf_create(WN, 0); put(S, 0, WN, 0xAB); nxgal_flush(); quiet();
    uint64_t on = round_(1, S), off = round_(0, S);
    CHECK(on == 0 && off == 1, "在录流增量期望 开 +0 / 关 +1（关是反证：没有区间作废就切遍），实得 +%llu / +%llu", (unsigned long long)on, (unsigned long long)off);
    gal_gwr_test = -1;
    nxgal_buf_delete(S);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
