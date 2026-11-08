// 计算着色器共享内存溢出改写（gal_spill.c）的声明：纯 C，不引 Metal 头；Linux / Windows 出包机单独编那份 .c 时也用（#783）。
//   gal_internal.h 在 Metal 4 可用性区之前包含本头，各块文件照旧经 gal_internal.h 看到这些声明；溢出缓冲的槽号 GAL_SPILL_SLOT 仍在 gal_internal.h。
#pragma once
#include <stdint.h>
#define GAL_TG_MEM_MAX 32768u   // 离线出库（不建设备）的目标设备 maxThreadgroupMemoryLength（iPhone A 系 / Apple 芯片 Mac 同为 32 KB）；运行时按 MTLDevice 当场查询
// 线程组内存上限：Mac / iOS 由 gal_prog.m 提供（有设备按 MTLDevice 查询，没有设备取 GAL_TG_MEM_MAX）；单独成库（GAL_SPILL_STANDALONE）时 gal_spill.c 给常量
uint32_t gal_spill_limit(void);
// 超限的 threadgroup 数组挪到槽 slot 的溢出缓冲：NULL = 没超限（原样）；(char *)-1 = 结构不认识（写 why）；否则新 MSL（malloc），*bytes = 每线程组溢出字节
char *gal_spill_msl(const char *src, uint32_t slot, uint32_t *bytes, char *why);
