// P0-2 采样器映射的宿主回归（只测纯映射函数，不建 Vulkan 设备）。
//
// 判定表（精确 / 经验证的等价 / 准确拒绝）见 android/native/nvn/nvn_vk_sampler.c 顶部注释；
// 这里把每一类钉成用例。核心反例是「三输入全成功但输出错」：输入 MirrorClamp + 自定义边界色 +
// reduction，旧实现返回 0 却给出 MirroredRepeat / 不透明黑 / 无 reduction —— 静默错值。
//
// 编译方式见 nvn_vk_sampler_mapping_test.py（含变异控制：把关键修复撤掉后必须变红）。
#include <stdio.h>
#include <string.h>
#include "nvn_vk_sampler.h"

// 宿主桩：android 系统属性。返回空串 = 诊断开关全关（fd_sampler_force_linear 不生效）。
// 真机（探针）编译时定义 SAMPLER_TEST_NO_PROP_STUB：__system_property_get 由 libc 提供。
#ifndef SAMPLER_TEST_NO_PROP_STUB
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = 0;
    return 0;
}
#endif

#include SAMPLER_SOURCE   // 生产实现（变异版由驱动用同一个宏指过去）

static int bad;

static samp_par base(void) {
    samp_par p;
    memset(&p, 0, sizeof p);
    p.minf = NVN_MIN_FILTER_LINEAR;
    p.magf = NVN_MAG_FILTER_LINEAR;
    p.ws = p.wt = p.wr = NVN_WRAP_MODE_REPEAT;
    p.lod_min = 0;
    p.lod_max = 10;
    p.border[3] = 1;   // 不透明黑：clamp-to-border 下也是三个精确枚举色之一
    return p;
}

static void fail(const char *name, const char *why, int rc) {
    bad++;
    printf("FAIL %-42s %s (rc=%d)\n", name, why, rc);
}

// 接受类：返回值必须是 0，且三个轴的寻址模式等于期望值。
static void expect_accept(const char *name, const samp_par *p,
                          VkSamplerAddressMode u, VkSamplerAddressMode v, VkSamplerAddressMode w) {
    VkSamplerCreateInfo ci;
    int rc = nvn_vk_sampler_from(p, &ci);
    if (rc) { fail(name, "被拒绝了（应当接受）", rc); return; }
    if (ci.addressModeU != u || ci.addressModeV != v || ci.addressModeW != w) {
        char why[160];
        snprintf(why, sizeof why, "寻址模式 %d/%d/%d，期望 %d/%d/%d",
                 (int)ci.addressModeU, (int)ci.addressModeV, (int)ci.addressModeW, (int)u, (int)v, (int)w);
        fail(name, why, rc);
        return;
    }
    printf("OK   %-42s\n", name);
}

// 接受类（只关心边界色 / reduction 落点）。
static void expect_border(const char *name, const samp_par *p, VkBorderColor want) {
    VkSamplerCreateInfo ci;
    int rc = nvn_vk_sampler_from(p, &ci);
    if (rc) { fail(name, "被拒绝了（应当接受）", rc); return; }
    if (ci.borderColor != want) {
        char why[96];
        snprintf(why, sizeof why, "borderColor=%d，期望 %d", (int)ci.borderColor, (int)want);
        fail(name, why, rc);
        return;
    }
    printf("OK   %-42s\n", name);
}

// 拒绝类：必须返回非 0，并且**不**留下一个看似成功的结果。
static void expect_reject(const char *name, const samp_par *p) {
    VkSamplerCreateInfo ci;
    memset(&ci, 0xa5, sizeof ci);
    int rc = nvn_vk_sampler_from(p, &ci);
    if (!rc) {
        char why[160];
        snprintf(why, sizeof why, "错误成功：返回 0，输出 u=%d border=%d cmp=%d",
                 (int)ci.addressModeU, (int)ci.borderColor, (int)ci.compareEnable);
        fail(name, why, rc);
        return;
    }
    printf("OK   %-42s (rejected)\n", name);
}

int main(void) {
    // ---- 过滤 / LOD / 各向异性 / 比较：精确映射（回归保护，行为与改动前一致）----
    {
        samp_par p = base();
        VkSamplerCreateInfo ci;
        if (nvn_vk_sampler_from(&p, &ci) || ci.minFilter != VK_FILTER_LINEAR ||
            ci.magFilter != VK_FILTER_LINEAR || ci.mipmapMode != VK_SAMPLER_MIPMAP_MODE_NEAREST)
            fail("filters-exact", "线性过滤映射错", 0);
        else printf("OK   %-42s\n", "filters-exact");
        p.minf = NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR;
        if (nvn_vk_sampler_from(&p, &ci) || ci.mipmapMode != VK_SAMPLER_MIPMAP_MODE_LINEAR)
            fail("mipmap-linear-exact", "mip 过滤映射错", 0);
        else printf("OK   %-42s\n", "mipmap-linear-exact");
        p = base(); p.aniso = 8.0f;
        if (nvn_vk_sampler_from(&p, &ci) || ci.anisotropyEnable != VK_TRUE || ci.maxAnisotropy != 8.0f)
            fail("aniso-exact", "各向异性没落到创建参数", 0);
        else printf("OK   %-42s\n", "aniso-exact");
        p = base(); p.cmp_mode = NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE; p.cmp_func = NVN_COMPARE_FUNC_LEQUAL;
        if (nvn_vk_sampler_from(&p, &ci) || ci.compareEnable != VK_TRUE || ci.compareOp != VK_COMPARE_OP_LESS_OR_EQUAL)
            fail("compare-exact", "深度比较映射错", 0);
        else printf("OK   %-42s\n", "compare-exact");
    }

    // ---- 寻址模式：精确 / 等价（与共享前端 nvn_red.h 的 nvn_samp_wrap 同一张表）----
    {
        samp_par p;
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_REPEAT;
        expect_accept("wrap-repeat-exact", &p, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT);
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_MIRRORED_REPEAT;
        expect_accept("wrap-mirrored-repeat-exact", &p, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT);
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_CLAMP_TO_EDGE;
        expect_accept("wrap-clamp-to-edge-exact", &p, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE);
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_MIRROR_CLAMP_TO_EDGE;
        expect_accept("wrap-mirror-clamp-to-edge-exact", &p, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE);
        // nvn_samp_wrap 把 0 与 7 同档（clamp to edge）：等价，不许再只是“看着像”
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_CLAMP;
        expect_accept("wrap-clamp-equiv", &p, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE);
        // 本次修的核心：MirrorClamp 曾经被映成 MirroredRepeat（无限折返），必须落到 mirror clamp to edge
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_MIRROR_CLAMP;
        expect_accept("wrap-mirror-clamp-equiv", &p, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE);
        // 混合轴：u=clamp v=repeat w=mirror clamp，三个轴互不串味
        p = base(); p.ws = NVN_WRAP_MODE_CLAMP; p.wt = NVN_WRAP_MODE_REPEAT; p.wr = NVN_WRAP_MODE_MIRROR_CLAMP;
        expect_accept("wrap-per-axis", &p, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE);
    }

    // ---- MIRROR_CLAMP_TO_BORDER：Vulkan 核心没有 mirror+clamp-to-border，也没有着色器侧模拟 → 准确拒绝 ----
    {
        samp_par p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_MIRROR_CLAMP_TO_BORDER;
        expect_reject("wrap-mirror-clamp-to-border-rejected", &p);
    }

    // ---- 边界色：三个枚举色精确；可达的自定义色准确拒绝；不可达的任意色不可观察 ----
    {
        samp_par p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_CLAMP_TO_BORDER;
        p.border[0] = p.border[1] = p.border[2] = p.border[3] = 0.0f;
        expect_border("border-transparent-black-exact", &p, VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK);
        p.border[0] = p.border[1] = p.border[2] = 1.0f; p.border[3] = 1.0f;
        expect_border("border-opaque-white-exact", &p, VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE);
        p.border[0] = p.border[1] = p.border[2] = 0.0f; p.border[3] = 1.0f;
        expect_border("border-opaque-black-exact", &p, VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK);
        // 自定义色 + clamp-to-border：旧实现静默按黑 → 现在必须拒绝（VK_EXT_custom_border_color 未启用）
        p.border[0] = 0.25f; p.border[1] = 0.5f; p.border[2] = 0.75f; p.border[3] = 1.0f;
        expect_reject("border-custom-reachable-rejected", &p);
        // 单轴 clamp-to-border 也算可达
        p = base(); p.ws = NVN_WRAP_MODE_CLAMP_TO_BORDER; p.wt = p.wr = NVN_WRAP_MODE_REPEAT;
        p.border[0] = 0.25f; p.border[1] = 0.5f; p.border[2] = 0.75f; p.border[3] = 1.0f;
        expect_reject("border-custom-one-axis-rejected", &p);
        // 没有 clamp-to-border 的轴：边界色永不被采样 → 接受（不可观察，不是近似）
        p = base(); p.ws = p.wt = p.wr = NVN_WRAP_MODE_REPEAT;
        p.border[0] = 0.25f; p.border[1] = 0.5f; p.border[2] = 0.75f; p.border[3] = 1.0f;
        expect_accept("border-custom-unreachable-accepted", &p, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT);
    }

    // ---- reduction：多纹素足迹要 filter-minmax 扩展（未启用）→ 拒绝；单纹素足迹与 AVERAGE 同值 → 等价 ----
    {
        // 线性放大：足迹必然是多个纹素 → 不能静默当 AVERAGE
        samp_par p = base(); p.reduction = NVN_SAMPLER_REDUCTION_MIN;
        expect_reject("reduction-min-multi-rejected", &p);
        p = base(); p.reduction = NVN_SAMPLER_REDUCTION_MAX;
        expect_reject("reduction-max-multi-rejected", &p);
        // 最近邻放大 + 最近邻/无 mip 缩小：一个纹素，min/max 与 average 同值（nvn_red_reduces 的同一足迹定义）
        p = base(); p.reduction = NVN_SAMPLER_REDUCTION_MIN; p.magf = NVN_MAG_FILTER_NEAREST; p.minf = NVN_MIN_FILTER_NEAREST;
        if (nvn_vk_sampler_from(&p, &(VkSamplerCreateInfo){0})) fail("reduction-min-single-texel-equiv", "单纹素足迹被拒绝", 0);
        else printf("OK   %-42s\n", "reduction-min-single-texel-equiv");
        // AVERAGE 是 Vulkan 默认：照常接受
        p = base(); p.reduction = NVN_SAMPLER_REDUCTION_AVERAGE;
        if (nvn_vk_sampler_from(&p, &(VkSamplerCreateInfo){0})) fail("reduction-average-exact", "AVERAGE 被拒绝", 0);
        else printf("OK   %-42s\n", "reduction-average-exact");
        // 未知 reduction 值：拒绝（不许当成 AVERAGE）
        p = base(); p.reduction = 7;
        expect_reject("reduction-unknown-rejected", &p);
    }

    // ---- 本任务的核心反例：MirrorClamp + 自定义边界色 + reduction，三输入全“看起来合法” ----
    // 旧实现返回 0 但输出 MirroredRepeat / 不透明黑 / 无 reduction：静默错值。必须至少在一处准确拒绝。
    {
        samp_par p = base();
        p.ws = p.wt = p.wr = NVN_WRAP_MODE_MIRROR_CLAMP;
        p.border[0] = 0.25f; p.border[1] = 0.5f; p.border[2] = 0.75f; p.border[3] = 1.0f;
        p.reduction = NVN_SAMPLER_REDUCTION_MIN;
        expect_reject("error-success-trio-rejected", &p);
    }

    // ---- 未知枚举：一律准确拒绝（不许静默落到默认值）----
    {
        samp_par p = base(); p.ws = 15;   /* 4 位字段里不是合法 NVN wrap 的值 */
        expect_reject("unknown-wrap-rejected", &p);
        p = base(); p.minf = 15;
        expect_reject("unknown-min-filter-rejected", &p);
        p = base(); p.magf = 15;
        expect_reject("unknown-mag-filter-rejected", &p);
        p = base(); p.cmp_mode = 3; p.cmp_func = NVN_COMPARE_FUNC_LESS;
        expect_reject("unknown-compare-mode-rejected", &p);
        p = base(); p.cmp_mode = NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE; p.cmp_func = 15;
        expect_reject("unknown-compare-func-rejected", &p);
    }

    if (bad) { printf("nvn-vk-sampler-mapping: %d FAILURES\n", bad); return 1; }
    printf("nvn-vk-sampler-mapping: ok\n");
    return 0;
}
