// 时间戳待写项的纯记账（不依赖 Vulkan）：按帧序号 FIFO 退休 + 跨帧槽位环。
// 为什么不能按帧奇偶结算：延迟 present 下 N-1 与 N+1 奇偶相同，退休 N-1 时本帧刚提交
// 还没执行的 N+1 也会被算进去——要么读到复用槽的旧值，要么环只涨不回落。
// 记账规则：入队记所属帧序号；退休只结算序号 <= 已拿到完成证明的那一帧；槽位从尾部
// 分配、从头部释放，在途帧的项不会挡住复用，也不会复用还没消费的槽。
#pragma once
#include <stdint.h>

struct s2a_ts_slot_ref {
    uint64_t frame_id;
};

struct s2a_ts_queue {
    struct s2a_ts_slot_ref *slots;   // 按槽号存所属帧序号（调用方提供，长度 >= cap）
    uint32_t cap;
    uint64_t head;                   // 已释放的槽数（FIFO 头）
    uint64_t tail;                   // 已分配的槽数（FIFO 尾）
};

static inline void s2a_ts_queue_init(struct s2a_ts_queue *q, struct s2a_ts_slot_ref *slots, uint32_t cap) {
    q->slots = slots;
    q->cap = cap;
    q->head = q->tail = 0;
}

static inline uint32_t s2a_ts_queue_count(const struct s2a_ts_queue *q) {
    return (uint32_t)(q->tail - q->head);
}

// 下一个会被分配到的槽号（不改变队列）。调用方先检查容量，成功记录后再 append。
static inline uint32_t s2a_ts_queue_next_slot(const struct s2a_ts_queue *q) {
    return q->cap ? (uint32_t)(q->tail % q->cap) : 0;
}

// 队列是否还有空位；满了就准确报红，不能覆盖未消费的槽。
static inline int s2a_ts_queue_can_append(const struct s2a_ts_queue *q) {
    return q && q->slots && q->cap && q->tail - q->head < q->cap;
}

// 追加一项。slot 返回分配到的槽号；队列满返回 -1。
static inline int s2a_ts_queue_append(struct s2a_ts_queue *q, uint64_t frame_id, uint32_t *slot) {
    if (!s2a_ts_queue_can_append(q) || !slot) return -1;
    uint32_t s = s2a_ts_queue_next_slot(q);
    q->slots[s].frame_id = frame_id;
    q->tail++;
    *slot = s;
    return 0;
}

// 队首起有多少项的帧序号 <= completed_frame_id；按 FIFO 顺序，遇到第一项未完成就停。
static inline uint32_t s2a_ts_queue_ready(const struct s2a_ts_queue *q, uint64_t completed_frame_id) {
    if (!q || !q->slots) return 0;
    uint32_t n = 0;
    for (uint64_t i = q->head; i < q->tail; i++) {
        if (q->slots[i % q->cap].frame_id > completed_frame_id) break;
        n++;
    }
    return n;
}

// 第 index 个待写项（从队首 0 开始）对应的槽号 / 帧序号。
static inline uint32_t s2a_ts_queue_slot(const struct s2a_ts_queue *q, uint32_t index) {
    return q->cap ? (uint32_t)((q->head + index) % q->cap) : 0;
}
static inline uint64_t s2a_ts_queue_frame(const struct s2a_ts_queue *q, uint32_t index) {
    return q->slots[s2a_ts_queue_slot(q, index)].frame_id;
}

// 从头部释放 n 项；n 不能超过当前项数。清空后把 head/tail 归零，避免计数器无界增长。
static inline void s2a_ts_queue_release(struct s2a_ts_queue *q, uint32_t n) {
    if (!q || n > s2a_ts_queue_count(q)) return;
    q->head += n;
    if (q->head == q->tail) q->head = q->tail = 0;
}
