// 描述符 set 的帧内复用缓存（纯 C，无 Vulkan 依赖，生产与宿主测试共用）。
//
// 目标：省掉重复的 vkAllocateDescriptorSets / vkUpdateDescriptorSets——只省这两个调用，
// 绑定与绘制照旧执行。资源解析、上传、同步仍然逐笔做，缓存不替代它们。
//
// 规则（缺一条都不安全）：
//  1. 键必须完整：#布局身份+代际、池代际、录制帧号、以及每个绑定的 (binding, 数组元素, 类型, 数量,
//     buffer 身份+offset+range / imageView+sampler 身份+imageLayout)。哈希只用于定位，
//     命中必须整键比较，不能只比 64 位指纹，也不能只比 guest 地址。
//  2. 命中直接借用原 set，不改写它；未命中才分配并完整初始化写入结构。
//  3. 已经被命令缓冲引用的 set 永不改写：同 buffer 不同 offset 是两条记录，不是一条。
//  4. 池 reset 时推进池代际，旧条目整体失效；淘汰只移除查找入口，在途引用的保活由提交记录负责。
//  5. 帧号只用于把复用限制在同一个录制帧内，不以帧边界代替 GPU 完成证明。
#pragma once
#include <stdint.h>
#include <string.h>

#define S2A_DESC_CACHE_MAX_BIND 16

// 一个 set 里一条绑定的比较字段。
struct s2a_desc_bind_key {
    uint32_t binding;
    uint32_t array_element;   // 单元素写入恒为 0，但必须进键（将来支持数组时不漏）
    uint32_t type;            // VkDescriptorType 的数值
    uint32_t count;
    uint64_t a;               // buffer: 对象身份；image: VkImageView
    uint64_t b;               // buffer: offset；image: VkSampler
    uint64_t c;               // buffer: range；image: imageLayout 与内容代际打包
};

struct s2a_desc_set_key {
    uint64_t layout;          // descriptor set layout 身份
    uint64_t layout_gen;      // 布局代际（布局重建会换代）
    uint64_t pool_gen;        // 描述符池代际（池 reset 会换代）
    uint32_t frame_seq;       // 录制帧号：复用只在一个录制帧内
    uint32_t nbind;
    uint64_t hash;
    struct s2a_desc_bind_key bind[S2A_DESC_CACHE_MAX_BIND];
};

struct s2a_desc_set_entry {
    struct s2a_desc_set_key key;
    uint64_t set;             // VkDescriptorSet 存成整数：本模块不依赖 Vulkan 头
    uint32_t valid;
};

static inline uint64_t s2a_desc_mix(uint64_t h, uint64_t v) {
    h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
    return h;
}

static inline uint64_t s2a_desc_key_hash(const struct s2a_desc_set_key *k) {
    uint64_t h = 1469598103934665603ull;
    h = s2a_desc_mix(h, k->layout);
    h = s2a_desc_mix(h, k->layout_gen);
    h = s2a_desc_mix(h, k->pool_gen);
    h = s2a_desc_mix(h, k->frame_seq);
    h = s2a_desc_mix(h, k->nbind);
    for (uint32_t i = 0; i < k->nbind; i++) {
        h = s2a_desc_mix(h, ((uint64_t)k->bind[i].binding << 32) | k->bind[i].array_element);
        h = s2a_desc_mix(h, ((uint64_t)k->bind[i].type << 32) | k->bind[i].count);
        h = s2a_desc_mix(h, k->bind[i].a);
        h = s2a_desc_mix(h, k->bind[i].b);
        h = s2a_desc_mix(h, k->bind[i].c);
    }
    return h;
}

// 整键比较：哈希只在定位阶段起作用，命中判定必须走这里。
static inline int s2a_desc_key_equal(const struct s2a_desc_set_key *x, const struct s2a_desc_set_key *y) {
    if (x->layout != y->layout || x->layout_gen != y->layout_gen || x->pool_gen != y->pool_gen ||
        x->frame_seq != y->frame_seq || x->nbind != y->nbind)
        return 0;
    for (uint32_t i = 0; i < x->nbind; i++) {
        const struct s2a_desc_bind_key *a = &x->bind[i], *b = &y->bind[i];
        if (a->binding != b->binding || a->array_element != b->array_element ||
            a->type != b->type || a->count != b->count ||
            a->a != b->a || a->b != b->b || a->c != b->c)
            return 0;
    }
    return 1;
}

// 开放寻址（线性探测）。返回命中条目或 NULL；*probe 返回可以登记的槽位。
static inline struct s2a_desc_set_entry *s2a_desc_cache_find(struct s2a_desc_set_entry *tab, uint32_t n,
                                                             const struct s2a_desc_set_key *key,
                                                             uint32_t *probe) {
    if (!tab || !n) return NULL;
    uint32_t i = (uint32_t)(key->hash & (n - 1));
    if (probe) *probe = i;
    // 探测上限：表满时全表扫描既慢又没意义（旧实现会退化成 O(n) 才判定未命中）。
    const uint32_t max_probe = n < 16u ? n : 16u;
    for (uint32_t step = 0; step < max_probe; step++) {
        struct s2a_desc_set_entry *e = &tab[(i + step) & (n - 1)];
        if (!e->valid) { if (probe) *probe = (i + step) & (n - 1); return NULL; }
        if (e->key.hash == key->hash && s2a_desc_key_equal(&e->key, key)) return e;
    }
    return NULL;
}

// 登记：只写查找入口。已被命令引用的 set 不会被改写（这里只覆盖自身的表项）。
static inline void s2a_desc_cache_store(struct s2a_desc_set_entry *tab, uint32_t n,
                                        const struct s2a_desc_set_key *key, uint64_t set) {
    if (!tab || !n) return;
    uint32_t slot = 0;
    if (s2a_desc_cache_find(tab, n, key, &slot)) return;   // 已有同名条目：不改写
    // 表满（探测链里没有空槽）时覆盖起始槽。这是“只增不删的开放寻址”的断链点：
    // 不覆盖就再也登记不进新键，缓存会永久退化为 0 命中。覆盖只丢提示，不影响任何在途 set。
    if (tab[slot].valid) {
        tab[slot].key = *key;
        tab[slot].key.hash = key->hash;
        tab[slot].set = set;
        return;
    }
    struct s2a_desc_set_entry *e = &tab[slot];
    e->key = *key;
    e->key.hash = key->hash;
    e->set = set;
    e->valid = 1;
}

// 池代际变化（reset）后整体失效：不是逐条删除，直接换代际，旧条目自然不再命中。
static inline void s2a_desc_cache_bump_generation(struct s2a_desc_set_key *key, uint64_t pool_gen) {
    key->pool_gen = pool_gen;
}
