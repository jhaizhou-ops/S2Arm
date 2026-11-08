// 池后备迁移前的地址覆盖判定（纯逻辑，宿主可测）：这段 guest 地址是否被连续的匿名映射完整覆盖。
// 为什么不许“每段都 rw”：脏页跟踪器 nvn_dirty_protect() 会把登记的页设成只读（maps 显示 r--p），
// 池里有被跟踪的页时整池会被误判成“不连续 rw”（本机实测 5 个热池因此全被拒绝迁移）。
#pragma once
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// 从已打开的 maps 流判断；返回 1 = 可迁移的连续匿名覆盖。
int s2a_poolahb_cover_check_stream(FILE *f, uint64_t base, uint64_t len);
// 从指定 maps 文件判断（宿主测试用；生产传 "/proc/self/maps"）。
int s2a_poolahb_cover_check_path(const char *path, uint64_t base, uint64_t len);

#ifdef __cplusplus
}
#endif
