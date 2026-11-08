#pragma once
// NVN program 的源快照 pin 记账（header-only，hle_nvn.c 与宿主夹具共用同一份实现）。
//
// 每个 serial 一条：owner=第一次 pin 的 program 指针（用于区分按值拷贝）；
// released=该 serial 已 Finalize/换 SetShaders，之后任何 Bind 不得再挂 pin（防止永久泄漏）。
// ref 用 source_store 的 slot+seq 定位；重复 key 前缀在 host 侧先去重，不碰 store 的 g_mu。
#pragma once
#include <stdint.h>
#include <string.h>

#define NVN_PROGRAM_PIN_MAX 6

struct s2a_source_pin_ref {
    uint32_t slot;
    uint64_t seq;
    uint8_t key[8];
    uint8_t sha[32];
};

struct nvn_program_pins {
    uint8_t n;
    uint8_t released;
    const void *owner;
    struct s2a_source_pin_ref refs[NVN_PROGRAM_PIN_MAX];
};

static inline int nvn_program_pins_has_key(const struct nvn_program_pins *p, const uint8_t key[8]) {
    for (unsigned i = 0; i < p->n; i++)
        if (!memcmp(p->refs[i].key, key, 8)) return 1;
    return 0;
}

// SetShaders 建好该 serial 的条目后调用：owner 固定为调用 SetShaders 的原件。
// 之后游戏按值拷贝程序对象、拷贝先 Bind，prog_source_pin 的 owner 不得把原件挤掉；
// 原件 Finalize / 换 SetShaders 时才能按 owner 解掉这些 pin。已 released 的条目不再改归属。
static inline void nvn_program_pins_set_owner(struct nvn_program_pins *p, const void *owner) {
    if (!p->released) p->owner = owner;
}

// 返回 1=已加入，0=同 key 前缀已存在（调用方应撤销刚拿到的 pin），-1=已释放/无槽位。
static inline int nvn_program_pins_add(struct nvn_program_pins *p, const void *owner,
                                       const struct s2a_source_pin_ref *ref) {
    if (p->released) return -1;
    if (nvn_program_pins_has_key(p, ref->key)) return 0;
    if (p->n >= NVN_PROGRAM_PIN_MAX) return -1;
    if (!p->owner) p->owner = owner;
    p->refs[p->n++] = *ref;
    return 1;
}

// 只有 owner 匹配时才解 pin 并标记 released；拷贝对象调用时不动原件的 pin。
// 返回要归还给 source_store 的 ref 数（写入 out，最多 MAX）。
static inline int nvn_program_pins_release(struct nvn_program_pins *p, const void *owner,
                                           struct s2a_source_pin_ref out[NVN_PROGRAM_PIN_MAX]) {
    if (p->released || p->owner != owner) return 0;
    int n = p->n;
    if (n) memcpy(out, p->refs, (size_t)n * sizeof out[0]);
    p->n = 0;
    p->released = 1;
    return n;
}
