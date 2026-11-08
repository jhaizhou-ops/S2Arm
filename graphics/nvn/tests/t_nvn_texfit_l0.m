// tex_fit 建的兼容视图的起点（mip 级 / 层）单测：着色器声明的类型与纹理类型不匹配时，tex_fit 建一个同维度的视图。
// Metal 的视图 level / slice 范围是相对【源纹理】的（实测：2 级的视图上写 NSMakeRange(2, 2) 被拒，报
//   "(newLevelRange.location + newLevelRange.length)(4) must be <= [texture mipmapLevelCount](2)"），
//   所以「源 = 带偏移的视图 t、范围从 0 起」得到的是 t 自己的起点，而「源 = t 的父纹理、范围从 l0 起」得到的是同一段。
// 期望按规则手写，不由被测实现推出：根纹理每个（级, 层）首 texel 写入 pat(级,层) = 级 * 16 + 层 + 1，
//   读回兼容视图的第 0 级第 0 层，就等于「它从哪一级、哪一层起算」：
//   ① 非视图（一般路径）：t 是根纹理 → 级数不变（4）、起点 0、读到 pat(0,0) = 1
//   ② 带偏移的视图 + 维度不匹配（2D 数组 → 2D）：起点必须是 t 的 2 级 / 2 层，读到 pat(2,2) = 35（不是 pat(0,0)）
//   ③ 带偏移的视图 + 维度不匹配（2D 数组 → 立方体，t 从第 6 层起）：起点层 6，读到 pat(2,6) = 39
//   ④ 负对照：与 ② 同源、但范围从 0 起 → 读到 pat(0,0) = 1，与 ② 的期望不同（这就是把 l0 去掉会红的位置）
// 反证：改前的 tex_fit 用「源 = t、范围 0」建视图（② 读到 35 纯属 t 的起点本来就是 2 级 2 层），改后视图的
//   parentRelativeLevel 才等于 t 的 parentRelativeLevel（2）；把 l0 去掉而源仍是父纹理 → ② 读到 1、断言失败。
// 需要 GPU：要真 MTLTexture（共享存储的纹理用 getBytes 读回，不需要画）。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static unsigned char pat(int l, int s) { return (unsigned char)(l * 16 + s + 1); }   // 每（级, 层）一个可区分的第一字节
static int first_byte(id<MTLTexture> v) {   // 视图自己的第 0 级、第 0 层的首 texel
    unsigned char b[4] = {0, 0, 0, 0};
    [v getBytes:b bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:0];
    return b[0];
}
static id<MTLTexture> make_root(int layers) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = 32; td.height = 32; td.arrayLength = (NSUInteger)layers; td.mipmapLevelCount = 4;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> root = [g_dev newTextureWithDescriptor:td]; REQUIRE(root);
    for (int l = 0; l < 4; l++) for (int s = 0; s < layers; s++) {
        unsigned char px[4] = {pat(l, s), pat(l, s), pat(l, s), 255};
        [root replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:l slice:s withBytes:px bytesPerRow:4 bytesPerImage:4];
    }
    return root;
}

int main(void) {
    @autoreleasepool {
        mtl_init();
        g_treg = calloc(8, sizeof *g_treg); g_ntreg = 8;
        uint64_t rid = 0;
        id<MTLTexture> root = make_root(6);
        REQUIRE(first_byte(root) == pat(0, 0));   // 根纹理自己的第 0 级第 0 层

        // ① 一般路径：t 不是视图 → 级数不变、起点 0（改前的行为逐字相同）
        id<MTLTexture> a = tex_fit(1, root, MTLTextureType2D, NVN_DPF_FLOAT, &rid);
        VERIFY(a && a.textureType == MTLTextureType2D && a.arrayLength == 1 && a.mipmapLevelCount == root.mipmapLevelCount &&
               a.parentRelativeLevel == 0 && a.parentRelativeSlice == 0 && first_byte(a) == pat(0, 0),
               "① 非视图进 2D 槽：级数 %lu（期望 4）、起点 %lu 级 %lu 层、读到 %d（期望 %d）",
               a ? (unsigned long)a.mipmapLevelCount : 0ul, a ? (unsigned long)a.parentRelativeLevel : 0ul,
               a ? (unsigned long)a.parentRelativeSlice : 0ul, a ? first_byte(a) : -1, (int)pat(0, 0));

        // ② 带 mip 偏移的视图 + 维度不匹配：视图必须从 t 的起点（2 级 / 2 层）起算
        id<MTLTexture> t = [root newTextureViewWithPixelFormat:root.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(2, 2) slices:NSMakeRange(2, 4)];
        REQUIRE(t && t.parentRelativeLevel == 2 && t.parentRelativeSlice == 2 && t.mipmapLevelCount == 2 && t.arrayLength == 4);
        id<MTLTexture> b = tex_fit(2, t, MTLTextureType2D, NVN_DPF_FLOAT, &rid);
        VERIFY(b && b.textureType == MTLTextureType2D && b.arrayLength == 1 && b.mipmapLevelCount == t.mipmapLevelCount &&
               b.parentRelativeLevel == t.parentRelativeLevel && b.parentRelativeSlice == t.parentRelativeSlice && first_byte(b) == pat(2, 2),
               "② 2 级 2 层的视图进 2D 槽：级数 %lu（期望 2）、起点 %lu 级 %lu 层（期望 2 / 2）、读到 %d（期望 %d）",
               b ? (unsigned long)b.mipmapLevelCount : 0ul, b ? (unsigned long)b.parentRelativeLevel : 0ul,
               b ? (unsigned long)b.parentRelativeSlice : 0ul, b ? first_byte(b) : -1, (int)pat(2, 2));

        // ③ 层偏移 + 维度不匹配：t 从第 6 层起、6 层 → 一个立方体的立方体视图，起点层必须是 6
        id<MTLTexture> root12 = make_root(12);
        id<MTLTexture> t2 = [root12 newTextureViewWithPixelFormat:root12.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(2, 2) slices:NSMakeRange(6, 6)];
        REQUIRE(t2 && t2.parentRelativeLevel == 2 && t2.parentRelativeSlice == 6);
        id<MTLTexture> c = tex_fit(3, t2, MTLTextureTypeCube, NVN_DPF_FLOAT, &rid);
        VERIFY(c && c.textureType == MTLTextureTypeCube && c.arrayLength == 1 && c.mipmapLevelCount == t2.mipmapLevelCount &&
               c.parentRelativeLevel == 2 && c.parentRelativeSlice == 6 && first_byte(c) == pat(2, 6),
               "③ 6 层起的视图进立方体槽：一个立方体、级数 %lu（期望 2）、起点 %lu 级 %lu 层（期望 2 / 6）、读到 %d（期望 %d）",
               c ? (unsigned long)c.mipmapLevelCount : 0ul, c ? (unsigned long)c.parentRelativeLevel : 0ul,
               c ? (unsigned long)c.parentRelativeSlice : 0ul, c ? first_byte(c) : -1, (int)pat(2, 6));

        // ⑤–⑦ 2D / 2D 数组 / 立方 / 立方数组都按层（上游参考实现（MIT）c83c48f2）：立方的 6 个面是 6 层，声明的类型只决定视图取几层。
        //   根 12 层，第 0 级第 k 层首字节 = pat(0,k) = k + 1；立方 = 根的 0–5 层，立方数组 = 根的 0–11 层（2 个立方）
        id<MTLTexture> cube = [root12 newTextureViewWithPixelFormat:root12.pixelFormat textureType:MTLTextureTypeCube levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 6)];
        id<MTLTexture> cubea = [root12 newTextureViewWithPixelFormat:root12.pixelFormat textureType:MTLTextureTypeCubeArray levels:NSMakeRange(0, 4) slices:NSMakeRange(0, 12)];
        REQUIRE(cube && cubea && cube.arrayLength == 1 && cubea.arrayLength == 2);
        id<MTLTexture> d = tex_fit(4, cube, MTLTextureType2DArray, NVN_DPF_FLOAT, &rid);
        int faces_ok = d && d.textureType == MTLTextureType2DArray && d.arrayLength == 6; if (faces_ok) for (int k = 0; k < 6; k++) { id<MTLTexture> l = [d newTextureViewWithPixelFormat:d.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(k, 1)]; faces_ok &= l && first_byte(l) == pat(0, k); }
        VERIFY(faces_ok, "⑤ 立方进 2D 数组槽：%lu 层（期望 6），第 k 层读到第 k 面（期望 1–6）", d ? (unsigned long)d.arrayLength : 0ul);
        id<MTLTexture> e = tex_fit(5, cube, MTLTextureType2D, NVN_DPF_FLOAT, &rid);
        VERIFY(e && e.textureType == MTLTextureType2D && first_byte(e) == pat(0, 0), "⑥ 立方进 2D 槽：第 0 面，读到 %d（期望 %d）", e ? first_byte(e) : -1, (int)pat(0, 0));
        id<MTLTexture> f = tex_fit(6, cubea, MTLTextureType2DArray, NVN_DPF_FLOAT, &rid);
        int f_ok = f && f.textureType == MTLTextureType2DArray && f.arrayLength == 12;
        if (f_ok) { id<MTLTexture> l = [f newTextureViewWithPixelFormat:f.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(7, 1)]; f_ok = l && first_byte(l) == pat(0, 7); }
        VERIFY(f_ok, "⑦ 立方数组（2 个立方）进 2D 数组槽：%lu 层（期望 12），第 7 层读到 pat(0,7) = %d", f ? (unsigned long)f.arrayLength : 0ul, (int)pat(0, 7));

        // ④ 负对照：与 ② 同一个 t、同一个父纹理，但范围从 0 起（= 把 l0 / s0 去掉）→ 读到根的第 0 级第 0 层，与 ② 的期望不同
        id<MTLTexture> bad = [root newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, t.mipmapLevelCount) slices:NSMakeRange(0, 1)];
        VERIFY(bad && first_byte(bad) == pat(0, 0) && first_byte(bad) != pat(2, 2),
               "④ 负对照：同源、范围从 0 起 → 读到 %d（期望根的第 0 级第 0 层 %d，且不等于 ② 的 %d）",
               bad ? first_byte(bad) : -1, (int)pat(0, 0), (int)pat(2, 2));
    }
    if (failures) { printf("✗ t_nvn_texfit_l0：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_texfit_l0：%u 项全过（tex_fit 的视图从父纹理的 parentRelativeLevel / parentRelativeSlice 起算）\n", checks);
    return 0;
}
