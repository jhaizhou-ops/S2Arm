// 池后备“可否迁移”的地址覆盖判定（宿主，用临时 maps 文本，不碰真实进程映射）。
// 为什么要单独测：这条判定直接决定迁移能不能做，而且真实 maps 里出现 r--p（脏页跟踪把页设只读）
// 是常态——要求“每段都是 rw”会把大多数热池误拒（本机实测 5 个热池全被判失败）。
#include <stdio.h>
#include <string.h>

#include "nvn/poolahb_cover.h"

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static const char *write_maps(const char *name, const char *text) {
    static char path[256];
    snprintf(path, sizeof path, "/tmp/vk_poolahb_%s.maps", name);
    FILE *f = fopen(path, "wb");
    if (!f) return NULL;
    fputs(text, f);
    fclose(f);
    return path;
}

int main(void) {
    const uint64_t B = 0x1050000000ull, L = 0x4000000ull;   // 64 MiB 池：B..B+0x4000000 = 1050000000..1054000000

    printf("  case %-32s", "single_rw_block");
    {
        const char *p = write_maps("single", "1050000000-1054000000 rw-p 00000000 00:00 0 \n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "multi_segment_with_ro_pages");
    {
        // 三段连续；中间一段是 r--p（脏页跟踪把池里的页设成只读）——必须接受。
        const char *p = write_maps("ro",
            "104c000000-1050000000 rw-p 0 0 0 \n"
            "1050000000-1051000000 rw-p 0 0 0 \n"
            "1051000000-1052000000 r--p 0 0 0 \n"
            "1052000000-1054000000 rw-p 0 0 0 \n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "hole_inside_range_rejected");
    {
        // 中间缺一段：不能迁（否则会把池外的页一起换掉/踩到空洞）。
        const char *p = write_maps("hole",
            "1050000000-1051000000 rw-p 0 0 0 \n"
            "1052000000-1054000000 rw-p 0 0 0 \n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 0);
        printf("ok\n");
    }

    printf("  case %-32s", "not_covering_end_rejected");
    {
        const char *p = write_maps("short", "1050000000-1053000000 rw-p 0 0 0 \n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 0);
        printf("ok\n");
    }

    printf("  case %-32s", "shared_backing_rejected");
    {
        // dmabuf / ashmem / apk 这类文件后备不能被“替页”当成普通匿名内存。
        // 非 kgsl 的设备映射（dma-heap/dma-buf 这类）不当作可替页的 guest 内存
        const char *p1 = write_maps("dmabuf", "1050000000-1054000000 rw-s 0 0 1 /dev/dma_heap/system\n");
        CHECK(s2a_poolahb_cover_check_path(p1, B, L) == 0);
        // ashmem 形态的 guest RAM 是允许的（本机可能是 /dev/ashmem 或 /dev/zero），单独在下面断言
        const char *p3 = write_maps("so", "1050000000-1054000000 r--p 0 0 1 /data/app/x/base.apk!/lib/arm64-v8a/libfoo.so\n");
        CHECK(s2a_poolahb_cover_check_path(p3, B, L) == 0);
        printf("ok\n");
    }

    printf("  case %-32s", "prefix_mapping_still_ok");
    {
        // 池前面还有一段别的映射：只要池本身连续覆盖就行。
        const char *p = write_maps("prefix",
            "104c000000-1050000000 rw-p 0 0 0 \n"
            "1050000000-1054000000 rw-p 0 0 0 \n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "kgsl_guest_ram_accepted");
    {
        // 本机 guest RAM 就是 /dev/kgsl-3d0 的共享映射（rw-s / r--s 混排），必须接受。
        const char *p = write_maps("kgsl",
            "105c000000-105d014000 rw-s 00000000 00:0f 1404 /dev/kgsl-3d0\n"
            "105d014000-105d018000 r--s 00000000 00:0f 1404 /dev/kgsl-3d0\n"
            "105d018000-1060000000 rw-s 00000000 00:0f 1404 /dev/kgsl-3d0\n");
        CHECK(s2a_poolahb_cover_check_path(p, 0x105c000000ull, 0x4000000ull) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "dev_zero_guest_ram_accepted");
    {
        // 本机 guest RAM 形态：/dev/zero (deleted) 共享映射，r--s / rw-s 交替（跟踪器把页设只读）。
        const char *p = write_maps("devzero",
            "105c000000-105d014000 rw-s 00000000 00:01 1774498 /dev/zero (deleted)\n"
            "105d014000-105d018000 r--s 01014000 00:01 1774498 /dev/zero (deleted)\n"
            "105d018000-1060000000 rw-s 01018000 00:01 1774498 /dev/zero (deleted)\n");
        CHECK(s2a_poolahb_cover_check_path(p, 0x105c000000ull, 0x4000000ull) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "ashmem_guest_ram_accepted");
    {
        const char *p = write_maps("ashmem2", "1050000000-1054000000 rw-s 0 0 1 /dev/ashmem/foo\n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "memfd_guest_ram_accepted");
    {
        // main 7ff542ea2 起 guest RAM 是 memfd_create("s2a-guest") 注入背板：
        // maps 里为 /memfd:s2a-guest (deleted)，r--s / rw-s 交替（跟踪器把页设只读）。必须接受，
        // 否则合并最新 main 后所有池都判“覆盖不足”，零拷贝静默失效（实测 8 个池全 failed）。
        const char *p = write_maps("memfdguest",
            "105c000000-105d014000 rw-s 105c000000 00:01 1926823 /memfd:s2a-guest (deleted)\n"
            "105d014000-105d018000 r--s 105d014000 00:01 1926823 /memfd:s2a-guest (deleted)\n"
            "105d018000-1060000000 rw-s 105d018000 00:01 1926823 /memfd:s2a-guest (deleted)\n");
        CHECK(s2a_poolahb_cover_check_path(p, 0x105c000000ull, 0x4000000ull) == 1);
        printf("ok\n");
    }

    printf("  case %-32s", "memfd_other_rejected");
    {
        // 只放行自家 guest 背板；别的 memfd（别的组件/进程共享）仍不可替页。
        const char *p = write_maps("memfdother", "1050000000-1054000000 rw-s 0 0 1 /memfd:some-other (deleted)\n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 0);
        printf("ok\n");
    }

    printf("  case %-32s", "dma_heap_rejected");
    {
        const char *p = write_maps("dmaheap", "1050000000-1054000000 rw-s 0 0 1 /dev/dma_heap/system\n");
        CHECK(s2a_poolahb_cover_check_path(p, B, L) == 0);
        printf("ok\n");
    }

    // 别名判定不在这里做：本机 guest RAM 是 /dev/kgsl-3d0 共享映射，所有段共享同一 dev/inode 且 offset 恒 0，
    // 用 maps 判别名会把所有映射都当成同一对象。别名由受控登记表（poolahb_alias.c）回答，见 vk_poolahb_alias_test。

    printf("vk-poolahb-cover: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}
