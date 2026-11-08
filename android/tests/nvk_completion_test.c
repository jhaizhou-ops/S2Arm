// D 接口（完成 token）宿主合同：假完成源驱动，不建 Vulkan device、不碰真队列、无锁无等待。
//
// 生产语义见 nvn_vk_completion.h：5 态事实（未提交/在途/GPU 完成/必需 CPU 交接完成/未知完成或失败）、
// 批次持有/放行、GPU 完成后退休回调、换代/Stop。本用例把真实完成源换成“测试自己推进事实”：
// mark_submitted / mark_gpu_done / mark_cpu_handoff_done / mark_unknown 就是完成源发布判决的同一批入口。
//
// 覆盖的独立期望：
//   1) 四态（未提交/在途/GPU 完成/未知）下持有与放行顺序：GPU 闸在 GPU 完成后放、CPU 交接闸必须等
//      “必需 CPU 交接已完成”，未知一律不放行；
//   2) 未知完成（device-lost/timeout/Stop，以及 GPU 完成后失败）保留引用、不回调、不放行、不回收令牌；
//   3) GPU 完成后退休回调恰好一次、只按注册序；注册过晚/超量被拒绝；
//   4) CPU 交接完成必须晚于 GPU 完成，乱序推进准确失败；重复推进返回 ALREADY 且不重复回调；
//   5) 换代后旧代回调不触发、旧令牌 STALE，旧代未完成批次的引用计入 abandoned_*；
//   6) Stop 拒绝新工作/新引用，但已提交且能证明完成的批次仍可推进、回调、放行、回收；
//   7) 有界令牌表：满了准确拒绝，回收后可复用；令牌 id 单调不复用。
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvn_vk_completion.h"

static int g_fails;
static int g_checks;
#define CHECK(cond, what)                                     \
    do {                                                      \
        g_checks++;                                           \
        if (!(cond)) {                                        \
            printf("FAIL: %s (line %d)\n", what, __LINE__);   \
            g_fails++;                                        \
        }                                                     \
    } while (0)

// ---- 假完成源 ----
// 真实来源是帧队列 fence / 事件完成证明（nvn_vk_first_draw_flush_ready 那条链）与 exec owner；
// 本测试不建 device、不提交、不等待，直接调事实登记入口模拟“完成源给出了判决”。
static int g_cb_log[64];
static int g_cb_n;

static void cb_record(struct nvk_completion_ledger *l, uint64_t token, void *opaque) {
    (void)l;
    (void)token;
    if (g_cb_n < 64) g_cb_log[g_cb_n] = (int)(intptr_t)opaque;
    g_cb_n++;
}

static void reset_cb_log(void) {
    memset(g_cb_log, 0, sizeof g_cb_log);
    g_cb_n = 0;
}

static int begin_batch(struct nvk_completion_ledger *l, int needs_cpu_handoff, uint64_t seq, uint64_t *token) {
    *token = 0;
    return nvk_completion_begin(l, needs_cpu_handoff, seq, token);
}

// 1) 四态下的持有/放行顺序（含“GPU 完成即可放 GPU 闸、CPU 交接闸要等交接完成”）。
static void test_four_state_hold_release(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 7);
    uint64_t t = 0;
    struct nvk_completion_info q;

    CHECK(begin_batch(&l, 1, 101, &t) == NVK_COMPLETION_OK && t != 0, "begin returns a token");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK, "query active token");
    CHECK(q.fact == NVK_COMPLETE_UNSUBMITTED, "new batch is unsubmitted");
    CHECK(q.submit_seq == 101 && q.generation == 7 && q.needs_cpu_handoff == 1, "query reports batch identity");
    CHECK(nvk_completion_may_release(&l, t, NVK_GATE_GPU) == 0, "no release before anything is proven");
    CHECK(nvk_completion_may_release(&l, t, NVK_GATE_CPU_HANDOFF) == 0, "no handoff release before proof");

    // 未提交：持有可以登记（A 在录制/提交前为延迟项保留引用），放行必须被拒绝。
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold gpu ref before submit");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK, "hold handoff ref");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_REFUSED,
          "unsubmitted batch must not release gpu refs");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_REFUSED,
          "unsubmitted batch must not release handoff refs");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_REFUSED, "unsubmitted batch cannot retire its token");

    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit advances to in-flight");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_IN_FLIGHT,
          "fact is in-flight");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_REFUSED,
          "in-flight batch must not release gpu refs");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_REFUSED,
          "in-flight batch must not release handoff refs");

    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_OK, "gpu done advances the fact");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_GPU_DONE,
          "needs-handoff batch stops at gpu-done until the handoff is reported");
    CHECK(nvk_completion_may_release(&l, t, NVK_GATE_GPU) == 1, "gpu refs are releasable after gpu done");
    CHECK(nvk_completion_may_release(&l, t, NVK_GATE_CPU_HANDOFF) == 0,
          "handoff refs stay held until the cpu handoff completes");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK, "release gpu ref after gpu done");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_REFUSED,
          "releasing an unheld gpu ref is refused");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_REFUSED,
          "handoff refs still not releasable at gpu-done");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_REFUSED,
          "a fact short of cpu handoff cannot retire its token");

    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t) == NVK_COMPLETION_OK, "cpu handoff completes the fact");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK,
          "handoff refs are releasable after the handoff");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_OK, "token retires after complete + refs released");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_STALE, "retired token is stale");

    // 不需要 CPU 交接的批次：GPU 完成即“必需 CPU 交接已完成”（空集），可直接放行/回收。
    uint64_t t2 = 0;
    CHECK(begin_batch(&l, 0, 102, &t2) == NVK_COMPLETION_OK, "begin no-handoff batch");
    CHECK(nvk_completion_hold(&l, t2, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK, "hold no-handoff batch");
    CHECK(nvk_completion_mark_submitted(&l, t2) == NVK_COMPLETION_OK, "submit no-handoff batch");
    CHECK(nvk_completion_mark_gpu_done(&l, t2) == NVK_COMPLETION_OK, "gpu done no-handoff batch");
    CHECK(nvk_completion_query(&l, t2, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_CPU_HANDOFF_DONE,
          "no-handoff batch jumps straight to the final fact");
    CHECK(nvk_completion_release(&l, t2, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK,
          "no-handoff batch releases handoff refs at gpu done");
    CHECK(nvk_completion_close(&l, t2) == NVK_COMPLETION_OK, "no-handoff batch retires immediately");

    // 坏闸值不能当合法闸使用（先创建批次，避免先被 STALE 吞掉）。
    uint64_t bad = 0;
    CHECK(begin_batch(&l, 0, 103, &bad) == NVK_COMPLETION_OK, "begin invalid-gate batch");
    CHECK(nvk_completion_hold(&l, bad, NVK_COMPLETE_UNSUBMITTED) == NVK_COMPLETION_REFUSED,
          "invalid gate on hold is refused");
    CHECK(nvk_completion_release(&l, bad, 7) == NVK_COMPLETION_REFUSED,
          "invalid gate on release is refused");
}

// 2) 未知完成：device-lost / timeout / Stop 三个来源都保留引用、不回调、不放行、不回收令牌。
static void test_unknown_retains(void) {
    const int causes[3] = {NVK_COMPLETION_CAUSE_DEVICE_LOST, NVK_COMPLETION_CAUSE_TIMEOUT,
                           NVK_COMPLETION_CAUSE_STOP};
    for (int i = 0; i < 3; i++) {
        struct nvk_completion_ledger l;
        nvk_completion_init(&l, 30 + (uint64_t)i);
        reset_cb_log();
        uint64_t t = 0;
        struct nvk_completion_info q;
        CHECK(begin_batch(&l, 1, 200 + (uint64_t)i, &t) == NVK_COMPLETION_OK, "begin for unknown retention");
        CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold gpu ref");
        CHECK(nvk_completion_hold(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK, "hold handoff ref");
        CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)(10 + i)) == NVK_COMPLETION_OK,
              "register retire callback");
        if (causes[i] == NVK_COMPLETION_CAUSE_STOP) {
            nvk_completion_request_stop(&l);
            CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_STOPPED,
                  "submit after stop is refused");
        } else {
            CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit batch");
        }
        CHECK(nvk_completion_mark_unknown(&l, t, causes[i]) == NVK_COMPLETION_OK,
              "completion source reports unknown");
        CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK, "query unknown batch");
        CHECK(q.fact == NVK_COMPLETE_UNKNOWN, "fact is unknown");
        CHECK(q.unknown_cause == causes[i], "unknown cause is recorded exactly");
        CHECK(q.callbacks_run == 0 && g_cb_n == 0, "unknown completion never runs retire callbacks");
        CHECK(nvk_completion_may_release(&l, t, NVK_GATE_GPU) == 0 &&
                  nvk_completion_may_release(&l, t, NVK_GATE_CPU_HANDOFF) == 0,
              "unknown completion is not releasable");
        CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_UNKNOWN,
              "release gpu ref of unknown batch is refused");
        CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_UNKNOWN,
              "release handoff ref of unknown batch is refused");
        // Stop 来源时 Stop 拒绝优先（不再接新工作）；其余来源按“未知完成”拒绝。
        CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) ==
                  (causes[i] == NVK_COMPLETION_CAUSE_STOP ? NVK_COMPLETION_STOPPED : NVK_COMPLETION_UNKNOWN),
              "no new refs on an unknown batch");
        CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_RETAINED,
              "unknown batch keeps its token (references retained)");
        CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_UNKNOWN,
              "unknown batch cannot be advanced to gpu done");
        CHECK(nvk_completion_mark_cpu_handoff_done(&l, t) == NVK_COMPLETION_UNKNOWN,
              "unknown batch cannot be advanced to cpu handoff done");
        CHECK(nvk_completion_mark_unknown(&l, t, NVK_COMPLETION_CAUSE_TIMEOUT) == NVK_COMPLETION_ALREADY,
              "re-reporting unknown is idempotent, not a new fact");
        CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.unknown_cause == causes[i],
              "idempotent unknown keeps the first cause");
        uint64_t gpu = 0, handoff = 0;
        nvk_completion_unknown_retained(&l, &gpu, &handoff);
        CHECK(gpu == 1 && handoff == 1, "unknown batch refs are reported as retained");
    }

    // GPU 完成之后才失去完成证明（device-lost 在 CPU 交接前）：回调已恰好一次，但交接侧引用仍保留。
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 40);
    reset_cb_log();
    uint64_t t = 0;
    struct nvk_completion_info q;
    CHECK(begin_batch(&l, 1, 300, &t) == NVK_COMPLETION_OK, "begin late-unknown batch");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK, "hold handoff ref");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)77) == NVK_COMPLETION_OK,
          "register callback for late-unknown batch");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit late-unknown batch");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_OK, "gpu done fires callbacks");
    CHECK(g_cb_n == 1 && g_cb_log[0] == 77, "gpu-done callback fired exactly once");
    CHECK(nvk_completion_mark_unknown(&l, t, NVK_COMPLETION_CAUSE_DEVICE_LOST) == NVK_COMPLETION_OK,
          "device lost after gpu done is still unknown completion");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_UNKNOWN,
          "fact becomes unknown");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_UNKNOWN,
          "handoff ref of late-unknown batch is retained");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_RETAINED, "late-unknown batch keeps its token");
    uint64_t gpu = 0, handoff = 0;
    nvk_completion_unknown_retained(&l, &gpu, &handoff);
    CHECK(gpu == 0 && handoff == 1, "only the still-held handoff ref is retained");
}

// 3) GPU 完成后退休回调：恰好一次、只按注册序；注册过晚/超量拒绝。
static void test_callbacks_exactly_once_in_order(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 50);
    reset_cb_log();
    uint64_t t = 0;
    struct nvk_completion_info q;
    CHECK(begin_batch(&l, 0, 400, &t) == NVK_COMPLETION_OK, "begin callback batch");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)1) == NVK_COMPLETION_OK,
          "register callback 1");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)2) == NVK_COMPLETION_OK,
          "register callback 2");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)3) == NVK_COMPLETION_OK,
          "register callback 3");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit callback batch");
    CHECK(g_cb_n == 0, "callbacks do not run before gpu completion");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_OK, "gpu done runs callbacks");
    CHECK(g_cb_n == 3 && g_cb_log[0] == 1 && g_cb_log[1] == 2 && g_cb_log[2] == 3,
          "callbacks run exactly once in registration order");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.callbacks == 3 && q.callbacks_run == 3,
          "query reports callback bookkeeping");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_ALREADY,
          "re-reporting gpu done is idempotent");
    CHECK(g_cb_n == 3, "callbacks never run twice");
    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t) == NVK_COMPLETION_ALREADY,
          "no-handoff batch is already complete");
    CHECK(g_cb_n == 3, "cpu handoff report does not re-run retire callbacks");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)4) == NVK_COMPLETION_REFUSED,
          "registering after gpu completion is refused (it would never run)");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_REFUSED,
          "no new refs on a completed batch");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_OK, "callback batch retires");

    // 回调容量：满了准确拒绝，不静默丢掉。
    uint64_t t2 = 0;
    CHECK(begin_batch(&l, 0, 401, &t2) == NVK_COMPLETION_OK, "begin capacity batch");
    for (int i = 0; i < NVK_COMPLETION_MAX_CALLBACKS; i++)
        CHECK(nvk_completion_on_gpu_done(&l, t2, cb_record, (void *)(intptr_t)i) == NVK_COMPLETION_OK,
              "register callback up to capacity");
    CHECK(nvk_completion_on_gpu_done(&l, t2, cb_record, (void *)(intptr_t)99) == NVK_COMPLETION_REFUSED,
          "callback beyond capacity is refused");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(&l, &st);
    CHECK(st.refused_full == 1, "callback overflow is counted");
    CHECK(nvk_completion_on_gpu_done(&l, t2, NULL, NULL) == NVK_COMPLETION_REFUSED, "null callback refused");
    CHECK(nvk_completion_close(&l, t2) == NVK_COMPLETION_REFUSED, "unsubmitted capacity batch cannot retire");
}

// 4) CPU 交接完成必须晚于 GPU 完成；乱序推进准确失败，重复推进 ALREADY 且不改事实。
static void test_out_of_order_rejected(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 60);
    uint64_t t = 0;
    struct nvk_completion_info q;

    CHECK(begin_batch(&l, 1, 500, &t) == NVK_COMPLETION_OK, "begin order batch");
    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t) == NVK_COMPLETION_REFUSED,
          "cpu handoff before submit is out of order");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_REFUSED,
          "gpu done before submit is out of order");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_UNSUBMITTED,
          "refused advances do not change the fact");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit order batch");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_ALREADY, "double submit is idempotent");
    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t) == NVK_COMPLETION_REFUSED,
          "cpu handoff before gpu done is out of order");
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_IN_FLIGHT,
          "in-flight fact survives the refused out-of-order handoff");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_OK, "gpu done order batch");
    CHECK(nvk_completion_mark_unknown(&l, t, NVK_COMPLETION_CAUSE_TIMEOUT) == NVK_COMPLETION_OK,
          "timeout after gpu done is recorded as unknown completion");

    // 已完成的批次不能被失败回退，也不能再乱序当成未完成处理。
    uint64_t t2 = 0;
    CHECK(begin_batch(&l, 1, 501, &t2) == NVK_COMPLETION_OK, "begin complete batch");
    CHECK(nvk_completion_mark_submitted(&l, t2) == NVK_COMPLETION_OK, "submit complete batch");
    CHECK(nvk_completion_mark_gpu_done(&l, t2) == NVK_COMPLETION_OK, "gpu done complete batch");
    CHECK(nvk_completion_mark_unknown(&l, t2, NVK_COMPLETION_CAUSE_DEVICE_LOST) == NVK_COMPLETION_OK,
          "gpu-done batch can still become unknown (handoff pending)");
    CHECK(nvk_completion_query(&l, t2, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_UNKNOWN,
          "late unknown is recorded");

    uint64_t t3 = 0;
    CHECK(begin_batch(&l, 1, 502, &t3) == NVK_COMPLETION_OK, "begin complete batch 2");
    CHECK(nvk_completion_mark_submitted(&l, t3) == NVK_COMPLETION_OK, "submit complete batch 2");
    CHECK(nvk_completion_mark_gpu_done(&l, t3) == NVK_COMPLETION_OK, "gpu done complete batch 2");
    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t3) == NVK_COMPLETION_OK, "cpu handoff completes batch 2");
    CHECK(nvk_completion_mark_unknown(&l, t3, NVK_COMPLETION_CAUSE_DEVICE_LOST) == NVK_COMPLETION_REFUSED,
          "a proven-complete fact cannot be rolled back to unknown");
    CHECK(nvk_completion_mark_cpu_handoff_done(&l, t3) == NVK_COMPLETION_ALREADY, "double handoff is idempotent");
    CHECK(nvk_completion_query(&l, t3, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_CPU_HANDOFF_DONE,
          "complete fact is preserved");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(&l, &st);
    CHECK(st.refused_out_of_order >= 4, "out-of-order advances are counted, not silently accepted");
    CHECK(nvk_completion_mark_unknown(&l, t3, 12345) == NVK_COMPLETION_REFUSED, "invalid unknown cause is refused");
}

// 5) 换代：旧代回调不触发、旧令牌 STALE，未完成批次的引用计入 abandoned_*。
static void test_generation_change(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 7);
    reset_cb_log();
    uint64_t a = 0, b = 0, c = 0;
    CHECK(begin_batch(&l, 1, 600, &a) == NVK_COMPLETION_OK, "begin old-gen in-flight batch");
    CHECK(nvk_completion_on_gpu_done(&l, a, cb_record, (void *)(intptr_t)5) == NVK_COMPLETION_OK,
          "register old-gen callback");
    CHECK(nvk_completion_hold(&l, a, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold old-gen gpu ref");
    CHECK(nvk_completion_hold(&l, a, NVK_GATE_CPU_HANDOFF) == NVK_COMPLETION_OK, "hold old-gen handoff ref");
    CHECK(nvk_completion_mark_submitted(&l, a) == NVK_COMPLETION_OK, "old-gen batch is in flight");

    CHECK(begin_batch(&l, 0, 601, &b) == NVK_COMPLETION_OK, "begin old-gen complete batch");
    CHECK(nvk_completion_mark_submitted(&l, b) == NVK_COMPLETION_OK, "submit old-gen complete batch");
    CHECK(nvk_completion_mark_gpu_done(&l, b) == NVK_COMPLETION_OK, "complete old-gen complete batch");
    CHECK(nvk_completion_close(&l, b) == NVK_COMPLETION_OK, "old-gen complete batch retires before generation change");

    CHECK(begin_batch(&l, 1, 602, &c) == NVK_COMPLETION_OK, "begin old-gen already-unknown batch");
    CHECK(nvk_completion_hold(&l, c, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold old-gen unknown ref");
    CHECK(nvk_completion_mark_submitted(&l, c) == NVK_COMPLETION_OK, "submit old-gen unknown batch");
    CHECK(nvk_completion_mark_unknown(&l, c, NVK_COMPLETION_CAUSE_DEVICE_LOST) == NVK_COMPLETION_OK,
          "old-gen batch already unknown before generation change");

    nvk_completion_set_generation(&l, 8);
    CHECK(nvk_completion_generation(&l) == 8, "generation advances");
    CHECK(g_cb_n == 0, "old-generation callback never fires after the generation change");
    CHECK(nvk_completion_query(&l, a, NULL) == NVK_COMPLETION_REFUSED, "null info is refused");
    struct nvk_completion_info q;
    CHECK(nvk_completion_query(&l, a, &q) == NVK_COMPLETION_STALE, "old token is stale after generation change");
    CHECK(nvk_completion_release(&l, a, NVK_GATE_GPU) == NVK_COMPLETION_STALE,
          "old-generation release is stale (references stay with the caller)");
    CHECK(nvk_completion_close(&l, a) == NVK_COMPLETION_STALE, "old-generation token cannot be closed");
    CHECK(nvk_completion_mark_gpu_done(&l, a) == NVK_COMPLETION_STALE,
          "old-generation facts cannot be advanced");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(&l, &st);
    CHECK(st.abandoned_batches == 2, "both unproven old-gen batches are abandoned");
    CHECK(st.abandoned_gpu_refs == 2 && st.abandoned_handoff_refs == 1,
          "abandoned refs are counted per gate (in-flight 1+1, unknown 1+0)");
    CHECK(st.generation_changes == 1, "generation change is counted once");
    uint64_t gpu = 0, handoff = 0;
    nvk_completion_unknown_retained(&l, &gpu, &handoff);
    CHECK(gpu == 0 && handoff == 0, "abandoned refs are not double-counted as current unknown retention");

    uint64_t fresh = 0;
    CHECK(begin_batch(&l, 1, 603, &fresh) == NVK_COMPLETION_OK, "new-generation batch can begin");
    CHECK(nvk_completion_query(&l, fresh, &q) == NVK_COMPLETION_OK && q.generation == 8,
          "new token carries the new generation");
    CHECK(fresh != a && fresh != b && fresh != c, "token ids are never reused");

    // 换代不撤销 Stop（新会话用 init）；旧代已完成但未放行的引用单独记账。
    nvk_completion_request_stop(&l);
    nvk_completion_set_generation(&l, 9);
    CHECK(nvk_completion_stop_requested(&l) == 1, "Stop is not cleared by a generation change");
}

// 6) Stop：拒绝新工作/新引用；已提交且能证明完成的批次仍可推进、回调、放行、回收。
static void test_stop(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 70);
    reset_cb_log();
    uint64_t t = 0;
    CHECK(begin_batch(&l, 1, 700, &t) == NVK_COMPLETION_OK, "begin before stop");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold before stop");
    nvk_completion_request_stop(&l);
    CHECK(nvk_completion_stop_requested(&l) == 1, "stop is published");
    uint64_t refused = 123;
    CHECK(nvk_completion_begin(&l, 0, 701, &refused) == NVK_COMPLETION_STOPPED && refused == 0,
          "new batch after stop is refused and writes no token");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_STOPPED, "new refs after stop are refused");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_record, (void *)(intptr_t)1) == NVK_COMPLETION_STOPPED,
          "new retire callbacks after stop are refused");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_STOPPED,
          "submitting an unsubmitted batch after stop is refused");
    CHECK(nvk_completion_mark_unknown(&l, t, NVK_COMPLETION_CAUSE_STOP) == NVK_COMPLETION_OK,
          "the owner can report the unsubmitted batch as unknown after stop");
    struct nvk_completion_info q;
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_UNKNOWN &&
              q.unknown_cause == NVK_COMPLETION_CAUSE_STOP,
          "stop-sourced unknown is recorded exactly");
    uint64_t gpu = 0, handoff = 0;
    nvk_completion_unknown_retained(&l, &gpu, &handoff);
    CHECK(gpu == 1 && handoff == 0, "stop-sourced unknown keeps its gpu ref");

    // 已提交批次在 Stop 后由真实完成源证明完成：事实推进、回调、放行、回收都必须仍然可用
    // （Stop 只拒绝新工作，不否认已证明的完成事实）。
    struct nvk_completion_ledger l2;
    nvk_completion_init(&l2, 71);
    reset_cb_log();
    uint64_t u = 0;
    CHECK(begin_batch(&l2, 0, 702, &u) == NVK_COMPLETION_OK, "begin in-flight batch before stop");
    CHECK(nvk_completion_hold(&l2, u, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold in-flight ref");
    CHECK(nvk_completion_on_gpu_done(&l2, u, cb_record, (void *)(intptr_t)8) == NVK_COMPLETION_OK,
          "register callback before stop");
    CHECK(nvk_completion_mark_submitted(&l2, u) == NVK_COMPLETION_OK, "submit before stop");
    nvk_completion_request_stop(&l2);
    CHECK(nvk_completion_mark_gpu_done(&l2, u) == NVK_COMPLETION_OK,
          "a proven completion may still be published after stop");
    CHECK(g_cb_n == 1 && g_cb_log[0] == 8, "the retire callback still fires exactly once for proven work");
    CHECK(nvk_completion_release(&l2, u, NVK_GATE_GPU) == NVK_COMPLETION_OK,
          "proven refs are releasable after stop");
    CHECK(nvk_completion_close(&l2, u) == NVK_COMPLETION_OK, "proven tokens are retireable after stop");
}

// 7) 有界令牌表：满了准确拒绝（不能静默成功），回收后令牌可复用且 id 单调不复用。
static void test_bounded_table(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 80);
    uint64_t tokens[NVK_COMPLETION_MAX_BATCHES];
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        tokens[i] = 0;
        CHECK(begin_batch(&l, 0, (uint64_t)(800 + i), &tokens[i]) == NVK_COMPLETION_OK &&
                  tokens[i] != 0,
              "fill bounded token table");
    }
    uint64_t overflow = 123;
    CHECK(nvk_completion_begin(&l, 0, 999, &overflow) == NVK_COMPLETION_REFUSED && overflow == 0,
          "a full token table refuses instead of silently dropping the batch");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(&l, &st);
    CHECK(st.refused_full == 1, "table overflow is counted");

    uint64_t victim = tokens[0];
    CHECK(nvk_completion_mark_submitted(&l, victim) == NVK_COMPLETION_OK, "submit victim batch");
    CHECK(nvk_completion_mark_gpu_done(&l, victim) == NVK_COMPLETION_OK, "gpu done victim batch");
    CHECK(nvk_completion_close(&l, victim) == NVK_COMPLETION_OK, "retire victim batch");
    uint64_t reused = 0;
    CHECK(begin_batch(&l, 0, 900, &reused) == NVK_COMPLETION_OK, "a retired slot is reusable");
    CHECK(reused != victim, "token ids are monotonic, never reused");
    CHECK(nvk_completion_query(&l, victim, NULL) == NVK_COMPLETION_REFUSED, "old token query is refused");
}

// 8) 词表/结果名与只读查询（诊断输出不能悄悄返回错名字）。
static void test_names_and_queries(void) {
    CHECK(nvk_completion_fact_name(NVK_COMPLETE_UNSUBMITTED) != NULL &&
              !strcmp(nvk_completion_fact_name(NVK_COMPLETE_UNSUBMITTED), "unsubmitted"),
          "unsubmitted fact name");
    CHECK(!strcmp(nvk_completion_fact_name(NVK_COMPLETE_IN_FLIGHT), "in-flight"), "in-flight fact name");
    CHECK(!strcmp(nvk_completion_fact_name(NVK_COMPLETE_GPU_DONE), "gpu-done"), "gpu-done fact name");
    CHECK(!strcmp(nvk_completion_fact_name(NVK_COMPLETE_CPU_HANDOFF_DONE), "cpu-handoff-done"),
          "cpu-handoff-done fact name");
    CHECK(!strcmp(nvk_completion_fact_name(NVK_COMPLETE_UNKNOWN), "unknown"), "unknown fact name");
    CHECK(!strcmp(nvk_completion_fact_name(42), "?"), "unknown fact value has a name");
    CHECK(!strcmp(nvk_completion_cause_name(NVK_COMPLETION_CAUSE_DEVICE_LOST), "device-lost"), "cause name");
    CHECK(!strcmp(nvk_completion_cause_name(NVK_COMPLETION_CAUSE_TIMEOUT), "timeout"), "timeout cause name");
    CHECK(!strcmp(nvk_completion_cause_name(NVK_COMPLETION_CAUSE_STOP), "stop"), "stop cause name");
    CHECK(!strcmp(nvk_completion_result_name(NVK_COMPLETION_OK), "ok"), "ok result name");
    CHECK(!strcmp(nvk_completion_result_name(NVK_COMPLETION_RETAINED), "retained"), "retained result name");
    CHECK(!strcmp(nvk_completion_result_name(-99), "?"), "unknown result has a name");

    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 90);
    struct nvk_completion_info q;
    uint64_t token = 0;
    CHECK(begin_batch(&l, 0, 1234, &token) == NVK_COMPLETION_OK, "begin seq batch");
    uint64_t by_seq = 0;
    CHECK(nvk_completion_find(&l, 1234, &by_seq) == NVK_COMPLETION_OK && by_seq == token,
          "query by submit sequence resolves the same batch token");
    CHECK(nvk_completion_find(&l, 4321, &by_seq) == NVK_COMPLETION_STALE && by_seq == 0,
          "unknown submit sequence is stale, not silently guessed");
    CHECK(nvk_completion_query(&l, 0, &q) == NVK_COMPLETION_STALE, "token 0 is not a batch");
    CHECK(nvk_completion_query(&l, 424242, &q) == NVK_COMPLETION_STALE, "unknown token is stale");
    CHECK(nvk_completion_may_release(&l, 424242, NVK_GATE_GPU) == 0, "unknown token cannot release");
    CHECK(nvk_completion_generation(&l) == 90, "generation readable");
    CHECK(nvk_completion_generation(NULL) == 0 && nvk_completion_stop_requested(NULL) == 1,
          "null ledger degrades safely");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(NULL, &st);
    CHECK(st.begins == 0, "null ledger stats are zeroed");
}

// 9) 回调重入：回调里只允许查询/放行；再推进事实/换代/关闭令牌必须被拒绝（保证“恰好一次”的顺序）。
static int g_reentrant_probe_calls;
static int g_reentrant_probe_refused;

static void cb_reentrant(struct nvk_completion_ledger *l, uint64_t token, void *opaque) {
    (void)opaque;
    g_reentrant_probe_calls++;
    if (nvk_completion_mark_unknown(l, token, NVK_COMPLETION_CAUSE_DEVICE_LOST) == NVK_COMPLETION_REFUSED)
        g_reentrant_probe_refused++;
    if (nvk_completion_mark_gpu_done(l, token) == NVK_COMPLETION_REFUSED) g_reentrant_probe_refused++;
    if (nvk_completion_close(l, token) == NVK_COMPLETION_REFUSED) g_reentrant_probe_refused++;
    uint64_t extra = 0;
    if (nvk_completion_begin(l, 0, 9999, &extra) == NVK_COMPLETION_REFUSED) g_reentrant_probe_refused++;
}

static void test_reentrancy_is_refused(void) {
    struct nvk_completion_ledger l;
    nvk_completion_init(&l, 95);
    g_reentrant_probe_calls = 0;
    g_reentrant_probe_refused = 0;
    uint64_t t = 0;
    CHECK(begin_batch(&l, 0, 950, &t) == NVK_COMPLETION_OK, "begin reentrancy batch");
    CHECK(nvk_completion_hold(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK, "hold reentrancy ref");
    CHECK(nvk_completion_on_gpu_done(&l, t, cb_reentrant, NULL) == NVK_COMPLETION_OK,
          "register reentrant probe callback");
    CHECK(nvk_completion_mark_submitted(&l, t) == NVK_COMPLETION_OK, "submit reentrancy batch");
    CHECK(nvk_completion_mark_gpu_done(&l, t) == NVK_COMPLETION_OK, "gpu done reentrancy batch");
    CHECK(g_reentrant_probe_calls == 1, "reentrant probe ran exactly once");
    CHECK(g_reentrant_probe_refused == 4, "facts/generation/close/begin are all refused inside a callback");
    struct nvk_completion_info q;
    CHECK(nvk_completion_query(&l, t, &q) == NVK_COMPLETION_OK && q.fact == NVK_COMPLETE_CPU_HANDOFF_DONE,
          "the callback could not corrupt the fact");
    struct nvk_completion_stats st;
    nvk_completion_get_stats(&l, &st);
    CHECK(st.refused_reentrant >= 4, "reentrant refusals are counted");
    CHECK(nvk_completion_release(&l, t, NVK_GATE_GPU) == NVK_COMPLETION_OK,
          "releasing refs from outside the callback still works");
    CHECK(nvk_completion_close(&l, t) == NVK_COMPLETION_OK, "batch retires after the callback returns");
}

int main(void) {
    test_four_state_hold_release();
    test_unknown_retains();
    test_callbacks_exactly_once_in_order();
    test_out_of_order_rejected();
    test_generation_change();
    test_stop();
    test_bounded_table();
    test_names_and_queries();
    test_reentrancy_is_refused();
    if (g_fails) {
        printf("nvk completion: %d FAILURES / %d checks\n", g_fails, g_checks);
        return 1;
    }
    printf("nvk completion: ok (%d checks: 5-state facts, hold/release order, unknown retention, "
           "retire callbacks, generation/stop, bounded tokens, reentrancy)\n", g_checks);
    return 0;
}
