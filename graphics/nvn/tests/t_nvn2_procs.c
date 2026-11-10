// NVN2（Switch 2）驱动按名可取的入口全集（graphics/nvn/gfx/nvn/nvn2_drv_names.txt，金刚 / Pokopia 20.5、Raiders 21.4、火纹 22 四款 sdk 抽出的 767 个）按名取得到，
//   以及 11-04 补的各类入口按驱动语义。期望值全部来自驱动反汇编（地址见 hle_nvn.c「NVN2 入口全量」段与 nvn2_cmd.h，下文「0x…」= 火纹 SDK 22 sdk），不跑实现推：
//   · 名字全集：767 个都取得到非空；只有未实现桩的必须正好是 kRed 里写明原因的 38 个（多一个、少一个都红）；
//   · 构建器 / 对象 Set / Get：先把对象填满 0xee 再 SetDefaults，按驱动布局逐字节核缺省（程序构建器递归深度 2、脏块图 +0x58/+0x5c/+0x60 = 1/16/16、
//     窗口构建器超时 -1 与 Rec.709 HDR 缺省），再 Set 后在驱动偏移处读原始字节、Get 读回；
//   · 栈上参数：HDR 显示元数据十个 float 按 Switch 调用约定（第 9 个占栈上 8 字节槽、只取低 4 字节）传，十个出参指针第 8–10 个在栈上；这四个入口不走大宿主栈；
//   · 纯函数：采样位置网格表、统一缓冲区句柄 / 设备命令句柄大小的驱动公式（期望手算）；
//   · 录制：延后推常量录成 OP_PUSH_CONST_PTR（指针、规整后的槽 / 偏移 / 字节数）；只改硬件排程的空操作与「缺省值不录」的状态命令不占命令内存；
//   · 未实现桩照旧报红回 0（调一个网格任务入口）。
#include "nvn_protos.h"
#include "nvn_obj.h"
#include "nvn2_cmd.h"
#include "nvn_count.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
typedef struct { _Atomic uint64_t cnt; void *fn; } slot_t;
extern slot_t nvn_slot[NVN_NFUNC];
extern const char *nvn_names[NVN_NFUNC];
extern void nvn_unimpl_entry(void);
extern void nvn_big_entry(void);
uint64_t s2a_npdm_window_need(const char *npdm);   // runtime/src/svc_mem.c：读 NPDM，Switch 2 的 ACID 布局置平台位（nvn2_on）

static const char *phase = "准备";
static unsigned checks;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "✗ t_nvn2_procs [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); CHECK(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))
#define FN(T, name) ((T)load(name))
static unsigned slot_of(const char *n) { unsigned i = 0; while (i < NVN_NFUNC && strcmp(nvn_names[i], n)) i++; CHECK(i < NVN_NFUNC); return i; }
static uint32_t rd32(const void *o, unsigned at) { uint32_t v; memcpy(&v, (const uint8_t *)o + at, 4); return v; }
static uint64_t rd64(const void *o, unsigned at) { uint64_t v; memcpy(&v, (const uint8_t *)o + at, 8); return v; }

static NVNdevice device;
static NVNmemoryPool pool;
static uint8_t *memory;

// 仍是未实现桩的 38 个（原因在 hle_nvn.c g_nvn2_red）：网格任务 6（DrawMeshTasks / DrawMeshTasksIndirect 11-05 已做）、光追 15、设备生成命令 4、脏块图计算 2、协作向量 3、条件开关 2、子程序 / 激发顶点 2、
//   采样位置读回 1、每 warp 暂存 1、原始描述符写 2 —— 少一个说明有人把做不到的入口「补」成了假成功（或真做出来了：同步改这张表），多一个说明漏实现
static const char *const kRed[] = {
    "nvnCommandBufferDrawMeshTasks3D", "nvnCommandBufferDrawMeshTasks3DIndirect",
    "nvnCommandBufferMultiDrawMeshTasks3DIndirect", "nvnCommandBufferMultiDrawMeshTasks3DIndirectCount", "nvnCommandBufferMultiDrawMeshTasksIndirect", "nvnCommandBufferMultiDrawMeshTasksIndirectCount",
    "nvnCommandBufferDispatchRays", "nvnCommandBufferDispatchRaysIndirect", "nvnCommandBufferBindAccelerationStructure", "nvnCommandBufferBindAccelerationStructures",
    "nvnCommandBufferBindAccelerationStructuresDeferred", "nvnCommandBufferBuildAccelerationStructures", "nvnCommandBufferCompactAccelerationStructure", "nvnCommandBufferCopyAccelerationStructure",
    "nvnCommandBufferRelocateAccelerationStructure", "nvnCommandBufferGetAccelerationStructureVisualizationData", "nvnDeviceCalculateAccelerationStructureMemoryRequirements",
    "nvnDeviceCompactAccelerationStructure", "nvnDeviceCopyAccelerationStructure", "nvnDeviceRelocateAccelerationStructure", "nvnProgramGetShaderGroupHandle",
    "nvnCommandBufferBeginDeviceCommands", "nvnCommandBufferEndDeviceCommands", "nvnCommandBufferSubmitDeviceCommands", "nvnProgramGetDeviceComputeMemorySize",
    "nvnCommandBufferComputeDirtyTileMap", "nvnCommandBufferComputeDirtyTileMapEx",
    "nvnCommandBufferConvertCooperativeVectorMatrix", "nvnDeviceConvertCooperativeVectorMatrix", "nvnDeviceGetCooperativeVectorMatrixSize",
    "nvnCommandBufferSetComputeEnableConditional", "nvnCommandBufferSetCopyEnableConditional",
    "nvnCommandBufferSetProgramSubroutines", "nvnCommandBufferSetProvokingVertexMode", "nvnMultisampleStateGetSampleLocations",
    "nvnProgramGetScratchBytesPerWarp", "nvnSamplerPoolWriteDescriptorTableData", "nvnTexturePoolWriteDescriptorTableData",
};
enum { NRED = sizeof kRed / sizeof *kRed };

static void drv_names(void) {
    phase = "NVN2 驱动名字全集";
    FILE *f = fopen("graphics/nvn/gfx/nvn/nvn2_drv_names.txt", "r"); CHECK(f != NULL);
    char line[256]; unsigned n = 0, red = 0, v205 = 0, v214 = 0, v22 = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        char *tab = strchr(line, '\t'); CHECK(tab != NULL); *tab = 0;
        if (!strcmp(tab + 1, "20.5")) v205++; else if (!strcmp(tab + 1, "21.4")) v214++; else if (!strcmp(tab + 1, "22")) v22++; else CHECK(!"版本列只能是 20.5 / 21.4 / 22");
        if (!h_nvnBootstrapLoader(line)) { fprintf(stderr, "✗ NVN2 驱动名字取不到：%s\n", line); exit(1); }
        int known = 0; for (unsigned k = 0; k < NRED; k++) known |= !strcmp(kRed[k], line);
        int stub = nvn_slot[slot_of(line)].fn == (void *)nvn_unimpl_entry;
        if (stub != known) { fprintf(stderr, "✗ %s：%s\n", line, stub ? "只有未实现桩，不在写明原因的清单里" : "清单说做不到，却有实现"); exit(1); }
        red += stub; n++;
    }
    fclose(f);
    CHECK(n == 767); CHECK(v205 == 758); CHECK(v214 == 5); CHECK(v22 == 4);
    CHECK(red == NRED); CHECK(NRED == 38);
    printf("  NVN2 驱动名字 %u 个（20.5 有 %u、21.4 新增 %u、22 新增 %u）：全部取得到；有实现 %u、写明原因的未实现桩 %u\n", n, v205, v214, v22, n - red, red);
}

// 程序构建器（0x660d40 SetDefaults：+0x18..+0x63 清零、+0x58 / +0x5c = 2，不动 +0x00..+0x17）
static void program_builder(void) {
    phase = "程序构建器";
    _Alignas(16) uint8_t b[0x80]; memset(b, 0xee, sizeof b);
    FN(void (*)(void *), "nvnProgramBuilderSetDefaults")(b);
    for (unsigned i = 0; i < 0x18; i++) CHECK(b[i] == 0xee);
    for (unsigned i = 0x18; i < 0x58; i++) CHECK(b[i] == 0);
    CHECK(rd32(b, 0x58) == 2 && rd32(b, 0x5c) == 2 && rd32(b, 0x60) == 0);
    for (unsigned i = 0x64; i < sizeof b; i++) CHECK(b[i] == 0xee);   // 驱动写到 +0x63 为止
    FN(void (*)(void *, NVNdevice *), "nvnProgramBuilderSetDevice")(b, &device);
    CHECK(rd64(b, 0x08) == (uint64_t)(uintptr_t)&device && FN(NVNdevice *(*)(const void *), "nvnProgramBuilderGetDevice")(b) == &device);
    static const NVNshaderData sd[2]; static const int dbg[3], rt[2], sub[4];
    FN(void (*)(void *, int, const NVNshaderData *), "nvnProgramBuilderSetShaders")(b, 2, sd);
    FN(void (*)(void *, int), "nvnProgramBuilderSetSampleShading")(b, 1);
    FN(void (*)(void *, int, const void *), "nvnProgramBuilderSetDebugDataHashes")(b, 3, dbg);
    FN(void (*)(void *, int, const void *), "nvnProgramBuilderSetRayTracingModules")(b, 2, rt);
    FN(void (*)(void *, int, const void *), "nvnProgramBuilderSetSubroutineLinkage")(b, 4, sub);
    FN(void (*)(void *, int), "nvnProgramBuilderSetMaxTraceRecursionDepth")(b, 5);
    FN(void (*)(void *, int), "nvnProgramBuilderSetMaxCallableRecursionDepth")(b, 6);
    FN(void (*)(void *, int), "nvnProgramBuilderSetProgramRayTracingFlags")(b, 0x31);
    CHECK(rd32(b, 0x28) == 2 && rd64(b, 0x30) == (uint64_t)(uintptr_t)sd && rd32(b, 0x18) == 1 && rd32(b, 0x1c) == 3 && rd64(b, 0x20) == (uint64_t)(uintptr_t)dbg);
    CHECK(rd32(b, 0x38) == 2 && rd64(b, 0x40) == (uint64_t)(uintptr_t)rt && rd32(b, 0x48) == 4 && rd64(b, 0x50) == (uint64_t)(uintptr_t)sub);
    CHECK(rd32(b, 0x58) == 5 && rd32(b, 0x5c) == 6 && rd32(b, 0x60) == 0x31);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetShaderCount")(b) == 2 && FN(const void *(*)(const void *), "nvnProgramBuilderGetShaders")(b) == sd);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetSampleShading")(b) == 1 && FN(const void *(*)(const void *), "nvnProgramBuilderGetDebugDataHashes")(b) == dbg);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetRayTracingModuleCount")(b) == 2 && FN(const void *(*)(const void *), "nvnProgramBuilderGetRayTracingModuleData")(b) == rt);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetSubroutineLinkageCount")(b) == 4 && FN(const void *(*)(const void *), "nvnProgramBuilderGetSubroutineLinkage")(b) == sub);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetMaxTraceRecursionDepth")(b) == 5 && FN(int (*)(const void *), "nvnProgramBuilderGetMaxCallableRecursionDepth")(b) == 6);
    CHECK(FN(int (*)(const void *), "nvnProgramBuilderGetProgramRayTracingFlags")(b) == 0x31);
    static NVNprogram p; CHECK(!FN(NVNboolean (*)(NVNprogram *, const void *), "nvnProgramInitializeFromBuilder")(&p, b));   // 带光追模块：宿主建不了，回失败
}

// 脏块图参数（0x64ed40 SetDefaults：全 0，+0x58 / +0x5c / +0x60 = 1 / 16 / 16）
static void dirty_tile_map(void) {
    phase = "脏块图参数";
    _Alignas(16) uint8_t p[0x80]; memset(p, 0xee, sizeof p);
    FN(void (*)(void *), "nvnDirtyTileMapParametersSetDefaults")(p);
    for (unsigned i = 0; i < 0x74; i++) CHECK(p[i] == (i == 0x58 ? 1 : i == 0x5c || i == 0x60 ? 16 : 0));
    CHECK(p[0x74] == 0xee);
    uint8_t region[24]; for (int i = 0; i < 24; i++) region[i] = (uint8_t)(0x40 + i);
    NVNtexture *tex = (NVNtexture *)(uintptr_t)0x1111; NVNtextureView *view = (NVNtextureView *)(uintptr_t)0x2222;
    FN(void (*)(void *, const void *, const void *, const void *), "nvnDirtyTileMapParametersSetTexture")(p, tex, view, region);
    FN(void (*)(void *, int, int, int, int), "nvnDirtyTileMapParametersSetInputs")(p, 1, 2, 3, 4);
    FN(void (*)(void *, uint64_t, int, int, uint64_t), "nvnDirtyTileMapParametersSetOutputs")(p, 0x123456789aull, 7, 8, 0xabcdef0123ull);
    FN(void (*)(void *, const void *, int, int, uint64_t), "nvnDirtyTileMapParametersSetConstantColorTable")(p, region, 9, 10, 0x55aa55aa55ull);
    FN(void (*)(void *, uint32_t, uint32_t), "nvnDirtyTileMapParametersSetDepthStencilMask")(p, 0xf0f0, 0x0f);
    FN(void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t), "nvnDirtyTileMapParametersSetExpandFootprint")(p, 0x101, 0, 0x7700, 1);   // 只取低 8 位：0x101 → 1、0x7700 → 0
    // 驱动的存放处：SetTexture stp x1, x2, [x0] + 区域在 +0x10；SetInputs stp w4, w1, [x0, #0x60] / str w2, [#0x28] / str w3, [#0x5c]；SetOutputs +0x30 / +0x38 / +0x3c / +0x40；
    //   SetConstantColorTable +0x48 / +0x2c / +0x58 / +0x50；SetDepthStencilMask stp w1, w2, [#0x68]；SetExpandFootprint strb ×4 在 +0x70..+0x73
    CHECK(rd64(p, 0) == 0x1111 && rd64(p, 8) == 0x2222 && !memcmp(p + 0x10, region, 24));
    CHECK(rd32(p, 0x64) == 1 && rd32(p, 0x28) == 2 && rd32(p, 0x5c) == 3 && rd32(p, 0x60) == 4);
    CHECK(rd64(p, 0x30) == 0x123456789aull && rd32(p, 0x38) == 7 && rd32(p, 0x3c) == 8 && rd64(p, 0x40) == 0xabcdef0123ull);
    CHECK(rd64(p, 0x48) == (uint64_t)(uintptr_t)region && rd32(p, 0x2c) == 9 && rd32(p, 0x58) == 10 && rd64(p, 0x50) == 0x55aa55aa55ull);
    CHECK(rd32(p, 0x68) == 0xf0f0 && rd32(p, 0x6c) == 0x0f && p[0x70] == 1 && p[0x71] == 0 && p[0x72] == 0 && p[0x73] == 1);
    const void *t = NULL, *v = NULL; uint8_t rg[24] = {0}; int a, b2, c, d; uint64_t o0, o3, cd; const void *cc; uint32_t dm, sm; uint8_t f0, f1, f2, f3;
    FN(void (*)(const void *, const void **, const void **, void *), "nvnDirtyTileMapParametersGetTexture")(p, &t, &v, rg);
    CHECK(t == tex && v == view && !memcmp(rg, region, 24));
    FN(void (*)(const void *, int *, int *, int *, int *), "nvnDirtyTileMapParametersGetInputs")(p, &a, &b2, &c, &d); CHECK(a == 1 && b2 == 2 && c == 3 && d == 4);
    FN(void (*)(const void *, uint64_t *, int *, int *, uint64_t *), "nvnDirtyTileMapParametersGetOutputs")(p, &o0, &b2, &c, &o3); CHECK(o0 == 0x123456789aull && b2 == 7 && c == 8 && o3 == 0xabcdef0123ull);
    FN(void (*)(const void *, const void **, int *, int *, uint64_t *), "nvnDirtyTileMapParametersGetConstantColorTable")(p, &cc, &a, &b2, &cd); CHECK(cc == region && a == 9 && b2 == 10 && cd == 0x55aa55aa55ull);
    FN(void (*)(const void *, uint32_t *, uint32_t *), "nvnDirtyTileMapParametersGetDepthStencilMask")(p, &dm, &sm); CHECK(dm == 0xf0f0 && sm == 0x0f);
    FN(void (*)(const void *, uint8_t *, uint8_t *, uint8_t *, uint8_t *), "nvnDirtyTileMapParametersGetExpandFootprint")(p, &f0, &f1, &f2, &f3); CHECK(f0 == 1 && f1 == 0 && f2 == 0 && f3 == 1);
    FN(void (*)(const void *, uint32_t *, uint32_t *), "nvnDirtyTileMapParametersGetDepthStencilMask")(p, NULL, NULL);   // 出参可空（驱动 cbz）
}

// 窗口构建器 / 窗口：缺省（0x66c240）、Set / Get、WindowInitialize 带过去；HDR 显示元数据按 Switch 调用约定传
typedef void (*hdr_set_fn)(void *, float, float, float, float, float, float, float, float, double, float);   // 第 9 个：栈上 8 字节槽，低 4 字节是 float
typedef void (*hdr_get_fn)(const void *, float *, float *, float *, float *, float *, float *, float *, float *, float *, float *);
static double slot_f(float f, uint32_t junk) { uint64_t u = (uint64_t)junk << 32; uint32_t b; memcpy(&b, &f, 4); u |= b; double d; memcpy(&d, &u, 8); return d; }
static void window(void) {
    phase = "窗口 / 窗口构建器";
    _Alignas(16) uint8_t b[0x80]; memset(b, 0xee, sizeof b);
    API(nvnWindowBuilderSetDefaults)((NVNwindowBuilder *)b);
    static const float disp_def[10] = {0.64f, 0.33f, 0.30f, 0.60f, 0.15f, 0.06f, 0.3127f, 0.329f, 0.03f, 1000.0f};   // 火纹 sdk 0xbb47f0 / 0xbb2a70 / 0xbb5140 的值
    CHECK(FN(int64_t (*)(const void *), "nvnWindowBuilderGetAcquireTimeout")(b) == -1 && FN(int (*)(const void *), "nvnWindowBuilderGetColorSpace")(b) == 0);
    float g[10]; hdr_get_fn hg = FN(hdr_get_fn, "nvnWindowBuilderGetHdrDisplayMetadata");
    hg(b, &g[0], &g[1], &g[2], &g[3], &g[4], &g[5], &g[6], &g[7], &g[8], &g[9]); for (int i = 0; i < 10; i++) CHECK(g[i] == disp_def[i]);
    float cll = 0, fall = 0; FN(void (*)(const void *, float *, float *), "nvnWindowBuilderGetHdrContentMetadata")(b, &cll, &fall); CHECK(cll == 200.0f && fall == 60.0f);
    FN(void (*)(void *, int64_t), "nvnWindowBuilderSetAcquireTimeout")(b, 16666667);
    FN(void (*)(void *, int), "nvnWindowBuilderSetColorSpace")(b, 0);
    FN(hdr_set_fn, "nvnWindowBuilderSetHdrDisplayMetadata")(b, 1, 2, 3, 4, 5, 6, 7, 8, slot_f(9.5f, 0xdeadbeef), 10.25f);   // 槽高 4 字节是垃圾：只许取低 4 字节
    FN(void (*)(void *, float, float), "nvnWindowBuilderSetHdrContentMetadata")(b, 400.0f, 120.0f);
    hg(b, &g[0], &g[1], &g[2], &g[3], &g[4], &g[5], &g[6], &g[7], &g[8], &g[9]);
    for (int i = 0; i < 8; i++) CHECK(g[i] == (float)(i + 1));
    CHECK(g[8] == 9.5f && g[9] == 10.25f);
    hg(b, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, &g[9]);   // 出参可空
    static NVNwindow w; CHECK(API(nvnWindowInitialize)(&w, (NVNwindowBuilder *)b));
    CHECK(FN(int64_t (*)(const void *), "nvnWindowGetAcquireTimeout")(&w) == 16666667);
    hdr_get_fn wg = FN(hdr_get_fn, "nvnWindowGetHdrDisplayMetadata"); float h[10];
    wg(&w, &h[0], &h[1], &h[2], &h[3], &h[4], &h[5], &h[6], &h[7], &h[8], &h[9]); CHECK(!memcmp(h, g, sizeof h));
    FN(void (*)(const void *, float *, float *), "nvnWindowGetHdrContentMetadata")(&w, &cll, &fall); CHECK(cll == 400.0f && fall == 120.0f);
    FN(hdr_set_fn, "nvnWindowSetHdrDisplayMetadata")(&w, 11, 12, 13, 14, 15, 16, 17, 18, slot_f(19.0f, 0x12345678), 20.0f);
    wg(&w, &h[0], &h[1], &h[2], &h[3], &h[4], &h[5], &h[6], &h[7], &h[8], &h[9]); for (int i = 0; i < 10; i++) CHECK(h[i] == (float)(11 + i));
    FN(void (*)(void *, float, float), "nvnWindowSetHdrContentMetadata")(&w, 1.5f, 2.5f);
    FN(void (*)(const void *, float *, float *), "nvnWindowGetHdrContentMetadata")(&w, &cll, &fall); CHECK(cll == 1.5f && fall == 2.5f);
    FN(void (*)(void *, int64_t), "nvnWindowSetAcquireTimeout")(&w, -1); CHECK(FN(int64_t (*)(const void *), "nvnWindowGetAcquireTimeout")(&w) == -1);
    // 栈上参数的四个入口在游戏栈上直接跑（换栈会丢 [sp] 上的参数）；正对照：同族的 SetColorSpace 走大宿主栈
    CHECK(nvn_slot[slot_of("nvnWindowBuilderSetHdrDisplayMetadata")].fn != (void *)nvn_big_entry);
    CHECK(nvn_slot[slot_of("nvnWindowGetHdrDisplayMetadata")].fn != (void *)nvn_big_entry);
    CHECK(nvn_slot[slot_of("nvnWindowBuilderSetColorSpace")].fn == (void *)nvn_big_entry);
}

// 多重采样状态：覆盖截断（字 0 第 5 位）读回、SetDefaults 清；采样位置网格（0x667dd0：n = max(采样数, 光栅采样数)）
static void multisample(void) {
    phase = "多重采样状态";
    NVNmultisampleState s; memset(&s, 0xee, sizeof s);
    API(nvnMultisampleStateSetDefaults)(&s);
    CHECK(!FN(NVNboolean (*)(const void *), "nvnMultisampleStateGetCoverageTruncationEnable")(&s));
    FN(void (*)(void *, uint32_t), "nvnMultisampleStateSetCoverageTruncationEnable")(&s, 0x301);   // 低 8 位 = 1
    CHECK(FN(NVNboolean (*)(const void *), "nvnMultisampleStateGetCoverageTruncationEnable")(&s) == 1);
    API(nvnMultisampleStateSetDefaults)(&s); CHECK(!FN(NVNboolean (*)(const void *), "nvnMultisampleStateGetCoverageTruncationEnable")(&s));
    static const struct { int samples, raster, w, h; } t[] = {{0, 0, 1, 1}, {1, 0, 1, 1}, {2, 0, 2, 4}, {4, 0, 2, 2}, {8, 0, 1, 2}, {16, 0, 1, 1}, {2, 8, 1, 2}, {4, 16, 1, 1}, {3, 0, -7, -7}, {6, 0, -7, -7}};
    for (unsigned k = 0; k < sizeof t / sizeof *t; k++) {
        API(nvnMultisampleStateSetDefaults)(&s); API(nvnMultisampleStateSetSamples)(&s, t[k].samples); API(nvnMultisampleStateSetRasterSamples)(&s, t[k].raster);
        int w = -7, h = -7; API(nvnMultisampleStateGetSampleLocationsGrid)(&s, &w, &h);
        CHECK(w == t[k].w && h == t[k].h);   // 3 / 6 等：驱动不写出参
    }
}

// 队列构建器：主队列、光追内存（+0x27 记「设过」，Get 回它）；SetDefaults 清
static void queue_builder(void) {
    phase = "队列构建器";
    NVNqueueBuilder b; memset(&b, 0xee, sizeof b); API(nvnQueueBuilderSetDefaults)(&b);
    int n = -1;
    CHECK(FN(NVNqueue *(*)(const void *), "nvnQueueBuilderGetPrimaryQueue")(&b) == NULL);
    CHECK(!FN(NVNboolean (*)(const void *, int *), "nvnQueueBuilderGetRayTracingMemorySize")(&b, &n) && n == 0);
    static NVNqueue q; FN(void (*)(void *, NVNqueue *), "nvnQueueBuilderSetPrimaryQueue")(&b, &q);
    FN(void (*)(void *, int), "nvnQueueBuilderSetRayTracingMemorySize")(&b, 0x100000);
    CHECK(FN(NVNqueue *(*)(const void *), "nvnQueueBuilderGetPrimaryQueue")(&b) == &q);
    CHECK(FN(NVNboolean (*)(const void *, int *), "nvnQueueBuilderGetRayTracingMemorySize")(&b, &n) == 1 && n == 0x100000);
    CHECK(FN(uint64_t (*)(const void *), "nvnQueueGetTotalRayTracingMemoryUsed")(&q) == 0);
}

// 设备命令缓冲 / 设备消息缓冲 / 设备上的纯函数
static void device_objects(void) {
    phase = "设备命令缓冲";
    _Alignas(16) uint8_t b[0x40]; memset(b, 0xee, sizeof b);
    FN(void (*)(void *), "nvnDeviceCommandBufferSetDefaults")(b);
    for (unsigned i = 0; i < 8; i++) CHECK(b[i] == 0xee);   // 0x656850：只清 +0x08..+0x2f
    for (unsigned i = 8; i < 0x30; i++) CHECK(b[i] == 0);
    FN(void (*)(void *, NVNdevice *), "nvnDeviceCommandBufferSetDevice")(b, &device);
    FN(void (*)(void *, const NVNmemoryPool *, int64_t, uint64_t), "nvnDeviceCommandBufferSetStorage")(b, &pool, 0x400, 0x2000);
    FN(void (*)(void *, uint64_t), "nvnDeviceCommandBufferSetCommandMemorySize")(b, 0x111);
    FN(void (*)(void *, uint64_t), "nvnDeviceCommandBufferSetComputeMemorySize")(b, 0x222);
    CHECK(rd64(b, 0) == (uint64_t)(uintptr_t)&device && rd64(b, 8) == (uint64_t)(uintptr_t)&pool && rd64(b, 0x10) == 0x400 && rd64(b, 0x18) == 0x2000);
    CHECK(rd64(b, 0x20) == 0x111 && rd64(b, 0x28) == 0x222);
    CHECK(FN(uint64_t (*)(const void *), "nvnDeviceCommandBufferGetHandle")(b) == API(nvnMemoryPoolGetBufferAddress)(&pool) + 0x400);   // 0x6568b0：池 GPU 地址 + 偏移

    phase = "设备上的纯函数";
    typedef uint64_t (*f_hsz)(const NVNdevice *, uint64_t); f_hsz hsz = FN(f_hsz, "nvnDeviceGetCommandHandleMemorySize");
    CHECK(hsz(&device, (0x1234ull << 40) | 2) == 0x48d0);   // (h >> 38) & 0x3fffffc，手算：0x1234 << 2
    CHECK(hsz(&device, (0x1234ull << 40) | 1) == 0 && hsz(&device, 0x10000) == 0);   // 低 2 位不是 2：不是设备命令句柄
    CHECK(FN(uint64_t (*)(const NVNdevice *, uint64_t, uint64_t), "nvnDeviceGetUniformBufferHandle")(&device, 0x123456780ull, 3) == 0x200012345678ull);   // 手算见 hle_nvn.c 公式
    CHECK(FN(int (*)(const NVNdevice *), "nvnDeviceGetFlags")(&device) == 0x5a);   // main() 里设备构建器 SetFlags(0x5a)

    phase = "设备消息缓冲";
    memset(b, 0xee, sizeof b); FN(void (*)(void *), "nvnDeviceMessageBufferSetDefaults")(b);
    for (unsigned i = 8; i < 0x28; i++) CHECK(b[i] == 0);
    FN(void (*)(void *, NVNdevice *), "nvnDeviceMessageBufferSetDevice")(b, &device);
    FN(void (*)(void *, const NVNmemoryPool *, int, int), "nvnDeviceMessageBufferSetStorage")(b, &pool, 0x800, 0x100);
    CHECK(rd64(b, 8) == (uint64_t)(uintptr_t)&pool && rd32(b, 0x10) == 0x800 && rd32(b, 0x14) == 0x100);
    memset(memory + 0x800, 0x77, 16);
    FN(void (*)(void *), "nvnDeviceMessageBufferReset")(b);
    CHECK(rd32(memory, 0x800) == 12 && rd32(memory, 0x804) == 0x100 && rd32(memory, 0x808) == 0 && memory[0x80c] == 0x77);   // 头 {12, 容量, 0}，只写 12 字节
    FN(void (*)(void *), "nvnDeviceMessageBufferBeginMessages")(b);
    CHECK(rd64(b, 0x18) == (uint64_t)(uintptr_t)(memory + 0x800) && rd32(b, 0x20) == 12 && rd32(b, 0x24) == 12);   // 已写到 = 0 → 终点取头第一个字
    int out = -1; CHECK(!FN(NVNboolean (*)(void *, void *, void *, uint64_t), "nvnDeviceMessageBufferGetNextMessage")(b, &out, NULL, 0));
    FN(void (*)(void *), "nvnDeviceMessageBufferEndMessages")(b); CHECK(rd64(b, 0x18) == 0 && rd64(b, 0x20) == 0);
    memset(memory + 0x800, 0x77, 16);
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd); CHECK(API(nvnCommandBufferInitialize)(&cmd, &device));
    FN(void (*)(NVNcommandBuffer *, const void *), "nvnCommandBufferResetDeviceMessageBuffer")(&cmd, b);
    CHECK(rd32(memory, 0x800) == 12 && rd32(memory, 0x804) == 0x100 && rd32(memory, 0x808) == 0);

    phase = "快速清除登记";
    typedef int (*f_ci)(NVNdevice *, const float *, NVNformat); f_ci ci = FN(f_ci, "nvnDeviceRegisterFastClearColorIndex");
    const float c0[4] = {0, 0, 0, 1}, c1[4] = {1, 0, 0, 1};
    int i0 = ci(&device, c0, NVN_FORMAT_RGBA8), i1 = ci(&device, c1, NVN_FORMAT_RGBA8);
    CHECK(i0 >= 0 && i1 >= 0 && i0 != i1 && ci(&device, c0, NVN_FORMAT_RGBA8) == i0 && ci(&device, c0, NVN_FORMAT_RGBA16F) != i0);   // 同值同格式同序号
    int last = 0; for (int k = 0; k < 20; k++) last = FN(int (*)(NVNdevice *, float), "nvnDeviceRegisterFastClearDepthIndex")(&device, (float)k / 64);
    CHECK(last == -1);   // 表 16 项：满了回 -1（同真机表满）
    CHECK(FN(NVNboolean (*)(NVNdevice *, int), "nvnDeviceRegisterFastClearStencil")(&device, 0x80) == 0);   // 表已满 → 序号 -1 → 失败

    phase = "NVX 通用地址 / 调试哈希";
    CHECK(FN(uint64_t (*)(const NVNmemoryPool *), "nvnMemoryPoolGetGenericAddressNVX")(&pool) == API(nvnMemoryPoolGetBufferAddress)(&pool));   // 驱动读池 +0x18 = 缓冲区地址
    static NVNprogram prog; CHECK(FN(const void *(*)(const NVNprogram *), "nvnProgramGetDebugDataHashesNVX")(&prog) == NULL);
}

// DLSS：构建器读回纹理号；改尺寸不超过初始化的输出分辨率才改
static void dlss(void) {
    phase = "DLSS";
    _Alignas(16) uint8_t b[0x100], n[0x220]; memset(b, 0, sizeof b);
    FN(void (*)(void *), "nvnDlssNetworkBuilderSetDefaults")(b);
    int ids[32], got[32]; for (int i = 0; i < 32; i++) ids[i] = 100 + i;
    FN(void (*)(void *, const void *, const int *), "nvnDlssNetworkBuilderSetTextureIDs")(b, NULL, ids);
    memset(got, 0, sizeof got); FN(void (*)(const void *, int *), "nvnDlssNetworkBuilderGetTextureIDs")(b, got); CHECK(!memcmp(got, ids, sizeof ids));
    FN(void (*)(void *, int, int), "nvnDlssNetworkBuilderSetOutputResolution")(b, 1920, 1080);
    CHECK(FN(NVNboolean (*)(void *, const void *), "nvnDlssNetworkInitialize")(n, b));
    typedef NVNboolean (*f_rs)(void *, int, int); f_rs rs = FN(f_rs, "nvnDlssNetworkResize");
    CHECK(!rs(n, 2560, 1080) && !rs(n, 1920, 1440));   // 超过初始化时的输出分辨率：回 0、不改
    CHECK(rd32(n, DLN_OUT_W) == 1920 && rd32(n, DLN_OUT_H) == 1080);
    CHECK(rs(n, 1280, 720) && rd32(n, DLN_OUT_W) == 1280 && rd32(n, DLN_OUT_H) == 720);
    CHECK(rs(n, 1920, 1080));   // 上限仍是初始化时的值，不随改小
}

// 录制：延后推常量录成 OP_PUSH_CONST_PTR；空操作 / 缺省值的状态命令不占命令内存
static void recording(void) {
    phase = "录制";
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd); CHECK(API(nvnCommandBufferInitialize)(&cmd, &device));
    memset(memory, 0xa5, 4096);
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, 4096); API(nvnCommandBufferBeginRecording)(&cmd);
    size_t u0 = API(nvnCommandBufferGetCommandMemoryUsed)(&cmd);
    FN(void (*)(NVNcommandBuffer *, int), "nvnCommandBufferSetGraphicsWorkloadPriority")(&cmd, 3);
    FN(void (*)(NVNcommandBuffer *, int), "nvnCommandBufferSetComputeWorkloadPriority")(&cmd, 3);
    FN(void (*)(NVNcommandBuffer *, int, float), "nvnCommandBufferSetResourceOccupancy")(&cmd, 1, 0.5f);
    FN(void (*)(NVNcommandBuffer *, uint32_t, const char *), "nvnCommandBufferInsertDebugMarkerGraphics")(&cmd, 1, "m");
    FN(void (*)(NVNcommandBuffer *, uint32_t), "nvnCommandBufferSetRepresentativeFragmentTest")(&cmd, 1);
    FN(void (*)(NVNcommandBuffer *, uint32_t), "nvnCommandBufferSetComputeEnable")(&cmd, 1);
    FN(void (*)(NVNcommandBuffer *, uint32_t), "nvnCommandBufferSetCopyEnable")(&cmd, 1);
    FN(void (*)(NVNcommandBuffer *, int, int), "nvnCommandBufferSetConservativeRasterMode")(&cmd, 0, 0);
    FN(void (*)(NVNcommandBuffer *, uint32_t), "nvnCommandBufferEnableExclusiveScissor")(&cmd, 0);
    FN(void (*)(NVNcommandBuffer *, const void *, const void *), "nvnCommandBufferBindShadingRateImage")(&cmd, NULL, NULL);
    CHECK(API(nvnCommandBufferGetCommandMemoryUsed)(&cmd) == u0);
    static uint8_t data[300];
    FN(void (*)(NVNcommandBuffer *, int, int, int, const void *), "nvnCommandBufferPushComputeConstantsDeferred")(&cmd, 9, 0x40, 300, data);   // 槽 9 → 1、300 夹到 256 - 0x40
    FN(void (*)(NVNcommandBuffer *, int, int, int, const void *), "nvnCommandBufferPushGraphicsConstantsDeferred")(&cmd, 2, 0, 3, data);      // < 4 字节：不发
    // 记录在录制自己的宿主块里（hle_nvn.c 命令缓冲影子块），句柄 = 第一条记录；上面的空操作不录，第一条就是推常量
    const uint8_t *r = (const uint8_t *)(uintptr_t)API(nvnCommandBufferEndRecording)(&cmd); CHECK(r && (r < memory || r >= memory + 4096)); op_hdr h; memcpy(&h, r, 8);
    CHECK(h.op == OP_PUSH_CONST_PTR && h.size == 8 + 16);
    p_push_const_ptr pc; memcpy(&pc, r + 8, sizeof pc);
    CHECK(pc.compute == 1 && pc.slot == 1 && pc.offset == 0x40 && pc.size == 0xc0 && pc.data == (uint64_t)(uintptr_t)data);
    memcpy(&h, r + 24, 8); CHECK(h.op != OP_PUSH_CONST_PTR);   // 第二条没录
}

// 任务 / 网格（11-05）：DrawMeshTasks(first, count) 录成图元 DM_PRIM_MESH_TASKS 的 OP_DRAW（first / count 原样）；Indirect 录 ind = 参数的 CPU 地址（GA）；
//   绑定阶段 7（网格）落宿主阶段 4、BindProgram 位 0x40 | 0x80 | 0x02 → 0x08 | 0x10 | 0x02 = 0x1a（期望按约定手写：任务 / 网格放曲面两阶段的位置）
static void mesh_recording(void) {
    phase = "网格录制";
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd); CHECK(API(nvnCommandBufferInitialize)(&cmd, &device));
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 4096, 4096); API(nvnCommandBufferBeginRecording)(&cmd);
    API(nvnCommandBufferBindProgram)(&cmd, NULL, 0xc2);
    API(nvnCommandBufferBindUniformBuffer)(&cmd, (NVNshaderStage)7, 2, API(nvnMemoryPoolGetBufferAddress)(&pool) + 0x200, 64);
    FN(void (*)(NVNcommandBuffer *, int, int), "nvnCommandBufferDrawMeshTasks")(&cmd, 5, 7);
    FN(void (*)(NVNcommandBuffer *, NVNbufferAddress), "nvnCommandBufferDrawMeshTasksIndirect")(&cmd, API(nvnMemoryPoolGetBufferAddress)(&pool) + 0x100);
    const uint8_t *r = (const uint8_t *)(uintptr_t)API(nvnCommandBufferEndRecording)(&cmd); CHECK(r); op_hdr h;
    memcpy(&h, r, 8); CHECK(h.op == OP_BIND_PROGRAM); p_bind_program_id bp; memcpy(&bp, r + 8, sizeof bp); CHECK(bp.stages == 0x1a); r += h.size;
    memcpy(&h, r, 8); CHECK(h.op == OP_BIND_UBO); p_bind_buf ub; memcpy(&ub, r + 8, sizeof ub); CHECK(ub.stage == 4 && ub.index == 2); r += h.size;
    p_draw d; memcpy(&h, r, 8); CHECK(h.op == OP_DRAW); const p_draw *dp = draw_rec(r + 8, h.size, &d);
    CHECK(dp->prim == DM_PRIM_MESH_TASKS && dp->first == 5 && dp->count == 7 && !dp->ind); r += h.size;
    memcpy(&h, r, 8); CHECK(h.op == OP_DRAW); dp = draw_rec(r + 8, h.size, &d);
    CHECK(dp->prim == DM_PRIM_MESH_TASKS && dp->ind == (uint64_t)(uintptr_t)(memory + 0x100));
}
// 未实现桩：调用回 0（报红、标直连异常），不崩
static void red_stub(void) {
    phase = "未实现桩";
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd);
    FN(void (*)(NVNcommandBuffer *, int, int, int, int, int, int), "nvnCommandBufferDrawMeshTasks3D")(&cmd, 0, 0, 0, 1, 1, 1);
    CHECK(FN(uint64_t (*)(const void *), "nvnProgramGetScratchBytesPerWarp")(&cmd) == 0);
}

// NVN2 带索引绘制的命令内存读数按入口取驱动真值（sdk 的 DrawElements* 推进 cmd[0] 的立即数，SDK 20.5 / 21.4 / 22 与 Sports Resort 一致）；间接绘制不在表内，仍按原估算
static void draw_device_bytes(void) {
    phase = "绘制设备字节";
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd); CHECK(API(nvnCommandBufferInitialize)(&cmd, &device));
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, 4096); API(nvnCommandBufferBeginRecording)(&cmd);
#define USED_BY(call, want) do { size_t u_ = API(nvnCommandBufferGetCommandMemoryUsed)(&cmd); call; CHECK(API(nvnCommandBufferGetCommandMemoryUsed)(&cmd) - u_ == (want)); } while (0)
    const NVNdrawPrimitive tri = NVN_DRAW_PRIMITIVE_TRIANGLES; const NVNindexType u16 = NVN_INDEX_TYPE_UNSIGNED_SHORT; const uint64_t ib = 0x123456780ull;
    USED_BY(API(nvnCommandBufferDrawElements)(&cmd, tri, u16, 6, ib), 24);
    USED_BY(API(nvnCommandBufferDrawElementsBaseVertex)(&cmd, tri, u16, 6, ib, 0), 48);
    USED_BY(API(nvnCommandBufferDrawElementsBaseVertex)(&cmd, tri, u16, 6, ib, 5), 72);
    USED_BY(API(nvnCommandBufferDrawElementsInstanced)(&cmd, tri, u16, 6, ib, 0, 0, 1), 44);
    USED_BY(API(nvnCommandBufferDrawElementsInstanced)(&cmd, tri, u16, 6, ib, 3, 0, 2), 48);
    USED_BY(API(nvnCommandBufferDrawElementsInstanced)(&cmd, tri, u16, 6, ib, 0, 7, 2), 48);
    USED_BY(API(nvnCommandBufferDrawElementsIndirect)(&cmd, tri, u16, ib, 0x234567890ull), 48);   // 入口的字节数不外溢到后面的记录
    NVNcommandHandle h = 0; USED_BY(h = API(nvnCommandBufferEndRecording)(&cmd), 0); CHECK(h);   // NVN2 的 END 不推进命令游标
    API(nvnCommandBufferBeginRecording)(&cmd); USED_BY(h = API(nvnCommandBufferEndRecording)(&cmd), 0); CHECK(h);   // 空录制：0 字节，句柄照给
#undef USED_BY
    API(nvnCommandBufferFinalize)(&cmd);
}

static void ounce_on(void) {   // 写一份 Switch 2 布局的 NPDM（ACID 魔数在 ACID +0x300），经原生层读一遍置平台位：nvn2_on() 起
    char path[1024]; const char *td = getenv("TMPDIR"); snprintf(path, sizeof path, "%s/t_nvn2_procs_npdm_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); CHECK(fd >= 0);
    static uint8_t npdm[0x80 + 0x400]; memcpy(npdm, "META", 4); uint32_t acid = 0x80; memcpy(npdm + 0x78, &acid, 4); memcpy(npdm + 0x80 + 0x300, "ACID", 4);
    CHECK(write(fd, npdm, sizeof npdm) == (ssize_t)sizeof npdm); close(fd);
    s2a_npdm_window_need(path); unlink(path);
    extern int nvn2_on(void); CHECK(nvn2_on());
}

int main(void) {
    char map[1024]; const char *td = getenv("TMPDIR"); snprintf(map, sizeof map, "%s/t_nvn2_procs_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(map); CHECK(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
    ounce_on();
    NVNdeviceBuilder db; memset(&db, 0, sizeof db);
    API(nvnDeviceBuilderSetDefaults)(&db); API(nvnDeviceBuilderSetFlags)(&db, 0x5a); CHECK(API(nvnDeviceInitialize)(&device, &db));
    CHECK(posix_memalign((void **)&memory, 65536, 65536) == 0);
    NVNmemoryPoolBuilder pb; memset(&pb, 0, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, 65536);
    CHECK(API(nvnMemoryPoolInitialize)(&pool, &pb));
    drv_names(); program_builder(); dirty_tile_map(); window(); multisample(); queue_builder(); device_objects(); dlss(); recording(); draw_device_bytes(); mesh_recording(); red_stub();
    unlink(map);
    printf("✓ t_nvn2_procs：NVN2 驱动按名可取的 767 个入口全部取得到，未实现桩正好是写明原因的 %d 个；程序构建器 / 脏块图 / 窗口 / 多重采样 / 队列构建器 / 设备命令与消息缓冲 / DLSS / 快速清除 / NVX 地址按驱动布局与公式；"
           "HDR 元数据栈上参数；延后推常量录成指针记录 → 通过（%u 项检查）\n", NRED, checks);
    return 0;
}
