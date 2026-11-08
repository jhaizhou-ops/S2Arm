// 遮挡查询页「按提交批次退休」的接线（纯逻辑，不依赖 Vulkan）。
//
// 为什么单独抽出来：查询页有两条完成路径——延迟退休（帧槽 fence 过后）与同步 flush（当场等
// fence）。两条路径都必须把该批的 batch_qid/suffix_qid 交给查询模块回收页；只结算报告不回收页
// 的那条路径不会立刻报错，只会慢慢把页池吃光（真机表现：页反复 64/64、开 pass 的查询准备从
// 2 us 涨到 50+ us）。这里把「退休一次、失败不清零」的语义固定下来，并让两条路径共用。
#pragma once
#include <stdint.h>

// 退休一个批次槽位。槽位为 0 表示这批没有查询页，直接成功。
// retire 返回非 0 时**不清零槽位**：上层看到失败要进终态，不能把没拿到结果的批次当成已完成。
// 返回 0 = 已退休或本来就是空的；-1 = 退休失败（槽位保持不变）。
static inline int s2a_qret_slot(uint64_t *slot, int (*retire)(uint64_t qid, void *ctx), void *ctx) {
    if (!slot || !*slot) return 0;
    uint64_t qid = *slot;
    if (retire && retire(qid, ctx) != 0) return -1;
    *slot = 0;
    return 0;
}

// 前缀批次按提交顺序退休；遇到失败立即返回，后面的批次不假装完成。
static inline int s2a_qret_prefix(uint64_t *slots, int n, int (*retire)(uint64_t, void *), void *ctx) {
    if (!slots || n <= 0) return 0;
    for (int i = 0; i < n; i++)
        if (s2a_qret_slot(&slots[i], retire, ctx) != 0) return -1;
    return 0;
}
