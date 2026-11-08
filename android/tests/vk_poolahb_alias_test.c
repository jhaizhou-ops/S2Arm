// 别名登记与迁移前冲突判定（宿主）。
#include <stdio.h>
#include <string.h>

#include "nvn/poolahb_alias.h"

static int g_fail, g_checks;
#define CHECK(c) do { g_checks++; if (!(c)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void) {
    const uint64_t A = 0x1050000000ull, B = 0x2000000000ull, L = 0x100000ull;

    printf("  case %-30s", "no_alias_no_conflict");
    s2a_alias_reset();
    CHECK(s2a_alias_conflict(A, L) == 0);
    printf("ok\n");

    printf("  case %-30s", "alias_source_blocks_migration");
    s2a_alias_reset();
    CHECK(s2a_alias_note(A, B, L) == 0);
    CHECK(s2a_alias_conflict(A, L) == 1);          // 来源被别名
    CHECK(s2a_alias_conflict(B, L) == 1);          // 别名地址也冲突
    CHECK(s2a_alias_conflict(A + L, L) == 0);      // 相邻但不相交
    printf("ok\n");

    printf("  case %-30s", "partial_overlap_blocks");
    s2a_alias_reset();
    CHECK(s2a_alias_note(A, B, L) == 0);
    CHECK(s2a_alias_conflict(A + L - 0x1000, 0x2000) == 1);
    printf("ok\n");

    printf("  case %-30s", "drop_clears");
    s2a_alias_reset();
    CHECK(s2a_alias_note(A, B, L) == 0);
    s2a_alias_drop(B);
    CHECK(s2a_alias_conflict(A, L) == 0);
    printf("ok\n");

    printf("  case %-30s", "idempotent_note");
    s2a_alias_reset();
    for (int i = 0; i < 100; i++) CHECK(s2a_alias_note(A, B, L) == 0);
    CHECK(s2a_alias_conflict(A, L) == 1);
    printf("ok\n");

    printf("  case %-30s", "table_full_is_refused");
    s2a_alias_reset();
    int full = 0;
    for (int i = 0; i < 400; i++) {
        if (s2a_alias_note(0x1000000000ull + (uint64_t)i * 0x200000ull, 0x3000000000ull + (uint64_t)i * 0x200000ull, 0x1000) != 0) { full = 1; break; }
    }
    CHECK(full == 1);   // 表满要显式失败，调用者据此拒绝迁移（保守）
    printf("ok\n");

    printf("vk-poolahb-alias: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}
