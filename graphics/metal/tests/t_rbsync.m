// 读回按需同步单测（帧率能耗线 10-21，暗黑2 / 塞尔达读回阻塞根因）：读回只等「被读的那块内存」对应的 GPU 工作，不等别的已提交工作。
// 造法：主队列上排一道等测试事件（hold）的队列等待，其后提交一段与被读对象无关的工作——hold 不放，这段工作永远做不完；
// 放 hold：①②⑥（不该等无关工作）在读线程返回之后才放，计时线程只作 10 秒防卡死上限（实现错误地等了无关工作 → 读线程堵到 10 秒后放 hold 才返回、判红）；
// ④（必须等）计时线程 500 ms 后放。被读对象的 GPU 写在 hold 之前已提交并做完。
// 10-23 改：原先①②⑥也是 500 ms 定时放，机器负载高时一次正确的后台读回也可能超过 500 ms，被误判成「等了无关工作」（原生层线门禁偶发 13/14）
// 期望（按定义手算，不跑被测实现）：
//   ① 非录制线程读缓冲（Gpu 层 WaitForAndFlushRanges 已等过同步号之后的 GetBufferData）：返回时 hold 仍是 0（没等无关工作），内容 = 写进去的图样
//   ② 非录制线程读贴图（TextureGroup.FlushAction 的 GetData）：同上，hold 仍是 0、内容对
//   ③ 录制线程读缓冲，缓冲的写已提交且做完、在录命令缓冲里有无关工作：不为它提交在录命令缓冲（已提交栅栏不变），内容对
//   ④ 正对照：录制线程读缓冲，缓冲的 GPU 写在 hold 之后的提交里（未做完）：必须等到它做完——返回时 hold = 1，内容 = 新图样
//   ⑤ 正对照：录制线程读缓冲，写在在录命令缓冲里：提交并等完（已提交栅栏 +1），内容 = 新图样
//   ⑥ 同①②，但渲染线程刚提交、没有在录的命令缓冲：读线程仍按非渲染线程走，hold 仍是 0、内容对
// 旧实现：①②⑥在 hold 之后才返回（等全部已提交 / 读回命令缓冲排在主队列 hold 之后；⑥没在录时客体线程被当成录制线程 gal_finish），③多提交一次
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
extern id<MTL4CommandQueue> g_gq; extern id<MTLDevice> g_gdev;
uint64_t gal_buf_read_gpu(uint32_t bid, int32_t offset, int32_t len);
uint64_t gal_committed_fence(void);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { N = 4096, TW = 16, TH = 16 };
static uint64_t g_sync = 1000;
static void gpu_wait(void) { nxgal_create_sync(g_sync, 1); nxgal_wait_sync(g_sync); g_sync++; }
static uint32_t mkbuf(uint8_t seed) {
    uint32_t b = nxgal_buf_create(N, 0); uint8_t d[N]; for (int k = 0; k < N; k++) d[k] = (uint8_t)(k * 13 + seed);
    nxgal_buf_set_data(b, 0, d, N); return b;
}
static int pat_bad(const uint8_t *p, uint8_t seed) { int bad = 0; for (int k = 0; k < N; k++) bad += p[k] != (uint8_t)(k * 13 + seed); return bad; }

// hold：主队列排一道等它的队列等待；计时线程到期（ms）或被叫放（hold_release）时放
static id<MTLSharedEvent> g_hold;
static volatile int g_hold_now;
static void *releaser(void *a) { long ms = (long)a; for (long t = 0; t < ms && !g_hold_now; t++) usleep(1000); g_hold.signaledValue = 1; return NULL; }
static pthread_t hold_arm_ms(long ms) {
    g_hold = [g_gdev newSharedEvent]; g_hold.signaledValue = 0; g_hold_now = 0;
    [g_gq waitForEvent:g_hold value:1];
    pthread_t t; pthread_create(&t, NULL, releaser, (void *)ms); return t;
}
static pthread_t hold_arm(void) { return hold_arm_ms(10000); }   // ①②⑥：读线程返回后 hold_release；10 秒只是防卡死
static void hold_release(pthread_t t) { g_hold_now = 1; pthread_join(t, NULL); }
// 一段与被读对象无关、排在 hold 之后的已提交工作（C → D 拷贝）
static uint32_t g_c, g_d;
static void unrelated_commit(void) { nxgal_buf_copy(g_c, g_d, 0, 0, N); nxgal_flush(); }

// 在另一条线程上读（多线程后端里客体线程直调 GetBufferData / 贴图 GetData）
typedef struct { int tex; uint32_t id; uint8_t *out; uint64_t hold_at_return; } rd_arg;
static void *reader(void *p) {
    rd_arg *a = p;
    if (a->tex) nxgal_tex_get_data(a->id, -1, -1, a->out, TW * TH * 4); else nxgal_buf_get_data(a->id, 0, N, a->out);
    a->hold_at_return = g_hold.signaledValue; return NULL;
}
static void read_on_thread(rd_arg *a) { pthread_t t; pthread_create(&t, NULL, reader, a); pthread_join(t, NULL); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    g_c = mkbuf(1); g_d = mkbuf(2);
    gal_buf_read_gpu(g_c, 0, N); gal_buf_read_gpu(g_d, 0, N); nxgal_flush();   // 交出过地址：之后的写走 GPU

    printf("· ① 非录制线程读缓冲：缓冲的 GPU 写已做完，主队列后面堵着无关工作 → 不等无关工作\n");
    {
        uint32_t s = mkbuf(0x40), a = mkbuf(0); gal_buf_read_gpu(a, 0, N); nxgal_flush();
        nxgal_buf_copy(s, a, 0, 0, N); gpu_wait();               // a 的 GPU 写：已提交、已做完
        pthread_t rel = hold_arm(); unrelated_commit();
        nxgal_buf_copy(g_c, g_d, 0, 0, N);                       // 主线程开着在录命令缓冲（读线程是非渲染线程）
        uint8_t out[N]; rd_arg r = {0, a, out, 9}; read_on_thread(&r);
        CHECK(r.hold_at_return == 0, "非录制线程读缓冲：期望返回时 hold 仍为 0（没等无关工作），实得 %llu", (unsigned long long)r.hold_at_return);
        CHECK(!pat_bad(out, 0x40), "非录制线程读缓冲：内容 %d 字节不符", pat_bad(out, 0x40));
        hold_release(rel); gpu_wait();
        nxgal_buf_delete(s); nxgal_buf_delete(a);
    }

    printf("· ② 非录制线程读贴图：贴图写已做完，主队列后面堵着无关工作 → 不等无关工作\n");
    {
        nxgal_tex_info ti = {TW, TH, 1, 1, 1, 1, 1, 4, 36 /* R8G8B8A8Unorm */, 0, 1 /* 2D */, {2, 3, 4, 5}};
        uint32_t t = nxgal_tex_create(&ti); uint8_t px[TW * TH * 4]; for (int k = 0; k < (int)sizeof px; k++) px[k] = (uint8_t)(k * 5 + 7);
        nxgal_tex_set_data(t, -1, -1, NULL, px, sizeof px); gpu_wait();
        pthread_t rel = hold_arm(); unrelated_commit();
        nxgal_buf_copy(g_c, g_d, 0, 0, N);
        uint8_t out[TW * TH * 4]; memset(out, 0, sizeof out); rd_arg r = {1, t, out, 9}; read_on_thread(&r);
        CHECK(r.hold_at_return == 0, "非录制线程读贴图：期望返回时 hold 仍为 0（没等无关工作），实得 %llu", (unsigned long long)r.hold_at_return);
        CHECK(!memcmp(out, px, sizeof px), "非录制线程读贴图：内容不符");
        hold_release(rel); gpu_wait();
        nxgal_tex_release(t);
    }

    printf("· ⑥ 同①②，但渲染线程刚提交、没有在录命令缓冲（暗黑2 客体线程回写阴影贴图时的情形）：读线程仍不是渲染线程，不等无关工作\n");
    for (int tex = 0; tex < 2; tex++) {
        nxgal_tex_info ti = {TW, TH, 1, 1, 1, 1, 1, 4, 36, 0, 1, {2, 3, 4, 5}};
        uint32_t s = mkbuf(0x30), a = mkbuf(0), t = 0; uint8_t px[TW * TH * 4]; for (int k = 0; k < (int)sizeof px; k++) px[k] = (uint8_t)(k * 3 + 1);
        gal_buf_read_gpu(a, 0, N); nxgal_flush();
        if (tex) { t = nxgal_tex_create(&ti); nxgal_tex_set_data(t, -1, -1, NULL, px, sizeof px); } else nxgal_buf_copy(s, a, 0, 0, N);
        gpu_wait();
        pthread_t rel = hold_arm(); unrelated_commit();          // 提交完不再录：没有在录命令缓冲
        uint8_t out[N]; memset(out, 0, sizeof out); rd_arg r = {tex, tex ? t : a, out, 9}; read_on_thread(&r);
        CHECK(r.hold_at_return == 0, "无在录时非渲染线程读%s：期望返回时 hold 仍为 0，实得 %llu", tex ? "贴图" : "缓冲", (unsigned long long)r.hold_at_return);
        CHECK(tex ? !memcmp(out, px, sizeof px) : !pat_bad(out, 0x30), "无在录时非渲染线程读%s：内容不符", tex ? "贴图" : "缓冲");
        hold_release(rel); gpu_wait();
        if (t) nxgal_tex_release(t);
        nxgal_buf_delete(s); nxgal_buf_delete(a);
    }

    printf("· ③ 录制线程读缓冲：写已做完、在录命令缓冲里只有无关工作 → 不为它提交\n");
    {
        uint32_t s = mkbuf(0x50), a = mkbuf(0); gal_buf_read_gpu(a, 0, N); nxgal_flush();
        nxgal_buf_copy(s, a, 0, 0, N); gpu_wait();
        nxgal_buf_copy(g_c, g_d, 0, 0, N);                       // 在录命令缓冲里的无关工作
        uint64_t f0 = gal_committed_fence(); uint8_t out[N]; nxgal_buf_get_data(a, 0, N, out);
        CHECK(gal_committed_fence() == f0, "录制线程读已做完的缓冲：期望不提交（已提交栅栏 %llu 不变），实得 %llu", (unsigned long long)f0, (unsigned long long)gal_committed_fence());
        CHECK(!pat_bad(out, 0x50), "录制线程读已做完的缓冲：内容 %d 字节不符", pat_bad(out, 0x50));
        gpu_wait(); nxgal_buf_delete(s); nxgal_buf_delete(a);
    }

    printf("· ④ 正对照：录制线程读缓冲，它的 GPU 写排在 hold 之后（已提交未做完）→ 必须等它做完\n");
    {
        uint32_t s = mkbuf(0x60), a = mkbuf(0); gal_buf_read_gpu(a, 0, N); nxgal_flush(); gpu_wait();
        pthread_t rel = hold_arm_ms(500);   // 必须等：计时放
        nxgal_buf_copy(s, a, 0, 0, N); nxgal_flush();            // a 的写在 hold 之后
        uint8_t out[N]; nxgal_buf_get_data(a, 0, N, out); uint64_t h = g_hold.signaledValue;
        CHECK(h == 1, "录制线程读未做完的缓冲：期望等到写做完（返回时 hold = 1），实得 %llu", (unsigned long long)h);
        CHECK(!pat_bad(out, 0x60), "录制线程读未做完的缓冲：内容 %d 字节不符", pat_bad(out, 0x60));
        pthread_join(rel, NULL); gpu_wait(); nxgal_buf_delete(s); nxgal_buf_delete(a);
    }

    printf("· ⑤ 正对照：录制线程读缓冲，写在在录命令缓冲里 → 提交并等完\n");
    {
        uint32_t s = mkbuf(0x70), a = mkbuf(0); gal_buf_read_gpu(a, 0, N); nxgal_flush(); gpu_wait();
        nxgal_buf_copy(s, a, 0, 0, N);                           // 在录
        uint64_t f0 = gal_committed_fence(); uint8_t out[N]; nxgal_buf_get_data(a, 0, N, out);
        CHECK(gal_committed_fence() == f0 + 1, "录制线程读在录写的缓冲：期望提交一次（已提交栅栏 %llu → %llu），实得 %llu", (unsigned long long)f0, (unsigned long long)f0 + 1, (unsigned long long)gal_committed_fence());
        CHECK(!pat_bad(out, 0x70), "录制线程读在录写的缓冲：内容 %d 字节不符", pat_bad(out, 0x70));
        nxgal_buf_delete(s); nxgal_buf_delete(a);
    }

    nxgal_buf_delete(g_c); nxgal_buf_delete(g_d);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
