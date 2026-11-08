#include "poolahb_alias.h"

#include <string.h>

#define ALIAS_MAX 256

struct alias_ent { uint64_t src, dst, size; int used; };
static struct alias_ent g_alias[ALIAS_MAX];

int s2a_alias_note(uint64_t src, uint64_t dst, uint64_t size) {
    if (!size || src + size < src || dst + size < dst) return -1;
    for (int i = 0; i < ALIAS_MAX; i++) {
        if (g_alias[i].used && g_alias[i].src == src && g_alias[i].dst == dst && g_alias[i].size == size) return 0;
    }
    for (int i = 0; i < ALIAS_MAX; i++) {
        if (g_alias[i].used) continue;
        g_alias[i].used = 1; g_alias[i].src = src; g_alias[i].dst = dst; g_alias[i].size = size;
        return 0;
    }
    return -1;   // 表满：调用者应按“不可迁移”处理（保守）
}

void s2a_alias_drop(uint64_t dst) {
    for (int i = 0; i < ALIAS_MAX; i++)
        if (g_alias[i].used && g_alias[i].dst == dst) memset(&g_alias[i], 0, sizeof g_alias[i]);
}

int s2a_alias_conflict(uint64_t addr, uint64_t len) {
    if (!len) return 0;
    for (int i = 0; i < ALIAS_MAX; i++) {
        if (!g_alias[i].used) continue;
        // 来源区间或其他别名地址与本区间相交，都算冲突（换底会留下指向旧后备的地址）。
        const uint64_t ranges[2][2] = {
            { g_alias[i].src, g_alias[i].src + g_alias[i].size },
            { g_alias[i].dst, g_alias[i].dst + g_alias[i].size },
        };
        for (int k = 0; k < 2; k++)
            if (addr < ranges[k][1] && ranges[k][0] < addr + len) return 1;
    }
    return 0;
}

void s2a_alias_reset(void) { memset(g_alias, 0, sizeof g_alias); }
