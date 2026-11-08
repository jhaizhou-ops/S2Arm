// NVN ReadTexels 的几何/打包换算宿主单测（纯逻辑，无 Vulkan / 无真机）。
//
// 覆盖：区域与子资源原样落到 plan（x/y/z、width/height/depth、level、layer0）；
// NVN 行距/层距语义（row/img = 0 的默认值、非 0 的 padding、小于紧排必须失败）；
// 块压缩格式的块对齐与块行字节；2D 数组 / 立方体数组 / 3D 的层与切片映射；
// 越界（level、区域、层）与格式无字节数的失败路径都给出可定位原因。
// 只编 nvn_vk_readback_plan.c（生产实现与真机路径共用）。
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvn_vk_readback_plan.h"

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; \
    printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CASE(name) do { printf("  case %-46s", name); } while (0)
#define END_CASE() do { printf("\n"); } while (0)

// NVN 目标 / 格式常量（与 nvn.h 同值）。
enum { T_1D = 0, T_2D = 1, T_3D = 2, T_1D_ARRAY = 3, T_2D_ARRAY = 4, T_CUBE = 8, T_CUBE_ARRAY = 9 };
enum { FMT_RGBA8 = 0x25, FMT_BC4 = 0x4B, FMT_ASTC_4x4 = 0x79 };

static struct nvn_vk_rb_desc desc(uint32_t fmt, int32_t target, int32_t bpb, int32_t bw, int32_t bh,
                                  uint32_t w, uint32_t h, uint32_t d, uint32_t levels, uint32_t layers) {
    struct nvn_vk_rb_desc o;
    memset(&o, 0, sizeof o);
    o.nvn_format = fmt; o.target = target; o.bpb = bpb; o.bw = bw; o.bh = bh;
    o.width = w; o.height = h; o.depth = d; o.levels = levels; o.layers = layers;
    return o;
}

static struct nvn_vk_rb_region region(int32_t x, int32_t y, int32_t z, int32_t w, int32_t h, int32_t d) {
    struct nvn_vk_rb_region o;
    o.x = x; o.y = y; o.z = z; o.width = w; o.height = h; o.depth = d;
    return o;
}

static int plan_ok(const struct nvn_vk_rb_desc *d, unsigned level, unsigned layer0,
                   const struct nvn_vk_rb_region *r, size_t row, size_t img,
                   struct nvn_vk_rb_plan *out) {
    char why[NVN_VK_RB_WHY_MAX] = "";
    int rc = nvn_vk_readback_plan(d, level, layer0, r, row, img, out, why, sizeof why);
    if (rc && !why[0]) {
        printf("    FAIL: plan failed without a reason\n");
        g_fail++;
    }
    return rc;
}

static int plan_fails(const struct nvn_vk_rb_desc *d, unsigned level, unsigned layer0,
                      const struct nvn_vk_rb_region *r, size_t row, size_t img, const char *want) {
    struct nvn_vk_rb_plan p;
    char why[NVN_VK_RB_WHY_MAX] = "";
    if (nvn_vk_readback_plan(d, level, layer0, r, row, img, &p, why, sizeof why) == 0) {
        printf("    FAIL: expected failure (%s), plan succeeded\n", want);
        g_fail++;
        return 0;
    }
    if (!why[0]) {
        printf("    FAIL: failure without a reason (want %s)\n", want);
        g_fail++;
        return 0;
    }
    if (want && !strstr(why, want)) {
        printf("    FAIL: reason does not mention %s: %s\n", want, why);
        g_fail++;
        return 0;
    }
    return 1;
}

int main(void) {
    struct nvn_vk_rb_plan p;
    struct nvn_vk_rb_slice s;
    struct nvn_vk_rb_desc d;
    struct nvn_vk_rb_region r;

    // 1. 2D RGBA8 整幅：row/img 默认按紧排；只有一层。
    END_CASE();
    CASE("2d rgba8 full image defaults");
    d = desc(FMT_RGBA8, T_2D, 4, 1, 1, 1024, 1024, 1, 1, 1);
    r = region(0, 0, 0, 1024, 1024, 0);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.level == 0 && p.layer0 == 0 && !p.is3d);
    CHECK(p.level_w == 1024 && p.level_h == 1024 && p.nz == 1);
    CHECK(p.block_cols == 1024 && p.block_rows == 1024);
    CHECK(p.copy_row_bytes == 4096 && p.copy_bytes == 1024u * 4096u);
    CHECK(p.dst_row == 4096 && p.dst_img == 1024u * 4096u);
    CHECK(p.staging_stride == 1024u * 4096u && p.staging_bytes == 1024u * 4096u);
    nvn_vk_readback_slice(&p, 0, &s);
    CHECK(s.image_layer == 0 && s.image_z == 0 && s.dst_offset == 0 && s.staging_offset == 0);
    CHECK(nvn_vk_readback_dst_extent(&p) == 1024u * 4096u);

    // 2. 2D 子区域 + 显式行距/层距：偏移原样落地，不退回整幅。
    END_CASE();
    CASE("2d sub-region with strided dst");
    d = desc(FMT_RGBA8, T_2D, 4, 1, 1, 1024, 1024, 1, 1, 1);
    r = region(16, 32, 0, 64, 8, 1);
    CHECK(plan_ok(&d, 0, 0, &r, 512, 8192, &p) == 0);
    CHECK(p.x == 16 && p.y == 32 && p.w == 64 && p.h == 8 && p.z == 0);
    CHECK(p.block_cols == 64 && p.block_rows == 8);
    CHECK(p.copy_row_bytes == 256 && p.copy_bytes == 2048);
    CHECK(p.dst_row == 512 && p.dst_img == 8192);
    CHECK(nvn_vk_readback_dst_extent(&p) == 7u * 512u + 256u);

    // 3. 2D 子区域 row/img = 0：默认只按区域紧排（不是整幅）。
    END_CASE();
    CASE("2d sub-region default strides are region-tight");
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.dst_row == 256 && p.dst_img == 8u * 256u);

    // 4. mip level 改变 level 尺寸与区域上界。
    END_CASE();
    CASE("mip level dims");
    d = desc(FMT_RGBA8, T_2D, 4, 1, 1, 1024, 512, 1, 11, 1);
    r = region(0, 0, 0, 128, 64, 1);
    CHECK(plan_ok(&d, 3, 0, &r, 0, 0, &p) == 0);
    CHECK(p.level_w == 128 && p.level_h == 64);
    CHECK(p.copy_row_bytes == 512 && p.copy_bytes == 64u * 512u);

    // 5. 2D 数组：layer0 + zoffset 落成 image_layer，img 距按层累加。
    END_CASE();
    CASE("2d array layer mapping");
    d = desc(FMT_RGBA8, T_2D_ARRAY, 4, 1, 1, 64, 64, 1, 1, 8);
    r = region(0, 0, 1, 64, 64, 2);
    CHECK(plan_ok(&d, 0, 2, &r, 0, 0, &p) == 0);
    CHECK(p.nz == 2 && p.dst_img == 64u * 64u * 4u);
    nvn_vk_readback_slice(&p, 0, &s);
    CHECK(s.image_layer == 3 && s.image_z == 0 && s.dst_offset == 0);
    nvn_vk_readback_slice(&p, 1, &s);
    CHECK(s.image_layer == 4 && s.image_z == 0 && s.dst_offset == p.dst_img);
    CHECK(nvn_vk_readback_dst_extent(&p) == p.dst_img + 63u * p.dst_row + p.copy_row_bytes);

    // 6. 立方体数组：层号就是面号（同一套 layer0 + z 映射）。
    END_CASE();
    CASE("cubemap array face mapping");
    d = desc(FMT_RGBA8, T_CUBE_ARRAY, 4, 1, 1, 32, 32, 1, 1, 12);
    r = region(0, 0, 3, 32, 32, 2);
    CHECK(plan_ok(&d, 0, 6, &r, 0, 0, &p) == 0);
    nvn_vk_readback_slice(&p, 0, &s);
    CHECK(s.image_layer == 9);
    nvn_vk_readback_slice(&p, 1, &s);
    CHECK(s.image_layer == 10);

    // 7. 3D：zoffset 落成 imageOffset.z，层号恒 0；mip 后 depth 也收缩。
    END_CASE();
    CASE("3d slice mapping with mip");
    d = desc(FMT_RGBA8, T_3D, 4, 1, 1, 64, 32, 16, 5, 1);
    r = region(0, 0, 2, 64, 32, 3);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.is3d && p.level_w == 64 && p.level_h == 32 && p.level_d == 16 && p.nz == 3);
    for (unsigned i = 0; i < 3; i++) {
        nvn_vk_readback_slice(&p, i, &s);
        CHECK(s.image_layer == 0 && s.image_z == 2 + i && s.dst_offset == i * p.dst_img);
    }
    d = desc(FMT_RGBA8, T_3D, 4, 1, 1, 64, 32, 16, 5, 1);
    r = region(0, 0, 0, 32, 16, 4);
    CHECK(plan_ok(&d, 1, 0, &r, 0, 0, &p) == 0);
    CHECK(p.level_w == 32 && p.level_h == 16 && p.level_d == 8 && p.nz == 4);

    // 8. 块压缩（BC4 4x4，8 B/块）：块行字节 = 块列数 x 8；区域按块对齐。
    END_CASE();
    CASE("bc4 block geometry");
    d = desc(FMT_BC4, T_2D, 8, 4, 4, 256, 256, 1, 1, 1);
    r = region(8, 4, 0, 32, 16, 1);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.block_cols == 8 && p.block_rows == 4);
    CHECK(p.copy_row_bytes == 64 && p.copy_bytes == 256);
    CHECK(p.dst_row == 64 && p.dst_img == 256);

    // 8b. 区域右/下边界允许不是整块（取到 level 边界）：240+16 = 256 是整块；252+4 也是整块。
    END_CASE();
    CASE("bc4 region ending at level edge");
    r = region(240, 0, 0, 16, 4, 1);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.block_cols == 4 && p.copy_row_bytes == 32);
    r = region(252, 252, 0, 4, 4, 1);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.block_cols == 1 && p.block_rows == 1);

    // 9. ASTC 8x8（bpb 16）：偏移与宽高都必须按 8 对齐（除边界）。
    END_CASE();
    CASE("astc 8x8 alignment");
    d = desc(FMT_ASTC_4x4, T_2D, 16, 8, 8, 512, 256, 1, 1, 1);
    r = region(16, 8, 0, 128, 64, 1);
    CHECK(plan_ok(&d, 0, 0, &r, 0, 0, &p) == 0);
    CHECK(p.block_cols == 16 && p.block_rows == 8);
    CHECK(p.copy_row_bytes == 256 && p.copy_bytes == 2048);
    r = region(16 + 4, 8, 0, 128, 64, 1);   // 偏移不在块边界
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "not aligned"));
    r = region(16, 8, 0, 116, 64, 1);       // 宽度不是整块且没到边界
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "whole number"));
    END_CASE();

    // 10. 1D / 1D_ARRAY：高度维恒为 1，层数来自 desc.layers。
    END_CASE();
    CASE("1d array layers");
    d = desc(FMT_RGBA8, T_1D_ARRAY, 4, 1, 1, 256, 4 /* layer count */, 1, 1, 4);
    r = region(0, 0, 1, 64, 1, 2);
    CHECK(plan_ok(&d, 0, 1, &r, 0, 0, &p) == 0);
    CHECK(p.level_h == 1 && p.nz == 2);
    nvn_vk_readback_slice(&p, 0, &s);
    CHECK(s.image_layer == 2 && s.image_z == 0);
    nvn_vk_readback_slice(&p, 1, &s);
    CHECK(s.image_layer == 3);

    // 11. 越界与非法输入：每条都报可定位原因，不静默退化成整幅/越界读。
    END_CASE();
    CASE("bounds and invalid input fail loudly");
    d = desc(FMT_RGBA8, T_2D, 4, 1, 1, 128, 128, 1, 2, 1);
    r = region(0, 0, 0, 129, 128, 1);
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "exceeds level"));
    r = region(0, 0, 0, 128, 128, 1);
    CHECK(plan_fails(&d, 2, 0, &r, 0, 0, "outside the texture"));
    r = region(-1, 0, 0, 16, 16, 1);
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "negative"));
    r = region(0, 0, 0, 0, 16, 1);
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "invalid copy region size"));
    d = desc(FMT_RGBA8, T_3D, 4, 1, 1, 64, 64, 8, 1, 1);
    r = region(0, 0, 6, 64, 64, 3);
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "3D copy region"));
    d = desc(FMT_RGBA8, T_2D_ARRAY, 4, 1, 1, 64, 64, 1, 1, 4);
    r = region(0, 0, 2, 64, 64, 3);
    CHECK(plan_fails(&d, 0, 2, &r, 0, 0, "layer range"));
    d = desc(FMT_RGBA8, T_2D, 0, 1, 1, 64, 64, 1, 1, 1);
    r = region(0, 0, 0, 64, 64, 1);
    CHECK(plan_fails(&d, 0, 0, &r, 0, 0, "no byte/block size"));

    // 12. 行距/层距小于紧排：dst 会互相覆盖，必须失败而不是写坏内存。
    END_CASE();
    CASE("stride smaller than packed layout fails");
    d = desc(FMT_RGBA8, T_2D, 4, 1, 1, 64, 64, 1, 1, 1);
    r = region(0, 0, 0, 64, 64, 1);
    CHECK(plan_fails(&d, 0, 0, &r, 128, 0, "row stride"));
    // img 只在多层时被使用：单层读回允许传任意 img（NVN 不消费它）。
    CHECK(plan_ok(&d, 0, 0, &r, 256, 1000, &p) == 0);
    d = desc(FMT_RGBA8, T_2D_ARRAY, 4, 1, 1, 64, 64, 1, 1, 2);
    r = region(0, 0, 0, 64, 64, 2);
    CHECK(plan_fails(&d, 0, 0, &r, 256, 1000, "image stride"));

    // 13. 行距/层距有 padding 时 dst 偏移按 padding 算（不是紧排）。
    END_CASE();
    CASE("padded strides keep dst offsets");
    d = desc(FMT_RGBA8, T_2D_ARRAY, 4, 1, 1, 32, 32, 1, 1, 3);
    r = region(0, 0, 0, 32, 32, 3);
    CHECK(plan_ok(&d, 0, 0, &r, 128 + 64, 4096 + 512, &p) == 0);
    CHECK(p.dst_row == 192 && p.dst_img == 4608);
    nvn_vk_readback_slice(&p, 2, &s);
    CHECK(s.dst_offset == 2u * 4608u);
    CHECK(nvn_vk_readback_dst_extent(&p) == 2u * 4608u + 31u * 192u + 128u);
    END_CASE();

    printf("%s: %d checks, %d failed\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
