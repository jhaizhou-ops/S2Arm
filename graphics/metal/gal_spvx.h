// SPIR-V 加固改写（gal_spvx.c）的声明：纯 C，不引 Metal 头；Linux / Windows 出包机单独编那份 .c 时也用（#783）。
//   gal_internal.h 在 Metal 4 可用性区之前包含本头，各块文件照旧经 gal_internal.h 看到这些声明；参数表槽号 GAL_ARG_UBOLEN / GAL_ARG_OOBCNT 与说明仍在 gal_internal.h。
#pragma once
#include <stdint.h>
#define GAL_MAX_SETS 8
#define GAL_UBOLEN_BINDING 0xfffeu   // 常量缓冲长度表 gal_ubo_len 的绑定号（参数表槽 GAL_ARG_UBOLEN）
#define GAL_OOBCNT_BINDING 0xfffdu   // 越界 / 循环到上限计数格的绑定号（参数表槽 GAL_ARG_OOBCNT）
enum { GAL_OOB_UBO, GAL_OOB_SSBO, GAL_OOB_SHARED, GAL_OOB_LOCAL, GAL_OOB_VEC, GAL_OOB_LOOP, GAL_OOB_NVAR };   // 计数格 [1] 的位号；前 5 类是越界、第 6 位 = 循环到上限
int gal_spvx_counting(void);   // 计数开着没有（NXGAL_BOUNDS_COUNT=1 开，缺省关、两端同出货口径；开着的局只读计数、不比像素）
// SPIR-V 加固改写：返回 malloc 的新码（*onw 字数），无需改写返回 NULL；st 累加各类计数（可为 NULL）
enum { GAL_SPVX_CLAMP, GAL_SPVX_UBO, GAL_SPVX_STORE, GAL_SPVX_ATOMIC, GAL_SPVX_LOOP, GAL_SPVX_SKIP, GAL_SPVX_NSTAT };
uint32_t *gal_spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT]);
void gal_spvx_totals(uint32_t out[GAL_SPVX_NSTAT]);   // 进程累计：钳位下标 / 常量缓冲访问 / 守卫写 / 守卫原子 / 循环回边上限 / 改不了（报红）
