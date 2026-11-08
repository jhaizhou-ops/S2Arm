// Conservative inspection of final SPIR-V on devices without vertex pipeline stores.
// Returns 0 only when no storage write/atomic is found and every storage
// resource is provably NonWritable; 1 means feature required, -1 malformed.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct s2a_spv_node {
    uint32_t op, target, target2, sampled, storage, member_count;
    uint64_t nonwritable_members;
    unsigned nonwritable:1, block:1, buffer_block:1, variable:1;
};

static inline int s2a_spv_store_target(const struct s2a_spv_node *n, uint32_t bound,
                                       uint32_t id, unsigned depth) {
    if (!id || id >= bound || depth >= 64) return 1;
    if (n[id].variable) {
        uint32_t s = n[id].storage;
        return s != 1 && s != 3 && s != 4 && s != 5 && s != 6 && s != 7 && s != 9;
    }
    if (n[id].op == 65 || n[id].op == 66 || n[id].op == 67 || n[id].op == 70 || n[id].op == 83)
        return s2a_spv_store_target(n, bound, n[id].target, depth + 1);
    if (n[id].op == 169)
        return s2a_spv_store_target(n, bound, n[id].target, depth + 1) ||
               s2a_spv_store_target(n, bound, n[id].target2, depth + 1);
    // OpPhi and other pointer producers are deliberately conservative.
    return 1;
}

static inline uint32_t s2a_spv_word(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static inline int s2a_spirv_storage_need(const void *bytes, size_t size, uint32_t expected_model) {
    const unsigned char *p = (const unsigned char *)bytes;
    if (!p || size < 20 || (size & 3u) || s2a_spv_word(p) != 0x07230203u) return -1;
    uint32_t bound = s2a_spv_word(p + 12);
    if (!bound || bound > (1u << 20)) return -1;
    struct s2a_spv_node *n = (struct s2a_spv_node *)calloc(bound, sizeof *n);
    if (!n) return -1;
    uint32_t *stores = (uint32_t *)malloc(size);
    if (!stores) { free(n); return -1; }
    size_t nstores = 0;
    int result = 0, vertex_entry = 0;
    size_t words = size / 4, pos = 5;
    while (pos < words) {
        uint32_t first = s2a_spv_word(p + pos * 4), count = first >> 16, op = first & 65535u;
        if (!count || count > words - pos) { result = -1; goto done; }
#define S2A_SPV_ARG(i) s2a_spv_word(p + (pos + (i)) * 4)
        if (op == 15 && count >= 5 && S2A_SPV_ARG(1) == expected_model &&
            S2A_SPV_ARG(3) == 0x6e69616d && (S2A_SPV_ARG(4) & 255u) == 0) vertex_entry = 1;
        if ((op >= 227 && op <= 242) || op == 318 || op == 319 || op == 5614 || op == 5615 || op == 6035 || op == 99) {
            result = 1; goto done;
        }
        if (op == 71 && count >= 3) {
            uint32_t id = S2A_SPV_ARG(1), dec = S2A_SPV_ARG(2);
            if (!id || id >= bound) { result = -1; goto done; }
            if (dec == 24) n[id].nonwritable = 1;
            if (dec == 2) n[id].block = 1;
            if (dec == 3) n[id].buffer_block = 1;
        } else if (op == 72 && count >= 4) {
            uint32_t id = S2A_SPV_ARG(1), member = S2A_SPV_ARG(2), dec = S2A_SPV_ARG(3);
            if (!id || id >= bound) { result = -1; goto done; }
            if (dec == 24 && member < 64) n[id].nonwritable_members |= UINT64_C(1) << member;
        } else if ((op >= 25 && op <= 30) || op == 32) {
            if (count < 2) { result = -1; goto done; }
            uint32_t id = S2A_SPV_ARG(1);
            if (!id || id >= bound) { result = -1; goto done; }
            n[id].op = op;
            if (op == 25) {
                if (count < 9) { result = -1; goto done; }
                n[id].sampled = S2A_SPV_ARG(7);
            } else if (op == 32) {
                if (count < 4) { result = -1; goto done; }
                n[id].target = S2A_SPV_ARG(3);
            } else if (op == 28 || op == 29) {
                if (count < 3) { result = -1; goto done; }
                n[id].target = S2A_SPV_ARG(2);
            } else if (op == 30) n[id].member_count = count - 2;
        } else if (op == 59) {
            if (count < 4) { result = -1; goto done; }
            uint32_t type = S2A_SPV_ARG(1), id = S2A_SPV_ARG(2);
            if (!id || id >= bound || !type || type >= bound) { result = -1; goto done; }
            n[id].variable = 1; n[id].target = type; n[id].storage = S2A_SPV_ARG(3);
        } else if (op == 65 || op == 66 || op == 67 || op == 70 || op == 83 || op == 169) {
            if (count < (op == 169 ? 6u : 4u)) { result = -1; goto done; }
            uint32_t id = S2A_SPV_ARG(2);
            if (!id || id >= bound) { result = -1; goto done; }
            n[id].op = op;
            n[id].target = S2A_SPV_ARG(op == 169 ? 4 : 3);
            if (op == 169) n[id].target2 = S2A_SPV_ARG(5);
        } else if (op == 62 || op == 63 || op == 64) {
            if (count < 2) { result = -1; goto done; }
            stores[nstores++] = S2A_SPV_ARG(1);
        }
        pos += count;
    }
    if (!vertex_entry) { result = -1; goto done; }
    for (size_t i = 0; i < nstores; i++)
        if (s2a_spv_store_target(n, bound, stores[i], 0)) { result = 1; goto done; }
    for (uint32_t i = 1; i < bound; i++) {
        if (!n[i].variable || (n[i].storage != 0 && n[i].storage != 2 && n[i].storage != 12)) continue;
        uint32_t id = n[i].target;
        unsigned hops = 0;
        while (id && id < bound && (n[id].op == 32 || n[id].op == 28 || n[id].op == 29) && hops++ < 64)
            id = n[id].target;
        if (!id || id >= bound || hops >= 64 || !n[id].op) { result = 1; goto done; }
        int buffer = n[i].storage == 12 || (n[i].storage == 2 && n[id].buffer_block);
        if (n[i].storage == 2 && !buffer) {
            if (n[id].op == 30 && n[id].block) continue;
            result = 1; goto done;
        }
        if (n[i].storage == 0) {
            if (n[id].op == 26 || n[id].op == 27) continue;
            if (n[id].op != 25) { result = 1; goto done; }
            if (n[id].sampled == 1) continue;
            if (n[id].sampled != 2) { result = 1; goto done; }
        }
        if (n[i].nonwritable || n[id].nonwritable) continue;
        if (buffer && n[id].op == 30 && n[id].member_count && n[id].member_count <= 64) {
            uint64_t need = n[id].member_count == 64 ? UINT64_MAX : (UINT64_C(1) << n[id].member_count) - 1;
            if ((n[id].nonwritable_members & need) == need) continue;
        }
        result = 1; goto done;
    }
done:
#undef S2A_SPV_ARG
    free(n);
    free(stores);
    return result;
}
