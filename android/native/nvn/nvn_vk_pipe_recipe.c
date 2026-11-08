// 管线配方：见 nvn_vk_pipe_recipe.h。纯计算，宿主回归与设备走同一份实现。
#include "nvn_vk_pipe_recipe.h"

#include <string.h>
#include <stddef.h>

void nvk_pipe_recipe_fill(struct nvk_pipe_recipe *r, const struct s2a_record_draw_state *st,
                          const char *request_id, const uint8_t prog_sha[32],
                          const uint32_t rt_fmt[8], uint32_t rt_color_count, uint32_t rt_bound_mask,
                          uint32_t depth_fmt, int has_depth, int depth_only, uint64_t device) {
    if (!r) return;
    memset(r, 0, sizeof *r);
    r->layout_policy = NVK_PIPE_LAYOUT_POLICY;
    r->device = device;
    r->prim = st ? st->prim : 0;
    r->rt_count = st ? st->rt_count : 0;
    r->state_seen = st ? st->state_seen : 0;
    r->rt_color_count = rt_color_count;
    r->rt_bound_mask = rt_bound_mask;
    if (rt_fmt) memcpy(r->rt_fmt, rt_fmt, sizeof r->rt_fmt);
    r->depth_fmt = depth_fmt;
    r->has_depth = has_depth ? 1u : 0u;
    r->depth_only = depth_only ? 1u : 0u;
    r->clear_mask = st ? (((st->depth_clear_mask ? 1u : 0u) | (st->stencil_clear_mask ? 2u : 0u))) : 0u;
    if (request_id) {
        size_t n = strlen(request_id);
        if (n >= sizeof r->request_id) n = sizeof r->request_id - 1;
        memcpy(r->request_id, request_id, n);
    }
    if (prog_sha) memcpy(r->prog_sha, prog_sha, 32);
    if (st) {
        for (int k = 0; k < 6; k++)
            if ((st->state_seen >> k) & 1) memcpy(r->state_obj[k], st->state_obj[k], sizeof r->state_obj[k]);
        memcpy(r->blend_obj, st->blend_obj, sizeof r->blend_obj);
        r->blend_seen = st->blend_seen;
        for (int i = 0; i < 32; i++) {
            r->vattr[i][0] = st->vattr[i].format;
            r->vattr[i][1] = st->vattr[i].offset;
            r->vattr[i][2] = st->vattr[i].stream;
        }
        memcpy(r->vstride, st->vstream_stride, sizeof r->vstride);
        memcpy(r->vdivisor, st->vstream_divisor, sizeof r->vdivisor);
    }
}

// request_id 只作日志/定位：跨局采纳时它可能变化（stage key 组），参与判据会造成
// “预热建好、真实绘制仍 miss”。真正的程序内容身份由 prog_sha（结果 SHA-256）承担。
static size_t nvk_pipe_recipe_req_off(void) { return offsetof(struct nvk_pipe_recipe, request_id); }
static size_t nvk_pipe_recipe_req_len(void) { return sizeof(((struct nvk_pipe_recipe *)0)->request_id); }

// 一份配方约 980 字节，逐字节 FNV 每笔要走 ~940 次循环：真机管线段 3.33 us/笔，
// 其中大头就在这个 hash 与 980 字节的 memset/填充上。改成按 64 位字混合。
// **判据不变**：hash 只作预筛，命中仍由 nvk_pipe_recipe_match 逐字节比较（见头文件约定），
// 所以换算法不影响“同一配方才命中”。唯一的对外影响是 pipe_key 取值变化 → 跨会话的管线
// 清单（nvn_vk_pipe_manifest）预热键一次性失效，表现为下一局多建一次管线，不影响正确性。
static inline uint64_t nvk_mix64(uint64_t h, uint64_t w) {
    h ^= w + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
    h *= 1099511628211ull;
    return h ^ (h >> 29);
}
static uint64_t nvk_hash_region(const uint8_t *p, size_t n, uint64_t h) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w;
        memcpy(&w, p + i, 8);
        h = nvk_mix64(h, w);
    }
    for (; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

uint64_t nvk_pipe_recipe_hash(const struct nvk_pipe_recipe *r) {
    if (!r) return 0;
    const uint8_t *p = (const uint8_t *)r;
    const size_t off = nvk_pipe_recipe_req_off();
    const size_t len = sizeof *r;
    uint64_t h = 1469598103934665603ull;
    h = nvk_hash_region(p, off, h);
    h = nvk_hash_region(p + off + nvk_pipe_recipe_req_len(), len - off - nvk_pipe_recipe_req_len(), h);
    // 末次扩散：短区域（或两侧都为 8 字节整数倍）时避免高 32 位不参与判据。
    h ^= h >> 33; h *= 0xff51afd7ed558ccdull; h ^= h >> 33;
    return h;
}

int nvk_pipe_recipe_match(const struct nvk_pipe_recipe *a, const struct nvk_pipe_recipe *b) {
    if (!a || !b) return 0;
    const size_t off = nvk_pipe_recipe_req_off();
    const size_t len = sizeof *a;
    if (memcmp(a, b, off) != 0) return 0;
    return memcmp((const uint8_t *)a + off + nvk_pipe_recipe_req_len(),
                  (const uint8_t *)b + off + nvk_pipe_recipe_req_len(),
                  len - off - nvk_pipe_recipe_req_len()) == 0;
}

int nvk_pipe_recipe_hit(uint64_t cached_key, const struct nvk_pipe_recipe *cached,
                        uint64_t key, const struct nvk_pipe_recipe *r) {
    return cached_key == key && nvk_pipe_recipe_match(cached, r);
}
