// 遮挡查询槽表折叠（11-05 王国之泪约 3.3 万帧后 visibility slot list 8 MiB 分配失败、std::bad_alloc）：生产 nvn_mtl.m 编进本 TU，真 Metal 缓冲。
// 期望（按 NVN 语义手算，不跑被测实现）：SAMPLES_PASSED 是自上次 ResetCounter 起的累计值；
//   ① 提交 1 的两个槽（5、7）完成后，环形缓冲被提交 2 复用并改写成 100，提交 2 自己的槽是 100 → 报告 = 5 + 7 + 100 = 112（旧实现读到改写后的值：300）；
//   ② 10 万次「一个提交一个槽、每次都报告、从不重置」→ 未完成的槽表始终 ≤ 1 项，最后报告累计 = 100000（旧实现槽表涨到 10 万项）。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 往槽表加一项：与 draw() 里计数开始时同一写法（缓冲 retain、围栏取 g_fence + 1）
static void push_slot(id<MTLBuffer> b, uint32_t slot) {
    if (g_nvs == g_vscap) { size_t c = g_vscap ? g_vscap * 2 : 64; REQUIRE(GROW(g_vs, c * sizeof *g_vs, "visibility slot list")); g_vscap = c; }
    g_vs[g_nvs++] = (vis_slot){(void *)CFBridgingRetain(b), slot, g_fence + 1};
}
// 报告完成时的求和：与 nvn_be_sub_commit 完成回调同一算法
static uint64_t consume(vis_list *l) {
    uint64_t sum = l->base;
    for (int k = 0; k < l->n; k++) { sum += ((const uint64_t *)((__bridge id<MTLBuffer>)l->s[k].buf).contents)[l->s[k].slot]; CFRelease(l->s[k].buf); }
    free(l); return sum;
}
static void complete(void) { g_fence++; g_done = g_fence; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); REQUIRE(dev);
        id<MTLBuffer> ring = [dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared]; REQUIRE(ring);
        uint64_t *v = ring.contents;

        vis_clear(); g_fence = 0; g_done = 0;
        v[0] = 5; v[1] = 7; push_slot(ring, 0); push_slot(ring, 1); complete();   // 提交 1
        vis_fold();                                                                // 提交 2 开始复用这块环形缓冲（sub begin）
        v[0] = 100; v[1] = 100; push_slot(ring, 0);                                // 提交 2 的 GPU 改写，再记自己的槽
        vis_list *l = vis_snapshot();
        VERIFY(l->base == 12 && l->n == 1, "① 报告时已完成的槽折进累计 12、未完成 1 项 → base=%llu n=%d", (unsigned long long)l->base, l->n);
        uint64_t sum = consume(l); complete();
        VERIFY(sum == 112, "① 报告值 = 5 + 7 + 100 = 112 → %llu", (unsigned long long)sum);

        vis_clear(); g_fence = 0; g_done = 0;
        int maxn = 0; uint64_t last = 0;
        for (int i = 0; i < 100000; i++) {
            vis_fold();                                   // sub begin
            v[0] = 1; push_slot(ring, 0);
            if (g_nvs > maxn) maxn = g_nvs;
            last = consume(vis_snapshot());
            complete();
        }
        VERIFY(maxn == 1, "② 只报告不重置 10 万次，未完成槽表最多 1 项 → %d", maxn);
        VERIFY(last == 100000, "② 最后一次报告累计 100000 → %llu", (unsigned long long)last);
        vis_clear();
    }
    printf("%s t_nvn_visfold %u/%u\n", failures ? "✗" : "✓", checks - failures, checks);
    return failures != 0;
}
