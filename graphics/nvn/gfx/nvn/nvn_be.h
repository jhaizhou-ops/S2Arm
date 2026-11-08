// Backend of the direct replay layer (#277 D3-1): Metal 4 or Metal 3, picked once in mtl_init. Same switch as the gal renderer (graphics/metal/gal_be.h), plus a device check:
//   NXGAL_BE=mtl3 forces Metal 3 (A/B on systems 26 and up; off by default; any other value does nothing, as in gal);
//   systems 26 and up whose GPU is in the Metal 4 family (supportsFamily:MTLGPUFamilyMetal4) take Metal 4;
//   everything else takes Metal 3: systems below 26, and GPUs without Metal 4 on 26 (A12X / A12Z / A13 class). The Metal 3 path needs the residency set on an old queue,
//   macOS 15 / iOS 18 on, which is the build's deployment floor (tools/toolchain.env).
// gal decides by system version only (gal_core.m gal_be_select); the device check is the direct layer's own until gal takes it too.
// Pure C without Metal: nvn_mtl.m passes in what it read, graphics/nvn/tests/t_nvn_be.c checks every case
#pragma once
#include <string.h>
enum { NVN_BE_MTL3 = 3, NVN_BE_MTL4 = 4 };
static inline int nvn_be_pick(const char *env, int os26, int family4, const char **why) {
    if (env && !strcmp(env, "mtl3")) { *why = "forced by NXGAL_BE=mtl3"; return NVN_BE_MTL3; }
    if (!os26) { *why = "system below macOS / iOS 26"; return NVN_BE_MTL3; }
    if (!family4) { *why = "GPU not in the Metal 4 family"; return NVN_BE_MTL3; }
    *why = "GPU in the Metal 4 family"; return NVN_BE_MTL4;
}
