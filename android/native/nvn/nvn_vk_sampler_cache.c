#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "nvn_vk_sampler_cache.h"
#include "nvn_vk_sampler.h"

// 命中判据是 (cube_view, samp_par 逐字节相同)，与索引结构无关：索引用哈希只是为了 O(1)。
// 线性扫描在槽数增长后是每笔数百次 memcmp（世界帧 600 笔 × 每笔一次采样器查询），
// 这是绘制路径上的固定成本，不是采样器本身的开销。
static uint32_t samp_hash(const samp_par *p, int cube_view) {
    const uint8_t *b = (const uint8_t *)p;
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < sizeof *p; i++) { h ^= b[i]; h *= 16777619u; }
    h ^= (uint32_t)cube_view * 2246822519u;
    h *= 16777619u;
    h ^= h >> 15;
    return h;
}

// 返回 wells 里的下标；-1 = 没有。index 不可用（分配失败）时退回线性扫描，结果相同。
static int samp_find(const struct nvn_vk_sampler_cache *c, const samp_par *p, int cube_view) {
    if (!c->tab || c->tab_cap <= 0) {
        for (int i = 0; i < c->n; i++)
            if (c->slots[i].valid && c->slots[i].cube_view == cube_view &&
                memcmp(&c->slots[i].p, p, sizeof *p) == 0) return i;
        return -1;
    }
    const uint32_t mask = (uint32_t)c->tab_cap - 1u;
    const uint32_t h = samp_hash(p, cube_view);
    for (uint32_t probe = 0; probe <= mask; probe++) {
        int32_t e = c->tab[(h + probe) & mask];
        if (!e) return -1;
        int i = (int)e - 1;
        if (i >= 0 && i < c->n && c->slots[i].valid && c->slots[i].cube_view == cube_view &&
            memcmp(&c->slots[i].p, p, sizeof *p) == 0) return i;
    }
    return -1;
}

static int samp_index_insert(struct nvn_vk_sampler_cache *c, int i) {
    if (!c->tab || c->tab_cap <= 0) return -1;
    const uint32_t mask = (uint32_t)c->tab_cap - 1u;
    const uint32_t h = samp_hash(&c->slots[i].p, c->slots[i].cube_view);
    for (uint32_t probe = 0; probe <= mask; probe++) {
        int32_t *x = &c->tab[(h + probe) & mask];
        if (!*x) { *x = (int32_t)(i + 1); return 0; }
    }
    return -1;   // 表满：条目仍然有效，只是查不到（下次会再建一个等价采样器），不影响正确性
}

// 重建索引：容量取 >= 2×ncap 的 2 的幂。失败保留旧索引（旧索引存的是下标，槽数组搬动后仍有效）。
static int samp_index_rebuild(struct nvn_vk_sampler_cache *c, int ncap) {
    int tcap = 32;
    while (tcap < ncap * 2) tcap <<= 1;
    int32_t *nt = (int32_t *)calloc((size_t)tcap, sizeof *nt);
    if (!nt) return -1;
    free(c->tab);
    c->tab = nt; c->tab_cap = tcap;
    for (int i = 0; i < c->n; i++) if (c->slots[i].valid) (void)samp_index_insert(c, i);
    return 0;
}

void nvn_vk_sampler_cache_init(struct nvn_vk_sampler_cache *c, struct s2a_vk_device *d) {
    memset(c, 0, sizeof *c);
    c->d = d;
    c->cap = 32;
    c->slots = (struct nvn_vk_sampler_slot *)calloc((size_t)c->cap, sizeof *c->slots);
    if (!c->slots) c->cap = 0;   // 分配失败：后续 get 会准确失败
    else if (samp_index_rebuild(c, c->cap) != 0)
        fprintf(stderr, "[nvn-vk] sampler cache index unavailable (out of memory); "
                        "lookups fall back to a linear scan\n");
}

void nvn_vk_sampler_cache_destroy(struct nvn_vk_sampler_cache *c) {
    for (int i = 0; i < c->n; i++) if (c->slots[i].valid) { vkDestroySampler(c->d->device, c->slots[i].s, NULL); c->slots[i].valid = 0; }
    free(c->slots); c->slots = NULL;
    free(c->tab); c->tab = NULL;
    c->cap = c->n = 0; c->tab_cap = 0;
}

VkSampler nvn_vk_sampler_cache_get(struct nvn_vk_sampler_cache *c, const samp_par *p, char *why, size_t why_size) {
    return nvn_vk_sampler_cache_get_for_view(c, p, 0, why, why_size);
}

VkSampler nvn_vk_sampler_cache_get_for_view(struct nvn_vk_sampler_cache *c, const samp_par *p, int cube_view,
                                            char *why, size_t why_size) {
    if (!p) { if (why && why_size) snprintf(why, why_size, "null sampler"); return VK_NULL_HANDLE; }
    cube_view = cube_view ? 1 : 0;
    {
        int hit = samp_find(c, p, cube_view);
        if (hit >= 0) { c->reused++; return c->slots[hit].s; }
    }
    VkSamplerCreateInfo ci;
    if (nvn_vk_sampler_from(p, &ci)) { if (why && why_size) snprintf(why, why_size, "unsupported sampler parameters (min 0x%x mag 0x%x)", p->minf, p->magf); return VK_NULL_HANDLE; }
    if (cube_view) {
        // 立方体采样只允许 CLAMP_TO_EDGE（Vulkan 的采样器合法性要求）；NVN 的 wrap 在这里没有别的映射。
        if (ci.addressModeU != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE ||
            ci.addressModeV != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE ||
            ci.addressModeW != VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE) {
            static int noted;
            if (!noted++)
                fprintf(stderr, "[nvn-vk] sampler used with a cube view: NVN wrap %u/%u/%u forced to CLAMP_TO_EDGE\n",
                        p->ws, p->wt, p->wr);
        }
        ci.addressModeU = ci.addressModeV = ci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    }
    VkSampler s;
    if (vkCreateSampler(c->d->device, &ci, NULL, &s) != VK_SUCCESS) { if (why && why_size) snprintf(why, why_size, "vkCreateSampler failed"); return VK_NULL_HANDLE; }
    if (c->n == c->cap) {
        // 按需增长（上限 4096 只为内存预算，不是语义上限）；增长失败才准确失败。
        int ncap = c->cap ? c->cap * 2 : 32;
        if (ncap > 4096) ncap = 4096;
        if (ncap <= c->cap) {
            vkDestroySampler(c->d->device, s, NULL);
            if (why && why_size) snprintf(why, why_size, "sampler cache at its memory budget (%d), cannot grow", c->cap);
            return VK_NULL_HANDLE;
        }
        struct nvn_vk_sampler_slot *ns = (struct nvn_vk_sampler_slot *)realloc(c->slots, (size_t)ncap * sizeof *ns);
        if (!ns) {
            vkDestroySampler(c->d->device, s, NULL);
            if (why && why_size) snprintf(why, why_size, "sampler cache grow failed (out of memory)");
            return VK_NULL_HANDLE;
        }
        memset(ns + c->cap, 0, (size_t)(ncap - c->cap) * sizeof *ns);
        c->slots = ns; c->cap = ncap;
        if (samp_index_rebuild(c, ncap) != 0)
            fprintf(stderr, "[nvn-vk] sampler cache index grow failed (out of memory); "
                            "the new entry is not indexed (lookups may create an equivalent sampler)\n");
    }
    c->slots[c->n].p = *p; c->slots[c->n].s = s; c->slots[c->n].valid = 1; c->slots[c->n].cube_view = cube_view;
    (void)samp_index_insert(c, c->n);
    c->n++;
    c->created++;
    return s;
}
