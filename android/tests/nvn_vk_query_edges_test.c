// 遮挡查询环形页的边界回归（宿主，无真机/无真 Vulkan：Vulkan 调桩提供已知结果）。
// 覆盖：reset 范围、同批多 pass 累计（页满前在 pass 边界合法换页）、段日志压缩、长期不 Reset、
// 会话重建。用法：nvn_vk_query_edges_test <case>；退出 0 = 该 case 通过。
// 每个 case 单进程（静态状态干净），由 tools/nvn_vk_query_edges.sh 逐个跑。
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include "nvn_vk_query.h"

// ---- Vulkan 桩（只提供类型/结果/完成时机，不模拟驱动开销）----
static unsigned long g_reset_calls, g_reset_slots, g_destroy_calls;
int nvn_vk_query_terminal_ready(void);
int __system_property_get(const char *n, char *v) { (void)n; v[0] = 0; return 0; }
int __android_log_print(int p, const char *t, const char *f, ...) { (void)p; (void)t; (void)f; return 0; }
VKAPI_ATTR VkResult VKAPI_CALL vkCreateQueryPool(VkDevice d, const VkQueryPoolCreateInfo *c,
                                                 const VkAllocationCallbacks *a, VkQueryPool *p) {
    (void)d; (void)c; (void)a; static unsigned next; *p = (VkQueryPool)(uintptr_t)(++next); return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL vkDestroyQueryPool(VkDevice d, VkQueryPool p, const VkAllocationCallbacks *a) { (void)d; (void)p; (void)a; g_destroy_calls++; }
VKAPI_ATTR void VKAPI_CALL vkCmdResetQueryPool(VkCommandBuffer c, VkQueryPool p, uint32_t f, uint32_t n) {
    (void)c; (void)p; (void)f; g_reset_calls++; g_reset_slots += n;
}
VKAPI_ATTR void VKAPI_CALL vkCmdBeginQuery(VkCommandBuffer c, VkQueryPool p, uint32_t q, VkQueryControlFlags f) { (void)c; (void)p; (void)q; (void)f; }
VKAPI_ATTR void VKAPI_CALL vkCmdEndQuery(VkCommandBuffer c, VkQueryPool p, uint32_t q) { (void)c; (void)p; (void)q; }
static unsigned long g_get_calls;
VKAPI_ATTR VkResult VKAPI_CALL vkGetQueryPoolResults(VkDevice d, VkQueryPool p, uint32_t f, uint32_t n, size_t sz,
                                                     void *data, VkDeviceSize st, VkQueryResultFlags fl) {
    (void)d; (void)p; (void)f; (void)sz; (void)fl;
    g_get_calls++;
    for (uint32_t i = 0; i < n; i++) *(uint64_t *)((unsigned char *)data + i * st) = 11;  // 每槽 11
    return VK_SUCCESS;
}
static int wg(void *o, uint64_t a, const void *p, size_t n) { (void)o; memcpy((void *)(uintptr_t)a, p, n); return 0; }

// 合并进来的 TIMESTAMP_TOP 段要用的几个入口：本用例不测时间戳，桩成“没有校准扩展”。
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice ph, uint32_t *n,
                                                                    VkQueueFamilyProperties *q) {
    (void)ph; if (n) *n = 0; (void)q;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance i, const char *n) { (void)i; (void)n; return NULL; }
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d, const char *n) { (void)d; (void)n; return NULL; }
VKAPI_ATTR void VKAPI_CALL vkCmdWriteTimestamp(VkCommandBuffer c, VkPipelineStageFlagBits st, VkQueryPool p, uint32_t q) {
    (void)c; (void)st; (void)p; (void)q;
}
#include <stdatomic.h>
#include "nvn_vk_query.c"

// 帧队列桩（P0-leak ③）：页耗尽回收必须走“有界等待、可重试”的 flush_ready(budget>0)，
// 不许用 5 s 超时即终态语义的 nvn_vk_first_draw_flush()。
static int g_flush_ready_calls, g_flush_ready_bounded, g_flush_terminal_calls;
// 默认按“等待成功”模拟：既有用例（sync_retire / sync_forgot）验的是退休接线，页耗尽时的回收应当
// 成功（与改动前的 flush() 桩返回 0 等价）。专门验 P0-leak ③ 的 page_exhaust 自己把返回值设成 1。
static int g_flush_ready_rc = 0;   // 1 = 预算内没拿到完成证明（资源保留）；0 = 全部已完成
int nvn_vk_first_draw_flush_ready(int64_t budget_ns) {
    g_flush_ready_calls++;
    if (budget_ns > 0) g_flush_ready_bounded++;
    return g_flush_ready_rc;
}
int nvn_vk_first_draw_flush(void) { g_flush_terminal_calls++; return 0; }   // 终态入口：页耗尽路径禁止调用
// 以下替身只为 macOS（Mach-O）链接：那边不许留未定义的弱符号（Linux/ELF 允许 NULL 弱引用）。
// 本用例不测时间戳与帧号，桩返回值不参与断言。
uint64_t guest_ns(void) { return 0; }
uint64_t guest_tick(void) { return 0; }
uint64_t now_ns(void) { return 0; }
int nvn_vk_first_draw_timestamp_top(struct s2a_vk_device *d, VkQueryPool pool, uint32_t slot,
                                    char *why, size_t why_size) {
    (void)d; (void)pool; (void)slot; (void)why; (void)why_size; return 0;
}
uint64_t nvn_vk_first_draw_frame_id(void) { return 0; }

static struct s2a_vk_device D;
static VkCommandBuffer C = (VkCommandBuffer)(uintptr_t)2;
static char why[256];
static struct s2a_record_memory mem = { .write = wg };

static void init(void) { D.device = (VkDevice)(uintptr_t)1; D.core_features.occlusionQueryPrecise = VK_TRUE; nvn_vk_query_reset_run(&D, why, sizeof why); }

// 一条命令缓冲的“开头”按生产顺序走：先 prepare（页选择 / 页耗尽回收，可能 flush 帧队列），
// 之后才在已开始的命令缓冲上录 query pool reset。生产接线：nvn_vk_first_draw.c:2924 在
// fd_cmd_get/vkBeginCommandBuffer **之前**调 prepare，:2958 在命令缓冲已开始之后调 cb_begin。
// 拆分原因见 nvn_vk_query.c:336-340：回收会 flush 并封口当前批次的命令缓冲，若那条缓冲已经
// vkBeginCommandBuffer，提交后再往上录命令会直接崩（真机 SIGSEGV fault 0x74）。夹具里的 C 是常量
// “已取得的命令缓冲”，所以这里能断言的只有调用顺序：prepare 必须是每条命令缓冲的第一个查询调用，
// cb_begin 在其后；page_exhaust 也正是靠这个顺序才会走到 prepare 里的 flush_ready(budget) 分支。
static int begin_cmd(void) {
    if (nvn_vk_query_prepare(&D, why, sizeof why)) return -1;   // 对应 first_draw.c:2924
    return nvn_vk_query_cb_begin(&D, C, why, sizeof why);        // 对应 first_draw.c:2958
}

// case reset_range：4 轮 used 8/128/8/8，reset 槽应为 4096/8/128/8（大批次后的小批次不再按大范围 reset）
static int case_reset_range(void) {
    init();
    unsigned used[4] = {8, 128, 8, 8}, exp[4] = {4096, 8, 128, 8};
    int bad = 0;
    for (int r = 0; r < 4; r++) {
        unsigned long r0 = g_reset_slots;
        if (begin_cmd()) { printf("cb fail %s\n", why); return 1; }
        for (unsigned i = 0; i < used[r]; i++) {
            if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) { printf("draw fail %s\n", why); return 1; }
            nvn_vk_query_pass_end();
        }
        uint64_t a = 0;
        nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&a, why, sizeof why);
        nvn_vk_query_batch_submitted((uint64_t)(r + 1));
        nvn_vk_query_batch_completed((uint64_t)(r + 1), why, sizeof why);
        nvn_vk_query_resolve(&D, why, sizeof why);
        unsigned long d = g_reset_slots - r0;
        printf("  round%d used=%u reset_slots=%lu expected=%u %s\n", r + 1, used[r], d, exp[r], d == exp[r] ? "OK" : "MISMATCH");
        if (d != exp[r]) bad = 1;
    }
    return bad;
}

// case multipass：同批 8 个 pass × 每 pass 513 段（累计 4104 > 单页 4096）——必须在 pass 边界合法换页，不得失败。
static int case_multipass(void) {
    init();
    unsigned acc = 0; int failed = 0;
    for (int pass = 0; pass < 8 && !failed; pass++) {
        if (begin_cmd()) { printf("cb fail pass%d %s\n", pass, why); failed = 1; break; }
        for (int i = 0; i < 513; i++) {
            if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) { printf("draw fail pass%d seg%d %s\n", pass, i, why); failed = 1; break; }
            nvn_vk_query_pass_end(); acc++;
        }
    }
    struct nvn_vk_query_stats st; nvn_vk_query_stats(&st);
    printf("  multipass 8x513: accepted=%u expected=4104 failed=%d fails_stat=%llu\n", acc, failed, (unsigned long long)st.fails);
    return (acc == 4104 && !failed) ? 0 : 1;
}

// case compact：两个 pass（4096 段）后报告应得 45056（11×4096），且期间压缩不串账
static int case_compact(void) {
    init();
    if (begin_cmd()) return 1;
    { if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) return 1; nvn_vk_query_pass_end(); }
    nvn_vk_query_batch_submitted(1);
    nvn_vk_query_reset_run(&D, why, sizeof why);
    nvn_vk_query_resolve(&D, why, sizeof why);
    if (begin_cmd()) return 1;
    for (unsigned i = 0; i < 4096; i++) { if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) { printf("draw fail %s\n", why); return 1; } nvn_vk_query_pass_end(); }
    uint64_t out = 999;
    nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&out, why, sizeof why);
    nvn_vk_query_batch_submitted(2);
    int a = nvn_vk_query_batch_completed(1, why, sizeof why), b = nvn_vk_query_batch_completed(2, why, sizeof why), c = nvn_vk_query_resolve(&D, why, sizeof why);
    printf("  compact: expected=45056 actual=%llu complete=%d/%d resolve=%d\n", (unsigned long long)out, a, b, c);
    return (out == 45056 && !a && !b && !c) ? 0 : 1;
}

// case cumulative：不 Reset 连续 262145 段（段日志折叠后仍不溢出）
static int case_cumulative(void) {
    init();
    uint32_t n = 0; uint64_t seq = 0; int rc = 0;
    while (n < QP_SEG_MAX + 1) {
        rc = begin_cmd(); if (rc) break;
        for (unsigned j = 0; j < QP_PAGE_SLOTS && n < QP_SEG_MAX + 1; j++) { rc = nvn_vk_query_draw_begin(&D, C, why, sizeof why); if (rc) break; nvn_vk_query_pass_end(); n++; }
        if (rc) break;
        nvn_vk_query_batch_submitted(++seq);
        rc = nvn_vk_query_batch_completed(seq, why, sizeof why); if (rc) break;
        nvn_vk_query_resolve(&D, why, sizeof why);
    }
    printf("  cumulative: accepted=%u expected=262145 seg_log=%u rc=%d\n", n, Q.seg_n, rc);
    return (n == QP_SEG_MAX + 1) ? 0 : 1;
}

// case abandoned：录了查询的批次被丢弃（提交失败/命令缓冲不会再提交）→ 页整页作废：
// 不标成已提交、不做 WAIT 读；引用这些段的报告前缀永远拿不到结果 → 准确报红（绝不写假 0）。
static int case_abandoned(void) {
    init();
    if (begin_cmd()) { printf("cb fail %s\n", why); return 1; }
    for (int i = 0; i < 3; i++) {
        if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) { printf("draw fail %s\n", why); return 1; }
        nvn_vk_query_pass_end();
    }
    uint64_t out = 777;
    nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&out, why, sizeof why);   // 报告引用这 3 段
    nvn_vk_query_batch_abandoned();                                             // 这批不会提交了
    unsigned long reads0 = g_get_calls;
    int rc_done = nvn_vk_query_batch_completed(1, why, sizeof why);             // 没有页归属 1：不读结果
    int rc_blk = nvn_vk_query_resolve_blocking(&D, why, sizeof why);            // 前缀永远不齐：准确失败
    struct nvn_vk_query_stats st; nvn_vk_query_stats(&st);
    printf("  abandoned: get_calls=%lu completed=%d blocking=%d out=%llu fails=%llu\n",
           g_get_calls - reads0, rc_done, rc_blk, (unsigned long long)out, (unsigned long long)st.fails);
    // 期望：一次 WAIT 读都没有、completed 是 no-op、blocking 报红、guest 计数没有被改写
    return (g_get_calls == reads0 && rc_done == 0 && rc_blk != 0 && out == 777) ? 0 : 1;
}

// case abandoned_forgot：**反例说明**——调用方忘了在批次丢弃时作废页，会怎样：
// 页被标成已提交并被 WAIT 读（get_calls 增加），报告把“从未执行过的查询”的桩值当成真值写回。
// 这条用例断言危险确实存在，用来锁住 fd_fq_fail → nvn_vk_query_batch_abandoned() 这一环不能删。
static int case_abandoned_forgot(void) {
    init();
    if (begin_cmd()) { printf("cb fail %s\n", why); return 1; }
    for (int i = 0; i < 3; i++) {
        if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) { printf("draw fail %s\n", why); return 1; }
        nvn_vk_query_pass_end();
    }
    uint64_t out = 777;
    nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&out, why, sizeof why);
    // 故意不作废：直接当成“这批提交了”。真实上这些查询从未被执行，驱动上 WAIT 读可能永远等下去。
    nvn_vk_query_batch_submitted(1);
    unsigned long reads0 = g_get_calls;
    int rc_done = nvn_vk_query_batch_completed(1, why, sizeof why);
    int rc_res = nvn_vk_query_resolve(&D, why, sizeof why);
    printf("  abandoned_forgot(反例): get_calls=%lu completed=%d resolve=%d out=%llu(桩值 11x3=33 才是危险信号)\n",
           g_get_calls - reads0, rc_done, rc_res, (unsigned long long)out);
    return (g_get_calls > reads0 && out == 33) ? 0 : 1;   // 危险成立 = 0；危险没出现反而说明用例失真
}

// case session：release 后新会话首次 Reset 前 Report 写 0，且计数/段/epoch/报告清零
// 统计在途页（已提交未回收）：同步 flush 没有按批次退休时，这个数会一路涨到页池耗尽。
static int inflight_pages(void) {
    int n = 0;
    for (int i = 0; i < QP_PAGES; i++) if (Q.page[i].used && Q.page[i].state == 2) n++;
    return n;
}
// 一批：开提交边界 → nseg 个查询段 → 报告 → 登记提交 →（可选）按批次退休 → 结算报告。
// 返回 0 = 这一步成功；-1 = 模块报红。
static int one_batch(uint64_t qid, int nseg, uint64_t *out, int retire) {
    if (begin_cmd()) { printf("query begin fail %s\n", why); return -1; }
    for (int i = 0; i < nseg; i++) {
        if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) return -1;   // 段日志满/段内页满会在这里报红
        nvn_vk_query_pass_end();
    }
    if (nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)out, why, sizeof why)) return -1;
    nvn_vk_query_batch_submitted(qid);
    if (retire && nvn_vk_query_batch_completed(qid, why, sizeof why)) { printf("completed fail %s\n", why); return -1; }
    if (nvn_vk_query_resolve(&D, why, sizeof why)) { printf("resolve fail %s\n", why); return -1; }
    return 0;
}
// case page_exhaust（P0-leak ③）：页池耗尽不许用 5 s 终态语义的 flush() 顶。
// 三段分别驱动 nvn_vk_first_draw_flush_ready(budget) 的三种返回（生产分支见 nvn_vk_query.c:294-315）：
//   ① 返回 1（预算内拿不到完成证明）→ 生产必须真的走到页耗尽回收分支、用带预算的 flush_ready、
//      绝不调终态 flush()、只 qp_refuse（Q.failed 保持 0、本次分配准确失败、下个提交边界重试）；
//   ② 返回 0（等到了完成证明）→ 后续批次必须能继续跑、页被回收并整体退休；
//   ③ 返回 <0（帧队列自己报终态）→ 生产必须走 qp_fail 把模块打成终态（这时才允许 Q.failed=1）。
static int case_page_exhaust(void) {
    init();
    g_flush_ready_calls = g_flush_ready_bounded = g_flush_terminal_calls = 0;
    g_flush_ready_rc = 1;
    int hit = 0;
    const int batches = 300, nseg = 1000;
    for (int b = 0; b < batches && !hit; b++) {
        uint64_t out = 0;
        if (one_batch((uint64_t)(b + 1), nseg, &out, 0 /* 不退休：把页占满 */)) hit = 1;
    }
    int calls = g_flush_ready_calls, bounded = g_flush_ready_bounded, terminal = g_flush_terminal_calls;
    struct nvn_vk_query_stats st; memset(&st, 0, sizeof st); nvn_vk_query_stats(&st);
    // 核心断言：模块**没**被打成终态（Q.failed 保持 0），拒绝计入统计；否则“可重试”就是假的。
    int ok = hit && calls > 0 && bounded == calls && terminal == 0 && !Q.failed && st.fails > 0;
    printf("  page_exhaust(未完成): 走到耗尽=%d flush_ready=%d(带预算 %d) terminal_flush=%d Q.failed=%d fails=%llu\n",
           hit, calls, bounded, terminal, Q.failed, (unsigned long long)st.fails);
    if (!ok) return 1;
    // 等待成功之后必须能继续：后面的批次要正常完成并回收页（证明上一步是“可重试等待”不是终态）。
    g_flush_ready_rc = 0;
    int resumed = 0;
    uint64_t out = 0;
    for (int b = 0; b < 40 && !resumed; b++)
        if (one_batch((uint64_t)(1000 + b), nseg, &out, 1) == 0) resumed = 1;
    int infl = inflight_pages();
    printf("  page_exhaust(重试): 恢复=%d 在途页=%d/%d 报告=%llu(含回收时补读的旧批次)\n",
           resumed, infl, QP_PAGES, (unsigned long long)out);
    // 恢复这一批里页被整体回收并退休：在途页必须归零（不是“勉强没超过页池”）。
    // 报告值只要求非 0（累计口径含回收时补读的旧批次，绝对值由 sync_retire 用例钉）。
    if (!(resumed && infl == 0 && out > 0)) return 1;
    // ③ 第三种返回：<0 = 帧队列自己报终态。此时不再是“可重试”，必须走 qp_fail 把模块打成终态
    //   （nvn_vk_query.c:297 那一支）；否则一次真实的帧队列失败会被当成普通重试反复吞掉。
    g_flush_ready_rc = -1;
    g_flush_ready_calls = g_flush_ready_bounded = 0;
    int hit_terminal = 0;
    for (int b = 0; b < batches && !hit_terminal; b++) {
        uint64_t o = 0;
        if (one_batch((uint64_t)(2000 + b), nseg, &o, 0 /* 不退休：再次把页占满触发页耗尽 */)) hit_terminal = 1;
    }
    struct nvn_vk_query_stats st2; memset(&st2, 0, sizeof st2); nvn_vk_query_stats(&st2);
    printf("  page_exhaust(终态): 走到耗尽=%d flush_ready=%d Q.failed=%d fails=%llu terminal_flush=%d\n",
           hit_terminal, g_flush_ready_calls, Q.failed, (unsigned long long)st2.fails, g_flush_terminal_calls);
    // <0 必须进终态（Q.failed=1），且仍然不许回头调用旧终态 flush() 入口。
    return (hit_terminal && Q.failed && g_flush_ready_calls > 0 && g_flush_terminal_calls == 0) ? 0 : 1;
}

// case sync_retire：同步完成路径连续 300 批、每批 1000 段（远超页池），在途页必须被及时回收、
// 报告仍是累计值（每段 11）。这是「同步 flush 完成了但查询页没退休」那条缺口的回归护栏。
static int case_sync_retire(void) {
    init();
    int worst = 0, failed_early = 0;
    uint64_t last = 0, segs = 0;
    const int batches = 300, nseg = 1000;
    for (int b = 0; b < batches; b++) {
        uint64_t out = 0;
        if (one_batch((uint64_t)(b + 1), nseg, &out, 1)) { failed_early = 1; break; }
        segs += (uint64_t)nseg;
        int now = inflight_pages();
        if (now > worst) worst = now;
        last = out;
    }
    struct nvn_vk_query_stats st; memset(&st, 0, sizeof st); nvn_vk_query_stats(&st);
    int end = inflight_pages();
    printf("  sync_retire: %d 批 x %d 段，在途页峰值=%d 收尾=%d 累计报告=%llu(期望 %llu) fails=%llu 早退=%d\n",
           batches, nseg, worst, end, (unsigned long long)last, (unsigned long long)(segs * 11),
           (unsigned long long)st.fails, failed_early);
    return (!failed_early && worst <= 4 && end == 0 && last == segs * 11 && st.fails == 0) ? 0 : 1;
}
// case sync_forgot（反例）：同一流程但不按批次退休 → 在途页必须堆到页池上限并报红，
// 证明「页不累积」确实是退休接线带来的，不是这套用例本身不占页。
static int case_sync_forgot(void) {
    init();
    int failed_early = 0;
    const int batches = 300, nseg = 1000;
    for (int b = 0; b < batches; b++) {
        uint64_t out = 0;
        if (one_batch((uint64_t)(b + 1), nseg, &out, 0)) { failed_early = 1; break; }
    }
    struct nvn_vk_query_stats st; memset(&st, 0, sizeof st); nvn_vk_query_stats(&st);
    int end = inflight_pages();
    printf("  sync_forgot(反例): %d 批不退休 → 在途页=%d(页池 %d) fails=%llu 早退=%d\n",
           batches, end, QP_PAGES, (unsigned long long)st.fails, failed_early);
    // 不退休就持续累积（同一用例退休时为 0）；这里只要求「明显在涨」，不假定一定顶到页池
    return (!failed_early && end >= 16) ? 0 : 1;
}

static int case_session(void) {
    init();
    if (begin_cmd()) return 1;
    { if (nvn_vk_query_draw_begin(&D, C, why, sizeof why)) return 1; nvn_vk_query_pass_end(); }
    uint64_t out = 999;
    nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&out, why, sizeof why);
    nvn_vk_query_batch_submitted(1);
    nvn_vk_query_batch_completed(1, why, sizeof why);
    nvn_vk_query_resolve(&D, why, sizeof why);
    nvn_vk_query_release_device();
    struct nvn_vk_query_stats st; nvn_vk_query_stats(&st);
    uint64_t next = 999;
    nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&next, why, sizeof why);
    nvn_vk_query_resolve(&D, why, sizeof why);
    printf("  session: before-reset report=%llu(expect 0) counting=%d seg=%u ep=%u rep=%u resets_stat=%llu\n",
           (unsigned long long)next, nvn_vk_query_counting(), Q.seg_n, Q.ep_n, Q.rep_n, (unsigned long long)st.resets);
    return (!nvn_vk_query_counting() && !Q.seg_n && !Q.ep_n && !Q.rep_n && !st.resets && next == 0) ? 0 : 1;
}

// Terminal readiness must not mutate pending query ownership or writeback queues.
static int case_terminal_pending(void) {
    init();
    if (begin_cmd() || nvn_vk_query_draw_begin(&D, C, why, sizeof why)) return 1;
    nvn_vk_query_pass_end();
    uint64_t output=999;
    if (nvn_vk_query_report(&D, &mem, (uint64_t)(uintptr_t)&output, why, sizeof why)) return 1;
    nvn_vk_query_batch_submitted(7);
    static struct qp_state saved_q; memcpy(&saved_q,&Q,sizeof Q);
    unsigned long destroys=g_destroy_calls;
    if (nvn_vk_query_terminal_ready() || nvn_vk_query_terminal_ready()) return 1;
    nvn_vk_query_release_device();
    if (memcmp(&saved_q,&Q,sizeof Q) || destroys!=g_destroy_calls || output!=999) return 1;
    if (nvn_vk_query_batch_completed(7,why,sizeof why) || nvn_vk_query_resolve(&D,why,sizeof why)) return 1;
    if (output!=11 || !nvn_vk_query_terminal_ready()) return 1;
    nvn_vk_query_release_device();
    return g_destroy_calls==destroys+1 ? 0 : 1;
}
static int case_terminal_timestamp(void) {
    TS.dev=(VkDevice)(uintptr_t)1; TS.pool=(VkQueryPool)(uintptr_t)99;
    s2a_ts_queue_init(&TS.fifo,TS.slots,TS_SLOTS);
    uint32_t slot=0; if (s2a_ts_queue_append(&TS.fifo,4,&slot)) return 1;
    TS.pend[0].slot=slot; TS.pend[0].frame_id=4; TS.pend[0].addr=123; TS.pend_n=1;
    static __typeof__(TS) saved_ts; memcpy(&saved_ts,&TS,sizeof TS);
    unsigned long destroys=g_destroy_calls;
    if (nvn_vk_query_terminal_ready() || nvn_vk_query_terminal_ready()) return 1;
    nvn_vk_query_release_device();
    if (memcmp(&saved_ts,&TS,sizeof TS) || destroys!=g_destroy_calls) return 1;
    TS.pend_n=0; s2a_ts_queue_release(&TS.fifo,1);
    if (!nvn_vk_query_terminal_ready()) return 1;
    nvn_vk_query_release_device();
    return g_destroy_calls==destroys+1 ? 0 : 1;
}
static int case_terminal_flags(void) {
    if (!nvn_vk_query_terminal_ready()) return 1;
    Q.failed=1; if (nvn_vk_query_terminal_ready()) return 1; Q.failed=0;
    TS.failed=1; if (nvn_vk_query_terminal_ready()) return 1; TS.failed=0;
    Q.seg_on=1; if (nvn_vk_query_terminal_ready()) return 1; Q.seg_on=0;
    Q.batch=1; if (nvn_vk_query_terminal_ready()) return 1; Q.batch=0;
    Q.page[0].state=1; if (nvn_vk_query_terminal_ready()) return 1; Q.page[0].state=0;
    struct qp_seg segment={0}; Q.seg=&segment; Q.seg_n=1;
    if (nvn_vk_query_terminal_ready()) return 1;
    segment.known=1;
    if (!nvn_vk_query_terminal_ready()) return 1;
    Q.seg=NULL; Q.seg_n=0;
    TS.fifo.tail=1; if (nvn_vk_query_terminal_ready()) return 1; TS.fifo.tail=0;
    return !nvn_vk_query_terminal_ready();
}

int main(int argc, char **argv) {
    if (argc != 2) { printf("usage: %s <case>\n", argv[0]); return 2; }
    const char *c = argv[1];
    int rc;
    if (!strcmp(c, "terminal_flags")) rc = case_terminal_flags();
    else if (!strcmp(c, "terminal_pending")) rc = case_terminal_pending();
    else if (!strcmp(c, "terminal_timestamp")) rc = case_terminal_timestamp();
    else if (!strcmp(c, "reset_range")) rc = case_reset_range();
    else if (!strcmp(c, "multipass")) rc = case_multipass();
    else if (!strcmp(c, "compact")) rc = case_compact();
    else if (!strcmp(c, "cumulative")) rc = case_cumulative();
    else if (!strcmp(c, "abandoned")) rc = case_abandoned();
    else if (!strcmp(c, "abandoned_forgot")) rc = case_abandoned_forgot();
    else if (!strcmp(c, "sync_retire")) rc = case_sync_retire();
    else if (!strcmp(c, "sync_forgot")) rc = case_sync_forgot();
    else if (!strcmp(c, "page_exhaust")) rc = case_page_exhaust();
    else if (!strcmp(c, "session")) rc = case_session();
    else { printf("unknown case %s\n", c); return 2; }
    printf("%s: %s\n", c, rc ? "FAIL" : "ok");
    return rc ? 1 : 0;
}
