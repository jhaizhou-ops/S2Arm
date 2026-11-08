// 存储前瞻不装冷键（审计 #1534 P1-111）：DM_NVN_TBDR=1 时提交开头的存储前瞻（nvn_be_sub_index → sdx_walk）只用已经装好的程序，
//   不为还没装的程序装库 / 现编（原先 prog_get：冷键在第一段交给 GPU 之前同步翻译完）。没装好的绘制走已有的保守分支（绑定的槽记成被读）。
// 生产引导 → 真程序对象（ProgramSetShaders，键不在着色器表里 = 冷键）→ 录 BindProgram + DrawArrays → 直接跑存储前瞻（不回放：本测只看前瞻）。
// 期望按语义手写：前瞻之后这支程序的序号在已解析表里仍没有（serial_get 为空）、索引仍有效（g_sdx_ok = 1）、操作数 = BindProgram / Draw / END 3 条。
// 反证：把 sdx_walk 的 prog_peek 换回 prog_get，前瞻当场解析这支程序（serial_put），serial_get 非空，红
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../gfx/nvn/nvn_mtl.m"

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static uint8_t *memory;
static unsigned checks;
enum { POOL_SIZE = 4 << 20, CODE_OFF = 0x7000, CODE_N = 0x40 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))

int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "1", 1);   // 存储前瞻只在 TBDR 开着时走（tbdr_on 第一次读）
    char map[] = "/tmp/t_nvn_sdx_cold.XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
    setenv("DM_NVN_SHMAP", map, 1);   // 空着色器表：本测的两个键都不在表里（冷键）
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(posix_memalign((void **)&memory, 65536, POOL_SIZE) == 0); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
    // 两个阶段的程序：控制段 0x880 字节（+0x704 = 代码长度），代码在池里；内容是本测自造的，键不在任何着色器表里 = 冷键
    for (int i = 0; i < 2 * CODE_N; i++) memory[CODE_OFF + i] = (uint8_t)(i * 7 + 1);
    static uint8_t ctl[2][0x880]; NVNshaderData sd[2];
    for (int i = 0; i < 2; i++) { uint32_t n = CODE_N; memcpy(ctl[i] + 0x704, &n, 4); ctl[i][0x100] = (uint8_t)(0xA0 + i);
        sd[i] = (NVNshaderData){API(nvnMemoryPoolGetBufferAddress)(&pool) + CODE_OFF + (uint64_t)i * CODE_N, ctl[i]}; }
    static NVNprogram prog; REQUIRE(API(nvnProgramInitialize)(&prog, &device)); REQUIRE(API(nvnProgramSetShaders)(&prog, 2, sd));
    const uint64_t serial = ((const prog_t *)&prog)->serial; REQUIRE(serial != 0);
    REQUIRE(serial_get(serial) == nil);   // 还没有谁解析过它
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, 65536); API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferBindProgram)(&commands, &prog, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferDrawArrays)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    uint64_t hh = (uint64_t)h; nvn_be_sub_index(&hh, 1);
    REQUIRE(g_sdx_ok == 1);       // TBDR 开着、索引有效
    REQUIRE(g_sdx_nop == 3);      // BindProgram / DrawArrays / END
    int resolved = serial_get(serial) != nil;
    printf("%s t_nvn_sdx_cold：存储前瞻遇到冷键程序 期望 不解析（已解析表里没有序号 %llu）→ %s（%u 项检查）\n", resolved ? "✗" : "✓",
           (unsigned long long)serial, resolved ? "前瞻当场解析了它（prog_get：冷键在第一段提交前现编）" : "没有解析", checks + 1);
    unlink(map);
    return resolved;
} }
