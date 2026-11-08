#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include "nvn_vk_sampler.h"
#include <stdlib.h>
#include <sys/system_properties.h>

// NVN 采样器参数 → VkSamplerCreateInfo 的映射判定表（P0-2：删除「错误成功」，不许静默近似）。
//
// 精确映射（Vulkan 核心逐位同义）：
//   minf 0..5 → (minFilter, mipmapMode)；magf 0/1；lod_min/lod_max/lod_bias；aniso；compare mode/func；
//   寻址 1 REPEAT、3 MIRROR_CLAMP_TO_EDGE、6 MIRRORED_REPEAT、7 CLAMP_TO_EDGE、
//   5 CLAMP_TO_BORDER（边界色是透明黑 / 不透明黑 / 不透明白之一时）；reduction 0 AVERAGE。
// 经验证的等价实现（有依据，不是新的近似）：
//   0 CLAMP → CLAMP_TO_EDGE、2 MIRROR_CLAMP → MIRROR_CLAMP_TO_EDGE：共享前端
//   graphics/nvn/gfx/nvn/nvn_red.h 的 nvn_samp_wrap 是 NVN 寻址的唯一一张表（Metal 后端 nvn_mtl.m wrapm
//   用的就是它），它把 0/7 与 2/3 各归同一档；两端逐值一致，Android 跟随同一张表。
//   min/max reduction 在足迹只可能是一个纹素时（magf 最近邻且 minf 为 0/2）与 AVERAGE 同值——
//   判据与共享前端 nvn_red_reduces 的足迹定义相同。
// 准确拒绝（返回 -1 并打印参数名与值，调用方明确报红；不产出一个「看起来成功」的采样器）：
//   4 MIRROR_CLAMP_TO_BORDER：Vulkan 核心没有 mirror+clamp-to-border，本后端也没有着色器侧模拟；
//     nvn_red.h 已注明 Metal 把它映成 mirror clamp to edge 是「只有 |x|>1 处不同」的近似，按矩阵
//     §2.8「iOS 的近似不能作为 Android 的追齐目标」处理，这里准确拒绝。
//   5 CLAMP_TO_BORDER + 自定义边界色：Vulkan 核心只有三个枚举色；VK_EXT_custom_border_color 未启用。
//   min/max reduction 且足迹可能覆盖多个纹素：需要 VK_EXT_sampler_filter_minmax，本后端未启用。
//   未知 wrap / minf / magf / compare mode / compare func / reduction 枚举。
// 不可观察（按不可观察精确，不是近似）：没有 clamp-to-border 的轴时边界色永不被采样，任意颜色都接受。
// 已知未实现（与 iOS 后端同档，写入一次日志）：lod_snap 没有落到创建参数（NVN 的 LOD 量化语义）。

// 每种拒绝原因只打一行，避免每笔绑定刷屏（键 = 参数名 + 值）。
static void sampler_once(const char *key, const char *fmt, ...) {
    static char seen[48][48];
    static int n;
    for (int i = 0; i < n; i++)
        if (!strcmp(seen[i], key)) return;
    if (n < (int)(sizeof seen / sizeof seen[0])) snprintf(seen[n++], sizeof seen[0], "%s", key);
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[nvn-vk] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// 1 = 精确；2 = 经验证的等价；0 = 未知/不可表达（调用方准确拒绝）。
static int wrap_mode(uint8_t w, VkSamplerAddressMode *o) {
    switch (w) {
    case NVN_WRAP_MODE_REPEAT: *o = VK_SAMPLER_ADDRESS_MODE_REPEAT; return 1;
    case NVN_WRAP_MODE_MIRROR_CLAMP_TO_EDGE: *o = VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE; return 1;
    case NVN_WRAP_MODE_MIRRORED_REPEAT: *o = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT; return 1;
    case NVN_WRAP_MODE_CLAMP_TO_EDGE: *o = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; return 1;
    case NVN_WRAP_MODE_CLAMP_TO_BORDER: *o = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER; return 1;
    case NVN_WRAP_MODE_CLAMP: *o = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; return 2;                // nvn_samp_wrap：0 与 7 同档
    case NVN_WRAP_MODE_MIRROR_CLAMP: *o = VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE; return 2;  // nvn_samp_wrap：2 与 3 同档
    default: return 0;
    }
}

static int wrap(uint8_t w, VkSamplerAddressMode *o) {
    int kind = wrap_mode(w, o);
    if (kind) return 0;
    char key[48];
    snprintf(key, sizeof key, "wrap=%u", w);
    if (w == NVN_WRAP_MODE_MIRROR_CLAMP_TO_BORDER)
        sampler_once(key, "【红】采样器准确拒绝：wrap=%u MIRROR_CLAMP_TO_BORDER（Vulkan 核心没有 mirror+"
                          "clamp-to-border，也没有着色器侧模拟；不静默降成 mirror clamp to edge）", w);
    else
        sampler_once(key, "【红】采样器准确拒绝：wrap=%u 不是已知的 NVN 寻址模式", w);
    return -1;
}

// 是否有任何轴的边界色会被采样：只有 clamp-to-border 会。
static int border_reachable(const samp_par *p) {
    return p->ws == NVN_WRAP_MODE_CLAMP_TO_BORDER || p->wt == NVN_WRAP_MODE_CLAMP_TO_BORDER ||
           p->wr == NVN_WRAP_MODE_CLAMP_TO_BORDER;
}

static int border_color(const samp_par *p, VkBorderColor *o) {
    int white = p->border[0] == 1.0f && p->border[1] == 1.0f && p->border[2] == 1.0f && p->border[3] == 1.0f;
    int transparent = p->border[0] == 0.0f && p->border[1] == 0.0f && p->border[2] == 0.0f && p->border[3] == 0.0f;
    int opaque_black = p->border[0] == 0.0f && p->border[1] == 0.0f && p->border[2] == 0.0f && p->border[3] == 1.0f;
    *o = white ? VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE
               : transparent ? VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK : VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
    if (!border_reachable(p)) return 0;   // 边界色不可观察：任意颜色都不影响采样结果
    if (white || transparent || opaque_black) return 0;
    char key[96];
    snprintf(key, sizeof key, "border=%g,%g,%g,%g", p->border[0], p->border[1], p->border[2], p->border[3]);
    sampler_once(key, "【红】采样器准确拒绝：border=(%g, %g, %g, %g) 是自定义边界色且 clamp-to-border 轴会用"
                      "它；Vulkan 核心只有透明黑/不透明黑/不透明白三个枚举色（VK_EXT_custom_border_color 未启用）",
                 p->border[0], p->border[1], p->border[2], p->border[3]);
    return -1;
}

// 与共享前端 nvn_red.h 的 nvn_red_reduces 同一足迹定义：magf 线性、或 minf 不是 0/2（会用到线性缩小 /
// mip）时足迹可能覆盖多个纹素，min/max 与 AVERAGE 不同；否则一个纹素，min/max ≡ average。
static int reduction_reduces(const samp_par *p) {
    return (p->reduction == NVN_SAMPLER_REDUCTION_MIN || p->reduction == NVN_SAMPLER_REDUCTION_MAX) &&
           (p->magf || (p->minf != NVN_MIN_FILTER_NEAREST && p->minf != NVN_MIN_FILTER_NEAREST_MIPMAP_NEAREST));
}

static int reduction(const samp_par *p) {
    switch (p->reduction) {
    case NVN_SAMPLER_REDUCTION_AVERAGE:
        return 0;
    case NVN_SAMPLER_REDUCTION_MIN:
    case NVN_SAMPLER_REDUCTION_MAX:
        if (reduction_reduces(p)) {
            char key[64];
            snprintf(key, sizeof key, "reduction=%u/%u/%u", p->reduction, p->minf, p->magf);
            sampler_once(key, "【红】采样器准确拒绝：reduction=%u（min/max）+ minf=%u magf=%u 的足迹可能覆盖多个"
                              "纹素；需要 VK_EXT_sampler_filter_minmax（本后端未启用），不静默当 AVERAGE",
                         p->reduction, p->minf, p->magf);
            return -1;
        }
        // 单纹素足迹：min/max 与 average 逐个纹素同值，属经验证的等价实现
        if (p->reduction == NVN_SAMPLER_REDUCTION_MIN)
            sampler_once("reduction=min-single", "采样器 reduction=MIN 在单纹素足迹下与 AVERAGE 同值"
                                                 "（与共享 nvn_red_reduces 同一足迹定义），按等价实现接受");
        else
            sampler_once("reduction=max-single", "采样器 reduction=MAX 在单纹素足迹下与 AVERAGE 同值"
                                                 "（与共享 nvn_red_reduces 同一足迹定义），按等价实现接受");
        return 0;
    default: {
        char key[48];
        snprintf(key, sizeof key, "reduction=%u", p->reduction);
        sampler_once(key, "【红】采样器准确拒绝：reduction=%u 不是已知的 NVN reduction 模式", p->reduction);
        return -1;
    }
    }
}

static int compare_op(uint8_t m, VkCompareOp *o) {
    switch (m) {
    case NVN_COMPARE_FUNC_NEVER: *o = VK_COMPARE_OP_NEVER; return 0;
    case NVN_COMPARE_FUNC_LESS: *o = VK_COMPARE_OP_LESS; return 0;
    case NVN_COMPARE_FUNC_EQUAL: *o = VK_COMPARE_OP_EQUAL; return 0;
    case NVN_COMPARE_FUNC_LEQUAL: *o = VK_COMPARE_OP_LESS_OR_EQUAL; return 0;
    case NVN_COMPARE_FUNC_GREATER: *o = VK_COMPARE_OP_GREATER; return 0;
    case NVN_COMPARE_FUNC_NOTEQUAL: *o = VK_COMPARE_OP_NOT_EQUAL; return 0;
    case NVN_COMPARE_FUNC_GEQUAL: *o = VK_COMPARE_OP_GREATER_OR_EQUAL; return 0;
    case NVN_COMPARE_FUNC_ALWAYS: *o = VK_COMPARE_OP_ALWAYS; return 0;
    default: return -1;
    }
}

// 诊断：debug.s2a.sampler_linear=1 时把所有采样器强制成线性（用于判定“竖条纹是不是最近邻放大”）。
static int fd_sampler_force_linear(void) {
    static int v = -1;
    if (v < 0) {
        char b[PROP_VALUE_MAX] = {0};
        __system_property_get("debug.s2a.sampler_linear", b);
        v = (b[0] && atoi(b) != 0) ? 1 : 0;
    }
    return v;
}
int nvn_vk_sampler_from(const samp_par *p, VkSamplerCreateInfo *ci) {
    if (!p || !ci) return -1;
    memset(ci, 0, sizeof *ci);
    ci->sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    if (p->magf != NVN_MAG_FILTER_NEAREST && p->magf != NVN_MAG_FILTER_LINEAR) {
        sampler_once("magf", "【红】采样器准确拒绝：magf=%u 不是已知的 NVN 放大过滤", p->magf);
        return -1;
    }
    ci->magFilter = p->magf == NVN_MAG_FILTER_NEAREST ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
    switch (p->minf) {
    case NVN_MIN_FILTER_NEAREST: ci->minFilter = VK_FILTER_NEAREST; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST; break;
    case NVN_MIN_FILTER_LINEAR: ci->minFilter = VK_FILTER_LINEAR; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST; break;
    case NVN_MIN_FILTER_NEAREST_MIPMAP_NEAREST: ci->minFilter = VK_FILTER_NEAREST; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST; break;
    case NVN_MIN_FILTER_LINEAR_MIPMAP_NEAREST: ci->minFilter = VK_FILTER_LINEAR; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST; break;
    case NVN_MIN_FILTER_NEAREST_MIPMAP_LINEAR: ci->minFilter = VK_FILTER_NEAREST; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR; break;
    case NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR: ci->minFilter = VK_FILTER_LINEAR; ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR; break;
    default:
        sampler_once("minf", "【红】采样器准确拒绝：minf=%u 不是已知的 NVN 缩小过滤", p->minf);
        return -1;
    }
    if (wrap(p->ws, &ci->addressModeU) || wrap(p->wt, &ci->addressModeV) || wrap(p->wr, &ci->addressModeW)) return -1;
    // Vulkan 要求 minLod >= 0；NVN 允许负值，与 Metal 后端同口径取 0。
    ci->minLod = p->lod_min < 0.0f ? 0.0f : p->lod_min;
    ci->maxLod = p->lod_max;
    ci->mipLodBias = p->lod_bias;
    // NVN 的各向异性上限与 Metal 一致按 16 收；不超过 1 不打开采样器各向异性。
    ci->anisotropyEnable = p->aniso > 1.0f ? VK_TRUE : VK_FALSE;
    ci->maxAnisotropy = p->aniso > 16.0f ? 16.0f : p->aniso > 1.0f ? p->aniso : 1.0f;
    if (p->lod_snap != 0.0f)
        sampler_once("lod_snap", "【黄】采样器 lod_snap=%g 没有落到创建参数（NVN 的 LOD 量化未实现；"
                                 "与 iOS 后端同档，写入一次日志）", (double)p->lod_snap);
    if (fd_sampler_force_linear()) {
        ci->magFilter = VK_FILTER_LINEAR;
        ci->minFilter = VK_FILTER_LINEAR;
        ci->mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    }
    if (p->cmp_mode != NVN_COMPARE_MODE_NONE) {
        if (p->cmp_mode != NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE) {
            sampler_once("cmp_mode", "【红】采样器准确拒绝：compare mode=%u 不是 NONE / COMPARE_R_TO_TEXTURE", p->cmp_mode);
            return -1;
        }
        ci->compareEnable = VK_TRUE;
        if (compare_op(p->cmp_func, &ci->compareOp)) {
            sampler_once("cmp_func", "【红】采样器准确拒绝：compare func=%u 不是已知的 NVN 比较函数", p->cmp_func);
            return -1;
        }
    }
    if (border_color(p, &ci->borderColor)) return -1;
    if (reduction(p)) return -1;
    ci->unnormalizedCoordinates = VK_FALSE;
    return 0;
}
