#include "nvn_vk_completion.h"

#include <string.h>

// 纯状态机：本文件不 include 任何 Vulkan 头、不加锁、不分配内存、不等待。真实完成源在拿到判决后
// 调 mark_*；这里只维护事实、回调顺序与引用持有，宿主与生产共用同一份实现。

static struct nvk_completion_batch *find_batch(struct nvk_completion_ledger *l, uint64_t token) {
    if (!l || token == 0) return NULL;
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        if (l->batches[i].token == token) return &l->batches[i];
    }
    return NULL;
}

static const struct nvk_completion_batch *find_batch_const(const struct nvk_completion_ledger *l, uint64_t token) {
    if (!l || token == 0) return NULL;
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        if (l->batches[i].token == token) return &l->batches[i];
    }
    return NULL;
}

static struct nvk_completion_batch *find_free_slot(struct nvk_completion_ledger *l) {
    if (!l) return NULL;
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        if (l->batches[i].token == 0) return &l->batches[i];
    }
    return NULL;
}

static int gate_valid(int gate) { return gate == NVK_GATE_GPU || gate == NVK_GATE_CPU_HANDOFF; }

static uint32_t *gate_refs(struct nvk_completion_batch *b, int gate) {
    return gate == NVK_GATE_GPU ? &b->gpu_refs : &b->handoff_refs;
}

static int fact_reaches_gate(int fact, int gate) {
    if (fact == NVK_COMPLETE_UNKNOWN) return 0;
    return fact >= gate;   // 事实数值单调：CPU 交接完成(3) >= GPU 完成(2) >= 在途(1) >= 未提交(0)
}

static void slot_clear(struct nvk_completion_batch *b) { memset(b, 0, sizeof *b); }

void nvk_completion_init(struct nvk_completion_ledger *l, uint64_t generation) {
    if (!l) return;
    memset(l, 0, sizeof *l);
    l->generation = generation;
    l->next_token = 1;   // 0 保留为“没有令牌”
}

void nvk_completion_request_stop(struct nvk_completion_ledger *l) {
    if (!l) return;
    if (l->firing) {
        l->stats.refused_reentrant++;
        return;
    }
    l->stop_requested = 1;
}

void nvk_completion_set_generation(struct nvk_completion_ledger *l, uint64_t generation) {
    if (!l) return;
    if (l->firing) {
        // 回调期间换代会让正在执行的这一批语义不清：拒绝并计红，调用方在回调返回后再换。
        l->stats.refused_reentrant++;
        return;
    }
    l->stats.generation_changes++;
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        struct nvk_completion_batch *b = &l->batches[i];
        if (!b->token) continue;
        if (b->fact == NVK_COMPLETE_CPU_HANDOFF_DONE) {
            // 事实已证明完成：放行是安全的，只是调用方没在换代前 release；令牌失效，引用按调用方自身
            // 的资源账保留（不是“未知完成”）。
            if (b->gpu_refs || b->handoff_refs) l->stats.complete_unreleased_refs += b->gpu_refs + b->handoff_refs;
        } else {
            // 旧代未完成：无法再证明完成 → 未知完成；回调不再触发，引用必须保留。
            l->stats.abandoned_batches++;
            l->stats.abandoned_gpu_refs += b->gpu_refs;
            l->stats.abandoned_handoff_refs += b->handoff_refs;
            if (b->fact == NVK_COMPLETE_UNKNOWN) {
                // 已经从“未知”账里转出，避免同一批引用在两个账上重复。
                if (l->stats.unknown_retained_gpu_refs >= b->gpu_refs)
                    l->stats.unknown_retained_gpu_refs -= b->gpu_refs;
                if (l->stats.unknown_retained_handoff_refs >= b->handoff_refs)
                    l->stats.unknown_retained_handoff_refs -= b->handoff_refs;
            } else {
                l->stats.unknown++;
            }
        }
        slot_clear(b);
    }
    l->generation = generation;
}

int nvk_completion_begin(struct nvk_completion_ledger *l, int needs_cpu_handoff, uint64_t submit_seq,
                         uint64_t *out_token) {
    if (out_token) *out_token = 0;
    if (!l || !out_token) return NVK_COMPLETION_REFUSED;
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (l->stop_requested) {
        l->stats.refused_stop++;
        return NVK_COMPLETION_STOPPED;
    }
    struct nvk_completion_batch *b = find_free_slot(l);
    if (!b) {
        l->stats.refused_full++;
        return NVK_COMPLETION_REFUSED;
    }
    slot_clear(b);
    if (l->next_token == 0) l->next_token = 1;
    b->token = l->next_token++;
    b->generation = l->generation;
    b->submit_seq = submit_seq;
    b->fact = NVK_COMPLETE_UNSUBMITTED;
    b->needs_cpu_handoff = needs_cpu_handoff ? 1 : 0;
    l->stats.begins++;
    *out_token = b->token;
    return NVK_COMPLETION_OK;
}

int nvk_completion_hold(struct nvk_completion_ledger *l, uint64_t token, int gate) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (!gate_valid(gate)) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (l->stop_requested) {
        l->stats.refused_stop++;
        return NVK_COMPLETION_STOPPED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (b->fact == NVK_COMPLETE_CPU_HANDOFF_DONE) {
        // 已完成批次的引用必须已经放行/正在回收；再登记新引用只会让它永远不可回收。
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    (*gate_refs(b, gate))++;
    l->stats.holds++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_release(struct nvk_completion_ledger *l, uint64_t token, int gate) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (!gate_valid(gate)) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        // 未知完成：不推进、不放行，引用保留。
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (!fact_reaches_gate(b->fact, gate)) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    uint32_t *refs = gate_refs(b, gate);
    if (*refs == 0) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    (*refs)--;
    l->stats.releases++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_on_gpu_done(struct nvk_completion_ledger *l, uint64_t token, nvk_completion_callback fn,
                               void *opaque) {
    if (!l || !fn) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (l->stop_requested) {
        l->stats.refused_stop++;
        return NVK_COMPLETION_STOPPED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (b->fact >= NVK_COMPLETE_GPU_DONE) {
        // GPU 完成事实已到/已回调过：再注册就永远不会执行，必须拒绝而不是静默接受。
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->n_callbacks >= NVK_COMPLETION_MAX_CALLBACKS) {
        l->stats.refused_full++;
        return NVK_COMPLETION_REFUSED;
    }
    b->callbacks[b->n_callbacks].fn = fn;
    b->callbacks[b->n_callbacks].opaque = opaque;
    b->n_callbacks++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_mark_submitted(struct nvk_completion_ledger *l, uint64_t token) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (b->fact != NVK_COMPLETE_UNSUBMITTED) return NVK_COMPLETION_ALREADY;
    if (l->stop_requested) {
        l->stats.refused_stop++;
        return NVK_COMPLETION_STOPPED;
    }
    b->fact = NVK_COMPLETE_IN_FLIGHT;
    l->stats.submitted++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_mark_gpu_done(struct nvk_completion_ledger *l, uint64_t token) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (b->fact >= NVK_COMPLETE_GPU_DONE) return NVK_COMPLETION_ALREADY;
    if (b->fact != NVK_COMPLETE_IN_FLIGHT) {
        // 未提交就声称 GPU 完成：乱序，准确拒绝（不能把没提交的批次当成已完成放行）。
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    b->fact = NVK_COMPLETE_GPU_DONE;
    l->stats.gpu_done++;
    // 按注册序同步回调恰好一次。回调里只允许查询/放行；firing 期间推进事实一律被拒绝。
    l->firing = 1;
    for (uint32_t i = 0; i < b->n_callbacks; i++) {
        nvk_completion_callback fn = b->callbacks[i].fn;
        void *opaque = b->callbacks[i].opaque;
        if (!fn) continue;
        b->callbacks_run++;
        l->stats.callbacks_run++;
        fn(l, b->token, opaque);
    }
    l->firing = 0;
    if (!b->needs_cpu_handoff) {
        // 没有必需的 CPU 交接：GPU 完成即“必需 CPU 交接已完成”（空集已满足），之后可直接放行/回收。
        b->fact = NVK_COMPLETE_CPU_HANDOFF_DONE;
        l->stats.cpu_handoff_done++;
    }
    return NVK_COMPLETION_OK;
}

int nvk_completion_mark_cpu_handoff_done(struct nvk_completion_ledger *l, uint64_t token) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        l->stats.refused_unknown++;
        return NVK_COMPLETION_UNKNOWN;
    }
    if (b->fact == NVK_COMPLETE_CPU_HANDOFF_DONE) return NVK_COMPLETION_ALREADY;
    if (b->fact != NVK_COMPLETE_GPU_DONE) {
        // CPU 交接完成必须晚于 GPU 完成：未提交/在途时声称交接完成是乱序，准确拒绝。
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    b->fact = NVK_COMPLETE_CPU_HANDOFF_DONE;
    l->stats.cpu_handoff_done++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_mark_unknown(struct nvk_completion_ledger *l, uint64_t token, int cause) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (cause != NVK_COMPLETION_CAUSE_DEVICE_LOST && cause != NVK_COMPLETION_CAUSE_TIMEOUT &&
        cause != NVK_COMPLETION_CAUSE_STOP && cause != NVK_COMPLETION_CAUSE_GENERATION &&
        cause != NVK_COMPLETION_CAUSE_SUBMIT_FAILED) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) return NVK_COMPLETION_ALREADY;
    if (b->fact == NVK_COMPLETE_CPU_HANDOFF_DONE) {
        // 已证明完成的事实不能被失败回退；调用方记录自己的失败原因，但本批不再变未知。
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    b->fact = NVK_COMPLETE_UNKNOWN;
    b->unknown_cause = cause;
    l->stats.unknown++;
    l->stats.unknown_retained_gpu_refs += b->gpu_refs;
    l->stats.unknown_retained_handoff_refs += b->handoff_refs;
    return NVK_COMPLETION_OK;
}

int nvk_completion_query(const struct nvk_completion_ledger *l, uint64_t token, struct nvk_completion_info *out) {
    if (out) memset(out, 0, sizeof *out);
    if (!l || !out) return NVK_COMPLETION_REFUSED;
    const struct nvk_completion_batch *b = find_batch_const(l, token);
    if (!b) return NVK_COMPLETION_STALE;
    out->token = b->token;
    out->generation = b->generation;
    out->submit_seq = b->submit_seq;
    out->fact = b->fact;
    out->unknown_cause = b->unknown_cause;
    out->needs_cpu_handoff = b->needs_cpu_handoff;
    out->gpu_refs = b->gpu_refs;
    out->handoff_refs = b->handoff_refs;
    out->callbacks = b->n_callbacks;
    out->callbacks_run = b->callbacks_run;
    return NVK_COMPLETION_OK;
}

int nvk_completion_find(const struct nvk_completion_ledger *l, uint64_t submit_seq, uint64_t *out_token) {
    if (out_token) *out_token = 0;
    if (!l || !out_token) return NVK_COMPLETION_REFUSED;
    for (int i = 0; i < NVK_COMPLETION_MAX_BATCHES; i++) {
        const struct nvk_completion_batch *b = &l->batches[i];
        if (!b->token || b->submit_seq != submit_seq) continue;
        *out_token = b->token;
        return NVK_COMPLETION_OK;
    }
    return NVK_COMPLETION_STALE;
}

int nvk_completion_may_release(const struct nvk_completion_ledger *l, uint64_t token, int gate) {
    if (!l || !gate_valid(gate)) return 0;
    const struct nvk_completion_batch *b = find_batch_const(l, token);
    if (!b) return 0;
    if (b->fact == NVK_COMPLETE_UNKNOWN) return 0;
    return fact_reaches_gate(b->fact, gate);
}

int nvk_completion_close(struct nvk_completion_ledger *l, uint64_t token) {
    if (!l) return NVK_COMPLETION_REFUSED;
    struct nvk_completion_batch *b = find_batch(l, token);
    if (!b) {
        l->stats.refused_stale++;
        return NVK_COMPLETION_STALE;
    }
    if (l->firing) {
        l->stats.refused_reentrant++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->fact == NVK_COMPLETE_UNKNOWN) {
        // 未知完成：令牌与引用都必须保留（会话收尾按 abandoned/保留账处理）。
        l->stats.refused_unknown++;
        return NVK_COMPLETION_RETAINED;
    }
    if (b->fact != NVK_COMPLETE_CPU_HANDOFF_DONE) {
        l->stats.refused_out_of_order++;
        return NVK_COMPLETION_REFUSED;
    }
    if (b->gpu_refs || b->handoff_refs) return NVK_COMPLETION_RETAINED;
    slot_clear(b);
    l->stats.retired_slots++;
    return NVK_COMPLETION_OK;
}

int nvk_completion_stop_requested(const struct nvk_completion_ledger *l) { return l ? l->stop_requested : 1; }
uint64_t nvk_completion_generation(const struct nvk_completion_ledger *l) { return l ? l->generation : 0; }

void nvk_completion_unknown_retained(const struct nvk_completion_ledger *l, uint64_t *gpu_refs,
                                     uint64_t *handoff_refs) {
    if (gpu_refs) *gpu_refs = l ? l->stats.unknown_retained_gpu_refs : 0;
    if (handoff_refs) *handoff_refs = l ? l->stats.unknown_retained_handoff_refs : 0;
}

void nvk_completion_get_stats(const struct nvk_completion_ledger *l, struct nvk_completion_stats *out) {
    if (!out) return;
    if (!l) {
        memset(out, 0, sizeof *out);
        return;
    }
    *out = l->stats;
}

const char *nvk_completion_fact_name(int fact) {
    switch (fact) {
    case NVK_COMPLETE_UNSUBMITTED: return "unsubmitted";
    case NVK_COMPLETE_IN_FLIGHT: return "in-flight";
    case NVK_COMPLETE_GPU_DONE: return "gpu-done";
    case NVK_COMPLETE_CPU_HANDOFF_DONE: return "cpu-handoff-done";
    case NVK_COMPLETE_UNKNOWN: return "unknown";
    default: return "?";
    }
}

const char *nvk_completion_cause_name(int cause) {
    switch (cause) {
    case NVK_COMPLETION_CAUSE_DEVICE_LOST: return "device-lost";
    case NVK_COMPLETION_CAUSE_TIMEOUT: return "timeout";
    case NVK_COMPLETION_CAUSE_STOP: return "stop";
    case NVK_COMPLETION_CAUSE_GENERATION: return "generation";
    case NVK_COMPLETION_CAUSE_SUBMIT_FAILED: return "submit-failed";
    default: return "?";
    }
}

const char *nvk_completion_result_name(int result) {
    switch (result) {
    case NVK_COMPLETION_OK: return "ok";
    case NVK_COMPLETION_ALREADY: return "already";
    case NVK_COMPLETION_REFUSED: return "refused";
    case NVK_COMPLETION_STALE: return "stale";
    case NVK_COMPLETION_UNKNOWN: return "unknown";
    case NVK_COMPLETION_STOPPED: return "stopped";
    case NVK_COMPLETION_RETAINED: return "retained";
    default: return "?";
    }
}
