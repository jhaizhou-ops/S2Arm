// NVN 未实现函数批量补齐（10-25，#270）：走生产 bootstrap 拿真函数指针，只测 CPU 侧语义（不录命令、不起 GPU 回放）。期望值都按 NVN 接口语义手写：
//   · 设备：整数 / 无符号快速清除色登记回成功；没有外部调试器；调试域号非 0 且两次不同；
//   · 采样器：整数 / 无符号边框色读回（#355 的存法按 float 存，取 float 能精确表示的值；整数版含负数）；调试 ID 稳定、两个对象不同；
//   · 命令缓冲：GetControlMemorySize / Free = 最近一次 AddControlMemory 的大小（主机不用控制内存）；
//   · 缓冲：调试 ID 非 0、两个对象不同、同一对象多次读一致。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static int bad;

static void *api(const char *n) {
    void *p = h_nvnBootstrapLoader(n);
    if (!p) { fprintf(stderr, "找不到公开 API：%s\n", n); bad++; }
    return p;
}
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
#define API(name) NVNT_##name name = (NVNT_##name)api(#name)

int main(void) {
    API(nvnDeviceRegisterFastClearColori); API(nvnDeviceRegisterFastClearColorui); API(nvnDeviceIsExternalDebuggerAttached); API(nvnDeviceGenerateDebugDomainId);
    API(nvnSamplerBuilderSetDefaults); API(nvnSamplerBuilderSetBorderColori); API(nvnSamplerBuilderSetBorderColorui);
    API(nvnSamplerInitialize); API(nvnSamplerGetBorderColori); API(nvnSamplerGetBorderColorui); API(nvnSamplerCompare); API(nvnSamplerGetDebugID);
    API(nvnCommandBufferInitialize); API(nvnCommandBufferAddControlMemory); API(nvnCommandBufferGetControlMemorySize); API(nvnCommandBufferGetControlMemoryFree);
    API(nvnCommandBufferGetControlMemoryUsed);
    API(nvnDeviceBuilderSetDefaults); API(nvnDeviceInitialize);
    API(nvnBlendStateSetDefaults); API(nvnBlendStateGetAdvancedMode); API(nvnBlendStateGetAdvancedOverlap); API(nvnBlendStateGetAdvancedPremultipliedSrc); API(nvnBlendStateGetAdvancedNormalizedDst);
    API(nvnMemoryPoolBuilderSetDefaults); API(nvnMemoryPoolBuilderSetDevice); API(nvnMemoryPoolBuilderSetStorage); API(nvnMemoryPoolBuilderSetFlags); API(nvnMemoryPoolInitialize);
    API(nvnBufferBuilderSetDefaults); API(nvnBufferBuilderSetDevice); API(nvnBufferBuilderSetStorage); API(nvnBufferInitialize); API(nvnBufferGetDebugID);
    if (bad) return 1;

    // ⓪ 混合状态缺省（#344）：按 SDK 机器码（SetDefaults 写 0x0102_0102_110c_0000）——premul TRUE、normdst TRUE、overlap UNCORRELATED、mode NONE
    NVNblendState bs; memset(&bs, 0xff, sizeof bs); nvnBlendStateSetDefaults(&bs);
    CHECK(nvnBlendStateGetAdvancedMode(&bs) == NVN_BLEND_ADVANCED_MODE_NONE && nvnBlendStateGetAdvancedOverlap(&bs) == NVN_BLEND_ADVANCED_OVERLAP_UNCORRELATED &&
          nvnBlendStateGetAdvancedPremultipliedSrc(&bs) == 1 && nvnBlendStateGetAdvancedNormalizedDst(&bs) == 1,
          "BlendState 缺省应为 mode NONE / overlap UNCORRELATED / premul 1 / normdst 1（实得 %d / %d / %d / %d）", (int)nvnBlendStateGetAdvancedMode(&bs),
          (int)nvnBlendStateGetAdvancedOverlap(&bs), (int)nvnBlendStateGetAdvancedPremultipliedSrc(&bs), (int)nvnBlendStateGetAdvancedNormalizedDst(&bs));

    // ① 设备
    NVNdevice dev; memset(&dev, 0, sizeof dev);
    const int ci[4] = {-1, 2, 3, 4}; const uint32_t cu[4] = {10, 20, 30, 40};
    CHECK(nvnDeviceRegisterFastClearColori(&dev, ci, NVN_FORMAT_RGBA32I), "RegisterFastClearColori 应回成功");
    CHECK(nvnDeviceRegisterFastClearColorui(&dev, cu, NVN_FORMAT_RGBA32UI), "RegisterFastClearColorui 应回成功");
    CHECK(!nvnDeviceIsExternalDebuggerAttached(&dev), "IsExternalDebuggerAttached 应为假");
    NVNdebugDomainId d1 = nvnDeviceGenerateDebugDomainId(&dev, "a"), d2 = nvnDeviceGenerateDebugDomainId(&dev, "b");
    CHECK(d1 != 0 && d2 != 0 && d1 != d2, "调试域号应非 0 且不同（%d / %d）", d1, d2);

    // ② 采样器：整数 / 无符号边框色原样读回
    NVNsamplerBuilder sb; NVNsampler s1, s2; int gi[4]; uint32_t gu[4];
    nvnSamplerBuilderSetDefaults(&sb); nvnSamplerBuilderSetBorderColori(&sb, ci);
    CHECK(nvnSamplerInitialize(&s1, &sb), "SamplerInitialize 返回假");
    nvnSamplerGetBorderColori(&s1, gi);
    CHECK(!memcmp(gi, ci, sizeof gi), "GetBorderColori 读回 %d,%d,%d,%d（应 -1,2,3,4）", gi[0], gi[1], gi[2], gi[3]);
    nvnSamplerBuilderSetBorderColorui(&sb, cu);
    CHECK(nvnSamplerInitialize(&s2, &sb), "SamplerInitialize 返回假");
    nvnSamplerGetBorderColorui(&s2, gu);
    CHECK(!memcmp(gu, cu, sizeof gu), "GetBorderColorui 读回 %u,%u,%u,%u（应 10,20,30,40）", gu[0], gu[1], gu[2], gu[3]);
    CHECK(nvnSamplerCompare(&s2, &s2), "同一采样器 Compare 应为相同");
    CHECK(nvnSamplerGetDebugID(&s1) != 0 && nvnSamplerGetDebugID(&s1) == nvnSamplerGetDebugID(&s1) && nvnSamplerGetDebugID(&s1) != nvnSamplerGetDebugID(&s2),
          "采样器调试 ID 应非 0、稳定、两对象不同");

    // ③ 命令缓冲控制内存
    NVNcommandBuffer cb; static uint8_t ctl[0x1800];
    CHECK(nvnCommandBufferInitialize(&cb, &dev), "CommandBufferInitialize 返回假");
    CHECK(nvnCommandBufferGetControlMemorySize(&cb) == 0 && nvnCommandBufferGetControlMemoryFree(&cb) == 0, "没给控制内存时 Size / Free 应为 0");
    nvnCommandBufferAddControlMemory(&cb, ctl, sizeof ctl);
    CHECK(nvnCommandBufferGetControlMemorySize(&cb) == sizeof ctl, "GetControlMemorySize=%zu（应 %zu）", nvnCommandBufferGetControlMemorySize(&cb), sizeof ctl);
    CHECK(nvnCommandBufferGetControlMemoryFree(&cb) == sizeof ctl - nvnCommandBufferGetControlMemoryUsed(&cb), "Free 应 = Size − Used");

    // ④ 缓冲调试 ID（要一个真内存池）
    NVNdeviceBuilder db; NVNdevice rdev; nvnDeviceBuilderSetDefaults(&db);
    if (nvnDeviceInitialize(&rdev, &db)) {
        void *storage = NULL; CHECK(posix_memalign(&storage, 65536, 65536) == 0, "posix_memalign");
        NVNmemoryPoolBuilder pb; NVNmemoryPool pool; nvnMemoryPoolBuilderSetDefaults(&pb); nvnMemoryPoolBuilderSetDevice(&pb, &rdev);
        nvnMemoryPoolBuilderSetStorage(&pb, storage, 65536); nvnMemoryPoolBuilderSetFlags(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        CHECK(nvnMemoryPoolInitialize(&pool, &pb), "MemoryPoolInitialize 返回假");
        NVNbufferBuilder bb; NVNbuffer b1, b2; nvnBufferBuilderSetDefaults(&bb); nvnBufferBuilderSetDevice(&bb, &rdev);
        nvnBufferBuilderSetStorage(&bb, &pool, 0, 4096); CHECK(nvnBufferInitialize(&b1, &bb), "BufferInitialize 返回假");
        nvnBufferBuilderSetStorage(&bb, &pool, 4096, 4096); CHECK(nvnBufferInitialize(&b2, &bb), "BufferInitialize 返回假");
        uint64_t i1 = nvnBufferGetDebugID(&b1), i2 = nvnBufferGetDebugID(&b2);
        CHECK(i1 && i2 && i1 != i2 && i1 == nvnBufferGetDebugID(&b1), "缓冲调试 ID 应非 0、两对象不同、多次读一致（%llu / %llu）", (unsigned long long)i1, (unsigned long long)i2);
    } else CHECK(0, "DeviceInitialize 返回假");

    printf("%s t_nvn_fill：混合状态缺省 / 设备 / 采样器边框色与调试 ID / 命令缓冲控制内存 / 缓冲调试 ID → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
