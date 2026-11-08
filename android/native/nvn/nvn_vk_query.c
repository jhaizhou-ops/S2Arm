// 遮挡查询（NVN_COUNTER_TYPE_SAMPLES_PASSED）的 Vulkan 实现：真实 query pool + 完成证明后写回。
// 只写 counter（+0 的 8 字节）；NVNcounterData 的 timestamp（+8）属于 §6.1.3 的 GPU/guest 时间基准
// 合同，尚未定义并验证，本模块不写、也不拿 CPU 时钟冒充（不伪造没实现的字段）。
//
// 结构（替换“全局单池 + 单窗口”的头阻塞设计）：
//  * 物理槽按“提交批次”持有：一页 = 一个 VkQueryPool（默认 512 槽），归属一个提交批次；
//    该批次拿到完成证明（fence 已过）时把结果复制进 CPU 段日志，页随即回收复用。
//  * 报告只存稳定逻辑边界 {epoch, count}，不存数值：写回时按段日志求和。后到的结果只改
//    自己那条段，绝不污染早先报告（段7→Report A 得 7；段11→Report B 得 18）。
//  * 一页用完可以再取一页：换页点只能在**命令缓冲开头**（render pass 之外，唯一合法记录
//    `vkCmdResetQueryPool` 的位置）；本仓没有启用 hostQueryReset 特性，所以 pass 内页满只能准确失败。
//    取不到页 = 准确失败，绝不静默丢计数、绝不写 0。
//  * 等待只发生在合法提交边界：提交成功后由调用方登记，完成证明后在既有 fence 退休路径回收。
//  * 整页按“已完成”处理依赖一条不变式（由调用方保证，见 nvn_vk_query_batch_abandoned 的注释）：
//    **录了查询的命令缓冲，要么随它所属的那一批一起提交成功，要么连页一起作废**；绝不允许
//    “命令缓冲丢了、页还留着” —— 那会让 WAIT 读等到一个永远不会完成的查询（旧版本 20 秒必崩的根因）。
#include "nvn_vk_query.h"
#include "nvn_vk_ts_math.h"
#include "nvn_vk_ts_queue.h"
#include <math.h>
#include <time.h>

#include <android/log.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/system_properties.h>
#include <stdio.h>
#include <string.h>

#define QP_LOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", "samples-passed: " __VA_ARGS__)

#define QP_PAGE_SLOTS 4096u          // 一页槽数（初始参数；段 = pass 内连续计数绘制，Report/Reset 也切段）
// 一个提交批次共用一页；跨多个 pass（命令缓冲）累计段。为保证“任一 pass 开始录时本页都还够一整段 pass 的余量”，
// 在每个 pass 开始处（cb_begin，render pass 之外，唯一合法换页点）若本页剩余 < 该余量就先换新页，避免 pass 内页满。
// 取半页：既覆盖“多 pass 累计挤占余量”的反例（8×513），又不影响普通批次（本款每批仅几十段，永不触发）。
#define QP_PAGE_ROTATE_MARGIN (QP_PAGE_SLOTS / 2u)
#define QP_PAGES 64                 // 同时持有的页数上限（在途批次 × 每批页数）
#define QP_SEG_MAX 262144u          // 段日志硬上限（压缩后仍不够就准确失败）
#define QP_EP_MAX 8192u             // epoch 记录上限（跨 256 次 Reset 的验收要求远小于此）
#define QP_REP_MAX 4096u            // 待写报告上限

// 页状态机：0 空闲（可复用）/ 1 录制中（属于 Q.batch）/ 2 已提交未完成（batch = 提交序号）。
//
// 整页在 state==2 且 fence 等到后带 WAIT 读，前提是**页里每个 begin 过的查询都真的随这批执行了**。
// 该不变式由三处保证：
//  ① pass 重开：同一命令缓冲内只开一个 render pass，段（begin/end）都录在同一个命令缓冲里，
//     页只在 cb_begin（pass 之外）追加/换页，所以页与命令缓冲的绑定在录制期不会被动过；
//  ② 命令缓冲提交失败 / 被丢弃：调用方**必须**调 nvn_vk_query_batch_abandoned()（帧队列进终态时
//     nvn_vk_first_draw.c 的 fd_fq_fail 会调），把本批录制中的页整页作废（used 归零 + 下次复用前整段 reset），
//     于是这些槽永远不会被登记、也不会被 WAIT 读；
//  ③ 会话重建：nvn_vk_query_release_device() 丢弃全部页归属（已提交未完成的页保留句柄随设备销毁，
//     绝不读结果——不伪造完成）。
struct qp_page {
    VkDevice dev;
    VkQueryPool pool;
    uint32_t cap;
    uint32_t used;
    uint64_t batch;                 // 所属提交批次号（0 = 空闲）
    int state;                      // 0 = 空闲可复用，1 = 录制中，2 = 已提交未完成
    int cmd_reset_pending;          // 没有 host reset 时，下次命令缓冲开头要记录一次 vkCmdResetQueryPool
    int init_full;                  // 1 = 该池自创建以来还没做过整池初始化（首次使用要 reset 0..cap）
    uint32_t reset_hi;              // 自上次整池初始化后被真正开始过查询的最高槽+1；复用时只需 reset 0..reset_hi
    uint32_t seg[QP_PAGE_SLOTS];    // 槽 → 段日志索引
};

struct qp_seg { uint32_t epoch; uint64_t value; int known; };
// first = 段日志里该 epoch 还保留的第一段；folded = 已经折入累计值的段和（索引 < first 的前缀）。
// 这样长期不 Reset 时也能把“已完成且不再被任何未写报告逐段引用”的前缀折成累计值，段日志不会无限涨。
// wr_k/wr_sum = 写回增量游标（上次写到哪一段、累计多少），把 O(报告×前缀) 降到摊还 O(段)。
struct qp_epoch { uint32_t id; uint32_t first; int live; uint64_t folded; uint32_t wr_k; uint64_t wr_sum; };
struct qp_report { uint64_t addr; struct s2a_record_memory mem; uint32_t epoch; uint32_t count; };

struct qp_state {
    VkDevice dev;
    int counting;
    int failed;
    char fail[200];
    uint32_t epoch;
    uint64_t batch, next_batch;
    struct qp_page page[QP_PAGES];
    struct qp_seg *seg;
    uint32_t seg_n, seg_cap;
    uint64_t *readbuf;              // 结果读回复用缓冲（避免每页 malloc/free 抖动）
    uint32_t readbuf_cap;
    struct qp_epoch ep[QP_EP_MAX];
    uint32_t ep_n;
    struct qp_report rep[QP_REP_MAX];
    uint32_t rep_n;
    int cur_page;
    int seg_on;
    VkCommandBuffer seg_cmd;
    uint32_t seg_slot;
    struct nvn_vk_query_stats st;
    int noted_counting, noted_zero, noted_nonzero, noted_before_reset;
};
static struct qp_state Q;
// 重置只在命令缓冲开头用 vkCmdResetQueryPool：vkResetQueryPool 需要 VkPhysicalDeviceVulkan12Features::
// hostQueryReset，本仓 vk_device 只启用 1.0 特性集，调用它是未定义行为（真机 SIGSEGV）——所以本模块
// 不用 host reset，也没有对应开关。

static void qp_seterr(char *why, size_t n, const char *text) { if (why && n) snprintf(why, n, "%s", text); }
static int qp_fail(const char *text, char *why, size_t why_size) {
    if (!Q.failed) {
        Q.failed = 1;
        snprintf(Q.fail, sizeof Q.fail, "%s", text);
        Q.st.fails++;
        QP_LOG("query backend failed: %s (no counter value is written after this)", text);
    }
    if (why && why_size) snprintf(why, why_size, "%s", Q.fail);
    return NVN_VK_QUERY_FAILED;
}
static void qp_set(char *why, size_t n, const char *t) { if (why && n) snprintf(why, n, "%s", t); }
// 可重试拒绝：页都还在途、资源全部保留、帧队列没进终态，所以**不**把查询模块打成终态
// （Q.failed 保持 0，nvn_vk_query_terminal_ready 的“未就绪”只因还有在途页/批次，不是坏状态）：
// 这一笔绘制准确失败，下一次提交边界（新的命令缓冲开头）还能继续尝试回收与计数。
// Q.st.fails 是统计计数（一次失败的页分配），与 qp_fail 的终态 fails 同列，靠 Q.failed 区分。
// 日志只打前 4 次：慢帧里每个 pass 都可能命中一次，逐次打印会刷爆 logcat。
static int qp_refuse(const char *text, char *why, size_t why_size) {
    Q.st.fails++;
    static int noted;
    if (noted++ < 4) QP_LOG("query page acquire refused (retryable at the next submit boundary): %s", text);
    if (why && why_size) snprintf(why, why_size, "%s", text);
    return NVN_VK_QUERY_FAILED;
}
static uint64_t qp_mono_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void nvn_vk_query_stats(struct nvn_vk_query_stats *out) { if (out) *out = Q.st; }
int nvn_vk_query_counting(void) { return Q.counting; }
int nvn_vk_query_immediate_mode(void) {
    static int cached = -1;
    if (cached < 0) {
        char v[PROP_VALUE_MAX] = {0};
        __system_property_get("debug.s2a.query_wait", v);
        cached = (v[0] == '1');
    }
    return cached;
}
void nvn_vk_query_debug(char *out, size_t n) {
    if (!out || !n) return;
    uint32_t used = (Q.cur_page >= 0) ? Q.page[Q.cur_page].used : 0;
    snprintf(out, n, "counting=%d seg_on=%d batch=%llu page=%d used=%u cap=%u segs=%u reps=%u epochs=%u failed=%d",
             Q.counting, Q.seg_on, (unsigned long long)Q.batch, Q.cur_page, used,
             Q.cur_page >= 0 ? Q.page[Q.cur_page].cap : 0, Q.seg_n, Q.rep_n, Q.ep_n, Q.failed);
}

// ---- 段日志（CPU 侧真实值，报告的唯一依据）----
static struct qp_epoch *qp_epoch_find(uint32_t id);

// 压缩段日志：把 [0, drop) 这段已完成、且不再被任何未写报告/在途页逐段引用的前缀折进各自 epoch 的累计值
// （folded），然后整体前移。返回 0 = 压掉了；-1 = 当前没有可安全折叠的前缀（调用方再扩容/准确失败）。
//
// 安全边界：
//   drop <= 每一条未写报告的 count —— 折叠绝不跨过报告要逐段求和的边界（否则会把 7 变 25）。
//   drop <= 每个在途页引用的最小段索引 —— 页里保存的是段日志索引，折掉后不更新就会指到别的段。
//   只能在段值已知后折叠：active 页排除在 drop 之外，故 [0,drop) 必为已读回的已知段；若不成立就放弃本次压缩。
static int qp_compact(void) {
    uint32_t drop = Q.seg_n;
    for (uint32_t i = 0; i < Q.rep_n; i++) if (Q.rep[i].count < drop) drop = Q.rep[i].count;
    for (int pi = 0; pi < QP_PAGES; pi++) {
        struct qp_page *pp = &Q.page[pi];
        if (pp->state == 0 || !pp->used) continue;
        for (uint32_t sl = 0; sl < pp->used; sl++) if (pp->seg[sl] < drop) drop = pp->seg[sl];
    }
    if (!drop) return -1;
    for (uint32_t k = 0; k < drop; k++) if (!Q.seg[k].known) return -1;
    // 逐段按它自己的 epoch 归属折进对应累计值（epoch 之间不串账）。
    for (uint32_t k = 0; k < drop; k++) {
        struct qp_epoch *e = qp_epoch_find(Q.seg[k].epoch);
        if (e) e->folded += Q.seg[k].value;
    }
    memmove(&Q.seg[0], &Q.seg[drop], (size_t)(Q.seg_n - drop) * sizeof Q.seg[0]);
    Q.seg_n -= drop;
    for (uint32_t i = 0; i < Q.ep_n; i++) {
        struct qp_epoch *e = &Q.ep[i];
        e->first = e->first >= drop ? e->first - drop : 0;
        e->wr_k = e->first; e->wr_sum = e->folded;   // 折叠后游标重置，保证累计不丢不重
    }
    for (uint32_t i = 0; i < Q.rep_n; i++)
        Q.rep[i].count = Q.rep[i].count >= drop ? Q.rep[i].count - drop : 0;
    for (int pi = 0; pi < QP_PAGES; pi++) {
        struct qp_page *pp = &Q.page[pi];
        if (pp->state == 0 || !pp->used) continue;
        for (uint32_t sl = 0; sl < pp->used; sl++)
            pp->seg[sl] = pp->seg[sl] >= drop ? pp->seg[sl] - drop : 0;
    }
    return 0;
}

static int qp_seg_push(uint32_t epoch, uint32_t *index_out) {
    if (Q.seg_n >= Q.seg_cap) {
        (void)qp_compact();   // 先尽量折掉已完成前缀；折不动才扩容
        if (Q.seg_n >= Q.seg_cap) {
            uint32_t cap = Q.seg_cap ? Q.seg_cap * 2u : 4096u;
            if (cap > QP_SEG_MAX) cap = QP_SEG_MAX;
            if (cap <= Q.seg_cap) return -1;
            struct qp_seg *nv = (struct qp_seg *)realloc(Q.seg, (size_t)cap * sizeof *nv);
            if (!nv) return -1;
            Q.seg = nv; Q.seg_cap = cap;
        }
    }
    Q.seg[Q.seg_n].epoch = epoch;
    Q.seg[Q.seg_n].value = 0;
    Q.seg[Q.seg_n].known = 0;
    *index_out = Q.seg_n++;
    return 0;
}

static struct qp_epoch *qp_epoch_find(uint32_t id) {
    for (uint32_t i = 0; i < Q.ep_n; i++) if (Q.ep[i].id == id) return &Q.ep[i];
    return NULL;
}
static struct qp_epoch *qp_epoch_open(uint32_t id, char *why, size_t why_size) {
    struct qp_epoch *e = qp_epoch_find(id);
    if (e) { e->live = 1; return e; }
    if (Q.ep_n >= QP_EP_MAX) {
        uint32_t w = 0;
        for (uint32_t i = 0; i < Q.ep_n; i++) {
            int keep = (Q.ep[i].id == Q.epoch);
            for (uint32_t r = 0; !keep && r < Q.rep_n; r++) if (Q.rep[r].epoch == Q.ep[i].id) keep = 1;
            if (keep) Q.ep[w++] = Q.ep[i];
        }
        Q.ep_n = w;
        if (Q.ep_n >= QP_EP_MAX) { qp_fail("epoch table full while reports are still pending", why, why_size); return NULL; }
    }
    e = &Q.ep[Q.ep_n++];
    e->id = id; e->first = Q.seg_n; e->live = 1; e->folded = 0; e->wr_k = Q.seg_n; e->wr_sum = 0;
    return e;
}

// 及时回收“既不是当前 epoch、也没有任何待写报告引用”的旧 epoch：否则 ep_n 只增不减，
// qp_epoch_find / live 重算每次都线性扫过全部历史 epoch（宿主夹具实测 254951635 次比较）。
// 回收安全：旧 epoch 的段只会被它自己的报告逐段求和；没有待写报告引用它，就不需要它的记录，
// 其残段会在后续压缩里被丢弃（无 base 归属，但没有报告读它）。
static void qp_epoch_prune(void) {
    uint32_t w = 0;
    for (uint32_t i = 0; i < Q.ep_n; i++) {
        struct qp_epoch *e = &Q.ep[i];
        int keep = (e->id == Q.epoch);
        for (uint32_t r = 0; !keep && r < Q.rep_n; r++) if (Q.rep[r].epoch == e->id) keep = 1;
        if (keep) Q.ep[w++] = Q.ep[i];
    }
    Q.ep_n = w;
}

// ---- 页管理 ----
static void qp_page_release(struct qp_page *p) { p->state = 0; p->batch = 0; p->used = 0; }

// 页全部在途时，回到合法提交边界：有界等待帧队列给出完成证明，该批次的页随即回收
// （约束 4：只在提交边界等待，pass 内绝不等待未提交的查询）。
// P0-leak ③：这里**不许**用 nvn_vk_first_draw_flush()——它是 5 s 超时即终态（FD_FQ_TIMEOUT）的语义，
// 慢 GPU / 长批次一次页耗尽就会把整个帧队列判死。改用 flush_ready(budget)：预算耗尽返回 1 =
// “命令已提交、资源全部保留、下次提交边界继续等”，是准确失败而不是终态。
#define QP_RECLAIM_BUDGET_NS (200ll * 1000000ll)   // 一次页耗尽的回收预算（远小于 5 s 终态阈值）
extern int nvn_vk_first_draw_flush_ready(int64_t budget_ns) __attribute__((weak));
static int qp_in_flush;
static int qp_page_acquire(char *why, size_t why_size) {
    for (int i = 0; i < QP_PAGES; i++) {
        if (Q.page[i].state == 0 && Q.page[i].pool && Q.page[i].dev == Q.dev) {
            Q.cur_page = i;
            Q.page[i].cmd_reset_pending = 1;   // 整页重置只能在命令缓冲开头（hostQueryReset 特性未启用，不能调 vkResetQueryPool）
            Q.page[i].used = 0; Q.page[i].state = 1; Q.page[i].batch = Q.batch;
            return 0;
        }
    }
    for (int i = 0; i < QP_PAGES; i++) {
        if (Q.page[i].pool && Q.page[i].dev == Q.dev) continue;
        if (Q.page[i].pool && Q.page[i].dev != Q.dev) {   // 旧设备的页随旧设备回收，不跨设备销毁
            Q.page[i].pool = VK_NULL_HANDLE; Q.page[i].dev = NULL; Q.page[i].state = 0; Q.page[i].used = 0;
        }
        VkQueryPoolCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        ci.queryType = VK_QUERY_TYPE_OCCLUSION;
        ci.queryCount = QP_PAGE_SLOTS;
        VkQueryPool pool = VK_NULL_HANDLE;
        if (vkCreateQueryPool(Q.dev, &ci, NULL, &pool) != VK_SUCCESS)
            return qp_fail("vkCreateQueryPool(VK_QUERY_TYPE_OCCLUSION) failed", why, why_size);
        Q.page[i].dev = Q.dev; Q.page[i].pool = pool; Q.page[i].cap = QP_PAGE_SLOTS;
        Q.page[i].used = 0; Q.page[i].state = 1; Q.page[i].batch = Q.batch;
        Q.cur_page = i;
        Q.page[i].cmd_reset_pending = 1;
        Q.page[i].init_full = 1; Q.page[i].reset_hi = 0;   // 新池：首次使用整池初始化一次
        return 0;
    }
    if (!qp_in_flush && nvn_vk_first_draw_flush_ready) {
        static int noted_exhausted;
        if (!noted_exhausted++) {
            noted_exhausted = 1;
            QP_LOG("query page pool exhausted (all %d pages in flight): bounded reclaim wait at a legal "
                   "submit boundary (%lld ms, non-terminal)", QP_PAGES, (long long)(QP_RECLAIM_BUDGET_NS / 1000000));
        }
        qp_in_flush = 1;
        int frc = nvn_vk_first_draw_flush_ready(QP_RECLAIM_BUDGET_NS);
        qp_in_flush = 0;
        if (frc < 0) return qp_fail("query page reclaim: frame queue reported a failure (its terminal state kept)", why, why_size);
        if (frc == 0) {
            // 全部已提交命令都拿到完成证明：把已提交页全部读结果并回收。
            if (nvn_vk_query_reclaim_all(why, why_size) != 0) return NVN_VK_QUERY_FAILED;
            if (Q.batch == 0) Q.batch = ++Q.next_batch;   // flush 提交后批次号已清：为继续录制开新批
            for (int i = 0; i < QP_PAGES; i++) {
                if (Q.page[i].state == 0 && Q.page[i].pool && Q.page[i].dev == Q.dev) {
                    Q.cur_page = i;
                    Q.page[i].cmd_reset_pending = 1;
                    Q.page[i].used = 0; Q.page[i].state = 1; Q.page[i].batch = Q.batch;
                    return 0;
                }
            }
        } else {
            // frc == 1：预算内没有完成证明。命令已提交、页与写回账本全部保留，帧队列**没有**进终态；
            // 本次查询分配准确失败，下一次提交边界再试（不把一次页耗尽当成终态）。
            return qp_refuse("query page pool exhausted and the bounded reclaim wait did not complete "
                             "(resources retained, retry at the next submit boundary)", why, why_size);
        }
    }
    {
        int s1 = 0, s2 = 0;
        for (int i = 0; i < QP_PAGES; i++) { if (Q.page[i].state == 1) s1++; else if (Q.page[i].state == 2) s2++; }
        char msg[200];
        snprintf(msg, sizeof msg, "all query pages in flight (recording=%d submitted=%d of %d, batch=%llu)",
                 s1, s2, QP_PAGES, (unsigned long long)Q.batch);
        return qp_fail(msg, why, why_size);
    }
}

static int qp_ensure(char *why, size_t why_size) {
    if (!Q.dev) return qp_fail("query: no Vulkan device", why, why_size);
    if (Q.seg) return 0;
    Q.seg_cap = 4096u;
    Q.seg = (struct qp_seg *)calloc(Q.seg_cap, sizeof *Q.seg);
    if (!Q.seg) { Q.seg_cap = 0; return qp_fail("query segment log allocation failed", why, why_size); }
    return 0;
}

// 命令缓冲开头（render pass 之外）：为本批录制取一页。第一次 Reset 之后才开始计。
// 页选择/回收（含页耗尽时的有界等待式回收）必须在**取得并开始录制命令缓冲之前**完成：
// 回收路径会 flush 帧队列，而 flush 会封口并提交当前批次命令缓冲；若此时正是本 pass 将要录制的
// 那条缓冲（已经 vkBeginCommandBuffer），提交后再往上录命令会直接崩（真机 SIGSEGV fault 0x74）。
// 因此拆成 prepare（无命令录制，可在 cmd 之前调用）与 cb_record（只录 query pool reset）。
int nvn_vk_query_prepare(struct s2a_vk_device *d, char *why, size_t why_size) {
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    if (!Q.counting) return 0;
    if (!d || !d->device) return qp_fail("query: device unavailable at command buffer begin", why, why_size);
    if (!d->core_features.occlusionQueryPrecise)
        return qp_fail("occlusionQueryPrecise is not enabled; precise samples-passed is unavailable", why, why_size);
    if (Q.dev != d->device) {
        for (int i = 0; i < QP_PAGES; i++) {
            if (Q.page[i].pool && Q.page[i].dev != d->device) {   // 旧设备：句柄随它回收
                Q.page[i].pool = VK_NULL_HANDLE; Q.page[i].dev = NULL; Q.page[i].state = 0; Q.page[i].used = 0;
            }
        }
        Q.dev = d->device;
        Q.cur_page = -1;
        // 设备切换：旧设备的页句柄随旧设备回收（不跨设备销毁）。若旧会话还有未写报告，它们的前缀
        // 永远拿不到结果——这是**设备切换**导致的失结果，下面 resolve_blocking 会准确报红；这里先记一行，
        // 免得真机上只看到“results not ready”这种笼统原因。
        if (Q.rep_n || Q.seg_n) {
            QP_LOG("device changed with %u pending report(s) / %u segment(s) from the previous device: "
                   "their prefix can never be read back (accurate failure follows, no fake zero)",
                   (unsigned)Q.rep_n, (unsigned)Q.seg_n);
        }
    }
    if (qp_ensure(why, why_size)) return NVN_VK_QUERY_FAILED;
    if (Q.batch == 0) Q.batch = ++Q.next_batch;
    // 同一提交批次共用一页（整页 reset 只需在该批第一个命令缓冲开头记录一次）；
    // 批内跨多个命令缓冲继续用同一页，不能每缓冲一页（世界加载时会把页表吃光）。
    // 但一页填满后必须换页：本函数一定在 render pass 之外（每条命令缓冲只有一个 pass），
    // 是唯一合法的“追加并 reset 新页”的位置，因此按批累积的段数不再受单页 4096 的硬上限。
    int need_page = !(Q.cur_page >= 0 && Q.page[Q.cur_page].state == 1 && Q.page[Q.cur_page].batch == Q.batch);
    if (!need_page) {
        struct qp_page *c = &Q.page[Q.cur_page];
        uint32_t rem = c->cap > c->used ? c->cap - c->used : 0;
        if (rem < QP_PAGE_ROTATE_MARGIN) need_page = 1;   // 余量不足以容纳下一段 pass：本 pass 开始处先换页
    }
    if (need_page) {
        if (qp_page_acquire(why, why_size)) return NVN_VK_QUERY_FAILED;
        {
            // 页池使用率窗口日志：某款游戏一批跨多页、或延迟 present 叠了几帧时，能提前看到余量吃紧。
            int busy = 0;
            for (int i = 0; i < QP_PAGES; i++) if (Q.page[i].state != 0) busy++;
            if (busy * 4 >= QP_PAGES * 3) {
                static unsigned last_pct;
                unsigned pct = (unsigned)(busy * 100 / QP_PAGES);
                if (pct / 10 != last_pct / 10) {
                    last_pct = pct;
                    QP_LOG("query page pool usage %d/%d (%u%%)", busy, QP_PAGES, pct);
                }
            }
        }
    }
    return 0;
}

int nvn_vk_query_cb_begin(struct s2a_vk_device *d, VkCommandBuffer cmd, char *why, size_t why_size) {
    (void)d;
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    if (!Q.counting) return 0;
    if (!cmd) return qp_fail("query: null command buffer", why, why_size);
    if (Q.cur_page < 0 || Q.cur_page >= QP_PAGES) return qp_fail("query: no recording page prepared", why, why_size);
    struct qp_page *p = &Q.page[Q.cur_page];
    if (p->cmd_reset_pending) {
        // 没有 host query reset 的设备：reset 必须在 render pass 之外，这里正好是命令缓冲开头。
        // 首次使用整池初始化一次；之后复用只 reset 上次真正开始过查询的范围 [0, reset_hi)，
        // 而不是把池容量 cap 当成每次必做的工作量（真机反例：每帧只用到 46 个槽，却 reset
        // 24576 个，约 534 倍，直接把 pass open 的 rest 从 2.8us 抬到 43.9us）。
        uint32_t cnt = p->init_full ? p->cap : p->reset_hi;
        if (cnt) vkCmdResetQueryPool(cmd, p->pool, 0, cnt);
        p->init_full = 0;
        p->cmd_reset_pending = 0;
        p->reset_hi = 0;   // 清本轮高水位：读回后按本轮实际用到的槽重设，不保留历史最大值
    }
    return 0;
}

int nvn_vk_query_draw_begin(struct s2a_vk_device *d, VkCommandBuffer cmd, char *why, size_t why_size) {
    (void)d;
    if (!Q.counting || Q.seg_on) return 0;
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    if (!cmd) return qp_fail("query: null command buffer", why, why_size);
    if (Q.cur_page < 0) return qp_fail("query segment begins with no recording page", why, why_size);
    struct qp_page *p = &Q.page[Q.cur_page];
    if (p->used >= p->cap) {
        // 这一页在当前 render pass 内被塞满。Vulkan 规范禁止在 render pass 内记录
        // vkCmdResetQueryPool，所以这里“换页并 reset”是不可能的；first_draw 每条命令缓冲只开一个
        // pass、单 pass 段数远小于页容量，实际不会走到。真走到只能准确失败，绝不做违规 reset。
        return qp_fail("query page full inside one render pass; a new page cannot be reset inside a pass",
                       why, why_size);
    }
    uint32_t index = 0;
    if (qp_seg_push(Q.epoch, &index)) return qp_fail("query segment log is full", why, why_size);
    uint32_t slot = p->used++;
    p->seg[slot] = index;
    vkCmdBeginQuery(cmd, p->pool, slot, VK_QUERY_CONTROL_PRECISE_BIT);
    Q.seg_cmd = cmd;
    Q.seg_slot = slot;
    Q.seg_on = 1;
    Q.st.slots++;
    return 0;
}

void nvn_vk_query_pass_end(void) {
    if (!Q.seg_on) return;
    if (Q.cur_page >= 0) vkCmdEndQuery(Q.seg_cmd, Q.page[Q.cur_page].pool, Q.seg_slot);
    Q.seg_on = 0;
    Q.st.segments++;
}

int nvn_vk_query_reset_run(struct s2a_vk_device *d, char *why, size_t why_size) {
    (void)d;
    nvn_vk_query_pass_end();
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    int first = !Q.counting;
    Q.counting = 1;
    Q.st.resets++;
    if (first && !Q.noted_counting++)
        QP_LOG("counting enabled by the first ResetCounter: real cumulative samples-passed");
    Q.epoch++;
    if (!qp_epoch_open(Q.epoch, why, why_size)) return NVN_VK_QUERY_FAILED;
    qp_epoch_prune();   // 及时回收无引用的旧 epoch，避免表越积越大、查找越扫越久
    return first ? NVN_VK_QUERY_NEED_PASS : 0;
}

int nvn_vk_query_report(struct s2a_vk_device *d, const struct s2a_record_memory *memory,
                        uint64_t addr, char *why, size_t why_size) {
    (void)d;
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    if (!memory || !memory->write) return qp_fail("query report: no guest write entry", why, why_size);
    if (!addr) return qp_fail("query report: null counter address", why, why_size);
    if (!Q.counting) {
        // 第一次 Reset 之前（含会话刚重建）：没有任何被计数的绘制，前端模型与 Metal 一致写 0。
        // 直接同步写回，不建 epoch / 不排队：否则会把上一局的 epoch/报告状态带进新会话。
        Q.st.before_reset_reports++;
        if (!Q.noted_before_reset++) QP_LOG("counter reported before any ResetCounter: writing 0 (frontend model)");
        uint64_t zero = 0;
        if (memory->write(memory->opaque, addr, &zero, sizeof zero) != 0)
            return qp_fail("writing the samples-passed counter to guest memory failed", why, why_size);
        Q.st.reports++;
        if (!Q.noted_zero++) QP_LOG("first zero report: addr=%#llx", (unsigned long long)addr);
        return 0;
    }
    if (Q.seg_on) {
        nvn_vk_query_pass_end();
        if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    }
    if (Q.rep_n >= QP_REP_MAX) return qp_fail("pending report table full", why, why_size);
    if (!qp_epoch_open(Q.epoch, why, why_size)) return NVN_VK_QUERY_FAILED;
    struct qp_report *r = &Q.rep[Q.rep_n++];
    r->addr = addr; r->mem = *memory; r->epoch = Q.epoch; r->count = Q.seg_n;   // 稳定逻辑边界
    return 0;
}

// ---- 提交 / 完成（由帧队列的既有提交与 fence 退休路径调用）----
void nvn_vk_query_batch_submitted(uint64_t seq) {
    if (!Q.batch) return;
    for (int i = 0; i < QP_PAGES; i++)
        if (Q.page[i].state == 1 && Q.page[i].batch == Q.batch) { Q.page[i].state = 2; Q.page[i].batch = seq; }
    Q.batch = 0;
    Q.cur_page = -1;
}

// 本批**不会提交了**（提交失败 / 命令缓冲被丢弃 / 帧队列进终态）：把本批所有“录制中”的页整页作废。
// 不变式的另一半（见 struct qp_page 的注释）：绝不能出现“命令缓冲丢了、页还留着”——那些槽里记录的
// begin 永远不会执行，一旦页被标成已提交并带 WAIT 读，渲染线程会等一个永远不完成的查询。
// 作废 = 槽位归零（不进结果、不进报告）+ 下次复用前整段 reset（phantom 查询连执行机会都没有）。
void nvn_vk_query_batch_abandoned(void) {
    if (!Q.batch) return;
    unsigned dropped = 0;
    for (int i = 0; i < QP_PAGES; i++) {
        struct qp_page *p = &Q.page[i];
        if (p->state != 1 || p->batch != Q.batch) continue;
        p->used = 0;
        p->cmd_reset_pending = 1;
        p->init_full = 0;      // 池本身仍是“已整池初始化”状态，复用只 reset 已用范围即可
        p->reset_hi = 0;
        p->state = 0;
        p->batch = 0;
        Q.cur_page = -1;
        dropped++;
    }
    Q.batch = 0;
    static int noted;
    if (dropped && !noted++) {
        noted = 1;
        QP_LOG("abandoned %u recording page(s): their batch will never be submitted "
               "(no result is read for them; counts from those passes are not written)", dropped);
    }
}

// 读一页的真实结果并回收。调用方必须已拿到该页所属提交的完成证明。
static int qp_page_read(struct qp_page *p, char *why, size_t why_size) {
    if (!p->pool || p->dev != Q.dev) { p->reset_hi = 0; qp_page_release(p); return 0; }
    if (!p->used) { p->reset_hi = 0; qp_page_release(p); return 0; }
    // 一页一次批量读（每槽单独一次调用在真机上把帧率打到 32fps：几十页 × 数千槽/帧）。
    // 复用缓冲：不再每页 malloc/free（每帧几十页的分配抖动也会压帧）。
    if (Q.readbuf_cap < p->used) {
        uint32_t cap = Q.readbuf_cap ? Q.readbuf_cap : 4096u;
        while (cap < p->used) cap *= 2u;
        if (cap > QP_PAGE_SLOTS) cap = QP_PAGE_SLOTS;
        uint64_t *nv = (uint64_t *)realloc(Q.readbuf, (size_t)cap * sizeof *nv);
        if (!nv) return qp_fail("query page read buffer allocation failed", why, why_size);
        Q.readbuf = nv; Q.readbuf_cap = cap;
    }
    uint64_t *vals = Q.readbuf;
    const uint64_t read_t0 = qp_mono_ns();
    VkResult vr = vkGetQueryPoolResults(p->dev, p->pool, 0, p->used, (size_t)p->used * sizeof *vals, vals,
                                        sizeof *vals, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
    {
        // 页已经有完成证明，正常应当立刻返回；真等出 1 ms 说明 fence→结果可读之间还有延迟，
        // 这一行用来定位“为什么渲染线程被查询卡住”（只在超阈值时打，不刷屏）。
        const uint64_t took = qp_mono_ns() - read_t0;
        if (took > 1000000ull) {
            static unsigned noted_slow;
            if (noted_slow++ < 8)
                QP_LOG("vkGetQueryPoolResults(WAIT) took %.2f ms for %u slots", (double)took / 1e6, p->used);
        }
    }
    if (vr != VK_SUCCESS) {
        char msg[200];
        snprintf(msg, sizeof msg, "vkGetQueryPoolResults failed for a completed page (%u slots, VkResult=%d)",
                 p->used, (int)vr);
        return qp_fail(msg, why, why_size);
    }
    for (uint32_t s = 0; s < p->used; s++) {
        uint32_t seg = p->seg[s];
        if (seg < Q.seg_n) { Q.seg[seg].value = vals[s]; Q.seg[seg].known = 1; }
    }
    // 记住“本轮真正用过的槽数”：复用这页时只需 reset [0, reset_hi)，不必整池 4096，也不保留历史最大值
    // （否则一次大批次之后，小批次会一直按大范围 reset）。
    p->reset_hi = p->used;
    qp_page_release(p);
    return 0;
}

int nvn_vk_query_batch_completed(uint64_t seq, char *why, size_t why_size) {
    if (Q.failed) return 0;
    for (int i = 0; i < QP_PAGES; i++)
        if (Q.page[i].state == 2 && Q.page[i].batch == seq)
            if (qp_page_read(&Q.page[i], why, why_size)) return NVN_VK_QUERY_FAILED;
    return 0;
}

// 一次完整 flush 成功后调用：此刻所有已提交命令都有完成证明，所有 state==2 的页都可以读结果并回收。
// 不依赖“哪个 fence 属于哪一批”的钩子是否被走到（真机实测那条路径不是唯一的退役入口）。
int nvn_vk_query_reclaim_all(char *why, size_t why_size) {
    if (Q.failed) return 0;
    for (int i = 0; i < QP_PAGES; i++)
        if (Q.page[i].state == 2)
            if (qp_page_read(&Q.page[i], why, why_size)) return NVN_VK_QUERY_FAILED;
    return 0;
}

// ---- 报告写回（按序、只写前缀已就绪的）----
static int qp_emit(const struct qp_report *r, uint64_t samples, char *why, size_t why_size) {
    if (r->mem.write(r->mem.opaque, r->addr, &samples, sizeof samples) != 0)
        return qp_fail("writing the samples-passed counter to guest memory failed", why, why_size);
    Q.st.reports++;
    Q.st.samples += samples;
    if (!samples) { Q.st.zero_reports++; if (!Q.noted_zero++) QP_LOG("first zero report: addr=%#llx", (unsigned long long)r->addr); }
    else if (!Q.noted_nonzero++) QP_LOG("first non-zero report: addr=%#llx samples=%llu", (unsigned long long)r->addr, (unsigned long long)samples);
    if (Q.st.reports % 64 == 0)
        QP_LOG("window: resets=%llu reports=%llu segments=%llu total_samples=%llu zero=%llu before_reset=%llu",
               (unsigned long long)Q.st.resets, (unsigned long long)Q.st.reports, (unsigned long long)Q.st.segments,
               (unsigned long long)Q.st.samples, (unsigned long long)Q.st.zero_reports,
               (unsigned long long)Q.st.before_reset_reports);
    return 0;
}

static int qp_write_reports(char *why, size_t why_size) {
    uint32_t done = 0;
    for (; done < Q.rep_n; done++) {
        struct qp_report *r = &Q.rep[done];
        struct qp_epoch *e = qp_epoch_find(r->epoch);
        if (!e) return qp_fail("report epoch record was recycled before writeback (no value written)", why, why_size);
        // 增量游标：只累加“上次写到 r->count”之间的新增段，写回总代价摊还 O(段数)，而不是
        // 每条报告都从 epoch 起点重算（那是把帧率从 60 拉到 29 的 O(报告×前缀)）。
        if (e->wr_k < e->first) { e->wr_k = e->first; e->wr_sum = e->folded; }
        if (e->wr_k > r->count) { e->wr_k = e->first; e->wr_sum = e->folded; }
        uint32_t k = e->wr_k;
        uint64_t add = 0;
        int ready = 1;
        for (; k < r->count; k++) { if (!Q.seg[k].known) { ready = 0; break; } add += Q.seg[k].value; }
        if (!ready) break;   // 顺序保证：前缀没齐不越过
        e->wr_sum += add;
        e->wr_k = r->count;
        if (qp_emit(r, e->wr_sum, why, why_size)) return NVN_VK_QUERY_FAILED;
    }
    if (done) {
        memmove(&Q.rep[0], &Q.rep[done], (size_t)(Q.rep_n - done) * sizeof Q.rep[0]);
        Q.rep_n -= done;
    }
    for (uint32_t i = 0; i < Q.ep_n; i++) {
        if (Q.ep[i].id == Q.epoch) { Q.ep[i].live = 1; continue; }
        int keep = 0;
        for (uint32_t r2 = 0; r2 < Q.rep_n; r2++) if (Q.rep[r2].epoch == Q.ep[i].id) { keep = 1; break; }
        Q.ep[i].live = keep;
    }
    return 0;
}

int nvn_vk_query_resolve(struct s2a_vk_device *d, char *why, size_t why_size) {
    (void)d;
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    return qp_write_reports(why, why_size);
}

int nvn_vk_query_resolve_blocking(struct s2a_vk_device *d, char *why, size_t why_size) {
    (void)d;
    if (Q.failed) { qp_set(why, why_size, Q.fail); return NVN_VK_QUERY_FAILED; }
    int rc = qp_write_reports(why, why_size);
    if (rc) return rc;
    if (Q.rep_n) return qp_fail("blocking query resolve left pending reports (results not ready)", why, why_size);
    return 0;
}

// ---- TIMESTAMP_TOP（0x10）：段顶时刻 ----
// 与遮挡查询分开的独立时间戳池。Vulkan 时间戳的起点由设备自定，不能直接 *period 当成
// guest_tick：有校准扩展时用 vkGetCalibratedTimestamps(DEVICE + CLOCK_MONOTONIC) 求 GPU 域
// 到单调钟的偏移，再按 guest_ns()-now_ns() 平移到游戏时钟；没有校准扩展时按 Metal 的兜底
// 口径，写回结算时刻的 guest_tick()。命令由帧队列录制/提交，完成点统一结算（不逐报告 submit）。
// 待写项按所属帧序号记账，退休只结算已拿到完成证明的帧；槽位是跨帧 FIFO 环。
#define TS_SLOTS 4096u
#define TS_PENDING TS_SLOTS
struct ts_pending {
    uint64_t addr;
    uint64_t frame_id;
    uint32_t slot;
    struct s2a_record_memory mem;
};
static struct {
    VkDevice dev;
    VkQueryPool pool;
    uint32_t valid_bits;
    double period;
    int cal_kind;                  // 0 = 无校准扩展（完成点 guest_tick 兜底），1 = KHR，2 = EXT
    PFN_vkGetCalibratedTimestampsKHR get_ts;
    int failed;
    struct s2a_ts_queue fifo;      // 跨帧 FIFO：帧序号 + 槽位复用
    struct s2a_ts_slot_ref slots[TS_SLOTS];
    struct ts_pending pend[TS_PENDING];
    int pend_n;
    uint64_t written;
} TS;

// 生产构建链接 runtime/src/os.c（强符号）；微例/宿主单测不链接时按弱符号回落到单调钟。
extern uint64_t guest_ns(void) __attribute__((weak));
extern uint64_t guest_tick(void) __attribute__((weak));
extern uint64_t now_ns(void) __attribute__((weak));
// 帧队列入口（生产链接 nvn_vk_first_draw.c；微例不链接时走同步记录路径）。
extern int nvn_vk_first_draw_timestamp_top(struct s2a_vk_device *d, VkQueryPool pool, uint32_t slot,
                                           char *why, size_t why_size) __attribute__((weak));
extern uint64_t nvn_vk_first_draw_frame_id(void) __attribute__((weak));

static uint64_t ts_mono_now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static uint64_t ts_game_ns_now(void) {
    if (guest_ns) {
        uint64_t g = guest_ns();
        if (g) return g;
    }
    return ts_mono_now();
}
static uint64_t ts_game_tick_now(void) {
    if (guest_tick) {
        uint64_t t = guest_tick();
        if (t) return t;
    }
    return ts_game_ns_now() * 12 / 625;
}

static int ts_fail(int code, const char *text, char *why, size_t why_size) {
    if (!TS.failed) {
        TS.failed = 1;
        QP_LOG("timestamp-top failed: %s", text);
    }
    qp_seterr(why, why_size, text);
    return code;
}

static uint64_t ts_mask_ticks(uint64_t v) { return v & s2a_ts_valid_mask(TS.valid_bits); }

// 建池前读图形队列族的 timestampValidBits；为 0 时规范不允许写时间戳，明确报不支持。
static int ts_ensure_pool(struct s2a_vk_device *d, char *why, size_t why_size) {
    if (!d || !d->device || !d->physical) return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: no Vulkan device", why, why_size);
    if (TS.pool && TS.dev == d->device) return 0;
    if (TS.pool) {
        // 旧池属于旧设备：不能跨设备 destroy；待写项也随旧会话丢弃。
        QP_LOG("timestamp-top: device changed; the previous timestamp pool is dropped with the old device");
        TS.pool = VK_NULL_HANDLE;
        TS.pend_n = 0;
        s2a_ts_queue_init(&TS.fifo, TS.slots, TS_SLOTS);
    }
    double period = d->properties.limits.timestampPeriod;
    if (period <= 0)
        return ts_fail(NVN_VK_QUERY_UNSUPPORTED, "timestamp-top: device reports no timestamp period", why, why_size);
    uint32_t nqf = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(d->physical, &nqf, NULL);
    if (!nqf || d->queue_family >= nqf)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: queue family properties are unavailable", why, why_size);
    VkQueueFamilyProperties *qfs = calloc(nqf, sizeof *qfs);
    if (!qfs) return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: out of memory for queue family properties", why, why_size);
    vkGetPhysicalDeviceQueueFamilyProperties(d->physical, &nqf, qfs);
    uint32_t valid_bits = qfs[d->queue_family].timestampValidBits;
    free(qfs);
    if (valid_bits == 0)
        return ts_fail(NVN_VK_QUERY_UNSUPPORTED,
                       "timestamp-top: the graphics queue family reports timestampValidBits=0", why, why_size);

    VkQueryPoolCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                                 .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = TS_SLOTS };
    if (vkCreateQueryPool(d->device, &ci, NULL, &TS.pool) != VK_SUCCESS) {
        TS.pool = VK_NULL_HANDLE;
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: vkCreateQueryPool(TIMESTAMP) failed", why, why_size);
    }
    TS.dev = d->device;
    TS.valid_bits = valid_bits > 64 ? 64 : valid_bits;
    TS.period = period;
    TS.cal_kind = 0;
    TS.get_ts = NULL;
    TS.pend_n = 0;
    s2a_ts_queue_init(&TS.fifo, TS.slots, TS_SLOTS);
    TS.written = 0;

    // 校准扩展：优先 KHR，其次 EXT；两者函数签名/时间域枚举相同，只是名字不同。
    const char *dev_name = NULL, *phys_name = NULL;
    if (d->calibrated_timestamps == 1) {
        dev_name = "vkGetCalibratedTimestampsKHR";
        phys_name = "vkGetPhysicalDeviceCalibrateableTimeDomainsKHR";
    } else if (d->calibrated_timestamps == 2) {
        dev_name = "vkGetCalibratedTimestampsEXT";
        phys_name = "vkGetPhysicalDeviceCalibrateableTimeDomainsEXT";
    }
    if (dev_name && phys_name) {
        PFN_vkGetPhysicalDeviceCalibrateableTimeDomainsKHR get_domains =
            (PFN_vkGetPhysicalDeviceCalibrateableTimeDomainsKHR)vkGetInstanceProcAddr(d->instance, phys_name);
        TS.get_ts = (PFN_vkGetCalibratedTimestampsKHR)vkGetDeviceProcAddr(d->device, dev_name);
        int has_dev = 0, has_mono = 0;
        if (get_domains && TS.get_ts) {
            uint32_t nd = 0;
            if (get_domains(d->physical, &nd, NULL) == VK_SUCCESS && nd && nd <= 64) {
                VkTimeDomainKHR domains[64];
                if (get_domains(d->physical, &nd, domains) == VK_SUCCESS) {
                    for (uint32_t i = 0; i < nd; i++) {
                        if (domains[i] == VK_TIME_DOMAIN_DEVICE_KHR) has_dev = 1;
                        if (domains[i] == VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR) has_mono = 1;
                    }
                }
            }
        }
        // 校准必须同时支持 DEVICE 和 CLOCK_MONOTONIC；只支持一半不算可用。
        if (has_dev && has_mono) {
            VkCalibratedTimestampInfoKHR info[2] = {
                { .sType = VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_KHR, .timeDomain = VK_TIME_DOMAIN_DEVICE_KHR },
                { .sType = VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_KHR, .timeDomain = VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR },
            };
            uint64_t t[2] = {0, 0}, dev = 0;
            if (TS.get_ts(d->device, 2, info, t, &dev) == VK_SUCCESS)
                TS.cal_kind = d->calibrated_timestamps;
        }
        if (!TS.cal_kind)
            QP_LOG("timestamp-top: calibrated timestamps unavailable; using guest_tick at completion");
    }

    QP_LOG("timestamp-top: pool created (%u slots, validBits=%u, period=%.6f ns, calibration=%s)",
           TS_SLOTS, (unsigned)TS.valid_bits, TS.period,
           TS.cal_kind == 1 ? "KHR" : TS.cal_kind == 2 ? "EXT" : "none");
    qp_seterr(why, why_size, "");
    return 0;
}

// 把一次 GPU 时间戳换算成 NVN 19.2 MHz 游戏时钟刻度。失败不写任何值（不拿别的时间轴冒充）。
// 校准值由调用方在每批 resolve 开头取一次，本批共用；fallback_tick 同理（无校准扩展时的口径）。
static int ts_convert(uint64_t raw, int have_cal, const uint64_t cal[2],
                      uint64_t fallback_tick, uint64_t *out, char *why, size_t why_size) {
    uint64_t ticks = ts_mask_ticks(raw);
    if (TS.cal_kind) {
        if (!have_cal || !cal)
            return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: calibration value is missing", why, why_size);
        uint64_t t0 = ts_mask_ticks(cal[0]);
        // 按 validBits 回绕：先在位宽内取差，再从第 N-1 位做符号扩展；不能直接对两个截断值相减。
        int64_t delta_ticks = s2a_ts_wrap_diff(ticks, t0, TS.valid_bits);
        double delta_ns = (double)delta_ticks * TS.period;
        if (delta_ns < -9.0e18 || delta_ns > 9.0e18)
            return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: calibrated delta is out of range", why, why_size);
        int64_t shift_ns = 0;
        if (guest_ns && now_ns) {
            uint64_t g = guest_ns(), n = now_ns();
            if (g && n) shift_ns = (int64_t)(g - n);   // 切后台冻结的时间差，正常情况下是 0 或很小的负数
        }
        double game_ns = (double)cal[1] + delta_ns + (double)shift_ns;
        if (game_ns < 0 || game_ns > 9.0e18)
            return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: calibrated game time is out of range", why, why_size);
        *out = (uint64_t)game_ns * 12 / 625;
        return 0;
    }
    // 兜底：Metal gpu_ticks() 同口径——结算那一刻的游戏时钟。同步后端里这就是命令已执行完的真实时刻。
    *out = fallback_tick;
    return 0;
}

static uint64_t ts_frame_id_now(void) {
    if (nvn_vk_first_draw_frame_id) {
        uint64_t id = nvn_vk_first_draw_frame_id();
        if (id) return id;
    }
    return 1;   // 没有帧队列的微例：固定一帧，同步路径随即结算
}

// 分配一个跨帧 FIFO 槽位。真正的 append 在命令录制成功后做；这里只检查容量。
static int ts_reserve_slot(uint32_t *slot, char *why, size_t why_size) {
    if (!s2a_ts_queue_can_append(&TS.fifo))
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: timestamp slot ring is full", why, why_size);
    if ((uint32_t)TS.pend_n >= TS_PENDING)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: pending timestamp table is full", why, why_size);
    *slot = s2a_ts_queue_next_slot(&TS.fifo);
    return 0;
}

static int ts_pending_add(uint64_t addr, uint64_t frame_id, uint32_t slot,
                          const struct s2a_record_memory *memory, char *why, size_t why_size) {
    uint32_t got = 0;
    if (s2a_ts_queue_append(&TS.fifo, frame_id, &got) != 0 || got != slot)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: timestamp slot ring is full", why, why_size);
    struct ts_pending *p = &TS.pend[TS.pend_n++];
    p->addr = addr;
    p->frame_id = frame_id;
    p->slot = slot;
    p->mem = *memory;
    return 0;
}

int nvn_vk_ts_top_enqueue(struct s2a_vk_device *d, const struct s2a_record_memory *memory,
                          uint64_t addr, char *why, size_t why_size) {
    if (TS.failed) { qp_seterr(why, why_size, "timestamp-top: timestamp query previously failed"); return NVN_VK_QUERY_FAILED; }
    if (!memory || !memory->write || !addr)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: no guest write entry/output address", why, why_size);
    int rc = ts_ensure_pool(d, why, why_size);
    if (rc < 0) return rc;
    if (!nvn_vk_first_draw_timestamp_top)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: no frame queue entry", why, why_size);
    uint32_t slot = 0;
    rc = ts_reserve_slot(&slot, why, why_size);
    if (rc < 0) return rc;
    uint64_t frame_id = ts_frame_id_now();
    if (nvn_vk_first_draw_timestamp_top(d, TS.pool, slot, why, why_size) != 0) {
        if (!why || !why[0]) qp_seterr(why, why_size, "timestamp-top: recording into the frame queue failed");
        return NVN_VK_QUERY_FAILED;
    }
    rc = ts_pending_add(addr, frame_id, slot, memory, why, why_size);
    if (rc < 0) return rc;
    qp_seterr(why, why_size, "");
    return 0;
}

int nvn_vk_ts_top_record(struct s2a_vk_device *d, VkCommandBuffer cmd,
                         const struct s2a_record_memory *memory, uint64_t addr,
                         char *why, size_t why_size) {
    if (!d || !d->device || !cmd)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: no device/command buffer", why, why_size);
    if (TS.failed) { qp_seterr(why, why_size, "timestamp-top: timestamp query previously failed"); return NVN_VK_QUERY_FAILED; }
    if (!memory || !memory->write || !addr)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: no guest write entry/output address", why, why_size);
    int rc = ts_ensure_pool(d, why, why_size);
    if (rc < 0) return rc;
    uint32_t slot = 0;
    rc = ts_reserve_slot(&slot, why, why_size);
    if (rc < 0) return rc;
    uint64_t frame_id = ts_frame_id_now();
    vkCmdResetQueryPool(cmd, TS.pool, slot, 1);
    vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, TS.pool, slot);
    rc = ts_pending_add(addr, frame_id, slot, memory, why, why_size);
    if (rc < 0) return rc;
    qp_seterr(why, why_size, "");
    return NVN_VK_QUERY_OK;
}

// completed_frame_id：已拿到完成证明的最大帧序号；只结算序号 <= 它的 FIFO 前缀。
// blocking=1 带 VK_QUERY_RESULT_WAIT_BIT；blocking=0 遇到未就绪就停，保留到下次。
int nvn_vk_ts_top_resolve(struct s2a_vk_device *d, uint64_t completed_frame_id, int blocking,
                          char *why, size_t why_size) {
    if (TS.failed) { qp_seterr(why, why_size, "timestamp-top: timestamp query previously failed"); return NVN_VK_QUERY_FAILED; }
    if (!TS.pool) return 0;
    if (!TS.pend_n) return 0;
    if (!d || !d->device || d->device != TS.dev)
        return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: resolve on a different device than the timestamp pool", why, why_size);
    uint32_t ready = s2a_ts_queue_ready(&TS.fifo, completed_frame_id);
    if (!ready) return 0;

    // 每次 resolve 开头校准一次，本批共用；避免一帧几十个时间戳就调几十次校准。
    int have_cal = 0;
    uint64_t cal[2] = {0, 0};
    if (TS.cal_kind) {
        VkCalibratedTimestampInfoKHR info[2] = {
            { .sType = VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_KHR, .timeDomain = VK_TIME_DOMAIN_DEVICE_KHR },
            { .sType = VK_STRUCTURE_TYPE_CALIBRATED_TIMESTAMP_INFO_KHR, .timeDomain = VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR },
        };
        uint64_t dev = 0;
        VkResult vr = TS.get_ts(d->device, 2, info, cal, &dev);
        if (vr != VK_SUCCESS) {
            char msg[180];
            snprintf(msg, sizeof msg, "timestamp-top: vkGetCalibratedTimestamps failed (VkResult=%d); no value written", (int)vr);
            return ts_fail(NVN_VK_QUERY_FAILED, msg, why, why_size);
        }
        have_cal = 1;
    }
    uint64_t fallback_tick = TS.cal_kind ? 0 : ts_game_tick_now();
    uint32_t done = 0;
    for (; done < ready; done++) {
        uint32_t slot = s2a_ts_queue_slot(&TS.fifo, done);
        struct ts_pending *e = &TS.pend[done];
        if (e->slot != slot || e->frame_id != s2a_ts_queue_frame(&TS.fifo, done))
            return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: timestamp queue bookkeeping mismatch", why, why_size);
        uint64_t raw = 0;
        VkQueryResultFlags flags = VK_QUERY_RESULT_64_BIT | (blocking ? VK_QUERY_RESULT_WAIT_BIT : 0u);
        VkResult vr = vkGetQueryPoolResults(d->device, TS.pool, slot, 1, sizeof raw, &raw, sizeof raw, flags);
        if (vr == VK_NOT_READY && !blocking) break;   // 这条还没有完成证明：它和后面的项都留到下次
        if (vr != VK_SUCCESS) {
            char msg[180];
            snprintf(msg, sizeof msg, "timestamp-top: vkGetQueryPoolResults failed for slot %u (VkResult=%d)",
                     slot, (int)vr);
            return ts_fail(NVN_VK_QUERY_FAILED, msg, why, why_size);
        }
        uint64_t ticks = 0;
        if (ts_convert(raw, have_cal, cal, fallback_tick, &ticks, why, why_size) < 0)
            return NVN_VK_QUERY_FAILED;
        uint64_t zero = 0;
        if (e->mem.write(e->mem.opaque, e->addr, &zero, 8) != 0 ||
            e->mem.write(e->mem.opaque, e->addr + 8, &ticks, 8) != 0)
            return ts_fail(NVN_VK_QUERY_FAILED, "timestamp-top: writing the counter to guest memory failed",
                           why, why_size);
        TS.written++;
    }
    if (done) {
        s2a_ts_queue_release(&TS.fifo, done);
        memmove(&TS.pend[0], &TS.pend[done], (size_t)(TS.pend_n - (int)done) * sizeof TS.pend[0]);
        TS.pend_n -= (int)done;
    }
    qp_seterr(why, why_size, "");
    return 0;
}

// 非变更终局检查：必须与所有查询录制、退休和写回串行。已知历史段不是待处理工作。
int nvn_vk_query_terminal_ready(void) {
    if (Q.failed || TS.failed || Q.seg_on || Q.batch || Q.rep_n || TS.pend_n ||
        TS.fifo.head != TS.fifo.tail) return 0;
    for (int i = 0; i < QP_PAGES; i++) if (Q.page[i].state != 0) return 0;
    for (uint32_t i = 0; i < Q.seg_n; i++) if (!Q.seg[i].known) return 0;
    return 1;
}

// 未就绪时必须完整保留查询池与 CPU 写回账本；调用者不得随后销毁设备。
void nvn_vk_query_release_device(void) {
    if (!nvn_vk_query_terminal_ready()) {
        QP_LOG("release_device refused: query work or writeback remains; pool and state retained");
        return;
    }
    int kept = 0;
    for (int i = 0; i < QP_PAGES; i++) {
        struct qp_page *p = &Q.page[i];
        if (p->pool && p->dev) {
            if (p->state == 2) kept++;
            else vkDestroyQueryPool(p->dev, p->pool, NULL);
        }
        p->pool = VK_NULL_HANDLE; p->dev = NULL; p->state = 0;
        p->used = 0; p->batch = 0; p->cmd_reset_pending = 0;
    }
    if (kept)
        QP_LOG("release_device kept %d in-flight query page(s); they are reclaimed by device destruction", kept);
    if (TS.pool) {
        if (TS.pend_n > 0) {
            QP_LOG("release_device with %d unread timestamp-top write(s) in flight; "
                   "pool kept and reclaimed by device destruction", TS.pend_n);
        } else if (TS.dev) {
            vkDestroyQueryPool(TS.dev, TS.pool, NULL);
        }
    }
    TS.pool = VK_NULL_HANDLE;
    TS.dev = VK_NULL_HANDLE;
    TS.pend_n = 0;
    s2a_ts_queue_init(&TS.fifo, TS.slots, TS_SLOTS);
    TS.cal_kind = 0;
    TS.get_ts = NULL;
    TS.failed = 0;
    // 会话级状态必须全部清掉：同一进程重建设备后不能继续带着上一会话的首错/计数/计数开关。
    if (Q.failed) QP_LOG("previous session query failure is kept in its log only: %s", Q.fail);
    Q.dev = NULL; Q.cur_page = -1; Q.batch = 0; Q.next_batch = 0;
    Q.seg_on = 0; Q.seg_cmd = VK_NULL_HANDLE; Q.seg_slot = 0;
    Q.counting = 0; Q.failed = 0; Q.fail[0] = '\0';
    Q.epoch = 0; Q.seg_n = 0; Q.ep_n = 0; Q.rep_n = 0;
    memset(&Q.st, 0, sizeof Q.st);
    Q.noted_counting = 0; Q.noted_zero = 0; Q.noted_nonzero = 0; Q.noted_before_reset = 0;
}
