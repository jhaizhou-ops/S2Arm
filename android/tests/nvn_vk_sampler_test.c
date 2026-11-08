#include <stdio.h>
#include <string.h>
#include "nvn_vk_sampler.h"

static int check(const char *name, samp_par *p, VkFilter minf, VkFilter magf, VkSamplerMipmapMode mm, VkSamplerAddressMode wrap, VkCompareOp cmp) {
    VkSamplerCreateInfo ci;
    if (nvn_vk_sampler_from(p, &ci)) { printf("%-12s FAIL map\n", name); return 1; }
    int ok = ci.minFilter == minf && ci.magFilter == magf && ci.mipmapMode == mm &&
             ci.addressModeU == wrap && ci.addressModeV == wrap && ci.addressModeW == wrap &&
             (cmp == VK_COMPARE_OP_NEVER ? ci.compareEnable == VK_FALSE : ci.compareOp == cmp);
    printf("%-12s min=%d mag=%d mm=%d wrap=%d cmp=%d %s\n", name, ci.minFilter, ci.magFilter, ci.mipmapMode, ci.addressModeU, ci.compareEnable, ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}

int main(void) {
    int bad = 0;
    samp_par p; memset(&p, 0, sizeof p);
    p.minf = NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR; p.magf = NVN_MAG_FILTER_LINEAR;
    p.ws = p.wt = p.wr = NVN_WRAP_MODE_REPEAT; p.lod_max = 10; p.border[3] = 1;
    bad += check("linear", &p, VK_FILTER_LINEAR, VK_FILTER_LINEAR, VK_SAMPLER_MIPMAP_MODE_LINEAR, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_COMPARE_OP_NEVER);
    memset(&p, 0, sizeof p); p.minf = NVN_MIN_FILTER_NEAREST; p.magf = NVN_MAG_FILTER_NEAREST;
    p.ws = p.wt = p.wr = NVN_WRAP_MODE_CLAMP_TO_EDGE; p.lod_max = 1; p.border[3] = 1;
    bad += check("nearest", &p, VK_FILTER_NEAREST, VK_FILTER_NEAREST, VK_SAMPLER_MIPMAP_MODE_NEAREST, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_COMPARE_OP_NEVER);
    memset(&p, 0, sizeof p); p.minf = NVN_MIN_FILTER_LINEAR; p.magf = NVN_MAG_FILTER_LINEAR;
    p.ws = p.wt = p.wr = NVN_WRAP_MODE_CLAMP; p.cmp_mode = NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE; p.cmp_func = NVN_COMPARE_FUNC_LEQUAL; p.lod_max = 1; p.border[3] = 1;
    bad += check("shadow", &p, VK_FILTER_LINEAR, VK_FILTER_LINEAR, VK_SAMPLER_MIPMAP_MODE_NEAREST, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_COMPARE_OP_LESS_OR_EQUAL);
    samp_par badp; memset(&badp, 0, sizeof badp); badp.minf = 15;   /* 4 位字段里的未知值（0x7f 会被截断，clang -Werror 报错） */
    VkSamplerCreateInfo ci;
    int rejected = nvn_vk_sampler_from(&badp, &ci) != 0;
    printf("unknown      %s\n", rejected ? "ok (rejected)" : "FAIL (accepted)");
    bad += !rejected;
    printf("nvn-vk-sampler: %s\n", bad ? "FAIL" : "ok");
    return bad ? 1 : 0;
}
