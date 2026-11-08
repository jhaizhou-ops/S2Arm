// 纹理内存子分配的纯逻辑（无 Vulkan 依赖，生产与宿主反例共用）。
//
// 为什么要抽出来：第一版把「从空闲表切一段」写成先 `tab[i] = tab[--n]` 再读 `tab[i]`，
// 结果回填的是被搬过来那条的偏移 + 目标块的块号 → 之后按该块分配会拿到另一块的区间，
// 两张仍在使用的纹理重叠。另有「复用偏移没有按本次请求的 alignment 重新对齐」。
// 这两个都是只能靠反例守住的不变量：
//   I1 任何两次同时有效的分配区间不得重叠；
//   I2 返回的偏移满足本次请求的 alignment；
//   I3 释放的区间必须回到它所属块；
//   I4 切分后的余量仍在同一块里且可再分配。
#pragma once
#include <stdint.h>
#include <string.h>

#define S2A_SUB_MAX_BLOCKS 64
#define S2A_SUB_MAX_FREE 4096

struct s2a_sub_block {
    uint64_t size;      // 块大小（字节）
    uint64_t used;      // bump 高水位
    uint32_t type;      // 内存类型索引
    int live;
    int owner;          // 调用方的标识（测试用来核对回填到哪个块）
};

struct s2a_sub_range { uint64_t off, size; uint32_t type; int block; };

struct s2a_sub_allocator {
    struct s2a_sub_block blocks[S2A_SUB_MAX_BLOCKS];
    struct s2a_sub_range free_list[S2A_SUB_MAX_FREE];
    int free_n;
    int block_n;
};

static inline uint64_t s2a_sub_align_up(uint64_t v, uint64_t a) { return a ? (v + a - 1) / a * a : v; }

static inline void s2a_sub_init(struct s2a_sub_allocator *a) { memset(a, 0, sizeof *a); }

// 登记一个已经创建好的块；返回块号，-1 表示满。
static inline int s2a_sub_add_block(struct s2a_sub_allocator *a, uint32_t type, uint64_t size, int owner) {
    for (int i = 0; i < S2A_SUB_MAX_BLOCKS; i++) {
        struct s2a_sub_block *b = &a->blocks[i];
        if (b->live) continue;
        b->live = 1; b->size = size; b->used = 0; b->type = type; b->owner = owner;
        if (i + 1 > a->block_n) a->block_n = i + 1;
        return i;
    }
    return -1;
}

static inline void s2a_sub_push_free(struct s2a_sub_allocator *a, uint64_t off, uint64_t size, uint32_t type, int block) {
    if (!size) return;
    for (int i = 0; i < a->free_n; i++) {
        struct s2a_sub_range *r = &a->free_list[i];
        if (r->block != block || r->type != type) continue;
        if (r->off + r->size == off) { r->size += size; return; }
        if (off + size == r->off) { r->off = off; r->size += size; return; }
    }
    if (a->free_n < S2A_SUB_MAX_FREE)
        a->free_list[a->free_n++] = (struct s2a_sub_range){ off, size, type, block };
}

// 在指定块里切一段；成功返回 0 并写 *off。只从该块的空闲表或 bump 区取。
static inline int s2a_sub_alloc_in(struct s2a_sub_allocator *a, int block, uint64_t need, uint64_t align,
                                   uint64_t *off) {
    if (block < 0 || block >= S2A_SUB_MAX_BLOCKS || !a->blocks[block].live) return -1;
    const struct s2a_sub_block *b = &a->blocks[block];
    const uint64_t al = align ? align : 1;
    for (int i = 0; i < a->free_n; i++) {
        struct s2a_sub_range r = a->free_list[i];   // 先拷出来：摘除会覆盖本条
        if (r.block != block || r.type != b->type) continue;
        uint64_t start = s2a_sub_align_up(r.off, al);
        if (start + need > r.off + r.size) continue;
        const uint64_t end = r.off + r.size;
        // 摘除本条（用末条填补），拷贝值在覆盖之前已经取好，不会读到别人的数据
        a->free_list[i] = a->free_list[--a->free_n];
        if (start > r.off) s2a_sub_push_free(a, r.off, start - r.off, b->type, block);
        if (start + need < end) s2a_sub_push_free(a, start + need, end - (start + need), b->type, block);
        *off = start;
        return 0;
    }
    uint64_t start = s2a_sub_align_up(b->used, al);
    if (start + need > b->size) return -1;
    a->blocks[block].used = start + need;
    *off = start;
    return 0;
}

// 归还：必须回到它所属的那一块（调用方给 block 号）。
static inline void s2a_sub_free(struct s2a_sub_allocator *a, int block, uint64_t off, uint64_t size) {
    if (block < 0 || block >= S2A_SUB_MAX_BLOCKS || !a->blocks[block].live) return;
    s2a_sub_push_free(a, off, size, a->blocks[block].type, block);
}
