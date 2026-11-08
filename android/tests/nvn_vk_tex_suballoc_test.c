// 纹理子分配的反例（宿主，纯逻辑）：块归属、对齐、切分余量、区间不重叠。
#include <stdio.h>
#include <string.h>
#include "nvn_vk_tex_suballoc.h"

static int fails;
static void check(int cond, const char *what) {
    printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
    if (!cond) fails++;
}

int main(void) {
    struct s2a_sub_allocator a;
    uint64_t off_a = 0, off_b = 0, off_b2 = 0;

    printf("== 纹理子分配 ==\n");
    s2a_sub_init(&a);
    int A = s2a_sub_add_block(&a, /*type*/ 1, 4096, /*owner*/ 100);
    int B = s2a_sub_add_block(&a, /*type*/ 1, 4096, /*owner*/ 200);
    check(A >= 0 && B >= 0 && A != B, "两个块各自登记");

    // 1) 基本分配
    check(s2a_sub_alloc_in(&a, A, 256, 256, &off_a) == 0 && off_a % 256 == 0, "A 块 256B/256 对齐");
    check(s2a_sub_alloc_in(&a, B, 512, 512, &off_b) == 0 && off_b % 512 == 0, "B 块 512B/512 对齐");

    // 2) 释放 B 的区间后，再从 B 分配必须回到 B（不能串到 A）
    s2a_sub_free(&a, B, off_b, 512);
    check(s2a_sub_alloc_in(&a, B, 512, 512, &off_b2) == 0, "从 B 重新分配成功");
    check(off_b2 == off_b, "重新分配回到 B 的同一段");

    // 3) 对齐：空闲区间起点只 256 对齐时，请求 512 必须重对齐（旧的空测释放偏移 0，本就 512 对齐，
    //    把 s2a_sub_alloc_in 里的 s2a_sub_align_up 去掉照样绿，维护方 11-04 复审判为空测）。
    {
        struct s2a_sub_allocator al;
        s2a_sub_init(&al);
        int A2 = s2a_sub_add_block(&al, 1, 4096, 100);
        uint64_t s1 = 0, s2 = 0, x = 0;
        check(s2a_sub_alloc_in(&al, A2, 256, 256, &s1) == 0 && s1 == 0, "对齐用例：A 第一段 256B/256（偏移 0）");
        check(s2a_sub_alloc_in(&al, A2, 256, 256, &s2) == 0 && s2 == 256, "对齐用例：A 第二段 256B/256（偏移 256）");
        s2a_sub_free(&al, A2, s2, 256);                  // 空闲区间起点 256：只 256 对齐
        check(s2a_sub_alloc_in(&al, A2, 128, 512, &x) == 0, "对齐用例：A 内 512 对齐分配成功");
        check(x % 512 == 0, "对齐用例：返回偏移满足 512 对齐（空闲起点 256，必须重对齐）");
    }

    // 4) 切分余量仍可再分配，且不重叠
    {
        uint64_t p = 0, q = 0;
        struct s2a_sub_allocator b2;
        s2a_sub_init(&b2);
        int C = s2a_sub_add_block(&b2, 2, 8192, 300);
        check(s2a_sub_alloc_in(&b2, C, 1024, 64, &p) == 0, "C 块首个 1024B");
        check(s2a_sub_alloc_in(&b2, C, 1024, 64, &q) == 0, "C 块第二个 1024B（bump 区）");
        check(p + 1024 <= q, "两块区间不重叠");
        s2a_sub_free(&b2, C, p, 1024);                   // 归还首段
        uint64_t r = 0;
        check(s2a_sub_alloc_in(&b2, C, 1024, 64, &r) == 0, "归还后能再切");
        check(r == p, "复用归还的那一段");
    }

    // 5) 跨块不串：B 的空闲区间不能被 A 的请求命中
    {
        struct s2a_sub_allocator c;
        s2a_sub_init(&c);
        int X = s2a_sub_add_block(&c, 3, 2048, 1);
        int Y = s2a_sub_add_block(&c, 3, 2048, 2);
        uint64_t oy = 0, ox = 0, oy2 = 0;
        check(s2a_sub_alloc_in(&c, Y, 512, 512, &oy) == 0, "Y 块分配一段");
        s2a_sub_free(&c, Y, oy, 512);                       // Y 空闲表出现一段
        check(s2a_sub_alloc_in(&c, X, 512, 512, &ox) == 0, "X 块分配（走自己的 bump 区）");
        // 真正的判据：向 Y 再要一次，必须还能拿到刚才归还的那一段 —— 说明 X 的分配没吃掉 Y 的空闲区间。
        check(s2a_sub_alloc_in(&c, Y, 512, 512, &oy2) == 0 && oy2 == oy,
              "X 的分配没有吃掉 Y 的空闲区间（跨块不串）");
    }

    // 6) 块满时失败而不是越界
    {
        struct s2a_sub_allocator d;
        s2a_sub_init(&d);
        int D = s2a_sub_add_block(&d, 4, 1024, 9);
        uint64_t o = 0;
        check(s2a_sub_alloc_in(&d, D, 1024, 1, &o) == 0, "刚好占满");
        check(s2a_sub_alloc_in(&d, D, 1, 1, &o) != 0, "再要就失败（不越界）");
    }
    printf("%s\n", fails ? "nvn-vk-tex-suballoc: 失败" : "nvn-vk-tex-suballoc: 通过");
    return fails ? 1 : 0;
}
