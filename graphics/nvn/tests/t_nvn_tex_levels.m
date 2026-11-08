// mip 层数按尺寸夹（11-05 朋友收集 c1105_ty6：128×256 渲染目标要 15 层，Metal validateWithDevice 断言、进程 abort）。生产 nvn_mtl.m 编进本 TU，真 Metal 设备。
// 期望（按 Ryujinx TexturePool.ClampLevels 手算：层数上限 = log2(最大边) + 1；3D 计深度，1D 只看宽，数组层不计）：
//   2D 128×256 要 15 → 9；2D 4×4 要 1 → 1（不夹）；3D 16×16×64 要 15 → 7；1D 64 要 15 → 7；2D 数组 32×32×256 层 要 15 → 6；2D 1024×1024 要 11 → 11（不多给）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void one(id<MTLDevice> dev, int target, uint32_t w, uint32_t h, uint32_t dpt, uint32_t lv, NSUInteger want, const char *what) {
    tex_t t; memset(&t, 0, sizeof t);
    t.d = (nvn_texdesc){.target = target, .format = NVN_FORMAT_RGBA8, .width = w, .height = h, .depth = dpt, .levels = lv};
    MTLTextureDescriptor *d = tex_desc(&t, 0);
    NSUInteger got = d ? d.mipmapLevelCount : 0;
    // 先看层数，层数超了就不交给 Metal（它会 abort 整个进程，后面的项看不到）
    id<MTLTexture> mt = got == want ? [dev newTextureWithDescriptor:d] : nil;
    VERIFY(got == want && mt, "%s 要 %u 层 → 期望 %lu，实得 %lu，建纹理 %s", what, lv, (unsigned long)want, (unsigned long)got, mt ? "成" : "未建");
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { fprintf(stderr, "no Metal device\n"); return 1; }
        g_dev = dev;
        one(dev, NVN_TEXTURE_TARGET_2D, 128, 256, 1, 15, 9, "2D 128×256");
        one(dev, NVN_TEXTURE_TARGET_2D, 4, 4, 1, 1, 1, "2D 4×4");
        one(dev, NVN_TEXTURE_TARGET_3D, 16, 16, 64, 15, 7, "3D 16×16×64");
        one(dev, NVN_TEXTURE_TARGET_1D, 64, 1, 1, 15, 7, "1D 64");
        one(dev, NVN_TEXTURE_TARGET_2D_ARRAY, 32, 32, 256, 15, 6, "2D 数组 32×32×256 层");
        one(dev, NVN_TEXTURE_TARGET_2D, 1024, 1024, 1, 11, 11, "2D 1024×1024");
    }
    printf("%s t_nvn_tex_levels %u/%u\n", failures ? "✗" : "✓", checks - failures, checks);
    return failures != 0;
}
