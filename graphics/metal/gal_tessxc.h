// 曲面翻译段（gal_tessxc.m）的接口：要在 spirv_cross_c.h 之后包含。stage 1 顶点（vt 变体）/ 2 TCS / 3 TES；base = 曲面接口缓冲起始槽号（GAL_TESS_AT）
#pragma once
#include "spirv_cross_c.h"
int gal_tessxc_modes(spvc_compiler c, int stage, int vt, uint32_t *flags, uint32_t *ocp, char *why);
void gal_tessxc_options(spvc_compiler c, spvc_compiler_options o, int vt, uint32_t base);
char *gal_tessxc_post(spvc_compiler c, spvc_resources res, const char *src, int stage, int vt, const char *entry, uint32_t *flags, uint32_t base, char *why);
