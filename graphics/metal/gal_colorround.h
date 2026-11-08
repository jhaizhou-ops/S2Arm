// 片元颜色出口 half 舍入改写（gal_colorround.c）的声明：不引 Metal 头，Linux / Windows 出包机单独编那份 .c 时也用（#783）。
//   gal_internal.h 在 Metal 4 可用性区之前包含本头，各块文件照旧经 gal_internal.h 看到这些声明。
#pragma once
#include <stdint.h>
#define GAL_COLOR_ROUND_SLOT 27   // 片元阶段：无混合 half 颜色附件的 RTZ 位图；计算阶段的 27 号仍给共享内存溢出
char *gal_color_round_msl(const char *msl, const char *entry, char *why);   // 片元主入口按附件位图量化 half 输出（gal_colorround.c）
const char *gal_color_round_helpers(void);   // 主入口与真实 Metal 回归共用的 RTZ 量化函数
