// 曲面细分接口（纯 C，11-05 从 gal_internal.h 搬出）：记录位、域 / 分区枚举、接口缓冲槽号、规范布局与翻译段（gal_tessxc.c）的原型。
//   gal_internal.h 在可用性区之外包含它；Windows 出包机的小库（graphics/metal/tools/nxgal_win.py）单独编 gal_tessxc.c / gal_vpullc.c 时用同一份
#pragma once
#include <stdint.h>

#define GAL_REC_VT 16u
#define GAL_REC_DOM_SHIFT 5
#define GAL_REC_SP_SHIFT 7
#define GAL_REC_CW (1u << 9)
#define GAL_REC_POINT (1u << 10)
enum { GAL_TESS_ISO = 1, GAL_TESS_TRI = 2, GAL_TESS_QUAD = 3 };       // 域
enum { GAL_TESS_EQUAL = 1, GAL_TESS_FODD = 2, GAL_TESS_FEVEN = 3 };   // 分区（SpacingEqual / FractionalOdd / FractionalEven）
// 控制点规范布局的位置号：0–31 通用、32 位置、33 点大小、34–41 裁剪距离
#define GAL_TESS_LOC_POS 32
#define GAL_TESS_LOC_PSZ 33
#define GAL_TESS_LOC_CLIP 34
// 曲面各段在参数表里的槽（8–23 是顶点缓冲槽：曲面三段都不用 stage_in 顶点缓冲，借用前几个）
#define GAL_TESS_SLOT_IN 8
#define GAL_TESS_SLOT_OUT 9
#define GAL_TESS_SLOT_PATCH 10
#define GAL_TESS_SLOT_FACTOR 11
#define GAL_TESS_SLOT_PARAMS 12
#define GAL_TESS_SLOT_POINTS 13
#define GAL_TESS_AT(base, slot) ((base) + (slot) - GAL_TESS_SLOT_IN)   // 起始槽号 base 下某个曲面接口缓冲的槽号（gal 的 base = GAL_TESS_SLOT_IN；直连另给，nxgal_dmsh_xc_tess）
#define GAL_REC_PATCH (1u << 11)        // 着色器记录位 11：TCS 写 / TES 读每片属性（patchOut / patchIn 结构体）
#define GAL_REC_SPILL (1u << 12)        // 着色器记录位 12：计算着色器共享内存溢出到设备内存（每线程组字节放 io_mask；10-21 合批前用值 16，与曲面 GAL_REC_VT 同值，改开）
#define GAL_TESS_CP_BYTES 576           // 规范布局每控制点字节数（32 × 16 + 位置 16 + 点大小 16 + 裁剪距离 32）
#define GAL_TESS_PATCH_BYTES 512        // 规范布局每片属性字节数（32 × 16）
#define GAL_TESS_OCP_SENTINEL 1234567891u   // TES 翻译时输出控制点数填这个哨兵，改写时换成运行时参数（gal_tess.m）
typedef struct { char name[96]; uint32_t loc; uint8_t patch; } gal_tess_loc;   // 接口变量名 → 位置号（SPIRV-Cross 成员名：有名用名，否则 m_<id>）
int gal_tess_canon(char **msl, const char *sname, int per_vertex, const gal_tess_loc *locs, int nlocs, char *why);
char *gal_tess_vt_msl(const char *msl, const char *entry, int *pulled, uint32_t base, char *why);   // base：曲面接口起始槽号（gal_prog.m tess_options）
char *gal_tess_tes_msl(const char *msl, const char *entry, int tri, uint32_t base, char *why);

// 顶点自取的纯 C 部分（gal_vpullc.c）：成员读法与辅助 MSL 原文，曲面前顶点改写（gal_tessxc.c）也用
char gal_vpull_kind(const char *ty, const char *name);
const char *nxgal_test_vpull_msl(void);   // 顶点自取辅助 MSL 原文（gal_vpullc.c）
