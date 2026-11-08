#include "bind_defer.h"

#include <string.h>

// 与 vk_record 既有的载荷校验同一条线：先拷出定长头，再按 n 校验句柄区是否完整落在记录里。
int s2a_bind_handles_parse(s2a_guest_read_fn rd, void *opaque,
                           const void *payload, uint32_t payload_bytes,
                           p_bind_handles *out, const char **why) {
    static const char W_SHORT[] = "bind-handles payload too small";
    static const char W_COUNT[] = "bind-handles count outside the record";
    static const char W_BASES[] = "deferred bind-handles missing pool bases";
    static const char W_READ[] = "deferred handle array unreadable";
    if (!payload || !out) {
        if (why) *why = W_SHORT;
        return S2A_BH_INVALID;
    }
    if (payload_bytes < offsetof(p_bind_handles, h)) {
        if (why) *why = W_SHORT;
        return S2A_BH_INVALID;
    }
    memset(out, 0, sizeof *out);
    memcpy(out, payload, payload_bytes > sizeof *out ? sizeof *out : payload_bytes);
    if (out->first < 0 || out->n < 0 || out->n > (int32_t)(sizeof out->h / sizeof out->h[0]) ||
        payload_bytes < offsetof(p_bind_handles, h) + (uint32_t)out->n * 8u) {
        if (why) *why = W_COUNT;
        return S2A_BH_INVALID;
    }
    if (!out->defer || !out->src || out->n == 0) return S2A_BH_OK;
    // deferred：h[] 在录制时未填，游戏之后才写句柄数组；尾部附录制时的池编号基址。
    if (payload_bytes < offsetof(p_bind_handles, h) + (uint32_t)out->n * 8u + sizeof(p_bind_pool_bases)) {
        if (why) *why = W_BASES;
        return S2A_BH_INVALID;
    }
    p_bind_pool_bases bases;
    memcpy(&bases, (const uint8_t *)payload + offsetof(p_bind_handles, h) + (uint32_t)out->n * 8u,
           sizeof bases);
    if (!rd || rd(opaque, out->src, out->h, (size_t)out->n * 8u)) {
        if (why) *why = W_READ;
        return S2A_BH_MEMORY;
    }
    for (int32_t i = 0; i < out->n; i++) {
        // bh_fresh 同式：纹理 id（低 20 位）+ tbase；采样器 id（20 位起）非零才 + sbase。
        // 独立句柄天然落位：separate texture/image 只有纹理 id（sbase 录为 0 或不读），
        // separate sampler 的句柄本身存为 id<<20（hle_nvn.c GetSeparateSamplerHandle）。
        uint64_t tid = out->h[i] & 0xfffffu, sid = out->h[i] >> 20;
        out->h[i] = (tid + (uint64_t)bases.tbase) |
                    ((sid ? sid + (uint64_t)bases.sbase : 0) << 20);
    }
    return S2A_BH_OK;
}
