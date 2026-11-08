// 驱动 GetProcAddress 名字全集（graphics/nvn/gfx/nvn/nvn_drv_names.txt，从 SDK 6.4 / 10.9 / 20.5 三版游戏自带 NVN 驱动抽出）按名都取得到、都有实现，
//   以及 11-03 补的 29 个 NVX / 私有入口按真机语义各测一遍。期望值全部来自驱动反汇编（地址见 hle_nvn.c 该段注释，下文「20.5 0x…」），不跑实现推期望：
//   · 名字全集：每个名字 h_nvnBootstrapLoader 非空（反证：补之前大乱斗 SPECIAL 取 nvnSetExternalDebuggerEnabledNVX 拿到 NULL，崩在 pc 0）；槽位是未实现桩 nvn_unimpl_entry 的
//     只许是已知 2 个（SetProgramSubroutines / SetProvokingVertexMode，取得到、调用报红回 0；GetSampleLocationsGrid 11-04 按 NVN2 驱动实现，t_nvn2_procs 测），新增一个就红；
//   · 开关类（SetExternalDebuggerEnabled / SetGLInterop / QueueSetTimeout / QueueSetTimeslice）：可调、回值同真机（超时回 0、时间片回 1）、记下的值读得回；
//   · 构建器预留 / 原生句柄：设备构建器 Set→Get 读回个数与指针；池构建器原生句柄与存储互斥（20.5 0x4c8c80 / 0x4c8c70）、三个预留地址读回、SetDefaults 清零；
//   · 池：带句柄建的池回那个句柄，普通池回服务层开的 nvmap 句柄（本文件顶替 S2A_NvMapFromGuest），预留过的块线性 / 特殊地址读回、没预留回 0；
//   · 同步：普通同步对象三个 syncpoint 查询都回 0（真机只认类型 5）；NvRmSync 来的回 1 对无效 syncpoint，个数不符回 0；
//   · 拷贝引擎拷贝：录成一条 OP_COPY_T2T，源区域只取 x / y / 宽 / 高、目标只取 x / y，深度 1、z 0、无视图、标志 0（20.5 0x4c31a0）；
//   · CUDA 互操作：+4 写 1（失败）；拦截一族：TryAcquire / Owned / Release 回 0、Initialize / Finalize 回 1、不写调用方的表、SetProcAddress 认得的名字回 1 并给出本层实现；
//   · 私有入口：H3ikr9ix 不替换 TexturePoolRegisterTexture；yK1NUEJH 按 4 字节为单位写进 {池, 池内偏移} + 偏移 处。
#include "nvn_protos.h"
#include "nvn_nvx.h"
#include "nvn_count.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
typedef struct { _Atomic uint64_t cnt; void *fn; } slot_t;
extern slot_t nvn_slot[NVN_NFUNC];
extern const char *nvn_names[NVN_NFUNC];
extern void nvn_unimpl_entry(void);

static const char *phase = "准备";
static unsigned checks;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "✗ t_nvn_nvx [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); CHECK(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))
#define FN(T, name) ((T)load(name))

static NVNdevice device;
static unsigned nmk;
__attribute__((visibility("default"), used)) int S2A_NvMapFromGuest(uint64_t address, uint32_t size) { (void)address; (void)size; return 41 + (int)++nmk; }

static void drv_names(void) {
    phase = "驱动名字全集";
    FILE *f = fopen("graphics/nvn/gfx/nvn/nvn_drv_names.txt", "r"); CHECK(f != NULL);
    char line[256]; unsigned n = 0, unimpl = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        void *p = h_nvnBootstrapLoader(line);
        if (!p) { fprintf(stderr, "✗ 驱动名字取不到：%s\n", line); exit(1); }
        unsigned i = 0; while (i < NVN_NFUNC && strcmp(nvn_names[i], line)) i++;
        CHECK(i < NVN_NFUNC);
        if (nvn_slot[i].fn == (void *)nvn_unimpl_entry) {   // 取得到但只有未实现桩（调用报红、回 0，不崩）：只许是下面这 2 个已知缺口，多一个就红
            static const char *const known[] = {"nvnCommandBufferSetProgramSubroutines", "nvnCommandBufferSetProvokingVertexMode"};
            int ok = 0; for (unsigned k = 0; k < 2; k++) ok |= !strcmp(known[k], line);
            if (!ok) { fprintf(stderr, "✗ 驱动名字只有未实现桩（不在已知 2 个里）：%s\n", line); exit(1); }
            unimpl++;
        }
        n++;
    }
    fclose(f);
    CHECK(n == 569);   // 三版驱动按名可达的并集（6.4 536 / 10.9 540 / 20.5 567），见清单头
    CHECK(unimpl == 2);
    printf("  驱动名字 %u 个：全部取得到非空指针；有实现 %u 个，只有未实现桩 %u 个（已知缺口）\n", n, n - unimpl, unimpl);
}

static void switches(void) {
    phase = "开关类";
    FN(void (*)(uint32_t), "nvnSetExternalDebuggerEnabledNVX")(1);
    CHECK(API(nvnDeviceIsExternalDebuggerAttached)(&device) == 0);   // 打开开关 ≠ 有调试器连上
    int iface = 0; FN(void (*)(const void *), "nvnSetGLInteropNVX")(&iface);
    union { NVNqueue q; queue_x o; } q; memset(&q, 0, sizeof q);
    CHECK(FN(int (*)(NVNqueue *, uint64_t), "nvnQueueSetTimeoutNVX")(&q.q, 5000000000ull) == 0);
    CHECK(q.o.timeout_ns == 5000000000ull);
    CHECK(FN(uint32_t (*)(NVNqueue *, uint32_t), "nvnQueueSetTimesliceNVX")(&q.q, 2000) == 1);
    CHECK(q.o.timeslice_us == 2000);
}

static void builders(void) {
    phase = "设备构建器预留区间";
    NVNdeviceBuilder db; memset(&db, 0xee, sizeof db);
    API(nvnDeviceBuilderSetDefaults)(&db);
    int (*dget)(const NVNdeviceBuilder *, const void **) = FN(int (*)(const NVNdeviceBuilder *, const void **), "nvnDeviceBuilderGetReservedAddressRangesNVX");
    const void *r = (const void *)1; CHECK(dget(&db, &r) == 0); CHECK(r == NULL);
    static const uint64_t ranges[6] = {0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x6000};
    FN(void (*)(NVNdeviceBuilder *, int, const void *), "nvnDeviceBuilderSetReservedAddressRangesNVX")(&db, 3, ranges);
    CHECK(dget(&db, &r) == 3); CHECK(r == ranges);
    CHECK(API(nvnDeviceBuilderGetFlags)(&db) == 0);   // 新字段不碰 flags

    phase = "池构建器原生句柄与预留地址";
    NVNmemoryPoolBuilder pb; memset(&pb, 0xee, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb);
    static uint8_t mem[4096];
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, sizeof mem);
    FN(void (*)(NVNmemoryPoolBuilder *, int32_t), "nvnMemoryPoolBuilderSetNativeHandleNVX")(&pb, 7);
    int32_t (*gnh)(const NVNmemoryPoolBuilder *) = FN(int32_t (*)(const NVNmemoryPoolBuilder *), "nvnMemoryPoolBuilderGetNativeHandleNVX");
    CHECK(gnh(&pb) == 7); CHECK(API(nvnMemoryPoolBuilderGetMemory)(&pb) == NULL); CHECK(API(nvnMemoryPoolBuilderGetSize)(&pb) == 0);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, sizeof mem);
    CHECK(gnh(&pb) == 0); CHECK(API(nvnMemoryPoolBuilderGetMemory)(&pb) == mem);
    void (*gres)(const NVNmemoryPoolBuilder *, uint64_t *, uint64_t *, uint64_t *) =
        FN(void (*)(const NVNmemoryPoolBuilder *, uint64_t *, uint64_t *, uint64_t *), "nvnMemoryPoolBuilderGetReservedAddressesNVX");
    uint64_t a = 9, b = 9, c = 9; gres(&pb, &a, &b, &c); CHECK(a == 0 && b == 0 && c == 0);
    FN(void (*)(NVNmemoryPoolBuilder *, uint64_t), "nvnMemoryPoolBuilderSetPitchAddressNVX")(&pb, 0x500000000ull);
    FN(void (*)(NVNmemoryPoolBuilder *, uint64_t), "nvnMemoryPoolBuilderSetBlockLinearAddressNVX")(&pb, 0x600000000ull);
    FN(void (*)(NVNmemoryPoolBuilder *, uint64_t), "nvnMemoryPoolBuilderSetSpecialAddressNVX")(&pb, 0x700000000ull);
    gres(&pb, &a, &b, &c); CHECK(a == 0x500000000ull && b == 0x600000000ull && c == 0x700000000ull);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb);
    gres(&pb, &a, &b, &c); CHECK(a == 0 && b == 0 && c == 0); CHECK(gnh(&pb) == 0);
}

static void pools(void) {
    phase = "池";
    int32_t (*gnh)(const NVNmemoryPool *) = FN(int32_t (*)(const NVNmemoryPool *), "nvnMemoryPoolGetNativeHandleNVX");
    uint64_t (*gbl)(const NVNmemoryPool *) = FN(uint64_t (*)(const NVNmemoryPool *), "nvnMemoryPoolGetBlockLinearAddressNVX");
    uint64_t (*gsp)(const NVNmemoryPool *) = FN(uint64_t (*)(const NVNmemoryPool *), "nvnMemoryPoolGetSpecialAddressNVX");
    uint8_t *mem; CHECK(posix_memalign((void **)&mem, 65536, 65536) == 0); memset(mem, 0, 65536);
    NVNmemoryPoolBuilder pb; memset(&pb, 0, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, 65536);
    NVNmemoryPool p1; memset(&p1, 0, sizeof p1); CHECK(API(nvnMemoryPoolInitialize)(&p1, &pb));
    CHECK(gnh(&p1) == 42); CHECK(gnh(&p1) == 42); CHECK(nmk == 1);   // 普通池：服务层开一次，之后读回同一个
    CHECK(gbl(&p1) == 0); CHECK(gsp(&p1) == 0);                       // 没预留：本层没有这两种映射
    FN(void (*)(NVNmemoryPoolBuilder *, uint64_t), "nvnMemoryPoolBuilderSetBlockLinearAddressNVX")(&pb, 0x600000000ull);
    FN(void (*)(NVNmemoryPoolBuilder *, uint64_t), "nvnMemoryPoolBuilderSetSpecialAddressNVX")(&pb, 0x700000000ull);
    NVNmemoryPool p2; memset(&p2, 0, sizeof p2); CHECK(API(nvnMemoryPoolInitialize)(&p2, &pb));
    CHECK(gbl(&p2) == 0x600000000ull); CHECK(gsp(&p2) == 0x700000000ull);
    API(nvnMemoryPoolFinalize)(&p2);

    phase = "yK1NUEJH 写池";
    struct { const NVNmemoryPool *pool; int64_t off; } loc = {&p1, 64};
    const uint8_t src[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    FN(void (*)(const void *, ptrdiff_t, const void *, size_t), "yK1NUEJH")(&loc, 8, src, sizeof src);
    CHECK(memcmp(mem + 72, src, 8) == 0); CHECK(mem[80] == 0 && mem[81] == 0);   // 10 字节只写 2 个字（4 字节为单位，尾 2 字节不写）
    CHECK(mem[71] == 0);
    API(nvnMemoryPoolFinalize)(&p1);

    phase = "带原生句柄建的池";
    NVNmemoryPoolBuilder hb; memset(&hb, 0, sizeof hb);
    API(nvnMemoryPoolBuilderSetDefaults)(&hb); API(nvnMemoryPoolBuilderSetDevice)(&hb, &device);
    FN(void (*)(NVNmemoryPoolBuilder *, int32_t), "nvnMemoryPoolBuilderSetNativeHandleNVX")(&hb, 77);
    NVNmemoryPool p3; memset(&p3, 0, sizeof p3); API(nvnMemoryPoolInitialize)(&p3, &hb);
    CHECK(gnh(&p3) == 77); CHECK(nmk == 1);   // 回构建器给的，不再开新句柄
}

static void syncs(void) {
    phase = "同步 syncpoint";
    NVNboolean (*cnt)(const NVNsync *, int *) = FN(NVNboolean (*)(const NVNsync *, int *), "nvnSyncGetSyncpointsCountNVX");
    NVNboolean (*get)(const NVNsync *, int, uint32_t *) = FN(NVNboolean (*)(const NVNsync *, int, uint32_t *), "nvnSyncGetSyncpointsNVX");
    NVNboolean (*set)(NVNsync *, int, const uint32_t *) = FN(NVNboolean (*)(NVNsync *, int, const uint32_t *), "nvnSyncSetSyncpointsNVX");
    NVNsync a; memset(&a, 0, sizeof a); CHECK(API(nvnSyncInitialize)(&a, &device));
    int n = -5; uint32_t pr[4] = {7, 7, 7, 7};
    CHECK(!cnt(&a, &n)); CHECK(n == -5);                 // 真机：类型不是 5 不写出参
    CHECK(!get(&a, 1, pr)); CHECK(pr[0] == 7);
    CHECK(!set(&a, 1, pr));
    NVNsync b; memset(&b, 0, sizeof b); const uint32_t rm[2] = {12, 34};
    CHECK(FN(NVNboolean (*)(NVNsync *, NVNdevice *, const void *), "nvnSyncInitializeFromNvRmSyncNVX")(&b, &device, rm));
    CHECK(!cnt(&b, NULL));                               // 出参为空回 0
    CHECK(cnt(&b, &n)); CHECK(n == 1);
    CHECK(!get(&b, 2, pr)); CHECK(pr[0] == 7);           // 个数不等回 0、不写
    CHECK(get(&b, 1, pr)); CHECK(pr[0] == 0xFFFFFFFFu && pr[1] == 0 && pr[2] == 7);
    CHECK(!get(&b, 1, NULL));
    const uint32_t nw[2] = {5, 99}; CHECK(set(&b, 1, nw)); CHECK(!set(&b, 2, nw));
    CHECK(API(nvnSyncWait)(&b, 0) != NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED);   // 仍是已到达
}

static void copy_engine(void) {
    phase = "拷贝引擎拷贝";
    uint8_t *mem; CHECK(posix_memalign((void **)&mem, 65536, 1 << 20) == 0); memset(mem, 0, 1 << 20);
    NVNmemoryPoolBuilder pb; memset(&pb, 0, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, 1 << 20);
    NVNmemoryPool pool; memset(&pool, 0, sizeof pool); CHECK(API(nvnMemoryPoolInitialize)(&pool, &pb));
    NVNtexture tex[2];
    for (int i = 0; i < 2; i++) {
        NVNtextureBuilder tb; memset(&tb, 0, sizeof tb);
        API(nvnTextureBuilderSetDefaults)(&tb); API(nvnTextureBuilderSetDevice)(&tb, &device);
        API(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&tb, 64, 64);
        API(nvnTextureBuilderSetLevels)(&tb, 1); API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
        API(nvnTextureBuilderSetStorage)(&tb, &pool, 65536 + i * 65536);
        memset(&tex[i], 0, sizeof tex[i]); CHECK(API(nvnTextureInitialize)(&tex[i], &tb));
    }
    NVNcommandBuffer cmd; memset(&cmd, 0, sizeof cmd); CHECK(API(nvnCommandBufferInitialize)(&cmd, &device));
    memset(mem, 0xa5, 32768);
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, 32768);
    API(nvnCommandBufferBeginRecording)(&cmd);
    const NVNcopyRegion sr = {3, 4, 9, 16, 8, 7}, dr = {5, 6, 2, 99, 99, 3};   // 源 z / 深度、目标 z / 宽高深都不该被用
    FN(void (*)(NVNcommandBuffer *, const NVNtexture *, const NVNcopyRegion *, const NVNtexture *, const NVNcopyRegion *),
       "nvnCommandBufferCopyTextureToTextureWithCopyEngineNVX")(&cmd, &tex[0], &sr, &tex[1], &dr);
    // 记录在录制自己的宿主块里（hle_nvn.c 命令缓冲影子块），句柄 = 第一条记录，游戏命令内存不写
    const uint8_t *rec = (const uint8_t *)(uintptr_t)API(nvnCommandBufferEndRecording)(&cmd); CHECK(rec && (rec < mem || rec >= mem + 32768));
    for (int i = 0; i < 32768; i++) CHECK(mem[i] == 0xa5);
    op_hdr h; memcpy(&h, rec, sizeof h); CHECK(h.op == OP_COPY_T2T);
    p_copy_t2t r; memcpy(&r, rec + 8, sizeof r);
    CHECK(r.sr.xoffset == 3 && r.sr.yoffset == 4 && r.sr.zoffset == 0 && r.sr.width == 16 && r.sr.height == 8 && r.sr.depth == 1);
    CHECK(r.dr.xoffset == 5 && r.dr.yoffset == 6 && r.dr.zoffset == 0 && r.dr.width == 16 && r.dr.height == 8 && r.dr.depth == 1);
    CHECK(r.has_sv == 0 && r.has_dv == 0 && r.flags == 0);
    op_hdr e; memcpy(&e, rec + h.size, sizeof e); CHECK(e.op == OP_END);
}

static void misc(void) {
    phase = "CUDA 互操作";
    uint32_t args[4] = {1, 0, 3, 0};
    FN(void (*)(void *), "nvnCUDAInteropFunction")(args);
    CHECK(args[1] == 1 && args[0] == 1 && args[2] == 3);

    phase = "拦截一族";
    uint8_t table[0x10b0]; memset(table, 0xab, sizeof table);
    CHECK(FN(NVNboolean (*)(void *), "nvnInterceptionInitializeNVX")(table) == 1);
    for (size_t i = 0; i < sizeof table; i++) CHECK(table[i] == 0xab);   // 表不写
    NVNboolean (*setp)(void *, const char *, void *, void **) = FN(NVNboolean (*)(void *, const char *, void *, void **), "nvnInterceptionSetProcAddressNVX");
    void *orig = NULL;
    CHECK(setp(table, "nvnDeviceInitialize", (void *)misc, &orig) == 1); CHECK(orig == h_nvnBootstrapLoader("nvnDeviceInitialize"));
    CHECK(h_nvnBootstrapLoader("nvnDeviceInitialize") == orig);           // 分派没被换
    orig = (void *)1;
    CHECK(setp(table, "DeviceInitialize", (void *)misc, &orig) == 0);     // 不以 nvn 开头
    CHECK(setp(table, "nvnNoSuchFunction", (void *)misc, &orig) == 0); CHECK(orig == (void *)1);
    void *old = (void *)1; NVNboolean (*setcb)(void *, void *, void **) = FN(NVNboolean (*)(void *, void *, void **), "nvnInterceptionSetDispatchResetCallbackNVX");
    CHECK(setcb(table, (void *)switches, &old) == 1); CHECK(old == NULL);
    CHECK(setcb(table, (void *)pools, &old) == 1); CHECK(old == (void *)switches);
    CHECK(FN(NVNboolean (*)(void *), "nvnInterceptionTryAcquireNVX")(table) == 0);
    CHECK(FN(NVNboolean (*)(const void *), "nvnInterceptionOwnedNVX")(table) == 0);
    CHECK(FN(NVNboolean (*)(void *), "nvnInterceptionReleaseNVX")(table) == 0);
    CHECK(FN(NVNboolean (*)(void), "nvnInterceptionFinalizeNVX")() == 1);

    phase = "H3ikr9ix";
    void *reg = h_nvnBootstrapLoader("nvnTexturePoolRegisterTexture");
    FN(void (*)(void *), "H3ikr9ix")((void *)misc);
    CHECK(h_nvnBootstrapLoader("nvnTexturePoolRegisterTexture") == reg);
}

int main(void) {
    drv_names();
    switches();
    builders();
    pools();
    syncs();
    copy_engine();
    misc();
    printf("✓ t_nvn_nvx：驱动名字全集取得到且有实现、29 个 NVX / 私有入口按真机语义 → 通过（%u 项检查）\n", checks);
    return 0;
}
