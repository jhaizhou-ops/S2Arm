// Android NVN 稀疏虚拟池的别名区间表（#1217 §2.8）。
// 只记「dst 区间 -> 源地址」；增删都必须先切掉重叠的旧记录并 unref 被切掉的部分。
// 调用方持 NVN 的 g_vp_mu（锁序 g_vp_mu → svc_mem g_mu），本文件不取任何锁。
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t lo, hi;   // 虚拟池内的 dst 偏移区间
    uint64_t src;      // 对应的源地址（背板 pgoff 的起点）
} s2a_vp_alias;

typedef struct {
    s2a_vp_alias *v;
    int n, cap;
} s2a_vp_alias_table;

// 清空并 unref 全部记录（vpool_release / vpool 复用）。
void s2a_vp_alias_clear(s2a_vp_alias_table *table);
// 切掉 [lo,hi) 覆盖的旧记录；被切掉的那几段逐段 unref。
void s2a_vp_alias_remove(s2a_vp_alias_table *table, uint64_t lo, uint64_t hi);
// 切掉重叠旧记录后登记 [lo,hi) -> src。成功 0，分配失败 ENOMEM（旧记录已切、新记录未登记）。
int s2a_vp_alias_add(s2a_vp_alias_table *table, uint64_t lo, uint64_t hi, uint64_t src);

#ifdef __cplusplus
}
#endif
