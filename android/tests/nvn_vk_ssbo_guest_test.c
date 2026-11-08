// 可写 graphics storage buffer（可写 SSBO 的“帧内影子 + 退休回写”）、零附件 render pass、图形驱动
// 常量段 c0、压缩纹理视图格式判定的宿主回归（L 级纯逻辑 + 真 Vulkan 语义；lavapipe 与真机同一份
// 用例源码）。
//
// 被测生产逻辑与接缝：
//   · nvn_vk_mrt.h 的 nvn_vk_driver_c0_base / nvn_vk_driver_c0_fill_graphics / nvn_vk_bcrt_view_format：
//     本文件直接 #include 头并链 nvn_vk_mrt.c（真生产实现，不复制算法）；D 段就是它们的逐项断言。
//   · first_draw.c 的可写 SSBO 帧内影子 / 退休回写（fd_ssbo_wb_find / fd_ssbo_wb_add /
//     fd_ssbo_wb_writeback）与零附件分支是 nvn_vk_first_draw.c 里的 static 实现。按任务约束本用例
//     **不链接 first_draw.c**：A/B 段在测试内按生产契约建立等价的“影子账本”参考模型（含反例策略），
//     并在真 Vulkan 上验证该契约赖以成立的驱动语义：
//       A. 同一 guest 区间本帧第二次绑定必须复用同一 VkBuffer/偏移（后一笔看到前一笔的 GPU 写）；
//          不同区间重叠必须准确拒绝（真 Vulkan 反例：两套重叠影子回写会静默丢一笔 GPU 写）；
//          地址未按 minStorageBufferOffsetAlignment 对齐必须拒绝。
//       B. 退休回写：host-visible coherent 影子由 GPU 写、fence 信号后 host memcpy 读回，内容与 GPU
//          写一致（这是 Vulkan fence 的 host 可见性语义，不是“CPU 直接映射 GPU 写”的借用语义）。
//       C. 零附件 render pass：VkRenderPass/VkFramebuffer attachmentCount=0、renderArea 覆盖视口时
//          光栅化照常执行，片元着色器能写 SSBO（fence 后读回写缓冲证明 GPU 真的执行了 draw）。
//     .sh 另外做“生产接缝存在性”检查，防止这组语义在 first_draw.c 里被删掉/改回旧实现（旧实现直接
//     报红 “writable graphics storage buffer is not implemented”、且 rt_count==0 直接失败）。
//
// 反例先行（本文件里每段先给“错误实现/错误策略”的断言，再给正确实现的断言）：
//   · 每次绑定都新建影子 → 后一笔看不到前一笔的 GPU 写（真 Vulkan 用例里用两块影子实测）；
//   · 只按 guest 起点匹配、忽略 size/重叠 → 同一存储出现两套影子，GPU 写互相覆盖；
//   · 可写 SSBO 地址不按 minStorageBufferOffsetAlignment 对齐仍然绑定 → 绑定偏移非 0 语义含糊，
//     生产要求准确报红而不是错误对齐；
//   · renderArea 小于视口 → 视口外没有片元（生产必须 renderArea=viewport）；
//   · 零附件时直接失败（旧实现）→ 只写 SSBO 的“编码”pass 无法执行。
//   D 段的反例由 .sh 的变异构建证明：把 c0 表基址改错、或跳过「块字节数==视图每像素字节数」校验，本用例必红。
//
// 打桩边界（只证这些）：不建 session、不链帧队列/纹理缓存；lavapipe 上用 vkCmdFillBuffer /
// vkCmdCopyBuffer 代表“GPU 写”路径（task 允许，且与 shader 写同属设备写、fence 可见性语义相同）。
// 不证明：Adreno 上的时序与驱动行为、ASTC/其它格式、多帧退休顺序、第一笔 draw 的完整管线。
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvn/nvn_vk_mrt.h"
#include "vk_device.h"

// vk_device.c 在 Android 上引用 bionic/liblog；宿主回归给这两个符号打桩。
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio;
    (void)tag;
    (void)fmt;
    return 0;
}
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = 0;
    return 0;
}

static struct s2a_vk_device D;
static int fails;
static int checks;

// ---------- 断言：每条失败都打 “✗ <定位>：期望 …，真结果 …” ----------

static void failf(const char *label, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("✗ %s：", label);
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
    fails++;
}

static void ck_true(const char *label, int ok, const char *expect) {
    checks++;
    if (!ok) failf(label, "期望 %s，真结果 不成立", expect);
}

static void ck_u32(const char *label, uint32_t got, uint32_t want) {
    checks++;
    if (got != want) failf(label, "期望 %u，真结果 %u", (unsigned)want, (unsigned)got);
}

static void ck_i32(const char *label, int32_t got, int32_t want) {
    checks++;
    if (got != want) failf(label, "期望 %d，真结果 %d", (int)want, (int)got);
}

static void ck_u64(const char *label, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) failf(label, "期望 %llu，真结果 %llu",
                           (unsigned long long)want, (unsigned long long)got);
}

static void ck_bytes(const char *label, const uint8_t *got, const uint8_t *want, size_t n) {
    size_t first = 0, diffs = 0, i;
    checks++;
    if (memcmp(got, want, n) == 0) return;
    for (i = 0; i < n; i++) {
        if (got[i] != want[i]) {
            if (!diffs) first = i;
            diffs++;
        }
    }
    failf(label, "期望 %zu 字节逐字节一致，真结果 首差 @%zu 期望=0x%02x 真结果=0x%02x，共 %zu 字节不符",
          n, first, (unsigned)want[first], (unsigned)got[first], diffs);
}

static void ck_why(const char *label, const char *why, const char *keyword) {
    checks++;
    if (!why[0]) {
        failf(label, "期望 why 写明拒绝原因（含 \"%s\"），真结果 空串", keyword);
        return;
    }
    if (!strstr(why, keyword)) failf(label, "期望 why 含 \"%s\"，真结果 \"%s\"", keyword, why);
}

static void group(const char *name) {
    printf("… %s\n", name);
    fflush(stdout);
}

// ============================================================================================
// A. 帧内影子账本：与 first_draw.c 的 fd_ssbo_wb_find / fd_ssbo_wb_add / fd_ssbo_wb_writeback
//    同口径的参考模型（生产实现是 static，按任务约束不链接 first_draw.c）。
// ============================================================================================

#define REF_SHADOW_MAX 16
struct ref_shadow {
    VkBuffer buf;
    void *map;
    uint64_t guest;
    uint32_t off, size;
    int writable;
};
struct ref_ledger {
    struct ref_shadow e[REF_SHADOW_MAX];
    int n;
};

// 返回值：>=0 命中影子下标；REF_FIND_OVERLAP = 不同区间重叠（生产要求准确拒绝）；
// REF_FIND_NONE = 没有影子（可以新建）。
enum { REF_FIND_NONE = -1, REF_FIND_OVERLAP = -2 };

// 同口径复制自 first_draw.c：同一 guest 区间“精确匹配（guest+size）”才复用；与已有影子部分重叠是
// 同一存储的两套影子（GPU 写会互相覆盖），准确报红而不是猜一个。
static int ref_find(const struct ref_ledger *l, uint64_t guest, uint32_t size) {
    int i;
    for (i = 0; i < l->n; i++) {
        const struct ref_shadow *w = &l->e[i];
        if (w->guest == guest && w->size == size) return i;
        if (guest < w->guest + w->size && w->guest < guest + size) return REF_FIND_OVERLAP;
    }
    return REF_FIND_NONE;
}

static int ref_add(struct ref_ledger *l, VkBuffer buf, void *map, uint64_t guest, uint32_t off,
                   uint32_t size, int writable) {
    struct ref_shadow *w;
    if (l->n >= REF_SHADOW_MAX) return -1;
    w = &l->e[l->n++];
    w->buf = buf;
    w->map = map;
    w->guest = guest;
    w->off = off;
    w->size = size;
    w->writable = writable ? 1 : 0;
    return 0;
}

// 退休回写：host-visible coherent 影子在 fence 信号后对 host 可见，按字节拷回 guest。
// 只回写 writable 且 guest/map/size 齐全的条目（生产同样跳过只读影子）。
static void ref_writeback(struct ref_ledger *l) {
    int i;
    for (i = 0; i < l->n; i++) {
        const struct ref_shadow *w = &l->e[i];
        if (w->writable && w->guest && w->map && w->size)
            memcpy((void *)(uintptr_t)w->guest, w->map, (size_t)w->size);
    }
    l->n = 0;
}

// 反例策略（错误实现）：每次绑定都新建影子，永远不复用。
static int wrong_find_always_new(const struct ref_ledger *l, uint64_t guest, uint32_t size) {
    (void)l;
    (void)guest;
    (void)size;
    return REF_FIND_NONE;
}
// 反例策略（错误实现）：只按 guest 起点匹配、忽略 size（把不同长度的区间当同一个影子）。
static int wrong_find_ignore_size(const struct ref_ledger *l, uint64_t guest, uint32_t size) {
    int i;
    (void)size;
    for (i = 0; i < l->n; i++)
        if (l->e[i].guest == guest) return i;
    return REF_FIND_NONE;
}
// 反例策略（错误实现）：重叠不拒绝，当成“没命中”而去新建第二套影子。
static int wrong_find_overlap_as_new(const struct ref_ledger *l, uint64_t guest, uint32_t size) {
    int i;
    for (i = 0; i < l->n; i++) {
        const struct ref_shadow *w = &l->e[i];
        if (w->guest == guest && w->size == size) return i;
        if (guest < w->guest + w->size && w->guest < guest + size) return REF_FIND_NONE;
    }
    return REF_FIND_NONE;
}

// 可写 SSBO 地址对齐规则（与 first_draw.c 内联规则同口径）：空区间拒绝；设备对齐必须是 2 的幂；
// 可写影子绑定偏移必须为 0（即 guest 地址按 minStorageBufferOffsetAlignment 对齐），否则拒绝。
static int ref_writable_reject(uint64_t addr, uint32_t size, uint64_t align) {
    if (!addr || !size) return 1;
    if (!align || (align & (align - 1))) return 1;
    return (addr & (align - 1)) != 0;
}

// 零附件 renderArea 规则（与 first_draw.c 零附件分支同口径）：取视口四舍五入，没有视口回退 1，
// 再夹到设备 framebuffer 上限（光栅化只在 renderArea 内产生片元）。
static uint32_t ref_render_area(uint32_t vp_seen, float vp, uint32_t limit) {
    uint32_t w = (vp_seen && vp > 0.0f) ? (uint32_t)(vp + 0.5f) : 1u;
    if (limit && w > limit) w = limit;
    return w ? w : 1u;
}

static uint8_t g_guest_ram[4096];
static uint8_t g_shadow_maps[REF_SHADOW_MAX][64];

static void case_a_shadow_ledger(void) {
    struct ref_ledger L;
    uint64_t base = (uint64_t)(uintptr_t)g_guest_ram;
    VkBuffer b0 = (VkBuffer)(uintptr_t)0x1000;
    int idx, i;

    group("[A/约定] 帧内影子账本：复用 / 重叠拒绝 / 容量 / 回写（生产 static 实现的等价契约）");
    memset(&L, 0, sizeof L);
    memset(g_guest_ram, 0x77, sizeof g_guest_ram);

    // --- 反例先行：错误策略必须被这些断言区分出来，否则下面的正例没有判别力。---
    checks++;
    if (ref_add(&L, b0, g_shadow_maps[0], base, 0, 64, 1) != 0)
        failf("[A0] 首次登记影子", "期望 成功，真结果 失败");
    ck_i32("[A-反例] 错误策略「每次绑定都新建影子」认不出同一区间（会新建第二套影子）",
           wrong_find_always_new(&L, base, 64), REF_FIND_NONE);
    ck_i32("[A-反例] 错误策略「只按 guest 起点匹配」把不同 size 当同一影子",
           wrong_find_ignore_size(&L, base, 128), 0);
    ck_i32("[A-反例] 错误策略「重叠不拒绝」会放行重叠区间去新建影子",
           wrong_find_overlap_as_new(&L, base + 32, 64), REF_FIND_NONE);

    // --- 正确规则：精确匹配（guest+size）才复用。---
    idx = ref_find(&L, base, 64);
    ck_i32("[A1] 同一 guest 区间第二次绑定命中同一影子", idx, 0);
    ck_true("[A1] 命中影子的 VkBuffer 与首次绑定相同", idx == 0 && L.e[idx].buf == b0,
            "同一 VkBuffer");
    ck_u32("[A1] 命中影子的绑定偏移与首次绑定相同", idx == 0 ? L.e[idx].off : 0xFFFFFFFFu, 0);

    // --- 不同 size / 部分重叠：必须准确拒绝（不是复用、也不是新建）。---
    ck_i32("[A2] 同起点不同长度 → 重叠拒绝", ref_find(&L, base, 128), REF_FIND_OVERLAP);
    ck_i32("[A2] 区间起点在已有区间内部 → 重叠拒绝", ref_find(&L, base + 32, 32), REF_FIND_OVERLAP);
    ck_i32("[A2] 已有区间起点在新区间内部 → 重叠拒绝", ref_find(&L, base - 16, 32), REF_FIND_OVERLAP);
    ck_i32("[A2] 新区间完全包住已有区间 → 重叠拒绝", ref_find(&L, base - 8, 128), REF_FIND_OVERLAP);
    // 相邻不算重叠（[base-32, base) 与 [base+64, base+128) 都能新建）。
    ck_i32("[A2] 紧邻下方（端点相接）不算重叠", ref_find(&L, base - 32, 32), REF_FIND_NONE);
    ck_i32("[A2] 紧邻上方（端点相接）不算重叠", ref_find(&L, base + 64, 32), REF_FIND_NONE);

    // --- 容量：一帧最多 16 个可写影子（生产 fd_ssbo_wb_add 的守卫）。---
    memset(&L, 0, sizeof L);
    for (i = 0; i < REF_SHADOW_MAX; i++) {
        checks++;
        if (ref_add(&L, (VkBuffer)(uintptr_t)(0x2000 + i * 0x100), g_shadow_maps[i],
                    base + (uint64_t)i * 64, 0, 64, 1) != 0)
            failf("[A3] 第 1..16 个影子登记", "期望 成功，真结果 第 %d 个失败", i + 1);
    }
    ck_i32("[A3] 本帧已有 16 个影子时仍可命中", ref_find(&L, base, 64), 0);
    ck_i32("[A3] 第 17 个影子必须被拒绝（不静默截断/不覆盖）",
           ref_add(&L, (VkBuffer)(uintptr_t)0x9000, g_shadow_maps[0], base + 4096, 0, 64, 1), -1);

    // --- 退休回写：只回写 writable，只读影子不得覆盖 guest。---
    memset(&L, 0, sizeof L);
    memset(g_guest_ram, 0x77, sizeof g_guest_ram);
    memset(g_shadow_maps, 0, sizeof g_shadow_maps);
    memset(g_shadow_maps[0], 0x11, 64);
    memset(g_shadow_maps[1], 0x22, 32);
    memset(g_shadow_maps[2], 0x33, 96);
    if (ref_add(&L, b0, g_shadow_maps[0], base, 0, 64, 1) != 0)
        failf("[A4] 可写影子登记", "期望 成功，真结果 失败");
    if (ref_add(&L, b0, g_shadow_maps[1], base + 64, 64, 32, 0) != 0)
        failf("[A4] 只读影子登记", "期望 成功，真结果 失败");
    if (ref_add(&L, b0, g_shadow_maps[2], base + 128, 128, 96, 1) != 0)
        failf("[A4] 可写影子登记", "期望 成功，真结果 失败");
    {
        uint8_t want[224];
        memset(want, 0x77, sizeof want);
        memset(want, 0x11, 64);
        memset(want + 128, 0x33, 96);
        ref_writeback(&L);
        ck_bytes("[A4] 退休回写：可写影子拷回 guest，只读影子不覆盖 guest", g_guest_ram, want,
                 sizeof want);
        ck_i32("[A4] 退休后账本清空（下一帧重新登记）", L.n, 0);
    }

    // 地址 0 的影子（无效 guest 指针）不允许回写（生产有 w->guest 守卫）。
    memset(&L, 0, sizeof L);
    memset(g_guest_ram, 0x66, sizeof g_guest_ram);
    memset(g_shadow_maps[3], 0x44, 64);
    if (ref_add(&L, b0, g_shadow_maps[3], 0, 0, 64, 1) != 0)
        failf("[A5] 无效 guest 地址登记", "期望 成功，真结果 失败");
    ref_writeback(&L);
    {
        uint8_t want[64];
        memset(want, 0x66, sizeof want);
        ck_bytes("[A5] guest 地址为 0 的影子不回写（不写空指针）", g_guest_ram, want, sizeof want);
    }
}

static void case_a_alignment(uint64_t align) {
    char label[160];
    group("[A] 可写 SSBO 地址对齐（设备 minStorageBufferOffsetAlignment）");
    checks++;
    if (!align || (align & (align - 1))) {
        failf("[A6] 设备 minStorageBufferOffsetAlignment", "期望 非 0 的 2 的幂，真结果 %llu",
              (unsigned long long)align);
        return;
    }
    printf("… 设备 minStorageBufferOffsetAlignment = %llu\n", (unsigned long long)align);
    snprintf(label, sizeof label, "[A6] 基地址按设备对齐（4096）接受");
    ck_true(label, ref_writable_reject(4096, 64, align) == 0, "接受");
    snprintf(label, sizeof label, "[A6] 基地址 4096+对齐值 接受");
    ck_true(label, ref_writable_reject(4096 + align, 64, align) == 0, "接受");
    snprintf(label, sizeof label, "[A6] 基地址 4096+1 未对齐必须拒绝");
    ck_true(label, ref_writable_reject(4096 + 1, 64, align) != 0, "拒绝");
    snprintf(label, sizeof label, "[A6] 基地址 4095（对齐值前一个字节）必须拒绝");
    ck_true(label, ref_writable_reject(4095, 64, align) != 0, "拒绝");
    snprintf(label, sizeof label, "[A6] 基地址 4096+对齐值-1 必须拒绝");
    ck_true(label, ref_writable_reject(4096 + align - 1, 64, align) != 0, "拒绝");
    ck_true("[A6] 地址 0 必须拒绝（空区间）", ref_writable_reject(0, 64, align) != 0, "拒绝");
    ck_true("[A6] 长度 0 必须拒绝（空区间）", ref_writable_reject(4096, 0, align) != 0, "拒绝");
    ck_true("[A6] 设备对齐为 0 必须拒绝（不可用）", ref_writable_reject(4096, 64, 0) != 0, "拒绝");
    ck_true("[A6] 设备对齐非 2 的幂（48）必须拒绝", ref_writable_reject(4096, 64, 48) != 0, "拒绝");
}

static void case_c_render_area_rule(void) {
    group("[C/约定] 零附件 renderArea 取视口并夹到设备 framebuffer 上限");
    ck_u32("[C0] 视口 640 取整", ref_render_area(1, 640.0f, 16384), 640);
    ck_u32("[C0] 视口 63.4 四舍五入到 63", ref_render_area(1, 63.4f, 16384), 63);
    ck_u32("[C0] 视口 63.5 四舍五入到 64", ref_render_area(1, 63.5f, 16384), 64);
    ck_u32("[C0] 没有记录视口时回退 1（不是 0）", ref_render_area(0, 640.0f, 16384), 1);
    ck_u32("[C0] 视口宽 0 回退 1", ref_render_area(1, 0.0f, 16384), 1);
    ck_u32("[C0] 视口超出 framebuffer 上限必须夹住", ref_render_area(1, 100000.0f, 16384), 16384);
    ck_u32("[C0] 上限较小时同样夹住", ref_render_area(1, 20000.0f, 4096), 4096);
}

// ============================================================================================
// D. 生产纯逻辑：驱动常量段 c0 布局 + 压缩纹理视图格式判定（直接链 nvn_vk_mrt.c）
// ============================================================================================

static void ck_c0_zero(const char *label, const uint8_t *c0, size_t from, size_t to) {
    size_t i;
    checks++;
    for (i = from; i < to; i++) {
        if (c0[i] != 0) {
            failf(label, "期望 [0x%zx,0x%zx) 全 0，真结果 @0x%zx = 0x%02x", from, to, i,
                  (unsigned)c0[i]);
            return;
        }
    }
}

static void case_d_driver_c0(void) {
    static const int bases[5] = { 0x110, 0x510, 0x410, 0x210, 0x310 };
    static const char *stages[5] = { "vs", "fs", "gs", "tcs", "tes" };
    uint8_t c0[NVN_VK_DRIVER_C0_BYTES];
    char why[256];
    uint64_t addr[16];
    uint32_t size[16];
    int stage;

    group("[D] 驱动常量段 c0 布局（生产 nvn_vk_mrt.c）");
    checks += 2;
    if (NVN_VK_DRIVER_C0_BYTES != 0xA00u)
        failf("[D0] 驱动 c0 段大小", "期望 0xA00，真结果 0x%x", (unsigned)NVN_VK_DRIVER_C0_BYTES);
    if (NVN_VK_DRIVER_C0_MAX_POINT != 2047.0f)
        failf("[D0] 最大点径常量", "期望 2047.0f，真结果 %f", (double)NVN_VK_DRIVER_C0_MAX_POINT);
    ck_i32("[D1] vs 存储缓冲表基址", nvn_vk_driver_c0_base(0), bases[0]);
    ck_i32("[D1] fs 存储缓冲表基址", nvn_vk_driver_c0_base(1), bases[1]);
    ck_i32("[D1] gs 存储缓冲表基址", nvn_vk_driver_c0_base(2), bases[2]);
    ck_i32("[D1] tcs 存储缓冲表基址", nvn_vk_driver_c0_base(3), bases[3]);
    ck_i32("[D1] tes 存储缓冲表基址", nvn_vk_driver_c0_base(4), bases[4]);
    ck_true("[D1] 未知 stage（5=compute）必须拒绝", nvn_vk_driver_c0_base(5) < 0,
            "返回负数");
    ck_true("[D1] 未知 stage（UINT32_MAX）必须拒绝", nvn_vk_driver_c0_base(UINT32_MAX) < 0,
            "返回负数");

    // 每个 stage 各填一次：本 stage 表按 16 字节 {u64 addr,u32 size,u32 pad} 排布；其它 stage 表、
    // 没有测量结论的位置保持 0；0x610 最大点径、0x644 base instance 总是写入。
    for (stage = 0; stage < 5; stage++) {
        char label[160];
        int b, r;
        memset(c0, 0xEE, sizeof c0);
        memset(addr, 0, sizeof addr);
        memset(size, 0, sizeof size);
        addr[0] = 0x1000123400ull;
        size[0] = 0x80;
        addr[7] = 0xdead0000ull;
        size[7] = 0x40;
        addr[2] = 0;   // 未绑定槽（addr=0）即使给了 size 也必须保持 0
        size[2] = 99;
        memset(why, 0, sizeof why);
        snprintf(label, sizeof label, "[D2] %s 填 c0", stages[stage]);
        checks++;
        r = nvn_vk_driver_c0_fill_graphics(c0, sizeof c0, (uint32_t)stage, addr, size, 7, why,
                                           sizeof why);
        if (r != 0) {
            failf(label, "期望 接受（rc=0），真结果 rc=%d why=\"%s\"", r, why);
            continue;
        }
        for (b = 0; b < 5; b++) {
            if (b == stage) {
                uint64_t ra = 0;
                uint32_t rn = 0;
                snprintf(label, sizeof label, "[D2] %s 槽 0 描述符地址 @0x%x", stages[stage],
                         bases[stage]);
                memcpy(&ra, c0 + bases[stage], sizeof ra);
                ck_u64(label, ra, 0x1000123400ull);
                snprintf(label, sizeof label, "[D2] %s 槽 0 描述符大小 @0x%x+8", stages[stage],
                         bases[stage]);
                memcpy(&rn, c0 + bases[stage] + 8, sizeof rn);
                ck_u32(label, rn, 0x80);
                snprintf(label, sizeof label, "[D2] %s 槽 7 描述符地址", stages[stage]);
                memcpy(&ra, c0 + bases[stage] + 16 * 7, sizeof ra);
                ck_u64(label, ra, 0xdead0000ull);
                snprintf(label, sizeof label, "[D2] %s 槽 7 描述符大小", stages[stage]);
                memcpy(&rn, c0 + bases[stage] + 16 * 7 + 8, sizeof rn);
                ck_u32(label, rn, 0x40);
                snprintf(label, sizeof label, "[D2] %s 未绑定槽 2 保持 0（size 不单独生效）",
                         stages[stage]);
                ck_c0_zero(label, c0, (size_t)bases[stage] + 16 * 2, (size_t)bases[stage] + 16 * 3);
                snprintf(label, sizeof label, "[D2] %s 槽 0 的 pad 字节保持 0", stages[stage]);
                ck_c0_zero(label, c0, (size_t)bases[stage] + 12, (size_t)bases[stage] + 16);
            } else {
                snprintf(label, sizeof label, "[D2] %s 表未被 %s 填充改写", stages[b], stages[stage]);
                ck_c0_zero(label, c0, (size_t)bases[b], (size_t)bases[b] + 16 * 16);
            }
        }
        {
            float maxp = 0.0f;
            uint32_t binst = 0;
            memcpy(&maxp, c0 + 0x610, sizeof maxp);
            checks++;
            if (memcmp(&maxp, &(float){ 2047.0f }, sizeof maxp) != 0)
                failf("[D2] c0 0x610 最大点径位模式", "期望 2047.0f，真结果 %f", (double)maxp);
            memcpy(&binst, c0 + 0x644, sizeof binst);
            ck_u32("[D2] c0 0x644 base instance", binst, 7);
            // 没有测量结论的位置保持 0（抽查头部/尾部/表间空隙）。
            ck_c0_zero("[D2] 0x000 起未测量区域保持 0", c0, 0, 0x100);
            ck_c0_zero("[D2] 0x600 附近未测量区域保持 0", c0, 0x600, 0x610);
            ck_c0_zero("[D2] 0x618 后未测量区域保持 0", c0, 0x618, 0x644);
            ck_c0_zero("[D2] 0x648 后未测量区域保持 0", c0, 0x648, 0x700);
            ck_c0_zero("[D2] c0 段尾部保持 0", c0, 0x9F0, 0xA00);
        }
    }

    // 拒绝路径：缓冲区过小 / 未知 stage / 缺表 / 缺 dst，都必须准确拒绝并写 why。
    memset(c0, 0, sizeof c0);
    memset(addr, 0, sizeof addr);
    memset(size, 0, sizeof size);
    memset(why, 0, sizeof why);
    ck_true("[D3] 缓冲区小于测量布局（0xA00-1）必须拒绝",
            nvn_vk_driver_c0_fill_graphics(c0, NVN_VK_DRIVER_C0_BYTES - 1, 0, addr, size, 0, why,
                                           sizeof why) != 0,
            "拒绝");
    ck_why("[D3] 缓冲区过小的 why 写明原因", why, "driver c0");
    memset(why, 0, sizeof why);
    ck_true("[D3] 缓冲区 0x100 必须拒绝",
            nvn_vk_driver_c0_fill_graphics(c0, 0x100, 0, addr, size, 0, why, sizeof why) != 0,
            "拒绝");
    memset(why, 0, sizeof why);
    ck_true("[D3] 未知 stage 9 必须拒绝",
            nvn_vk_driver_c0_fill_graphics(c0, sizeof c0, 9, addr, size, 0, why, sizeof why) != 0,
            "拒绝");
    ck_why("[D3] 未知 stage 的 why 写明原因", why, "driver c0");
    ck_true("[D3] dst=NULL 必须拒绝",
            nvn_vk_driver_c0_fill_graphics(NULL, sizeof c0, 0, addr, size, 0, why, sizeof why) != 0,
            "拒绝");
    ck_true("[D3] ssbo_addr=NULL 必须拒绝",
            nvn_vk_driver_c0_fill_graphics(c0, sizeof c0, 0, NULL, size, 0, why, sizeof why) != 0,
            "拒绝");
    ck_true("[D3] ssbo_size=NULL 必须拒绝",
            nvn_vk_driver_c0_fill_graphics(c0, sizeof c0, 0, addr, NULL, 0, why, sizeof why) != 0,
            "拒绝");
    // 边界：正好 0xA00 字节接受；baseline instance 0 / 0xFFFFFFFF 原样写入。
    memset(addr, 0, sizeof addr);
    memset(size, 0, sizeof size);
    checks++;
    if (nvn_vk_driver_c0_fill_graphics(c0, NVN_VK_DRIVER_C0_BYTES, 2, addr, size, 0, why,
                                       sizeof why) != 0)
        failf("[D3] 正好 0xA00 字节", "期望 接受，真结果 拒绝（why=\"%s\"）", why);
    {
        uint32_t binst = 0xFFFFFFFFu;
        memcpy(&binst, c0 + 0x644, sizeof binst);
        ck_u32("[D3] base instance 0 原样写入", binst, 0);
    }
    memset(addr, 0, sizeof addr);
    memset(size, 0, sizeof size);
    checks++;
    if (nvn_vk_driver_c0_fill_graphics(c0, sizeof c0, 4, addr, size, 0xFFFFFFFFu, why,
                                       sizeof why) != 0)
        failf("[D3] base instance 0xFFFFFFFF 填充", "期望 接受，真结果 拒绝（why=\"%s\"）", why);
    {
        uint32_t binst = 0;
        memcpy(&binst, c0 + 0x644, sizeof binst);
        ck_u32("[D3] base instance 0xFFFFFFFF 原样写入", binst, 0xFFFFFFFFu);
    }
}

static void ck_view_accept(const char *label, VkFormat base, VkFormat view, VkFormat want) {
    VkFormat out = VK_FORMAT_R8G8B8A8_UNORM;   // 预置非 UNDEFINED，验证接受时确实写 out
    char why[256] = "";
    int rc = nvn_vk_bcrt_view_format(base, view, &out, why, sizeof why);
    checks++;
    if (rc != 0) {
        failf(label, "期望 接受（rc=0, out=%d），真结果 拒绝（rc=%d）why=\"%s\"", (int)want, rc, why);
        return;
    }
    if (out != want) failf(label, "期望 out=%d，真结果 out=%d", (int)want, (int)out);
}

static void ck_view_reject(const char *label, VkFormat base, VkFormat view, const char *keyword) {
    VkFormat out = VK_FORMAT_R8G8B8A8_UNORM;
    char why[256] = "";
    int rc = nvn_vk_bcrt_view_format(base, view, &out, why, sizeof why);
    checks++;
    if (rc == 0) {
        failf(label, "期望 拒绝（rc!=0），真结果 接受（rc=0, out=%d）", (int)out);
        return;
    }
    if (out != VK_FORMAT_UNDEFINED)
        failf(label, "期望 拒绝时 out 复位成 VK_FORMAT_UNDEFINED，真结果 out=%d", (int)out);
    if (!why[0])
        failf(label, "期望 why 写明拒绝原因（含 \"%s\"），真结果 空串", keyword);
    else if (!strstr(why, keyword))
        failf(label, "期望 why 含 \"%s\"，真结果 \"%s\"", keyword, why);
}

static void case_d_bcrt_view_format(void) {
    group("[D] BC 压缩底图 + 无压缩颜色视图的格式层判定（生产 nvn_vk_bcrt_view_format）");
    // 接受：块字节数 == 视图每像素字节数（BC1/BC4 = 8 字节；BC3/BC7 = 16 字节）。
    ck_view_accept("[D4] BC4(8B 块) + RGBA16UI(8B/px) 接受", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_R16G16B16A16_UINT, VK_FORMAT_R16G16B16A16_UINT);
    ck_view_accept("[D4] BC1(8B 块) + RGBA16UI(8B/px) 接受", VK_FORMAT_BC1_RGBA_UNORM_BLOCK,
                   VK_FORMAT_R16G16B16A16_UINT, VK_FORMAT_R16G16B16A16_UINT);
    ck_view_accept("[D4] BC5(16B 块) + RGBA32UI(16B/px) 接受", VK_FORMAT_BC5_SNORM_BLOCK,
                   VK_FORMAT_R32G32B32A32_UINT, VK_FORMAT_R32G32B32A32_UINT);
    ck_view_accept("[D4] BC7(16B 块) + RGBA32UI(16B/px) 接受", VK_FORMAT_BC7_UNORM_BLOCK,
                   VK_FORMAT_R32G32B32A32_SINT, VK_FORMAT_R32G32B32A32_SINT);
    {
        char why[128] = "";
        checks++;
        if (nvn_vk_bcrt_view_format(VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_R32G32B32A32_SFLOAT, NULL,
                                    why, sizeof why) != 0)
            failf("[D4] out=NULL（只要格式层判定）", "期望 接受，真结果 拒绝（why=\"%s\"）", why);
    }
    // 拒绝：旧/宽松规则会接受 4 字节/2 字节视图去“编码”8/16 字节块，或接受非 BC 底图。
    ck_view_reject("[D5] BC4(8B 块) + RGBA8(4B/px) 必须拒绝", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_R8G8B8A8_UNORM, "not an 8/16-byte uncompressed colour format");
    ck_view_reject("[D5] BC4(8B 块) + R32_UINT(4B/px) 必须拒绝", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_R32_UINT, "not an 8/16-byte uncompressed colour format");
    ck_view_reject("[D5] BC7(16B 块) + RGBA16UI(8B/px) 必须拒绝", VK_FORMAT_BC7_UNORM_BLOCK,
                   VK_FORMAT_R16G16B16A16_UINT, "cannot encode blocks");
    ck_view_reject("[D5] BC3(16B 块) + RGBA16UI(8B/px) 必须拒绝", VK_FORMAT_BC3_UNORM_BLOCK,
                   VK_FORMAT_R16G16B16A16_UINT, "cannot encode blocks");
    ck_view_reject("[D5] 非 BC 压缩底图（R8_UNORM）必须拒绝", VK_FORMAT_R8_UNORM,
                   VK_FORMAT_R16G16B16A16_UINT, "not a BC compressed format");
    ck_view_reject("[D5] VK_FORMAT_UNDEFINED 底图必须拒绝", VK_FORMAT_UNDEFINED,
                   VK_FORMAT_R16G16B16A16_UINT, "not a BC compressed format");
    ck_view_reject("[D5] 压缩视图（BC1）必须拒绝", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_BC1_RGBA_UNORM_BLOCK, "compressed or depth");
    ck_view_reject("[D5] 深度视图（D32_SFLOAT）必须拒绝", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_D32_SFLOAT, "compressed or depth");
    ck_view_reject("[D5] 2 字节视图（R16_UINT）必须拒绝", VK_FORMAT_BC4_UNORM_BLOCK,
                   VK_FORMAT_R16_UINT, "not an 8/16-byte uncompressed colour format");
    ck_view_reject("[D5] 压缩视图（ASTC 4x4）必须拒绝", VK_FORMAT_BC7_UNORM_BLOCK,
                   VK_FORMAT_ASTC_4x4_UNORM_BLOCK, "compressed or depth");
    // 拒绝时 why 可为 NULL（生产 fail_why 有空判，不允许崩溃）。
    checks++;
    if (nvn_vk_bcrt_view_format(VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R8G8B8A8_UNORM, NULL, NULL, 0) == 0)
        failf("[D5] why=NULL 的拒绝路径", "期望 拒绝（rc!=0），真结果 接受");
}

// ============================================================================================
// 真 Vulkan 小工具（建 device / host-visible coherent 缓冲 / 命令录制与提交）
// ============================================================================================

// HOST_VISIBLE|HOST_COHERENT 的 buffer（map 读写）。设备不支持就直接报红，不降级成别的内存类型。
static int make_host_buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer *out,
                            VkDeviceMemory *mem_out, void **map_out, const char *tag) {
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    VkMemoryRequirements mr;
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    uint32_t idx;
    VkResult r;

    *out = VK_NULL_HANDLE;
    *mem_out = VK_NULL_HANDLE;
    *map_out = NULL;
    ci.size = size;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    r = vkCreateBuffer(D.device, &ci, NULL, out);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkCreateBuffer 成功，真结果 rc=%d size=%llu", (int)r,
              (unsigned long long)size);
        return -1;
    }
    vkGetBufferMemoryRequirements(D.device, *out, &mr);
    idx = s2a_vk_memory_type(&D, mr.memoryTypeBits,
                             VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                             NULL);
    if (idx == UINT32_MAX) {
        failf(tag, "期望 存在 HOST_VISIBLE|HOST_COHERENT 的 buffer 内存类型，真结果 没有"
                   "（memoryTypeBits=0x%x）", mr.memoryTypeBits);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        return -1;
    }
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = idx;
    r = vkAllocateMemory(D.device, &ai, NULL, mem_out);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkAllocateMemory 成功，真结果 rc=%d size=%llu", (int)r,
              (unsigned long long)mr.size);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        return -1;
    }
    r = vkBindBufferMemory(D.device, *out, *mem_out, 0);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkBindBufferMemory 成功，真结果 rc=%d", (int)r);
        vkFreeMemory(D.device, *mem_out, NULL);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        *mem_out = VK_NULL_HANDLE;
        return -1;
    }
    r = vkMapMemory(D.device, *mem_out, 0, VK_WHOLE_SIZE, 0, map_out);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkMapMemory 成功，真结果 rc=%d", (int)r);
        vkFreeMemory(D.device, *mem_out, NULL);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        *mem_out = VK_NULL_HANDLE;
        return -1;
    }
    return 0;
}

static void free_host_buffer(VkBuffer buf, VkDeviceMemory mem, int mapped) {
    if (mapped && mem) vkUnmapMemory(D.device, mem);
    if (buf) vkDestroyBuffer(D.device, buf, NULL);
    if (mem) vkFreeMemory(D.device, mem, NULL);
}

static void buf_barrier(VkCommandBuffer cmd, VkBuffer buf, VkDeviceSize off, VkDeviceSize size,
                        VkPipelineStageFlags src_stage, VkAccessFlags src_access,
                        VkPipelineStageFlags dst_stage, VkAccessFlags dst_access) {
    VkBufferMemoryBarrier b = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.buffer = buf;
    b.offset = off;
    b.size = size;
    vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, NULL, 1, &b, 0, NULL);
}

static VkCommandBuffer begin_cb(const char *tag) {
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VkCommandBuffer cmd = VK_NULL_HANDLE;

    ca.commandPool = D.command_pool;
    ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ca.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(D.device, &ca, &cmd) != VK_SUCCESS) {
        failf(tag, "期望 分配命令缓冲成功，真结果 vkAllocateCommandBuffers 失败");
        return VK_NULL_HANDLE;
    }
    if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS) {
        failf(tag, "期望 vkBeginCommandBuffer 成功，真结果 失败");
        vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
        return VK_NULL_HANDLE;
    }
    return cmd;
}

// 结束录制 + 提交 + 等 fence（5 秒超时即红）。返回 0 = 完成证明到手。
static int run_cb(VkCommandBuffer cmd, const char *tag) {
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    VkFence fence = VK_NULL_HANDLE;
    VkResult r;
    int ok = -1;

    r = vkEndCommandBuffer(cmd);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkEndCommandBuffer 成功，真结果 rc=%d", (int)r);
        return -1;
    }
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    r = vkCreateFence(D.device, &fi, NULL, &fence);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkCreateFence 成功，真结果 rc=%d", (int)r);
        return -1;
    }
    r = vkQueueSubmit(D.queue, 1, &si, fence);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkQueueSubmit 成功，真结果 rc=%d", (int)r);
    } else if (vkWaitForFences(D.device, 1, &fence, VK_TRUE, 5000000000ull) != VK_SUCCESS) {
        failf(tag, "期望 栅栏 5s 内触发，真结果 超时");
    } else {
        ok = 0;
    }
    vkDestroyFence(D.device, fence, NULL);
    return ok;
}

// ============================================================================================
// A/B（真 Vulkan）：同一 guest 区间复用影子 → 后一笔看到前一笔的 GPU 写；退休回写 = fence 后 memcpy
// ============================================================================================

static void case_a_shadow_reuse_vk(void) {
    const char *tag = "[A] 同一区间第二笔绑定复用同一影子";
    static uint8_t guest[64];
    VkBuffer shadow = VK_NULL_HANDLE, fresh = VK_NULL_HANDLE;
    VkDeviceMemory smem = VK_NULL_HANDLE, fmem = VK_NULL_HANDLE;
    void *smap = NULL, *fmap = NULL;
    VkBuffer r0 = VK_NULL_HANDLE, r1 = VK_NULL_HANDLE;
    VkDeviceMemory r0mem = VK_NULL_HANDLE, r1mem = VK_NULL_HANDLE;
    void *r0map = NULL, *r1map = NULL;
    struct ref_ledger L;
    VkCommandBuffer cmd;
    VkBufferCopy cp = { 0, 0, 4 };
    uint32_t got0 = 0, got1 = 0;
    int idx;

    group("[A/B] 帧内影子：同一 guest 区间复用 → 后一笔看到前一笔的 GPU 写（真 Vulkan / lavapipe）");
    memset(guest, 0x5A, sizeof guest);   // guest 里是旧内容
    if (make_host_buffer(sizeof guest,
                         VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                             VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &shadow, &smem, &smap, tag) != 0)
        goto out;
    memcpy(smap, guest, sizeof guest);   // 首次绑定：guest 字节 → 新影子（生产同序）
    memset(&L, 0, sizeof L);
    checks++;
    if (ref_add(&L, shadow, smap, (uint64_t)(uintptr_t)guest, 0, sizeof guest, 1) != 0)
        failf(tag, "期望 首次绑定登记影子成功，真结果 失败");

    // 第二笔绑定：同一 guest 区间必须命中同一 VkBuffer/偏移。
    idx = ref_find(&L, (uint64_t)(uintptr_t)guest, sizeof guest);
    ck_i32("[A1-VK] 同一区间第二次绑定命中同一影子", idx, 0);
    ck_true("[A1-VK] 命中影子是同一 VkBuffer 对象", idx == 0 && L.e[idx].buf == shadow,
            "同一 VkBuffer");
    ck_u32("[A1-VK] 命中影子绑定偏移相同", idx == 0 ? L.e[idx].off : 0xFFFFFFFFu, 0);

    // 正例：第一笔记的 GPU 写（fill）与第二笔的读（copy）落在同一影子，后一笔必须看到前一笔。
    if (make_host_buffer(16, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &r0, &r0mem, &r0map, tag) != 0)
        goto out;
    if (make_host_buffer(16, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &r1, &r1mem, &r1map, tag) != 0)
        goto out;
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) goto out;
    vkCmdFillBuffer(cmd, shadow, 0, 16, 0x11223344u);
    buf_barrier(cmd, shadow, 0, 16, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT);
    vkCmdCopyBuffer(cmd, shadow, r0, 1, &cp);
    buf_barrier(cmd, r0, 0, 16, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    if (run_cb(cmd, tag) == 0) {
        memcpy(&got0, r0map, sizeof got0);
        ck_u32("[A2-VK] 后一笔通过同一影子看到前一笔的 GPU 写", got0, 0x11223344u);
        ck_true("[A2-VK] 结果不是 guest 旧字节（不是读了 guest 副本）", got0 != 0x5A5A5A5Au,
                "!= 0x5A5A5A5A");
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);

    // 反例先行：如果第二笔绑定新建一块影子（旧/错误实现），后一笔就看丢第一笔的 GPU 写。
    if (make_host_buffer(sizeof guest,
                         VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                             VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &fresh, &fmem, &fmap, tag) != 0)
        goto out;
    memcpy(fmap, guest, sizeof guest);   // 新影子从 guest 旧字节初始化
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) goto out;
    vkCmdFillBuffer(cmd, shadow, 0, 16, 0x11223344u);
    buf_barrier(cmd, shadow, 0, 16, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT);
    vkCmdCopyBuffer(cmd, fresh, r1, 1, &cp);   // 第二笔绑到了“新影子”
    buf_barrier(cmd, r1, 0, 16, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    if (run_cb(cmd, tag) == 0) {
        memcpy(&got1, r1map, sizeof got1);
        ck_u32("[A-反例-VK] 第二笔新建影子时看不到前一笔的 GPU 写（证明必须复用）", got1,
               0x5A5A5A5Au);
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);

    // 退休回写：fence 信号后把影子按字节拷回 guest（生产 fd_ssbo_wb_writeback）。
    ck_u32("[B-VK] fence 后直接读影子的内容 = GPU 写", *(const uint32_t *)smap, 0x11223344u);
    ref_writeback(&L);
    ck_u32("[B-VK] 退休回写后 guest 内容 = GPU 写", *(const uint32_t *)guest, 0x11223344u);
    // 反例：若回写的是“新影子”（旧/错误实现），会把 GPU 写静默覆盖回旧值。
    memcpy(guest, fmap, sizeof guest);
    ck_u32("[B-反例-VK] 从错误的影子回写会把 guest 覆盖回旧值（证明必须回写命中的影子）",
           *(const uint32_t *)guest, 0x5A5A5A5Au);

out:
    free_host_buffer(r0, r0mem, r0 != VK_NULL_HANDLE);
    free_host_buffer(r1, r1mem, r1 != VK_NULL_HANDLE);
    free_host_buffer(fresh, fmem, fresh != VK_NULL_HANDLE);
    free_host_buffer(shadow, smem, shadow != VK_NULL_HANDLE);
}

static void case_a_overlap_hazard_vk(void) {
    const char *tag = "[A] 重叠影子的危险（真 Vulkan）";
    static uint8_t guest[256];
    VkBuffer a = VK_NULL_HANDLE, b = VK_NULL_HANDLE;
    VkDeviceMemory amem = VK_NULL_HANDLE, bmem = VK_NULL_HANDLE;
    void *amap = NULL, *bmap = NULL;
    VkCommandBuffer cmd;
    struct ref_ledger L;
    uint32_t got;

    group("[A-反例] 两个影子覆盖重叠 guest 区间 → 回写顺序决定谁丢写（必须拒绝重叠，真 Vulkan）");
    memset(guest, 0, sizeof guest);
    if (make_host_buffer(128, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                                  VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &a, &amem, &amap, tag) != 0)
        goto out;
    if (make_host_buffer(128, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                                  VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &b, &bmem, &bmap, tag) != 0)
        goto out;
    // A 覆盖 guest[0,128)，B 覆盖 guest[64,192)：两块“影子”在 guest[64,128) 重叠。
    memcpy(amap, guest, 128);
    memcpy(bmap, guest + 64, 128);
    memset(&L, 0, sizeof L);
    checks++;
    if (ref_add(&L, a, amap, (uint64_t)(uintptr_t)guest, 0, 128, 1) != 0)
        failf(tag, "期望 登记第一块影子，真结果 失败");
    ck_i32("[A2-VK] 重叠的第二块影子必须被准确拒绝（不能当成新影子放行）",
           ref_find(&L, (uint64_t)(uintptr_t)(guest + 64), 128), REF_FIND_OVERLAP);
    // 反例：如果错误地放行两套重叠影子，GPU 写同一段 guest 后按登记顺序回写会静默丢一笔。
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) goto out;
    vkCmdFillBuffer(cmd, a, 64, 16, 0xAAAAAAAAu);   // A 写 guest[64,80)
    buf_barrier(cmd, a, 0, VK_WHOLE_SIZE, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT);
    vkCmdFillBuffer(cmd, b, 0, 16, 0xBBBBBBBBu);    // B 写 guest[64,80)（同一段 guest）
    buf_barrier(cmd, b, 0, VK_WHOLE_SIZE, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                VK_ACCESS_HOST_READ_BIT);
    if (run_cb(cmd, tag) == 0) {
        // 按影子登记顺序回写（生产 fd_ssbo_wb_writeback 就是按帧内登记顺序逐条 memcpy）。
        memcpy(guest, amap, 128);
        memcpy(guest + 64, bmap, 128);
        got = *(const uint32_t *)(guest + 64);
        ck_u32("[A-反例-VK] 两套重叠影子回写后 A 的 GPU 写被静默覆盖（证明重叠必须拒绝）", got,
               0xBBBBBBBBu);
        ck_true("[A-反例-VK] 被覆盖的写不是 A 的值", got != 0xAAAAAAAAu, "!= 0xAAAAAAAA");
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);

out:
    free_host_buffer(a, amem, a != VK_NULL_HANDLE);
    free_host_buffer(b, bmem, b != VK_NULL_HANDLE);
}

static void case_b_retire_writeback_vk(void) {
    const char *tag = "[B] 退休回写 / fence 可见性";
    static uint8_t guest[128];
    uint8_t want[128];
    VkBuffer shadow = VK_NULL_HANDLE;
    VkDeviceMemory smem = VK_NULL_HANDLE;
    void *smap = NULL;
    VkCommandBuffer cmd;
    struct ref_ledger L;
    int i;

    group("[B] 退休回写：host-visible coherent 影子由 GPU 写、fence 后 host memcpy 读回（真 Vulkan）");
    memset(guest, 0x00, sizeof guest);
    if (make_host_buffer(sizeof guest,
                         VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                             VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &shadow, &smem, &smap, tag) != 0)
        return;
    memcpy(smap, guest, sizeof guest);
    memset(&L, 0, sizeof L);
    checks++;
    if (ref_add(&L, shadow, smap, (uint64_t)(uintptr_t)guest, 0, sizeof guest, 1) != 0)
        failf(tag, "期望 影子登记成功，真结果 失败");

    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) {
        free_host_buffer(shadow, smem, 1);
        return;
    }
    // host 写入（映射）→ transfer 写的可见性依赖。
    buf_barrier(cmd, shadow, 0, VK_WHOLE_SIZE, VK_PIPELINE_STAGE_HOST_BIT,
                VK_ACCESS_HOST_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT);
    // 两块不同区域、“GPU 写”成不同值（不是全缓冲单一值，避免初始值恰好对上的假绿）。
    vkCmdFillBuffer(cmd, shadow, 0, 16, 0xAABBCCDDu);
    vkCmdFillBuffer(cmd, shadow, 16, 16, 0x01020304u);
    buf_barrier(cmd, shadow, 0, VK_WHOLE_SIZE, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    if (run_cb(cmd, tag) == 0) {
        // 反例先行：fence 信号本身不会把 guest 改掉——退休回写（memcpy）是必须的一步。
        ck_u32("[B-反例-VK] fence 后未回写时 guest 仍是旧值（回写不是自动的）",
               *(const uint32_t *)guest, 0x00000000u);
        // fence 的 host 可见性：host 直接读影子已经能看到 GPU 写。
        ck_u32("[B-VK] fence 后 host 读影子 = 第一笔 GPU 写", ((const uint32_t *)smap)[0],
               0xAABBCCDDu);
        ck_u32("[B-VK] fence 后 host 读影子 = 第二笔 GPU 写", ((const uint32_t *)smap)[4],
               0x01020304u);
        // 退休回写：按字节拷回（生产 fd_ssbo_wb_writeback 的语义）。
        ref_writeback(&L);
        for (i = 0; i < 128; i++) {
            if (i < 16) want[i] = (uint8_t)(0xAABBCCDDu >> (8 * (i % 4)));
            else if (i < 32) want[i] = (uint8_t)(0x01020304u >> (8 * ((i - 16) % 4)));
            else want[i] = 0;
        }
        ck_bytes("[B-VK] 退休回写后 guest 与 GPU 写逐字节一致、未写区域不变", guest, want,
                 sizeof want);
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
    free_host_buffer(shadow, smem, 1);
}

// ============================================================================================
// C（真 Vulkan）：零附件 render pass + 零附件 framebuffer，draw 真的执行、FS 真的写 SSBO
// ============================================================================================

// 全屏三角形（无顶点缓冲，用 gl_VertexIndex）。
static const uint32_t k_zero_attach_vs[] = {
    0x07230203u, 0x00010300u, 0x000d000bu, 0x0000002bu,
    0x00000000u, 0x00020011u, 0x00000001u, 0x0006000bu,
    0x00000001u, 0x4c534c47u, 0x6474732eu, 0x3035342eu,
    0x00000000u, 0x0003000eu, 0x00000000u, 0x00000001u,
    0x0007000fu, 0x00000000u, 0x00000004u, 0x6e69616du,
    0x00000000u, 0x0000000cu, 0x0000001du, 0x00030003u,
    0x00000002u, 0x000001c2u, 0x000a0004u, 0x475f4c47u,
    0x4c474f4fu, 0x70635f45u, 0x74735f70u, 0x5f656c79u,
    0x656e696cu, 0x7269645fu, 0x69746365u, 0x00006576u,
    0x00080004u, 0x475f4c47u, 0x4c474f4fu, 0x6e695f45u,
    0x64756c63u, 0x69645f65u, 0x74636572u, 0x00657669u,
    0x00040005u, 0x00000004u, 0x6e69616du, 0x00000000u,
    0x00030005u, 0x00000009u, 0x00000070u, 0x00060005u,
    0x0000000cu, 0x565f6c67u, 0x65747265u, 0x646e4978u,
    0x00007865u, 0x00060005u, 0x0000001bu, 0x505f6c67u,
    0x65567265u, 0x78657472u, 0x00000000u, 0x00060006u,
    0x0000001bu, 0x00000000u, 0x505f6c67u, 0x7469736fu,
    0x006e6f69u, 0x00070006u, 0x0000001bu, 0x00000001u,
    0x505f6c67u, 0x746e696fu, 0x657a6953u, 0x00000000u,
    0x00070006u, 0x0000001bu, 0x00000002u, 0x435f6c67u,
    0x4470696cu, 0x61747369u, 0x0065636eu, 0x00070006u,
    0x0000001bu, 0x00000003u, 0x435f6c67u, 0x446c6c75u,
    0x61747369u, 0x0065636eu, 0x00030005u, 0x0000001du,
    0x00000000u, 0x00040047u, 0x0000000cu, 0x0000000bu,
    0x0000002au, 0x00030047u, 0x0000001bu, 0x00000002u,
    0x00050048u, 0x0000001bu, 0x00000000u, 0x0000000bu,
    0x00000000u, 0x00050048u, 0x0000001bu, 0x00000001u,
    0x0000000bu, 0x00000001u, 0x00050048u, 0x0000001bu,
    0x00000002u, 0x0000000bu, 0x00000003u, 0x00050048u,
    0x0000001bu, 0x00000003u, 0x0000000bu, 0x00000004u,
    0x00020013u, 0x00000002u, 0x00030021u, 0x00000003u,
    0x00000002u, 0x00030016u, 0x00000006u, 0x00000020u,
    0x00040017u, 0x00000007u, 0x00000006u, 0x00000002u,
    0x00040020u, 0x00000008u, 0x00000007u, 0x00000007u,
    0x00040015u, 0x0000000au, 0x00000020u, 0x00000001u,
    0x00040020u, 0x0000000bu, 0x00000001u, 0x0000000au,
    0x0004003bu, 0x0000000bu, 0x0000000cu, 0x00000001u,
    0x0004002bu, 0x0000000au, 0x0000000eu, 0x00000001u,
    0x0004002bu, 0x0000000au, 0x00000010u, 0x00000002u,
    0x00040017u, 0x00000017u, 0x00000006u, 0x00000004u,
    0x00040015u, 0x00000018u, 0x00000020u, 0x00000000u,
    0x0004002bu, 0x00000018u, 0x00000019u, 0x00000001u,
    0x0004001cu, 0x0000001au, 0x00000006u, 0x00000019u,
    0x0006001eu, 0x0000001bu, 0x00000017u, 0x00000006u,
    0x0000001au, 0x0000001au, 0x00040020u, 0x0000001cu,
    0x00000003u, 0x0000001bu, 0x0004003bu, 0x0000001cu,
    0x0000001du, 0x00000003u, 0x0004002bu, 0x0000000au,
    0x0000001eu, 0x00000000u, 0x0004002bu, 0x00000006u,
    0x00000020u, 0x40000000u, 0x0004002bu, 0x00000006u,
    0x00000022u, 0x3f800000u, 0x0004002bu, 0x00000006u,
    0x00000025u, 0x00000000u, 0x00040020u, 0x00000029u,
    0x00000003u, 0x00000017u, 0x00050036u, 0x00000002u,
    0x00000004u, 0x00000000u, 0x00000003u, 0x000200f8u,
    0x00000005u, 0x0004003bu, 0x00000008u, 0x00000009u,
    0x00000007u, 0x0004003du, 0x0000000au, 0x0000000du,
    0x0000000cu, 0x000500c4u, 0x0000000au, 0x0000000fu,
    0x0000000du, 0x0000000eu, 0x000500c7u, 0x0000000au,
    0x00000011u, 0x0000000fu, 0x00000010u, 0x0004006fu,
    0x00000006u, 0x00000012u, 0x00000011u, 0x0004003du,
    0x0000000au, 0x00000013u, 0x0000000cu, 0x000500c7u,
    0x0000000au, 0x00000014u, 0x00000013u, 0x00000010u,
    0x0004006fu, 0x00000006u, 0x00000015u, 0x00000014u,
    0x00050050u, 0x00000007u, 0x00000016u, 0x00000012u,
    0x00000015u, 0x0003003eu, 0x00000009u, 0x00000016u,
    0x0004003du, 0x00000007u, 0x0000001fu, 0x00000009u,
    0x0005008eu, 0x00000007u, 0x00000021u, 0x0000001fu,
    0x00000020u, 0x00050050u, 0x00000007u, 0x00000023u,
    0x00000022u, 0x00000022u, 0x00050083u, 0x00000007u,
    0x00000024u, 0x00000021u, 0x00000023u, 0x00050051u,
    0x00000006u, 0x00000026u, 0x00000024u, 0x00000000u,
    0x00050051u, 0x00000006u, 0x00000027u, 0x00000024u,
    0x00000001u, 0x00070050u, 0x00000017u, 0x00000028u,
    0x00000026u, 0x00000027u, 0x00000025u, 0x00000022u,
    0x00050041u, 0x00000029u, 0x0000002au, 0x0000001du,
    0x0000001eu, 0x0003003eu, 0x0000002au, 0x00000028u,
    0x000100fdu, 0x00010038u,
};
// 片元：按 gl_FragCoord 写 SSBO 的每个像素格（无颜色输出）。
static const uint32_t k_zero_attach_fs[] = {
    0x07230203u, 0x00010300u, 0x000d000bu, 0x00000025u,
    0x00000000u, 0x00020011u, 0x00000001u, 0x0006000bu,
    0x00000001u, 0x4c534c47u, 0x6474732eu, 0x3035342eu,
    0x00000000u, 0x0003000eu, 0x00000000u, 0x00000001u,
    0x0006000fu, 0x00000004u, 0x00000004u, 0x6e69616du,
    0x00000000u, 0x0000000cu, 0x00030010u, 0x00000004u,
    0x00000007u, 0x00030003u, 0x00000002u, 0x000001c2u,
    0x000a0004u, 0x475f4c47u, 0x4c474f4fu, 0x70635f45u,
    0x74735f70u, 0x5f656c79u, 0x656e696cu, 0x7269645fu,
    0x69746365u, 0x00006576u, 0x00080004u, 0x475f4c47u,
    0x4c474f4fu, 0x6e695f45u, 0x64756c63u, 0x69645f65u,
    0x74636572u, 0x00657669u, 0x00040005u, 0x00000004u,
    0x6e69616du, 0x00000000u, 0x00030005u, 0x00000008u,
    0x00786469u, 0x00060005u, 0x0000000cu, 0x465f6c67u,
    0x43676172u, 0x64726f6fu, 0x00000000u, 0x00050005u,
    0x0000001au, 0x4374754fu, 0x736c6c65u, 0x00000000u,
    0x00050006u, 0x0000001au, 0x00000000u, 0x6c6c6563u,
    0x00000073u, 0x00050005u, 0x0000001cu, 0x5f74756fu,
    0x6c6c6563u, 0x00000073u, 0x00040047u, 0x0000000cu,
    0x0000000bu, 0x0000000fu, 0x00040047u, 0x00000019u,
    0x00000006u, 0x00000004u, 0x00030047u, 0x0000001au,
    0x00000002u, 0x00040048u, 0x0000001au, 0x00000000u,
    0x00000019u, 0x00050048u, 0x0000001au, 0x00000000u,
    0x00000023u, 0x00000000u, 0x00030047u, 0x0000001cu,
    0x00000019u, 0x00040047u, 0x0000001cu, 0x00000021u,
    0x00000000u, 0x00040047u, 0x0000001cu, 0x00000022u,
    0x00000000u, 0x00020013u, 0x00000002u, 0x00030021u,
    0x00000003u, 0x00000002u, 0x00040015u, 0x00000006u,
    0x00000020u, 0x00000000u, 0x00040020u, 0x00000007u,
    0x00000007u, 0x00000006u, 0x00030016u, 0x00000009u,
    0x00000020u, 0x00040017u, 0x0000000au, 0x00000009u,
    0x00000004u, 0x00040020u, 0x0000000bu, 0x00000001u,
    0x0000000au, 0x0004003bu, 0x0000000bu, 0x0000000cu,
    0x00000001u, 0x0004002bu, 0x00000006u, 0x0000000du,
    0x00000001u, 0x00040020u, 0x0000000eu, 0x00000001u,
    0x00000009u, 0x0004002bu, 0x00000006u, 0x00000012u,
    0x00000040u, 0x0004002bu, 0x00000006u, 0x00000014u,
    0x00000000u, 0x0003001du, 0x00000019u, 0x00000006u,
    0x0003001eu, 0x0000001au, 0x00000019u, 0x00040020u,
    0x0000001bu, 0x0000000cu, 0x0000001au, 0x0004003bu,
    0x0000001bu, 0x0000001cu, 0x0000000cu, 0x00040015u,
    0x0000001du, 0x00000020u, 0x00000001u, 0x0004002bu,
    0x0000001du, 0x0000001eu, 0x00000000u, 0x0004002bu,
    0x00000006u, 0x00000020u, 0x10000000u, 0x00040020u,
    0x00000023u, 0x0000000cu, 0x00000006u, 0x00050036u,
    0x00000002u, 0x00000004u, 0x00000000u, 0x00000003u,
    0x000200f8u, 0x00000005u, 0x0004003bu, 0x00000007u,
    0x00000008u, 0x00000007u, 0x00050041u, 0x0000000eu,
    0x0000000fu, 0x0000000cu, 0x0000000du, 0x0004003du,
    0x00000009u, 0x00000010u, 0x0000000fu, 0x0004006du,
    0x00000006u, 0x00000011u, 0x00000010u, 0x00050084u,
    0x00000006u, 0x00000013u, 0x00000011u, 0x00000012u,
    0x00050041u, 0x0000000eu, 0x00000015u, 0x0000000cu,
    0x00000014u, 0x0004003du, 0x00000009u, 0x00000016u,
    0x00000015u, 0x0004006du, 0x00000006u, 0x00000017u,
    0x00000016u, 0x00050080u, 0x00000006u, 0x00000018u,
    0x00000013u, 0x00000017u, 0x0003003eu, 0x00000008u,
    0x00000018u, 0x0004003du, 0x00000006u, 0x0000001fu,
    0x00000008u, 0x0004003du, 0x00000006u, 0x00000021u,
    0x00000008u, 0x00050080u, 0x00000006u, 0x00000022u,
    0x00000020u, 0x00000021u, 0x00060041u, 0x00000023u,
    0x00000024u, 0x0000001cu, 0x0000001eu, 0x0000001fu,
    0x0003003eu, 0x00000024u, 0x00000022u, 0x000100fdu,
    0x00010038u,
};

#define ZA_W 64u
#define ZA_H 64u
#define ZA_CELLS (ZA_W * ZA_H)
#define ZA_SENTINEL 0xDEADDEADu

static VkShaderModule make_shader(const uint32_t *words, size_t bytes, const char *tag) {
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    VkShaderModule mod = VK_NULL_HANDLE;
    VkResult r;
    ci.codeSize = bytes;
    ci.pCode = words;
    r = vkCreateShaderModule(D.device, &ci, NULL, &mod);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkCreateShaderModule 成功，真结果 rc=%d", (int)r);
        return VK_NULL_HANDLE;
    }
    return mod;
}

// 把 SSBO 的每格复位成哨兵值（用 transfer 写，避免依赖上一笔 draw 的结果）。
static int reset_cells(VkBuffer cells, const char *tag) {
    VkCommandBuffer cmd = begin_cb(tag);
    int ok;
    if (cmd == VK_NULL_HANDLE) return -1;
    vkCmdFillBuffer(cmd, cells, 0, ZA_CELLS * 4, ZA_SENTINEL);
    buf_barrier(cmd, cells, 0, ZA_CELLS * 4, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT |
                    VK_ACCESS_MEMORY_WRITE_BIT);
    ok = run_cb(cmd, tag);
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
    return ok;
}

// 检查 cells 里“应写入”的区域都等于 0x10000000+idx，其它格仍是哨兵。返回 -1 已打红。
static int check_cells_pattern(const uint32_t *cells, uint32_t region_w, uint32_t region_h,
                               const char *label) {
    uint32_t x, y, missing = 0, wrong = 0, extra = 0;
    uint32_t first_x = 0, first_y = 0, first_got = 0, first_want = 0;
    uint32_t extra_x = 0, extra_y = 0;
    for (y = 0; y < ZA_H; y++) {
        for (x = 0; x < ZA_W; x++) {
            uint32_t idx = y * ZA_W + x;
            uint32_t got = cells[idx];
            uint32_t want = 0x10000000u + idx;
            int inside = (x < region_w && y < region_h);
            if (inside && got == ZA_SENTINEL) {
                if (!missing) { first_x = x; first_y = y; }
                missing++;
            } else if (inside && got != want) {
                if (!wrong) { first_x = x; first_y = y; first_got = got; first_want = want; }
                wrong++;
            } else if (!inside && got != ZA_SENTINEL) {
                if (!extra) { extra_x = x; extra_y = y; }
                extra++;
            }
        }
    }
    checks++;
    if (missing || wrong || extra) {
        if (missing)
            failf(label, "期望 renderArea 内每个像元都被片元写到，真结果 缺 %u 个（首个 (%u,%u) 仍是哨兵）",
                  missing, first_x, first_y);
        if (wrong)
            failf(label, "期望 像元值=0x10000000+idx，真结果 %u 个不符（首个 (%u,%u) 期望 0x%08x 真结果 0x%08x）",
                  wrong, first_x, first_y, first_want, first_got);
        if (extra)
            failf(label, "期望 renderArea 外不产生片元写，真结果 %u 个像元被写（首个 (%u,%u)）",
                  extra, extra_x, extra_y);
        return -1;
    }
    return 0;
}

// 录一段“零附件 render pass 里的 draw”：renderArea 由调用方给，viewport/scissor 由动态状态给。
static int record_zero_attach_draw(VkCommandBuffer cmd, VkRenderPass pass, VkFramebuffer fb,
                                   VkPipeline pipe, VkPipelineLayout layout, VkDescriptorSet set,
                                   VkExtent2D area, VkExtent2D viewport, const char *tag) {
    VkRenderPassBeginInfo bi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    VkViewport vp = { 0.0f, 0.0f, (float)viewport.width, (float)viewport.height, 0.0f, 1.0f };
    VkRect2D scissor = { { 0, 0 }, { (int32_t)viewport.width, (int32_t)viewport.height } };

    bi.renderPass = pass;
    bi.framebuffer = fb;
    bi.renderArea.offset = (VkOffset2D){ 0, 0 };
    bi.renderArea.extent = area;
    bi.clearValueCount = 0;
    bi.pClearValues = NULL;
    vkCmdBeginRenderPass(cmd, &bi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdSetViewport(cmd, 0, 1, &vp);
    vkCmdSetScissor(cmd, 0, 1, &scissor);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, NULL);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    (void)tag;
    return 0;
}

static void case_c_zero_attachment_vk(void) {
    const char *tag = "[C] 零附件 render pass";
    VkShaderModule vs = VK_NULL_HANDLE, fs = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
    VkRenderPass pass = VK_NULL_HANDLE;
    VkFramebuffer fb = VK_NULL_HANDLE;
    VkPipeline pipe = VK_NULL_HANDLE;
    VkBuffer cells = VK_NULL_HANDLE;
    VkDeviceMemory cmem = VK_NULL_HANDLE;
    void *cmap = NULL;
    VkCommandBuffer cmd;
    VkResult r;

    group("[C] 零附件 render pass：attachmentCount=0 的 pass/framebuffer 能录 draw 并真的执行（真 Vulkan）");
    checks++;
    if (D.properties.limits.maxFramebufferWidth < ZA_W ||
        D.properties.limits.maxFramebufferHeight < ZA_H) {
        failf("[C1] 设备 framebuffer 上限", "期望 >= %ux%u，真结果 %ux%u", ZA_W, ZA_H,
              (unsigned)D.properties.limits.maxFramebufferWidth,
              (unsigned)D.properties.limits.maxFramebufferHeight);
        return;
    }

    // 1) 零附件 render pass：attachmentCount=0、一个无任何附件的 graphics subpass。
    {
        VkSubpassDescription sub = { 0 };
        VkRenderPassCreateInfo ci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
        sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 0;
        sub.pColorAttachments = NULL;
        sub.pDepthStencilAttachment = NULL;
        ci.attachmentCount = 0;
        ci.pAttachments = NULL;
        ci.subpassCount = 1;
        ci.pSubpasses = &sub;
        r = vkCreateRenderPass(D.device, &ci, NULL, &pass);
        ck_true("[C1] attachmentCount=0 的 VkRenderPass 建得出来", r == VK_SUCCESS,
                "vkCreateRenderPass 返回 VK_SUCCESS");
        if (r != VK_SUCCESS) return;
    }
    // 2) 零附件 framebuffer：尺寸来自视口（光栅化需要 renderArea 在 framebuffer 内）。
    {
        VkFramebufferCreateInfo ci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        ci.renderPass = pass;
        ci.attachmentCount = 0;
        ci.pAttachments = NULL;
        ci.width = ZA_W;
        ci.height = ZA_H;
        ci.layers = 1;
        r = vkCreateFramebuffer(D.device, &ci, NULL, &fb);
        ck_true("[C1] attachmentCount=0 的 VkFramebuffer 建得出来", r == VK_SUCCESS,
                "vkCreateFramebuffer 返回 VK_SUCCESS");
        if (r != VK_SUCCESS) return;
    }
    // 3) FS 写 SSBO：验证 GPU 真的执行了这笔零附件 draw。
    if (make_host_buffer(ZA_CELLS * 4,
                         VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                         &cells, &cmem, &cmap, tag) != 0)
        goto out;
    vs = make_shader(k_zero_attach_vs, sizeof k_zero_attach_vs, tag);
    fs = make_shader(k_zero_attach_fs, sizeof k_zero_attach_fs, tag);
    if (!vs || !fs) goto out;
    {
        VkDescriptorSetLayoutBinding bind = { 0 };
        VkDescriptorSetLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
        bind.binding = 0;
        bind.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bind.descriptorCount = 1;
        bind.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        ci.bindingCount = 1;
        ci.pBindings = &bind;
        r = vkCreateDescriptorSetLayout(D.device, &ci, NULL, &set_layout);
        ck_true("[C1] FS 可写 SSBO 的描述符布局", r == VK_SUCCESS,
                "vkCreateDescriptorSetLayout 返回 VK_SUCCESS");
        if (r != VK_SUCCESS) goto out;
    }
    {
        VkPipelineLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        ci.setLayoutCount = 1;
        ci.pSetLayouts = &set_layout;
        r = vkCreatePipelineLayout(D.device, &ci, NULL, &layout);
        ck_true("[C1] 管线布局", r == VK_SUCCESS, "vkCreatePipelineLayout 返回 VK_SUCCESS");
        if (r != VK_SUCCESS) goto out;
    }
    {
        VkDescriptorPoolSize sz = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
        VkDescriptorPoolCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
        ci.maxSets = 1;
        ci.poolSizeCount = 1;
        ci.pPoolSizes = &sz;
        if (vkCreateDescriptorPool(D.device, &ci, NULL, &pool) != VK_SUCCESS) {
            failf(tag, "期望 vkCreateDescriptorPool 成功，真结果 失败");
            goto out;
        }
        {
            VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
            ai.descriptorPool = pool;
            ai.descriptorSetCount = 1;
            ai.pSetLayouts = &set_layout;
            if (vkAllocateDescriptorSets(D.device, &ai, &set) != VK_SUCCESS) {
                failf(tag, "期望 vkAllocateDescriptorSets 成功，真结果 失败");
                goto out;
            }
        }
        {
            VkDescriptorBufferInfo bi = { cells, 0, VK_WHOLE_SIZE };
            VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
            w.dstSet = set;
            w.dstBinding = 0;
            w.descriptorCount = 1;
            w.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            w.pBufferInfo = &bi;
            vkUpdateDescriptorSets(D.device, 1, &w, 0, NULL);
        }
    }
    // 4) graphics 管线：全屏三角形 + 无颜色附件的 FS；viewport/scissor 用动态状态，方便做反例。
    {
        VkPipelineShaderStageCreateInfo st[2];
        VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
        VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
        VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
        VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
        VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
        VkPipelineDynamicStateCreateInfo dy = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
        VkDynamicState dyn_states[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
        VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
        memset(st, 0, sizeof st);
        st[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        st[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        st[0].module = vs;
        st[0].pName = "main";
        st[1] = st[0];
        st[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        st[1].module = fs;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        vp.viewportCount = 1;
        vp.scissorCount = 1;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1.0f;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        cb.attachmentCount = 0;   // 零附件 subpass 的混合状态也必须 0 个附件
        cb.pAttachments = NULL;
        dy.dynamicStateCount = 2;
        dy.pDynamicStates = dyn_states;
        ci.stageCount = 2;
        ci.pStages = st;
        ci.pVertexInputState = &vi;
        ci.pInputAssemblyState = &ia;
        ci.pViewportState = &vp;
        ci.pRasterizationState = &rs;
        ci.pMultisampleState = &ms;
        ci.pColorBlendState = &cb;
        ci.pDynamicState = &dy;
        ci.layout = layout;
        ci.renderPass = pass;
        r = vkCreateGraphicsPipelines(D.device, VK_NULL_HANDLE, 1, &ci, NULL, &pipe);
        ck_true("[C1] 零颜色附件（attachmentCount=0）的 graphics 管线建得出来", r == VK_SUCCESS,
                "vkCreateGraphicsPipelines 返回 VK_SUCCESS");
        if (r != VK_SUCCESS) goto out;
    }

    // 反例先行：renderArea（32x32）小于视口（64x64）→ 视口外没有片元写入。
    if (reset_cells(cells, tag) != 0) goto out;
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) goto out;
    record_zero_attach_draw(cmd, pass, fb, pipe, layout, set,
                            (VkExtent2D){ 32, 32 }, (VkExtent2D){ ZA_W, ZA_H }, tag);
    if (run_cb(cmd, tag) == 0)
        (void)check_cells_pattern((const uint32_t *)cmap, 32, 32,
                                  "[C-反例-VK] renderArea 小于视口时视口外不产生片元");
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);

    // 正例：renderArea=视口=64x64 → 所有 4096 个像元都被片元着色器写到（GPU 真的执行了 draw）。
    if (reset_cells(cells, tag) != 0) goto out;
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) goto out;
    record_zero_attach_draw(cmd, pass, fb, pipe, layout, set,
                            (VkExtent2D){ ZA_W, ZA_H }, (VkExtent2D){ ZA_W, ZA_H }, tag);
    if (run_cb(cmd, tag) == 0)
        (void)check_cells_pattern((const uint32_t *)cmap, ZA_W, ZA_H,
                                  "[C2-VK] 零附件 pass 的 draw 真的执行（FS 写满 SSBO）");
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);

out:
    if (pipe) vkDestroyPipeline(D.device, pipe, NULL);
    if (pool) vkDestroyDescriptorPool(D.device, pool, NULL);
    if (layout) vkDestroyPipelineLayout(D.device, layout, NULL);
    if (set_layout) vkDestroyDescriptorSetLayout(D.device, set_layout, NULL);
    if (fb) vkDestroyFramebuffer(D.device, fb, NULL);
    if (pass) vkDestroyRenderPass(D.device, pass, NULL);
    if (vs) vkDestroyShaderModule(D.device, vs, NULL);
    if (fs) vkDestroyShaderModule(D.device, fs, NULL);
    free_host_buffer(cells, cmem, cells != VK_NULL_HANDLE);
}

// ============================================================================================

int main(void) {
    char why[256] = "";

    // L 级：纯逻辑用例先跑（不需要 Vulkan），任何一条红都能单独定位。
    case_a_shadow_ledger();
    case_c_render_area_rule();
    case_d_driver_c0();
    case_d_bcrt_view_format();

    printf("… 建 Vulkan 设备（lavapipe / 真机同一份用例源码）\n");
    if (s2a_vk_device_create(&D, why, sizeof why)) {
        printf("✗ 设备创建：期望 建 Vulkan 设备跑真 Vulkan 语义用例，真结果 失败（%s）\n", why);
        return 1;
    }
    printf("… 设备：%s / %s\n", D.driver_name, D.driver_info);

    // S 级：真 Vulkan 语义。
    case_a_alignment(D.properties.limits.minStorageBufferOffsetAlignment);
    case_a_shadow_reuse_vk();
    case_a_overlap_hazard_vk();
    case_b_retire_writeback_vk();
    case_c_zero_attachment_vk();

    (void)s2a_vk_device_destroy(&D, 0);
    if (fails) {
        printf("✗ nvn_vk_ssbo_guest: %d 处不符（共 %d 项检查）\n", fails, checks);
        return 1;
    }
    printf("✓ nvn_vk_ssbo_guest: 帧内影子复用 / 重叠拒绝 / 对齐拒绝 / 退休回写 / 零附件 pass / 驱动 c0 / "
           "bcrt 格式层 %d 项检查全部通过（真 Vulkan）\n", checks);
    return 0;
}
