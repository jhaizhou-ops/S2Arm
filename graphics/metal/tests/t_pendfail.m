// 镜像拷回失败（gal_buf.m pend_flush，审计 #846 F-pend-flush-drop）单测：提交前把待拷回段（pend）拷回真缓冲时暂存块建不出，
// 没拷成的段必须留在 pend 里（影子还在，下次提交 / 非镜像用到前重拷），不能当成「全部拷完」清掉——清掉后真缓冲永远停在 CPU 写之前的字节。
// 造法：4 MB 缓冲（影子上限）整块写进已用区间 → pend [0, 4 MB)；单测进程里还没有暂存块（之前的写都是没碰过的直写），
//   拷回要新建 4 MB 暂存块——此刻注入建缓冲失败（gal_newbuf_test_fail），stg_alloc 返回 nil。
// 期望（手算，不跑被测实现）：撤注入后下一次 GPU 拷贝从这块缓冲读到的是 CPU 写进去的 0x11（修前读到写前的 0x00）。
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
enum { SZ = 4 << 20 };
static uint8_t *g_d;
static void put(uint32_t b, int off, int len, uint8_t v) { memset(g_d, v, (size_t)len); nxgal_buf_set_data(b, off, g_d, len); }
static int bad(uint32_t b, int off, int len, uint8_t v) { nxgal_buf_get_data(b, off, len, g_d); int n = 0; for (int i = 0; i < len; i++) n += g_d[i] != v; return n; }
static uint32_t g_sync = 1;
static void quiet(void) { nxgal_create_sync(g_sync, 1); nxgal_wait_sync(g_sync); g_sync++; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    g_d = malloc(SZ);
    printf("· 4 MB 缓冲整块镜像写（pend [0, 4 MB)），提交前拷回时暂存块建不出：没拷成的段留着，下次重拷；GPU 之后读到 CPU 写的值\n");
    uint32_t B = nxgal_buf_create(SZ, 0), D = nxgal_buf_create(4096, 0);
    put(B, 0, SZ, 0x00);
    gal_buf_read_gpu(B, 0, 16); nxgal_flush(); quiet();   // 交出过地址、GPU 做完：之后可建影子
    gal_buf_read_gpu(B, 0, 16);                     // 本次提交已用 [0, 16)
    uint64_t m0 = g_gp_n[GP_MIRRORW];
    put(B, 0, SZ, 0x11);                            // 命中已用：建影子、整块记 pend
    CHECK(g_gp_n[GP_MIRRORW] - m0 == 1, "造法前提：期望镜像写 +1，实得 +%llu", (unsigned long long)(g_gp_n[GP_MIRRORW] - m0));
    gal_newbuf_test_fail = 1; nxgal_flush(); gal_newbuf_test_fail = 0;   // 提交前拷回：4 MB 暂存块建不出
    quiet();
    nxgal_buf_copy(B, D, 0, 0, 4096);               // GPU 读 B（非镜像用法：先拷回 pend）→ D
    nxgal_flush(); quiet();
    int nb = bad(D, 0, 4096, 0x11);
    CHECK(nb == 0, "拷回失败之后 GPU 读 B 期望全是 CPU 写的 0x11，实得 %d / 4096 字节不是（读到写前的旧字节 = 失败段被当成拷完清掉）", nb);
    nxgal_buf_delete(B); nxgal_buf_delete(D);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
