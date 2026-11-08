// NVN 稀疏虚拟池别名区间表：只做区间切分与 ref/unref 记账，不碰任何锁。
#include "s2a_vp_alias.h"
#include "../runtime/vm/backing.h"
#include "../../../runtime/src/native.h"   // die
#include "../../../platform/plat.h"                    // plat_page_size

#include <errno.h>
#include <stdlib.h>
#include <string.h>

// 入口不变量（interface owner #6567620762 ③）：进表的每条记录 [lo,hi) 和源地址都必须按宿主页对齐。
// hle_nvn.c 的 vpool_map 先在 :2836 早退，把 4K 对齐但宿主页不对齐（如 16K 宿主上的 4K）或越界的请求
// 只记进页表；若这里仍看到不对齐的区间，说明调用方违约，后面的切段 unref 会拿错源地址，必须响亮中止。
static size_t alias_page_or_die(const char *op) {
    size_t page = plat_page_size();
    if (!page) die("NVN 别名表 %s：宿主页不可用", op);
    return page;
}
static void alias_require_page_aligned(const char *op, size_t page, uint64_t lo, uint64_t hi, uint64_t src) {
    if ((lo | hi | src) & (uint64_t)(page - 1))
        die("NVN 别名表 %s 调用方违约：区间 / 源未按宿主页（%zu）对齐 %#llx+%#llx src=%#llx",
            op, page, (unsigned long long)lo, (unsigned long long)hi, (unsigned long long)src);
}

static int alias_reserve(s2a_vp_alias_table *table, int need) {
    if (need <= table->cap) return 0;
    int capacity = table->cap ? table->cap : 8;
    while (capacity < need) {
        if (capacity > INT32_MAX / 2) return ENOMEM;
        capacity *= 2;
    }
    s2a_vp_alias *next = realloc(table->v, (size_t)capacity * sizeof *next);
    if (!next) return ENOMEM;
    table->v = next;
    table->cap = capacity;
    return 0;
}

void s2a_vp_alias_remove(s2a_vp_alias_table *table, uint64_t lo, uint64_t hi) {
    if (!table || hi <= lo) return;
    size_t page = alias_page_or_die("remove");
    alias_require_page_aligned("remove", page, lo, hi, 0);
    int write = 0;
    for (int i = 0; i < table->n; i++) {
        s2a_vp_alias e = table->v[i];
        if (e.hi <= lo || e.lo >= hi) { table->v[write++] = e; continue; }
        // 切掉的交集必须 unref 对应源地址：旧映射被新请求覆盖，源页不再需要这段引用。
        uint64_t cut_lo = e.lo > lo ? e.lo : lo;
        uint64_t cut_hi = e.hi < hi ? e.hi : hi;
        uint64_t cut_src = e.src + (cut_lo - e.lo);
        if (((cut_lo | cut_hi | cut_src) & (uint64_t)(page - 1)))
            die("NVN 别名表 remove：记录内部未按宿主页（%zu）对齐 %#llx+%#llx src=%#llx（表已损坏）",
                page, (unsigned long long)cut_lo, (unsigned long long)cut_hi, (unsigned long long)cut_src);
        s2a_mem_backing_alias_unref(cut_src, cut_hi - cut_lo);
        if (e.lo < cut_lo) { s2a_vp_alias left = e; left.hi = cut_lo; table->v[write++] = left; }
        if (e.hi > cut_hi) { s2a_vp_alias right = e; right.lo = cut_hi; right.src = e.src + (cut_hi - e.lo); table->v[write++] = right; }
    }
    table->n = write;
}

int s2a_vp_alias_add(s2a_vp_alias_table *table, uint64_t lo, uint64_t hi, uint64_t src) {
    if (!table || hi <= lo) return EINVAL;
    size_t page = alias_page_or_die("add");
    alias_require_page_aligned("add", page, lo, hi, src);
    s2a_vp_alias_remove(table, lo, hi);
    int error = alias_reserve(table, table->n + 1);
    if (error) return error;
    int at = table->n;
    while (at > 0 && table->v[at - 1].lo > lo) at--;
    memmove(&table->v[at + 1], &table->v[at], (size_t)(table->n - at) * sizeof *table->v);
    table->v[at] = (s2a_vp_alias){lo, hi, src};
    table->n++;
    return 0;
}

void s2a_vp_alias_clear(s2a_vp_alias_table *table) {
    if (!table) return;
    for (int i = 0; i < table->n; i++)
        s2a_mem_backing_alias_unref(table->v[i].src, table->v[i].hi - table->v[i].lo);
    free(table->v);
    memset(table, 0, sizeof *table);
}
