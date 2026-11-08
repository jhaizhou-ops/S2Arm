// 活 nvnBuffer 区间表：按缓冲 CPU 起点登记 {起点, 长度}，按地址查「地址落在哪个活缓冲里」。
//   用途：NVN storage 绑定只给地址、size=0 时，安卓 Vulkan 回放按地址求精确长度（hle_nvn.c nvn_buf_extent → nvn_vk_mrt.c）。
//   11-07 时之笛 Switch 2 室外 30 → 5–6 帧：原实现是无序数组 + 写锁下线性扫描，BufferInitialize / Finalize 各 O(活缓冲数)，
//   游戏每帧大量建删缓冲 → 游戏线程 49% / 47% 耗在两个入口（37.6% 等写锁）。这里换成按起点有序的树堆（treap，随机优先级的二叉搜索树），
//   每个结点带「子树内最大终点」，登记 / 注销 / 查询都是期望 O(log n)。
// 语义（与原表一致处）：键 = 起点，同起点再登记 = 改长度；注销不存在的起点无事；size = 0 或起点 0 不登记。
// 语义（原表未定义处，定下来）：多个活缓冲重叠覆盖同一地址时，取起点最大（离地址最近）的那个——游戏算地址是「缓冲地址 + 偏移」，
//   最近的起点就是最具体的那个缓冲；原表是无序数组首个命中，结果随建删顺序漂移。
// 表本身不加锁：调用方用下面的 nvn_breg_lock 保护（同 nvn_hmap.h 的口径）。单测 graphics/nvn/tests/t_buf_reg.c、t_nvn_bufreg_rate.m。
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <stdatomic.h>

typedef struct { uint64_t base, size, mx; uint32_t l, r, pri; } nvn_breg_node;   // mx = 子树内最大终点（终点 = 起点 + 长度，饱和到 UINT64_MAX）
typedef struct { nvn_breg_node *a; uint32_t cap, root, free_, n; uint32_t rng; } nvn_breg;   // a[0] 是空结点哨兵；free_ = 空闲链表头（经 l 串起来）

static inline void nvn_breg_init(nvn_breg *t) { memset(t, 0, sizeof *t); t->rng = 0x9e3779b9u; }
static inline void nvn_breg_free(nvn_breg *t) { free(t->a); nvn_breg_init(t); }
static inline uint64_t nvn_breg_end(uint64_t b, uint64_t n) { return b + n < b ? UINT64_MAX : b + n; }
static inline void nvn_breg_pull(nvn_breg *t, uint32_t x) {
    nvn_breg_node *a = t->a; uint64_t m = nvn_breg_end(a[x].base, a[x].size);
    if (a[x].l && a[a[x].l].mx > m) m = a[a[x].l].mx;
    if (a[x].r && a[a[x].r].mx > m) m = a[a[x].r].mx;
    a[x].mx = m;
}
// 拆分：x 拆成 {起点 < k 或 ≤ k（le = 1）} 与其余；结果写 *L / *R
static inline void nvn_breg_split(nvn_breg *t, uint32_t x, uint64_t k, int le, uint32_t *L, uint32_t *R) {
    if (!x) { *L = *R = 0; return; }
    if (t->a[x].base < k || (le && t->a[x].base == k)) { nvn_breg_split(t, t->a[x].r, k, le, &t->a[x].r, R); *L = x; }
    else { nvn_breg_split(t, t->a[x].l, k, le, L, &t->a[x].l); *R = x; }
    nvn_breg_pull(t, x);
}
static inline uint32_t nvn_breg_merge(nvn_breg *t, uint32_t x, uint32_t y) {   // x 的键全小于 y
    if (!x || !y) return x ? x : y;
    if (t->a[x].pri > t->a[y].pri) { t->a[x].r = nvn_breg_merge(t, t->a[x].r, y); nvn_breg_pull(t, x); return x; }
    t->a[y].l = nvn_breg_merge(t, x, t->a[y].l); nvn_breg_pull(t, y); return y;
}
// 注销起点 = base 的项（不存在则无事）
static inline void nvn_breg_del(nvn_breg *t, uint64_t base) {
    if (!t->root) return;
    uint32_t L, M, R; nvn_breg_split(t, t->root, base, 0, &L, &M); nvn_breg_split(t, M, base, 1, &M, &R);
    if (M) { t->a[M].l = t->free_; t->free_ = M; t->n--; }   // 键唯一：M 至多一个结点
    t->root = nvn_breg_merge(t, L, R);
}
// 登记 / 改长度；内存不够返回 0（该起点不在表里，查询退回调用方的池尾近似）
static inline int nvn_breg_put(nvn_breg *t, uint64_t base, uint64_t size) {
    if (!base || !size) return 1;
    nvn_breg_del(t, base);   // 同起点 = 改长度：先摘掉旧项（O(log n)），下面按新长度插回
    if (!t->free_) {   // 空闲链表空 = 1..cap-1 全占用：容量翻倍，新槽串进空闲链表（下标稳定，realloc 不影响树）
        uint32_t oc = t->cap, nc = oc ? oc * 2 : 1024;
        nvn_breg_node *na = realloc(t->a, (size_t)nc * sizeof *na);
        if (!na) return 0;
        if (!oc) { memset(&na[0], 0, sizeof na[0]); oc = 1; }
        for (uint32_t i = nc - 1; i >= oc; i--) { na[i].l = t->free_; t->free_ = i; }
        t->a = na; t->cap = nc;
    }
    uint32_t y = t->free_; t->free_ = t->a[y].l;
    t->rng ^= t->rng << 13; t->rng ^= t->rng >> 17; t->rng ^= t->rng << 5;
    t->a[y] = (nvn_breg_node){base, size, nvn_breg_end(base, size), 0, 0, t->rng};
    uint32_t L, R; nvn_breg_split(t, t->root, base, 0, &L, &R);
    t->root = nvn_breg_merge(t, nvn_breg_merge(t, L, y), R);
    t->n++;
    return 1;
}
// 查询：addr 落在某个活缓冲 [起点, 终点) 里时，返回起点最大的那个结点下标（0 = 不在任何活缓冲里）
static inline uint32_t nvn_breg_find_in(const nvn_breg *t, uint32_t x, uint64_t addr) {
    const nvn_breg_node *a = t->a;
    while (x && a[x].mx > addr) {
        if (a[x].base > addr) { x = a[x].l; continue; }   // 本结点与右子树起点都 > addr
        uint32_t r = a[x].r;                               // 右子树起点更大：先找那里（只有 mx > addr 才可能命中）
        if (r && a[r].mx > addr) { uint32_t h = nvn_breg_find_in(t, r, addr); if (h) return h; }
        if (nvn_breg_end(a[x].base, a[x].size) > addr) return x;
        x = a[x].l;
    }
    return 0;
}
static inline int nvn_breg_find(const nvn_breg *t, uint64_t addr, uint64_t *base, uint64_t *size) {
    uint32_t x = t->root ? nvn_breg_find_in(t, t->root, addr) : 0;
    if (!x) return 0;
    *base = t->a[x].base; *size = t->a[x].size;
    return 1;
}

// 轻量锁：抢不到先自旋（只读不写，不抢缓存行），自旋 64 次还没放就 sched_yield 让出核，避免持锁线程被抢占时空转。
//   临界区只有一次树操作（百纳秒级），争用时比进内核排队交接快一个量级；纯 C11 原子，安卓 / 苹果同一份。
static inline void nvn_breg_lock(_Atomic int *l) {
    for (;;) {
        if (!atomic_exchange_explicit(l, 1, memory_order_acquire)) return;
        for (int n = 0; atomic_load_explicit(l, memory_order_relaxed); ) if (++n >= 64) { sched_yield(); n = 0; }
    }
}
static inline void nvn_breg_unlock(_Atomic int *l) { atomic_store_explicit(l, 0, memory_order_release); }
