// 池迁移选择策略（宿主）：迁哪个池、在预算/上限/门槛下怎么选。
// 目标不是“迁得多”，而是“每 MB AHB 省最多每帧上传字节”。
#include <stdio.h>
#include <string.h>

#include "nvn/poolahb_policy.h"

static int g_fail, g_checks;
#define CHECK(c) do { g_checks++; if (!(c)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

#define MB (1ull << 20)

int main(void) {
    struct s2a_pa_candidate c[4];
    memset(c, 0, sizeof c);

    printf("  case %-30s", "empty");
    CHECK(s2a_pa_select(c, 0, 0, 64 * MB, 128 * MB) == -1);
    printf("ok\n");

    printf("  case %-30s", "skip_done_and_failed");
    {
        c[0].base = 0x1000; c[0].len = 64 * MB; c[0].bytes = 8 * MB; c[0].done = 1;
        c[1].base = 0x2000; c[1].len = 64 * MB; c[1].bytes = 9 * MB; c[1].failed = 1;
        CHECK(s2a_pa_select(c, 2, 0, 64 * MB, 512 * MB) == -1);
        printf("ok\n");
    }

    printf("  case %-30s", "respect_size_cap_and_budget");
    {
        memset(c, 0, sizeof c);
        c[0].len = 128 * MB; c[0].bytes = 64 * MB;          // 超单池上限
        c[1].len = 64 * MB;  c[1].bytes = 32 * MB;          // 超预算
        CHECK(s2a_pa_select(c, 2, 0, 64 * MB, 32 * MB) == -1);
        printf("ok\n");
    }

    printf("  case %-30s", "respect_min_bytes");
    {
        memset(c, 0, sizeof c);
        c[0].len = 4 * MB; c[0].bytes = 32 * 1024;          // 低于门槛
        CHECK(s2a_pa_select(c, 1, 64 * 1024, 64 * MB, 512 * MB) == -1);
        printf("ok\n");
    }

    printf("  case %-30s", "prefer_bytes_per_ahb_byte");
    {
        memset(c, 0, sizeof c);
        // 大池省字节多，但“每 MB AHB 省多少”低；小池比值高 → 选小池。
        c[0].len = 64 * MB; c[0].bytes = 8 * MB;    // 0.125 B/B
        c[1].len = 4 * MB;  c[1].bytes = 1 * MB;    // 0.25  B/B
        CHECK(s2a_pa_select(c, 2, 0, 64 * MB, 128 * MB) == 1);
        memset(c, 0, sizeof c);
        c[0].len = 64 * MB; c[0].bytes = 8 * MB;
        c[1].len = 64 * MB; c[1].bytes = 2 * MB;    // 比值相同？不，8>2 → 选 0
        CHECK(s2a_pa_select(c, 2, 0, 64 * MB, 256 * MB) == 0);
        printf("ok\n");
    }

    printf("  case %-30s", "tie_breaks_stable");
    {
        memset(c, 0, sizeof c);
        c[0].len = 8 * MB; c[0].bytes = 2 * MB;
        c[1].len = 8 * MB; c[1].bytes = 2 * MB;      // 完全并列 → 取下标小者（稳定、可复现）
        CHECK(s2a_pa_select(c, 2, 0, 64 * MB, 128 * MB) == 0);
        printf("ok\n");
    }

    printf("vk-poolahb-policy: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}
