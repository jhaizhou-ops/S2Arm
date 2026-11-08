// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// compute dispatch 的纹理消费点快照：一次拿全「NVN 槽位/handle → 已解析并带代际的对象 → 精确视图
// → 采样器 → 编译事实」，并登记保活。编译请求与运行期 descriptor 绑定吃同一份条目：编译等待期间
// 发生对象 Finalize、同槽换对象或注册表换代，都不会让两侧看到不同对象；证明不了是同一份就整笔失败。
// 这里不建任何 Vulkan 对象：解析/视图/采样器归 nvn_vk_first_draw.c（与图形 kind==2 同源），
// 保活归 nvn_vk_texcache.c，事实来自 direct/texture_facts.c。
#include "nvn_vk_compute.h"
#include "nvn_vk_texcache.h"
#include <stdio.h>
#include <string.h>

// 设备侧解析入口：成功返回 0 并 pin 底图（及非默认视图）；失败 -1 且不留下任何保活。
extern int s2a_vk_nvn_texture_bind_for_compute(struct s2a_vk_device *device, uint64_t handle,
    struct nvn_vk_tex **tex_out, VkImageView *view_out, VkSampler *sampler_out,
    char *why, size_t why_bytes);
// 与上面严格配对：view 必须是解析时返回的同一个句柄。
extern void s2a_vk_nvn_texture_release_for_compute(struct nvn_vk_tex *tex, VkImageView view);
extern int s2a_vk_adapter_tex_facts(int id, struct s2a_vk_tex_facts *out, char *why, size_t why_size)
    __attribute__((weak));
// 弱链接[androiddraw]：s2a_vk_adapter_registry_generation（mtl_vk_adapter.c 提供）
extern uint64_t s2a_vk_adapter_registry_generation(void) __attribute__((weak));
// 只读解析：同 id 的已注册纹理对象（复核快照期间注册表换代时用，不 pin、不建对象）。
// 弱链接[androiddraw]：s2a_vk_adapter_tex_by_id（mtl_vk_adapter.c 提供；宿主单测不链适配器）
extern int s2a_vk_adapter_tex_by_id(int id, struct nvn_vk_tex **out, char *why, size_t why_size)
    __attribute__((weak));

static void set_why(char *why, size_t n, const char *text) { if (why && n) snprintf(why, n, "%s", text); }

const struct nvk_compute_tex_binding *nvk_compute_texture_snapshot_find(
    const struct nvk_compute_tex_snapshot *snapshot, unsigned slot) {
    if (!snapshot) return NULL;
    for (int i = 0; i < snapshot->count; ++i)
        if (snapshot->items[i].slot == slot) return &snapshot->items[i];
    return NULL;
}

void nvk_compute_texture_snapshot_release(struct nvk_compute_tex_snapshot *snapshot) {
    if (!snapshot) return;
    for (int i = 0; i < snapshot->count; ++i) {
        if (!snapshot->items[i].tex) continue;
        s2a_vk_nvn_texture_release_for_compute(snapshot->items[i].tex, snapshot->items[i].view);
        snapshot->items[i].tex = NULL;
        snapshot->items[i].view = VK_NULL_HANDLE;
        snapshot->items[i].sampler = VK_NULL_HANDLE;
    }
    memset(snapshot, 0, sizeof *snapshot);
}

int nvk_compute_texture_snapshot_acquire(struct s2a_vk_device *device,
    const struct s2a_record_dispatch_state *state, struct nvk_compute_tex_snapshot *out,
    char *why, size_t why_bytes) {
    if (!out) { set_why(why, why_bytes, "compute texture snapshot output missing"); return -1; }
    memset(out, 0, sizeof *out);
    if (!state) { set_why(why, why_bytes, "compute texture snapshot state missing"); return -1; }
    if (!s2a_vk_adapter_tex_facts) {
        set_why(why, why_bytes, "compute texture facts unavailable: texture registry adapter missing");
        return -1;
    }
    // 取快照期间注册表不允许换代：事实（注册表只读副本）与对象（texcache 解析结果）必须来自同一刻。
    // reg_tex/reg_samp/tex_release 都会推进代际；单执行线程下这里不会变，变了就整笔失败，不混两份。
    const uint64_t reggen = s2a_vk_adapter_registry_generation ? s2a_vk_adapter_registry_generation() : 0;
    for (unsigned slot = 0; slot < 32; ++slot) {
        if (!state->tex_present[slot]) continue;
        if (out->count >= NVK_COMPUTE_TEXTURE_MAX) {
            snprintf(why, why_bytes, "compute texture snapshot exceeds %d entries: slot=%u",
                NVK_COMPUTE_TEXTURE_MAX, slot);
            nvk_compute_texture_snapshot_release(out);
            return -1;
        }
        const uint64_t handle = state->tex_handle[slot];
        const uint32_t id = (uint32_t)(handle & 0xFFFFFu);
        char inner[96] = "";
        struct s2a_vk_tex_facts facts;
        memset(&facts, 0, sizeof facts);
        if (s2a_vk_adapter_tex_facts((int)id, &facts, inner, sizeof inner)) {
            snprintf(why, why_bytes,
                "compute texture fact unresolved: slot=%u id=%u handle=0x%llx kind=texture (%s) reggen=%llu",
                slot, id, (unsigned long long)handle, inner[0] ? inner : "no reason",
                (unsigned long long)reggen);
            nvk_compute_texture_snapshot_release(out);
            return -1;
        }
        // 先判事实能否描述（纯计算、不碰设备对象）：描述不了就失败，不留半套保活。
        struct s2a_nvn_texture_fact nf;
        memset(&nf, 0, sizeof nf);
        if (s2a_nvn_texture_fact(facts.nvn_format, facts.nvn_target, facts.layers, &nf, inner, sizeof inner)) {
            snprintf(why, why_bytes,
                "compute texture fact unmapped: slot=%u id=%u nvn_format=0x%x target=0x%x layers=%u "
                "levels=%u samples=%d (%s) reggen=%llu",
                slot, id, facts.nvn_format, facts.nvn_target, facts.layers, facts.levels, facts.samples,
                inner[0] ? inner : "no reason", (unsigned long long)reggen);
            nvk_compute_texture_snapshot_release(out);
            return -1;
        }
        struct nvn_vk_tex *tex = NULL;
        VkImageView view = VK_NULL_HANDLE;
        VkSampler sampler = VK_NULL_HANDLE;
        if (s2a_vk_nvn_texture_bind_for_compute(device, handle, &tex, &view, &sampler, inner, sizeof inner) ||
            !tex) {
            snprintf(why, why_bytes, "compute texture slot %u (id=%u handle=0x%llx) did not bind: %s",
                slot, id, (unsigned long long)handle, inner[0] ? inner : "no reason");
            nvk_compute_texture_snapshot_release(out);
            return -1;
        }
        // 对象必须就是事实描述的那一个：格式/目标不一致说明同槽换了对象或注册表在取快照期间换代，
        // 绝不把两份不同的对象混成一条快照。
        if (tex->nvn_format != facts.nvn_format || tex->nvn_target != facts.nvn_target) {
            snprintf(why, why_bytes,
                "compute texture snapshot is inconsistent: slot=%u id=%u object fmt=0x%x target=0x%x "
                "vs facts fmt=0x%x target=0x%x reggen=%llu",
                slot, id, tex->nvn_format, tex->nvn_target, facts.nvn_format, facts.nvn_target,
                (unsigned long long)reggen);
            s2a_vk_nvn_texture_release_for_compute(tex, view);
            nvk_compute_texture_snapshot_release(out);
            return -1;
        }
        struct nvk_compute_tex_binding *b = &out->items[out->count++];
        b->slot = slot;
        b->handle = handle;
        b->tex_id = id;
        b->samp_id = (uint32_t)(handle >> 20);
        b->registry_generation = reggen;
        b->tex = tex;
        b->view = view;
        b->sampler = sampler;
        b->fact = nf;
    }
    if (s2a_vk_adapter_registry_generation) {
        const uint64_t after = s2a_vk_adapter_registry_generation();
        if (after != reggen) {
            // 注册表在取快照期间变过：可能只是别的线程登记了与本 dispatch 无关的纹理。
            // 判据不能是“整表换代 = 失败”，而是逐项复核：每个 handle 重新解析到的对象必须还是
            // 快照里 pin 住的那一个（同一 tex 指针、同格式/目标），否则才准确失败。
            // 逐项复核依赖 adapter 的对象查询缝；缝缺席（engine=OFF / 诊断目标）时无法证明
            // “还是同一个对象”，按准确失败处理，绝不空指针直调（宿主实测 rc=-11 就崩在这里）。
            if (!s2a_vk_adapter_tex_by_id) {
                snprintf(why, why_bytes,
                    "compute texture snapshot raced a registry change but the revalidation seam is unavailable "
                    "(reggen %llu -> %llu)", (unsigned long long)reggen, (unsigned long long)after);
                nvk_compute_texture_snapshot_release(out);
                return -1;
            }
            for (int i = 0; i < out->count; ++i) {
                struct nvk_compute_tex_binding *b = &out->items[i];
                struct nvn_vk_tex *again = NULL;
                char inner[128] = "";
                if (s2a_vk_adapter_tex_by_id((int)b->tex_id, &again, inner, sizeof inner) ||
                    again != b->tex) {
                    snprintf(why, why_bytes,
                        "compute texture snapshot raced a registry change: reggen %llu -> %llu, slot=%u id=%u (%s)",
                        (unsigned long long)reggen, (unsigned long long)after, b->slot, b->tex_id,
                        inner[0] ? inner : "object changed or gone");
                    nvk_compute_texture_snapshot_release(out);
                    return -1;
                }
            }
        }
    }
    return 0;
}

void nvk_compute_texture_facts(const struct nvk_compute_tex_snapshot *snapshot,
    struct nvk_compute_texture_set *set) {
    if (!set) return;
    memset(set, 0, sizeof *set);
    if (!snapshot) return;
    for (int i = 0; i < snapshot->count && i < NVK_COMPUTE_TEXTURE_MAX; ++i) {
        const struct nvk_compute_tex_binding *b = &snapshot->items[i];
        const int n = set->count;
        memcpy(set->format[n], b->fact.format, sizeof set->format[n]);
        memcpy(set->sampler[n], b->fact.sampler_type, sizeof set->sampler[n]);
        set->items[n].stage = "cs";
        set->items[n].handle = 8u + 2u * b->slot;
        set->items[n].cbuf_slot = -1;
        set->items[n].sampler_type = set->sampler[n];
        set->items[n].format = set->format[n];
        set->items[n].is_buffer = b->fact.is_buffer;
        set->items[n].normalized = b->fact.normalized;
        set->items[n].separate = 0;   // 组合句柄：采样器在 handle 的高 20 位
        set->items[n].array_length = b->fact.array_length;
        set->count = n + 1;
    }
}
