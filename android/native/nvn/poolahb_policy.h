// 池后备迁移的“选谁”策略（纯逻辑，宿主可测）。
//
// 目标不是“迁得越多越好”，而是**每占用 1 MB AHB 内存能省掉多少每帧上传字节**最高。
// 因此按 (每帧引用字节 / 池大小) 排序，而不是按绝对字节；并受预算、单池上限、失败/已完成状态约束。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_pa_candidate {
    uint64_t base;
    uint64_t len;
    uint64_t bytes;   // 近期每窗被引用的字节数（已衰减）
    int done;         // 已迁移
    int failed;       // 迁移失败过，不再试
};

// 返回应迁移的下标；-1 = 本次没有可迁的。
// 规则：跳过 done/failed；len 必须 <= max_len 且 <= budget_left；bytes 必须 >= min_bytes（避免为冷池付成本）；
// 在满足条件的候选中取 bytes/len 最大者（省字节/AHB 字节），相同时取 bytes 更大者、再相同取下标小者。
int s2a_pa_select(const struct s2a_pa_candidate *c, int n, uint64_t min_bytes,
                  uint64_t max_len, uint64_t budget_left);

#ifdef __cplusplus
}
#endif
