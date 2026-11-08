// GAL Metal 后端：计数（ReportCounter / ResetCounter / ICounterEvent）与条件渲染。
// 语义照 Ryujinx Vulkan 后端 Queries/（CounterQueue / CounterQueueEvent / BufferedQuery）：
//   · 每种计数一条有序队列；「区间」= 相邻两次 Report 之间（含其间的 Reset）。
//   · 交给 Gpu 层的值是累计值：accum（自上次 Reset 起）+ 本区间结果 / divisor（向上取整；divisor == 1 不做除法）——CounterQueueEvent.TryConsume。
//   · Reset 只给「当前区间」打清零标记：该区间出结果时先把 accum 清 0；区间里 Reset 前已画的样本作废（Vulkan 重开查询）。
//   · 区间里没有绘制 → 不等 GPU，结果 = accum（+0）立即可出（Vulkan Complete(withResult: draws > 0)）。
//   · TransformFeedbackPrimitivesWritten 恒走「无结果」（Vulkan 同）；PrimitivesGenerated：Apple GPU 无管线统计，同 Vulkan 不支持时的路径（+0），首例报红。
// 与 Vulkan 后端的两处有意差异（按硬件语义取更正确的一边）：
//   ① 跨命令缓冲累计：Vulkan 提交时重开查询（PipelineFull.FlushCommandsImpl 里 CmdResetQueryPool + CmdBeginQuery），区间跨提交会丢前段；
//      这里区间槽跨通道 / 跨提交一直累加（通道 visibilityResultType = Accumulate）。
//   ② 事件被 Dispose（release）后：Vulkan 直接跳过（不进 accum）；这里照常进 accum，只是不回报——硬件计数器不因为没人读而少计。
// 可见性缓冲：一块 32 KB 共享缓冲 = 4096 个 8 字节槽（偏移只用低 15 位，社区 Metal 后端实测硬件只认低 15 位，留在界内）。
//   槽在区间第一次绘制时取、CPU 清 0；区间结束（Report / Reset）后随事件等 GPU 完成、读值、还槽。
// 辅助绘制（通道内清屏三角）不计样本（Vulkan 后端的局部清屏走 CmdClearAttachments 或另一条命令缓冲里的辅助着色器，都不在查询里）：画前关计数。
//   Metal 不许同一编码器里重复用一个可见性偏移（含关掉后再开，MTL_DEBUG_LAYER 断言），所以一个区间在一个编码器里被辅助绘制切成 k 段就要 k 个槽，
//   这些槽串成区间的槽链、出结果时求和。每个新编码器从链头起按段序重用同一条链（偏移唯一只限同一编码器；Accumulate 跨编码器累加），
//   故链长 = 区间在单个编码器里的最多段数，与区间跨多少通道 / 命令缓冲、多久不取结果无关；
//   单个编码器里段数到 VIS_SEG_MAX 时，下一次辅助绘制前结束渲染通道（gal_cnt_aux_wants_break），链长封顶 VIS_SEG_MAX。
//   旧做法每段都取新槽、链只增不减：马车8 菜单一个区间几千帧不出结果、每帧一次局部清屏，链涨到 4096 槽用尽（10-21 测试机局），之后的绘制不计样本。
// 完成判定：事件记下区间最后一次绘制所在的命令缓冲（强引用）；该缓冲提交后（g_gcb 已不是它），在队列上 signal 本模块自己的共享事件
//   （队列语义：signal 在此前已提交的全部命令完成后才生效），signaledValue ≥ 该值即结果已写好。不改 gal_core 的栅栏。
#import "gal_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
enum { CNT_SAMPLES = 0, CNT_PRIMS = 1, CNT_XFB = 2, CNT_TIME = 3, CNT_NTYPES = 4 };   // = Ryujinx.Graphics.GAL.CounterType（CNT_TIME = S2ATimestamp，S2A 加）
// 时间戳（S2A_GPU_TS，帧率能耗线 10-23）：结果 = 报告所在命令缓冲在 GPU 上的结束时刻（主机单调时钟纳秒，同 Stopwatch / PerformanceCounter 时基），
// 命令缓冲完成回调（gal_core.m 提交反馈）记进环 g_ts_*；照直连层「每个报告取它所在段的 GPU 结束时刻」。没有在录 / 已提交命令时取 CPU 当下
#define VIS_SLOTS 4096
#define VIS_LOW_WATER 64          // 空闲槽低于此数：在 Report / Reset 处（编码器之外）提交并等全部在途计数出结果
// 一个区间在单个编码器里的最多段数（= 槽链最长）。≤ VIS_LOW_WATER：区间开头空闲槽 ≥ VIS_LOW_WATER（Report / Reset 处排空保证），区间内再取也取不空
#define VIS_SEG_MAX 16
_Static_assert(VIS_SEG_MAX <= VIS_LOW_WATER, "区间槽链上限要不大于低水位");

typedef struct {
    uint32_t id;                  // 0 = 内部作废项（Reset 前本区间已画的样本：只为等 GPU 用完再还槽）
    int32_t slot;                 // 可见性槽链头（g_slot_next 串起同一区间的多个槽）；-1 = 无 GPU 结果（区间没画 / 非 SamplesPassed）
    void *cb;                     // 区间最后一次绘制所在命令缓冲（retained）；提交后换成 qf
    uint64_t qf;                  // g_cev 上的完成值；0 = 未分配
    double divisor;
    uint8_t clear, released;
    uint8_t ts;                   // 时间戳事件（CNT_TIME）：不占可见性槽，按 tf 那次提交的 GPU 结束时刻出结果
    uint64_t tf;                  // 所在提交的栅栏值（gal_cb_id）；0 = 当场出（取 CPU 当下）
    uint64_t td;                  // 首次看到栅栏已完成的时刻（反馈回调迟迟不到的兜底计时）
} cnt_ev;
typedef struct { cnt_ev *q; int head, n, cap; uint64_t accum; } cnt_queue;
// 当前区间：slot = 槽链头（g_slot_next 按段序串起）；seg = 本编码器里当前段用的槽（-1 = 本编码器里还没画过），nseg = 本编码器里的段数
typedef struct { int32_t slot, seg; void *cb; uint8_t clear; uint16_t nseg; uint64_t draws; } cnt_cur;

static cnt_queue g_q[CNT_NTYPES];
static cnt_cur g_cur[CNT_NTYPES] = {{-1, -1, NULL, 0, 0, 0}, {-1, -1, NULL, 0, 0, 0}, {-1, -1, NULL, 0, 0, 0}, {-1, -1, NULL, 0, 0, 0}};
// 提交完成时刻环（命令缓冲反馈线程写、计数侧读；先写时刻再写栅栏值，读到栅栏值即时刻已就绪）
#define TS_RING 1024
static _Atomic uint64_t g_ts_fence[TS_RING], g_ts_end[TS_RING];
void gal_cnt_on_cb_done(uint64_t fence, double gpu_end_s) {
    uint64_t ns = gpu_end_s > 0 ? (uint64_t)(gpu_end_s * 1e9) : clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    g_ts_end[fence % TS_RING] = ns; g_ts_fence[fence % TS_RING] = fence;
}
// 1 = 可出（*v = 时刻）；0 = 还要等（提交没做完，或做完了反馈回调还没跑到）
static int ts_ready(cnt_ev *e, uint64_t *v) {
    if (!e->tf) { *v = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); return 1; }
    if (gal_done_fence() < e->tf) return 0;
    uint64_t f = g_ts_fence[e->tf % TS_RING];
    if (f == e->tf) { *v = g_ts_end[e->tf % TS_RING]; return 1; }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (f > e->tf) { *v = now; return 1; }   // 环已被覆盖（积压超 TS_RING 次提交）：退回 CPU 当下
    if (!e->td) e->td = now;
    if (now - e->td > 5000000) { GRED_ONCE("时间戳计数：提交 %llu 已完成 5 ms 仍没收到反馈时刻，退回 CPU 当下", (unsigned long long)e->tf); *v = now; return 1; }
    return 0;
}
static id<MTLBuffer> g_vis;
static uint16_t g_free[VIS_SLOTS]; static int g_nfree;
// Metal 规定同一渲染编码器里一个偏移只能设一次（MTL_DEBUG_LAYER 断言「Using the same offset … twice in the same command encoder」）：
// 区间在同一编码器里离开自己的槽（辅助绘制关计数）后再回来，必须用链上的下一个槽；同一区间的槽按段序串起，出结果时求和
static int16_t g_slot_next[VIS_SLOTS];
static id<MTLSharedEvent> g_cev; static uint64_t g_cseq;
static int64_t g_applied_off = -1;   // 当前渲染编码器上设好的可见性偏移；-1 = 关
static uint32_t g_next_id;
static uint32_t *g_rid; static uint64_t *g_rval; static int g_nready, g_capready;   // 已出、待 poll 取走

static void cnt_init(void) {
    if (g_vis) return;
    // 事件先建：可见性缓冲建不出时计数照常按 0 出结果（没有槽可取），assign_fences / wait_cev 仍要它
    if (!g_cev) g_cev = [g_gdev newSharedEvent];
    g_vis = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared];
    if (!g_vis) { GRED_ONCE("建可见性结果缓冲失败（%d 字节）：SamplesPassed 不计、按 0 出结果，下次开通道重试：%s", VIS_SLOTS * 8, gal_mem_note()); return; }
    g_vis.label = @"gal_cnt_visibility";
    memset(g_vis.contents, 0, VIS_SLOTS * 8);
    gal_res_add(g_vis);
    for (int i = 0; i < VIS_SLOTS; i++) g_free[i] = (uint16_t)(VIS_SLOTS - 1 - i);
    g_nfree = VIS_SLOTS;
}
static int slot_alloc(void) {
    if (!g_nfree) return -1;
    int s = g_free[--g_nfree];
    ((volatile uint64_t *)g_vis.contents)[s] = 0;   // 只在上一个使用者的命令完成后才回到空闲表，CPU 清零不与 GPU 竞争
    g_slot_next[s] = -1;
    return s;
}
static void slot_free(int s) { g_free[g_nfree++] = (uint16_t)s; }
static void *cb_retain_cur(void) { return g_gcb ? (__bridge_retained void *)g_gcb : NULL; }
static void cb_drop(void **cb) { if (*cb) { (void)(__bridge_transfer id)*cb; *cb = NULL; } }   // 取回 +1，表达式结束即释放

static cnt_ev *q_push(int t) {
    cnt_queue *q = &g_q[t];
    if (q->n == q->cap) {
        if (q->head) { memmove(q->q, q->q + q->head, (q->n - q->head) * sizeof *q->q); q->n -= q->head; q->head = 0; }
        else { q->cap = q->cap ? q->cap * 2 : 64; q->q = realloc(q->q, q->cap * sizeof *q->q); }
    }
    cnt_ev *e = &q->q[q->n++]; memset(e, 0, sizeof *e); e->slot = -1; e->divisor = 1; return e;
}
static cnt_ev *ev_find(uint32_t id) {
    if (!id) return NULL;
    for (int t = 0; t < CNT_NTYPES; t++) for (int i = g_q[t].head; i < g_q[t].n; i++) if (g_q[t].q[i].id == id) return &g_q[t].q[i];
    return NULL;
}
static void ready_push(uint32_t id, uint64_t v) {
    if (g_nready == g_capready) { g_capready = g_capready ? g_capready * 2 : 64; g_rid = realloc(g_rid, g_capready * sizeof *g_rid); g_rval = realloc(g_rval, g_capready * sizeof *g_rval); }
    g_rid[g_nready] = id; g_rval[g_nready++] = v;
}

// 已提交（命令缓冲不再是在录那条）的事件：一次队列 signal 覆盖全部
static void assign_fences(void) {
    void *cur = (__bridge void *)g_gcb; int need = 0;
    for (int t = 0; t < CNT_NTYPES && !need; t++) for (int i = g_q[t].head; i < g_q[t].n; i++) { cnt_ev *e = &g_q[t].q[i]; if (!e->qf && e->cb && e->cb != cur) { need = 1; break; } }
    if (!need) return;
    uint64_t v = ++g_cseq; [g_gq signalEvent:g_cev value:v];
    for (int t = 0; t < CNT_NTYPES; t++) for (int i = g_q[t].head; i < g_q[t].n; i++) { cnt_ev *e = &g_q[t].q[i]; if (!e->qf && e->cb && e->cb != cur) { e->qf = v; cb_drop(&e->cb); } }
}
// 按队列顺序出结果（累计值依赖前面的事件，不能跳着出）
// 可见性缓冲没建成时也要出：此时没有任何槽（g_nfree = 0），事件都不带槽、按 0 累计，不读 vis
static void collect(void) {
    assign_fences();
    uint64_t done = g_cev.signaledValue;
    volatile uint64_t *vis = (volatile uint64_t *)g_vis.contents;
    for (int t = 0; t < CNT_NTYPES; t++) {
        cnt_queue *q = &g_q[t];
        while (q->head < q->n) {
            cnt_ev *e = &q->q[q->head];
            if (e->ts) {
                uint64_t tv; if (!ts_ready(e, &tv)) break;
                q->head++;
                if (e->id && !e->released) ready_push(e->id, tv);
                continue;
            }
            if (e->slot >= 0 && !(e->qf && e->qf <= done)) break;
            uint64_t v = 0;
            for (int s = e->slot, nx; s >= 0; s = nx) { nx = g_slot_next[s]; v += vis[s]; slot_free(s); }
            cb_drop(&e->cb);
            q->head++;
            if (!e->id) continue;   // 作废项：只还槽
            if (e->clear) q->accum = 0;
            q->accum += e->divisor == 1 ? v : (uint64_t)ceil((double)v / e->divisor);
            if (!e->released) ready_push(e->id, q->accum);
        }
        if (q->head == q->n) q->head = q->n = 0;
    }
}
static void wait_cev(uint64_t v) {
    if (g_cev.signaledValue < v && ![g_cev waitUntilSignaledValue:v timeoutMS:3000]) gal_gpu_stall_exit(g_cev, "计数结果", v, g_cev.signaledValue);   // 3 秒即判卡死退出（gal_core.m）
}
// 让全部在途计数出结果（提交在录命令并等）；只在编码器之外调用
static void drain_all(void) {
    void *cur = (__bridge void *)g_gcb; int in_rec = 0;
    for (int t = 0; t < CNT_NTYPES; t++) for (int i = g_q[t].head; i < g_q[t].n; i++) if (g_q[t].q[i].cb && g_q[t].q[i].cb == cur) in_rec = 1;
    if (in_rec) gal_commit();
    assign_fences();
    wait_cev(g_cseq);
    collect();
}
static uint32_t next_id(void) { if (!++g_next_id) ++g_next_id; return g_next_id; }

// ---------- 计数线程等结果（照 Ryujinx Vulkan Queries/CounterQueue.cs EventConsumer：消费线程自己等队头查询出结果，不靠别人再叫醒）----------
// 10-22 八方2 开场「出图停 → 引擎出图看门狗自崩」：渲染线程在 FetchVisibilityForPrimitives 里 CPU 轮询遮挡查询结果（bWait、无限等），
// 我方计数线程只在 UpdateCounters / PreFrame 叫醒时取一次：那一刻队头的命令缓冲还在录（懒同步不当场提交）或 GPU 没做完，
// 之后提交 / GPU 完成都没人再叫醒它，结果留在 C 端不写回客体内存，游戏与 GPU 两边都闲着互等。
// 现在：提交钩子（gal_commit 末尾）与无需 GPU 的报告当场叫醒；队头已提交没做完就在本线程等 GPU 共享事件
static pthread_mutex_t g_wm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wc = PTHREAD_COND_INITIALIZER;
static uint64_t g_wgen;
static void wake_waiter(void) { pthread_mutex_lock(&g_wm); g_wgen++; pthread_cond_broadcast(&g_wc); pthread_mutex_unlock(&g_wm); }
// 队头状态：1 = 有可取的（已出队列非空 / 某队头不需 GPU 或 GPU 已做完）；2 = 队头已提交、等 GPU（*want = 该完成值）；3 = 队头还在在录命令缓冲；0 = 没有在途
static int head_state(uint64_t *want) {
    if (g_nready) return 1;
    uint64_t done = g_cev ? g_cev.signaledValue : 0; int st = 0;
    for (int t = 0; t < CNT_NTYPES; t++) {
        cnt_queue *q = &g_q[t];
        if (q->head >= q->n) continue;
        cnt_ev *e = &q->q[q->head];
        if (e->ts) {
            uint64_t tv; if (ts_ready(e, &tv)) return 1;
            if (e->tf > gal_committed_fence()) { if (!st) st = 3; continue; }   // 还在在录命令缓冲里：等提交叫醒
            if (st != 4 && st != 2) { st = 4; *want = e->tf; }                  // 已提交没做完（或反馈未到）：等主栅栏
            continue;
        }
        if (e->slot < 0 || (e->qf && e->qf <= done)) return 1;
        if (e->qf) { if (st != 2 || e->qf < *want) *want = e->qf; st = 2; }
        else if (!st) st = 3;
    }
    return st;
}
void gal_cnt_on_commit(void) {
    if (g_q[CNT_TIME].head < g_q[CNT_TIME].n) { wake_waiter(); return; }   // 有在途时间戳：提交后它们可能就能出了
    for (int t = 0; t < CNT_NTYPES; t++) for (int i = g_q[t].head; i < g_q[t].n; i++) if (g_q[t].q[i].cb && !g_q[t].q[i].qf) { wake_waiter(); return; }
}

// ---------- 钩子 ----------
void gal_cnt_on_pass_begin(MTL4RenderPassDescriptor *d) {
    cnt_init();
    d.visibilityResultBuffer = g_vis;
    // 区间槽跨编码器累加（不在通道开头清零；清零由 CPU 在取槽时做）。Metal 3 路径的老通道描述到 26 才有这个属性：26 以下设不了，报红（累加语义缺，计数会偏）
    if ([d respondsToSelector:@selector(setVisibilityResultType:)]) d.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    else GRED_ONCE("Metal 3（26 以下）：渲染通道描述没有 visibilityResultType，可见性计数不能跨编码器累加，SamplesPassed 会偏");
    g_applied_off = -1;                                           // 新编码器缺省可见性模式 = 关
    g_cur[CNT_SAMPLES].seg = -1; g_cur[CNT_SAMPLES].nseg = 0;      // 新编码器从链头起重用区间的槽（Accumulate 跨编码器累加）
}
void gal_cnt_on_draw(id<MTL4RenderCommandEncoder> e) {
    for (int t = 0; t < CNT_NTYPES; t++) g_cur[t].draws++;
    cnt_cur *c = &g_cur[CNT_SAMPLES];
    if (c->seg < 0 || g_applied_off != (int64_t)c->seg * 8) {
        // 本编码器里开新一段：用链上下一个槽（新编码器 = 链头），链到头了才取新槽接在链尾
        int s = c->seg < 0 ? c->slot : g_slot_next[c->seg];
        if (s < 0) {
            s = slot_alloc();
            if (s < 0) {
                GRED_ONCE("可见性槽用尽（%d 个）：本次绘制不计 SamplesPassed", VIS_SLOTS);
                if (g_applied_off >= 0) { [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:(NSUInteger)g_applied_off]; g_applied_off = -1; }
                return;
            }
            if (c->seg < 0) c->slot = s; else g_slot_next[c->seg] = (int16_t)s;
        }
        c->seg = s; c->nseg++;
        [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:(NSUInteger)s * 8]; g_applied_off = (int64_t)s * 8;
    }
    if (c->cb != (__bridge void *)g_gcb) { cb_drop(&c->cb); c->cb = cb_retain_cur(); }
}
int gal_cnt_aux_wants_break(void) {
    // 区间在本编码器里已切出 VIS_SEG_MAX 段：这次辅助绘制前结束通道，之后的绘制在新编码器里从链头重用，链不再变长
    int kind; gal_cur_enc(&kind);
    return kind == 1 && g_cur[CNT_SAMPLES].nseg >= VIS_SEG_MAX;
}
void gal_cnt_on_aux_draw(id<MTL4RenderCommandEncoder> e) {
    // 关计数时偏移填正在离开的那个槽（本编码器里已用过的偏移），不占用新偏移
    if (g_applied_off >= 0) { [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:(NSUInteger)g_applied_off]; g_applied_off = -1; }
}

// ---------- C ABI ----------
NXGAL_API uint32_t nxgal_counter_report(int32_t type, float divisor, int32_t host_reserved) { GAL_API_LOCK();
    (void)host_reserved;   // Vulkan 用它给「主机条件渲染」保留查询对象；本后端不做主机条件渲染（nxgal_cond_begin 恒 0），无需保留
    if (type < 0 || type >= CNT_NTYPES) { GRED_ONCE("未知计数类型 %d", type); return 0; }
    cnt_init();
    cnt_cur *c = &g_cur[type];
    if (type == CNT_PRIMS && c->draws) GRED_ONCE("PrimitivesGenerated：Apple GPU 无管线统计，区间结果按 0（同 Ryujinx Vulkan 不支持 pipelineStatisticsQuery 时的路径）");
    if (type == CNT_TIME) {
        cnt_ev *e = q_push(type); e->id = next_id(); e->ts = 1;
        e->tf = g_gcb ? gal_cb_id() : gal_committed_fence();   // 在录命令缓冲的这次提交；没在录 = 最后一次提交（报告排在它之后、紧随其完成）
        uint64_t tv; if (ts_ready(e, &tv)) wake_waiter();
        return e->id;
    }
    cnt_ev *e = q_push(type);
    e->id = next_id();
    e->slot = type == CNT_SAMPLES ? c->slot : -1;
    e->cb = c->cb; c->cb = NULL;
    e->clear = c->clear;
    e->divisor = divisor > 0 ? (double)divisor : 1.0;
    uint32_t id = e->id;
    int now = e->slot < 0;   // 区间没画：结果不等 GPU，当场可出
    c->slot = c->seg = -1; c->nseg = 0; c->clear = 0; c->draws = 0;
    if (g_nfree < VIS_LOW_WATER) drain_all();
    if (now) wake_waiter();
    return id;
}
NXGAL_API void nxgal_counter_reset(int32_t type) { GAL_API_LOCK();
    if (type < 0 || type >= CNT_NTYPES) return;
    cnt_init();
    cnt_cur *c = &g_cur[type];
    if (c->slot >= 0) {   // Reset 前本区间已画的样本作废（Vulkan：draws != 0 时重开查询）；槽等 GPU 用完再还
        cnt_ev *e = q_push(type); e->id = 0; e->slot = c->slot; e->cb = c->cb; c->cb = NULL; c->slot = c->seg = -1; c->nseg = 0;
    } else cb_drop(&c->cb);
    c->clear = 1;
    if (g_nfree < VIS_LOW_WATER) drain_all();
}
NXGAL_API void nxgal_counter_flush(uint32_t id) { GAL_API_LOCK();
    // 结果按队列顺序出：该事件以及排在它前面的（含 Reset 留下的作废项）都要完成
    cnt_ev *e = ev_find(id);
    if (!e) return;   // 已出结果（或从未存在）
    if (e->ts) {   // 时间戳：所在提交还在录就提交，等它做完、反馈回调记下时刻（最多 50 ms，之后 ts_ready 退回 CPU 当下不会发生——这里只等）
        uint64_t tf = e->tf;
        if (tf && tf >= gal_cb_id() && g_gcb) gal_commit();
        if (tf) { gal_wait(tf); for (int k = 0; k < 500 && g_ts_fence[tf % TS_RING] < tf; k++) usleep(100); }
        collect(); return;
    }
    int t = 0; while (!(e >= g_q[t].q && e < g_q[t].q + g_q[t].n)) t++;
    cnt_queue *q = &g_q[t]; int last = (int)(e - q->q);
    void *cur = (__bridge void *)g_gcb; int in_rec = 0;
    for (int i = q->head; i <= last; i++) if (q->q[i].cb && q->q[i].cb == cur) in_rec = 1;
    if (in_rec) gal_commit();
    assign_fences();
    uint64_t need = 0;   // collect 会挪动队列，先取值
    for (int i = q->head; i <= last; i++) if (q->q[i].slot >= 0 && q->q[i].qf > need) need = q->q[i].qf;
    if (need) wait_cev(need);
    collect();
}
NXGAL_API void nxgal_counter_release(uint32_t id) { GAL_API_LOCK();
    cnt_ev *e = ev_find(id);
    if (e) { e->released = 1; return; }
    for (int i = 0; i < g_nready; i++) if (g_rid[i] == id) {
        memmove(g_rid + i, g_rid + i + 1, (g_nready - i - 1) * sizeof *g_rid);
        memmove(g_rval + i, g_rval + i + 1, (g_nready - i - 1) * sizeof *g_rval);
        g_nready--; return;
    }
}
NXGAL_API int32_t nxgal_counter_poll(uint32_t *ids, uint64_t *values, int32_t max) { GAL_API_LOCK();
    collect();
    int n = g_nready < max ? g_nready : max;
    if (n <= 0) return 0;
    memcpy(ids, g_rid, n * sizeof *ids); memcpy(values, g_rval, n * sizeof *values);
    memmove(g_rid, g_rid + n, (g_nready - n) * sizeof *g_rid);
    memmove(g_rval, g_rval + n, (g_nready - n) * sizeof *g_rval);
    g_nready -= n;
    return n;
}
NXGAL_API void nxgal_counter_kick(void) { wake_waiter(); }
// 计数线程调：返回时可能有新结果可 poll（或超时 / 被叫醒）。不持 API 锁等，等 GPU 最多 timeout_ms；队头还在在录缓冲时等提交 / 叫醒（超 1 秒报一次红：
// 没有提交就出不了结果，游戏若在 CPU 上轮询会一直等）；没有在途时等叫醒（不定时醒）
NXGAL_API int32_t nxgal_counter_wait(int32_t timeout_ms) {
    uint64_t gen, want = 0; int st;
    static uint64_t rec_since; static int rec_red;
    {
        GAL_API_LOCK();
        pthread_mutex_lock(&g_wm); gen = g_wgen; pthread_mutex_unlock(&g_wm);
        assign_fences();
        st = head_state(&want);
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (st != 3) { rec_since = 0; rec_red = 0; }
        else if (!rec_since) rec_since = now;
        else if (!rec_red && now - rec_since > 1000000000ull) {
            rec_red = 1;
            GLOG("【红】计数：队头查询在没提交的命令缓冲里已 %.1f 秒（没有提交就出不了结果；游戏在 CPU 上轮询结果会一直等）", (now - rec_since) / 1e9);
        }
    }
    if (st == 1) return 1;
    if (st == 2) { [g_cev waitUntilSignaledValue:want timeoutMS:(uint64_t)timeout_ms]; return 1; }
    if (st == 4) { if (gal_done_fence() >= want) usleep(100); else gal_wait_fence_timeout(want, timeout_ms); return 1; }   // 时间戳：等主栅栏（做完后等反馈回调写时刻）
    pthread_mutex_lock(&g_wm);
    if (st == 0) while (g_wgen == gen) pthread_cond_wait(&g_wc, &g_wm);
    else {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += timeout_ms / 1000; ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000; if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
        while (g_wgen == gen && pthread_cond_timedwait(&g_wc, &g_wm, &ts) == 0) {}
    }
    pthread_mutex_unlock(&g_wm);
    return st;
}
// Vulkan PreFrame 只清同步对象；这里顺手把已完成的计数收进已出队列（C# PreFrame 随后 Update 取走）
NXGAL_API void nxgal_pre_frame(void) { GAL_API_LOCK(); collect(); }

// 条件渲染：恒返回 0（Gpu 层走 CPU 判定：evt.Flush() 等结果写回客体内存再比较——ConditionalRendering.cs）。
// 「结果已出时返回 1 + C 端按结果跳过绘制」不比返回 0 快：结果已出时 CPU 路径的 Flush 是空操作（NxCounterEvent.Done），只剩一次客体内存读；
// 结果未出时返回 1 需要 GPU 端谓词（Metal 没有），只能等——与 CPU 路径同价。故不做。
NXGAL_API int32_t nxgal_cond_begin(uint32_t ev, uint64_t compare, uint32_t ev2, int32_t is_equal) { GAL_API_LOCK();
    (void)ev; (void)compare; (void)ev2; (void)is_equal;
    return 0;
}
NXGAL_API void nxgal_cond_end(void) { GAL_API_LOCK();}

// Runs after counter consumer and command-buffer callbacks have joined/drained.
void gal_cnt_reset_session(void) {
    for (int t = 0; t < CNT_NTYPES; t++) {
        cb_drop(&g_cur[t].cb);
        for (int i = g_q[t].head; i < g_q[t].n; i++) cb_drop(&g_q[t].q[i].cb);
        free(g_q[t].q); g_q[t] = (cnt_queue){0};
        g_cur[t] = (cnt_cur){.slot = -1, .seg = -1};
    }
    if (g_vis) gal_res_remove(g_vis);
    g_vis = nil; g_cev = nil; g_cseq = 0; g_applied_off = -1; g_next_id = 0;
    memset(g_free, 0, sizeof g_free); memset(g_slot_next, -1, sizeof g_slot_next); g_nfree = 0;
    memset(g_ts_fence, 0, sizeof g_ts_fence); memset(g_ts_end, 0, sizeof g_ts_end);
    free(g_rid); free(g_rval); g_rid = NULL; g_rval = NULL; g_nready = g_capready = 0;
    wake_waiter();
}
GAL_MTL4_ZONE_END
