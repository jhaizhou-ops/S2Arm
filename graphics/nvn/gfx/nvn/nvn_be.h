// Backend of the direct replay layer (#277 D3-1): Metal 4 or Metal 3, picked once in mtl_init. Same switch as the gal renderer (graphics/metal/gal_be.h), plus a device check:
//   NXGAL_BE=mtl3 forces Metal 3 (A/B on systems 26 and up; off by default; any other value does nothing, as in gal);
//   systems 26 and up whose GPU is in the Metal 4 family (supportsFamily:MTLGPUFamilyMetal4) take Metal 4;
//   everything else takes Metal 3: systems below 26, GPUs without Metal 4 on 26 (A12X / A12Z / A13 class), and iOS / iPadOS 26.x (below 27):
//   11-09 #311 iPhone18,2 iOS 26.5.2：Metal 4 上屏时系统合成进程 backboardd 在 CA::OGL::MetalContext::add_shared_event（capture_detached ← 分离图层）断言崩溃、
//   连崩 3 次带走整个系统界面；玩家用 NXGAL_BE=mtl3 绕开。我方设备都是 iOS 27，复现不了也降不了级：26.x 一律走 Metal 3（玩家实测能绕开的那条），27 起照旧。Mac 不受影响。
//   The Metal 3 path needs the residency set on an old queue,
//   macOS 15 / iOS 18 on, which is the build's deployment floor (tools/toolchain.env).
// gal decides by system version only (gal_core.m gal_be_select); the device check is the direct layer's own until gal takes it too.
// Pure C without Metal: nvn_mtl.m passes in what it read, graphics/nvn/tests/t_nvn_be.c checks every case
#pragma once
#include <string.h>
enum { NVN_BE_MTL3 = 3, NVN_BE_MTL4 = 4 };
// ios26x：iOS / iPadOS 26.x（26 ≤ 版本 < 27）；Mac 恒 0
static inline int nvn_be_pick(const char *env, int os26, int family4, int ios26x, const char **why) {
    if (env && !strcmp(env, "mtl3")) { *why = "forced by NXGAL_BE=mtl3"; return NVN_BE_MTL3; }
    if (!os26) { *why = "system below macOS / iOS 26"; return NVN_BE_MTL3; }
    if (ios26x) { *why = "iOS 26: no detached-layer direct present (backboardd add_shared_event assert, #311), Metal 3"; return NVN_BE_MTL3; }
    if (!family4) { *why = "GPU not in the Metal 4 family"; return NVN_BE_MTL3; }
    *why = "GPU in the Metal 4 family"; return NVN_BE_MTL4;
}
