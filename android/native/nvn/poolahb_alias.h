// 别名登记（纯逻辑，宿主可测）：宿主层每次把一段 guest 内存 alias 到第二个虚拟地址时登记来源区间；
// 池后备迁移前必须确认该区间**没有**任何受控别名，否则换底只会换掉一个地址、旧别名仍指向旧内容。
//
// 说明：/proc/self/maps 无法可靠判定别名——本机 guest RAM 是 /dev/kgsl-3d0 的共享映射，
// 所有段共用同一 dev/inode 且 offset 恒为 0，用 dev+inode+offset 会把所有映射都判成同一个对象。
// 所以别名判定必须来自“谁真的创建了别名”，即本登记表。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 登记一条别名：src 区间被复制到 dst。返回 0 成功。
int s2a_alias_note(uint64_t src, uint64_t dst, uint64_t size);
// 解除 dst 处的别名登记（unmap/回滚）。
void s2a_alias_drop(uint64_t dst);
// 查询：[addr, addr+len) 是否与任何已登记别名相交。返回 1 = 有别名（不可迁移）。
int s2a_alias_conflict(uint64_t addr, uint64_t len);
// 清空（会话重建 / 测试）。
void s2a_alias_reset(void);

#ifdef __cplusplus
}
#endif
