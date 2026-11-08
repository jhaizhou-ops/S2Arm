// RGBA8 纹理被着色器当 R32 整数原子图像绑（缺口 #8，11-05 时之笛开场；参照 上游参考实现 PR #1312「Atomic reinterpretation of RGBA8」，MIT）。生产 nvn_mtl.m（包含）+ 真 Metal 设备。
// 语义（与被测实现无关）：Switch 上图像格式由着色器的图像声明决定怎么解释纹素的位，RGBA8 纹理当 r32ui 图像读写时，一个纹素的 4 个字节就是那个 32 位整数（小端：R 是低字节）；
//   原子、普通采样 / 渲染 / 拷贝看到的是同一份字节。Metal 只在 R32Uint / R32Sint 存储上给原子用法，改前遇到这种绑定报红 128、整条命令跳过。
// 期望（手算）：4×4 RGBA8 纹理每个纹素先写字节 (04, 03, 02, 01) = 整数 0x01020304；着色器在 (0,0) 原子 OR 0x10203040。
//   ① img_atomic_prepare 放行（返回 1，改前 0）
//   ② 序号表里的纹理仍是 RGBA8Unorm（采样 / 渲染照旧），它的底层存储是 R32Uint；图像槽解析到的 R32Uint 纹理与它同一块底层存储
//   ③ GPU：经图像槽那张纹理原子 OR 之后，经 RGBA8 那张读回：(0,0) = 0x01020304 | 0x10203040 = 0x11223344（字节 44 33 22 11），(1,0) 仍 0x01020304（升级拷贝保住原内容）
//   ④ 底层 R32 存储在驻留集里；RGBA8 视图退休（贴图对象 Finalize 后共享表仍持有它；它所在的池销毁、共享表放掉它）→ 围栏后底层存储随之出驻留集
// 负对照（11-05 手工做过，写在报告里）：去掉 img_atomic_prepare 里的 RGBA8 升级那段 → ① 返回 0、② ③ 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL_SIZE = 1 << 20, TID = 7 };
static id<MTLTexture> root_of(id<MTLTexture> t) { while (t.parentTexture) t = t.parentTexture; return t; }
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL_SIZE)); memset(mem, 0, POOL_SIZE);
    pool_t pool = {.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL_SIZE};
    nvn_be_pool_add(mem, POOL_SIZE);
    tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = nvn_new_serial(); t.pool = &pool; t.off = 65536; t.mem = mem + t.off;
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = 4, .height = 4, .depth = 1, .levels = 1};
    nvn_tex_layout(&t.d, &t.L); nvn_be_tex_init(&t); nvn_be_reg_tex(TID, &t, NULL);
    nvn_be_sub_begin(); id<MTLTexture> orig = tex_mtl(&t); uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(orig && orig.pixelFormat == MTLPixelFormatRGBA8Unorm && orig.storageMode == MTLStorageModePrivate);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; REQUIRE(q);
    {   // 测试自己填初值（不经被测实现）：每个纹素 0x01020304
        id<MTLBuffer> src = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; for (int i = 0; i < 16; i++) ((uint32_t *)src.contents)[i] = 0x01020304u;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:MTLSizeMake(4, 4, 1) toTexture:orig destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    }
    NvShader *sh = [NvShader new]; snprintf(sh->key, sizeof sh->key, "rgba_atomic_test");
    sh->rf.b = calloc(1, sizeof *sh->rf.b); REQUIRE(sh->rf.b);   // NvShader frees it
    sh->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .dtt = MTLTextureType2D, .dpf = NVN_DPF_UINT, .reg = 0, .rw = 1, .atomic_image = 1}; sh->rf.nb = 1; sh->rf.has_atomic_image = 1;
    S.img[5][0] = TID;   // compute stage image slot 0
    nvn_be_sub_begin();
    int ok = img_atomic_prepare(sh, 5);
    pthread_mutex_lock(&g_rmu);   // the image slot as encode_args resolves it (NVN_RB_IMG: tex_fast_rid, then img_fit for an image read in another class)
    void *tv = NULL; tex_fast_rid(TID, &tv); id<MTLTexture> slot = (__bridge id<MTLTexture>)tv; uint64_t rid = 0;
    id<MTLTexture> img = slot && mtl_pf_dpf(slot.pixelFormat) != NVN_DPF_UINT ? img_fit(TID, slot, NVN_DPF_UINT, &rid) : slot;
    pthread_mutex_unlock(&g_rmu);
    f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    VERIFY(ok == 1, "① img_atomic_prepare 放行：返回 %d（期望 1）", ok);
    id<MTLTexture> rgba = tex_mtl(&t), root = root_of(rgba);
    VERIFY(rgba.pixelFormat == MTLPixelFormatRGBA8Unorm && root.pixelFormat == MTLPixelFormatR32Uint && tex_atomic_usage(root),
           "② 序号表里的纹理格式 %lu（期望 RGBA8Unorm 70）、底层存储格式 %lu（期望 R32Uint 53）、底层带原子用法 %d", (unsigned long)rgba.pixelFormat, (unsigned long)root.pixelFormat, tex_atomic_usage(root));
    VERIFY(img && img.pixelFormat == MTLPixelFormatR32Uint && root_of(img) == root, "② 图像槽解析到格式 %lu（期望 53）、与 RGBA8 同一块底层存储 %d", (unsigned long)img.pixelFormat, img && root_of(img) == root);
    if (img && img.pixelFormat == MTLPixelFormatR32Uint) {   // ③
        NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void stamp(texture2d<uint, access::read_write> t [[texture(0)]]) { t.atomic_fetch_or(uint2(0), 0x10203040u); }" options:o error:&e];
        id<MTLComputePipelineState> ps = lib ? [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"stamp"] error:&e] : nil; REQUIRE(ps);
        id<MTLBuffer> out = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; memset(out.contents, 0xa5, 64);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setTexture:img atIndex:0]; [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding];
        [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);   // host textures are untracked: the read goes in its own command buffer after the atomic
        cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:rgba sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:64];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *w = out.contents;
        VERIFY(cb.status == MTLCommandBufferStatusCompleted && w[0] == 0x11223344u && w[1] == 0x01020304u && w[15] == 0x01020304u,
               "③ 原子 OR 后经 RGBA8 读回：(0,0) %#010x（期望 0x11223344）、(1,0) %#010x、(3,3) %#010x（期望 0x01020304）", w[0], w[1], w[15]);
    } else VERIFY(0, "③ 没有 R32 图像可派发（见 ②）");
    VERIFY(resident(root), "④ 底层 R32 存储在驻留集里：%d", resident(root));
    {   // ④ 贴图对象 Finalize（共享表仍持有，照旧驻留）、再销毁它所在的池（共享表放掉它）：围栏后底层存储出驻留集
        nvn_be_sub_begin(); nvn_be_tex_release(&t); nvn_be_alias_drop_pool(&pool); f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
        int gone = 0; for (int k = 0; k < 200 && !gone; k++) { usleep(10000); defer_drain(); gone = !resident(root); }
        VERIFY(gone, "④ 池销毁、RGBA8 视图退休，围栏后底层存储出驻留集：%d（期望 1）", gone);
    }
    printf("%s t_nvn_rgba_atomic：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
