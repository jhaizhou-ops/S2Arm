// 帧录 GPU 贴图存放（nvn_frame_rec.inc fr_dump_gpu / fr_restore_gpu）：直接包含生产 nvn_mtl.m，在真 Metal 上建四张私有贴图登记进序号表，
//   填已知内容 → 录（fr_dump_gpu）→ 盖成别的内容 → 放（fr_restore_gpu）→ 用与被测实现无关的办法读回比对。期望手写：
//   ① BC1 16×8、2 级（压缩：每 4×4 块 8 字节）：两级的块字节逐字节 = 填进去的
//   ② Depth32Float_Stencil8 32×16：深度 = 0.375、模板 = 0x5a（blit 按深度面 / 模板面分别读回）
//   ③ Depth32Float 32×16：深度 = 0.625
//   ④ RGBA8Unorm 4 倍多重采样 32×16：清成 (0.2, 0.4, 0.6, 1.0) 后录，盖成全 0 后放，再解析成单采样读回 = (51, 102, 153, 255)
//   ⑤ Depth32Float 4 倍多重采样 32×16：清成 0.25 后录，盖成 1.0 后放，深度解析（取样本 0）读回 = 0.25
//   录：存 5 张、不存 0 张。旧录法（不认这三类）存 0 张、放回后内容是盖过的那份 → ①–⑤ 红
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static id<MTLTexture> mk(MTLPixelFormat f, NSUInteger w, NSUInteger h, NSUInteger levels, NSUInteger samples, MTLTextureUsage u) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new]; d.pixelFormat = f; d.width = w; d.height = h; d.mipmapLevelCount = levels; d.sampleCount = samples;
    d.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D; d.storageMode = MTLStorageModePrivate; d.usage = u;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; REQUIRE(t); return t;
}
static void blit_in(id<MTLTexture> t, const void *src, NSUInteger len, NSUInteger bpr, NSUInteger bpi, NSUInteger w, NSUInteger h, NSUInteger level, MTLBlitOption opt) {
    id<MTLBuffer> b = [g_dev newBufferWithBytes:src length:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0) options:opt];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(!cb.error);
}
static id<MTLBuffer> blit_out(id<MTLTexture> t, NSUInteger len, NSUInteger bpr, NSUInteger bpi, NSUInteger w, NSUInteger h, NSUInteger level, MTLBlitOption opt) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:len options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:opt];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(!cb.error); return b;
}
static void clear_ms(id<MTLTexture> t, double v) {   // 多重采样贴图清成 v（颜色 = (v, 2v, 3v, 1)；深度 = v），每个样本同值
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (t.pixelFormat == MTLPixelFormatDepth32Float) { rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = v; rp.depthAttachment.storeAction = MTLStoreActionStore; }
    else { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(v, 2 * v, 3 * v, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore; }
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(!cb.error);
}
static id<MTLTexture> resolve_ms(id<MTLTexture> t) {   // 解析成单采样（颜色平均 / 深度取样本 0）：读回走的是 Metal 自己的解析，与被测的着色器无关
    int dep = t.pixelFormat == MTLPixelFormatDepth32Float;
    id<MTLTexture> r = mk(t.pixelFormat, t.width, t.height, 1, 1, MTLTextureUsageRenderTarget);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassAttachmentDescriptor *a = dep ? (MTLRenderPassAttachmentDescriptor *)rp.depthAttachment : rp.colorAttachments[0];
    a.texture = t; a.resolveTexture = r; a.loadAction = MTLLoadActionLoad; a.storeAction = MTLStoreActionMultisampleResolve;
    if (dep) rp.depthAttachment.depthResolveFilter = MTLMultisampleDepthResolveFilterSample0;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(!cb.error);
    return r;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    const MTLTextureUsage RT = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    // ① BC1：块数据随便取（逐字节比，不看解码）；压缩格式不能当渲染目标，用 ShaderWrite（游戏经整数视图写压缩贴图时就是这样）
    id<MTLTexture> bc = mk(MTLPixelFormatBC1_RGBA, 16, 8, 2, 1, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView);
    uint8_t bc0[4 * 2 * 8], bc1[2 * 1 * 8]; for (unsigned i = 0; i < sizeof bc0; i++) bc0[i] = (uint8_t)(i * 7 + 3); for (unsigned i = 0; i < sizeof bc1; i++) bc1[i] = (uint8_t)(0xa0 + i);
    blit_in(bc, bc0, sizeof bc0, 4 * 8, sizeof bc0, 16, 8, 0, MTLBlitOptionNone); blit_in(bc, bc1, sizeof bc1, 2 * 8, sizeof bc1, 8, 4, 1, MTLBlitOptionNone);
    // ② D32F_S8
    id<MTLTexture> ds = mk(MTLPixelFormatDepth32Float_Stencil8, 32, 16, 1, 1, RT);
    float dv[32 * 16]; uint8_t sv[32 * 16]; for (int i = 0; i < 32 * 16; i++) { dv[i] = 0.375f; sv[i] = 0x5a; }
    blit_in(ds, dv, sizeof dv, 32 * 4, sizeof dv, 32, 16, 0, MTLBlitOptionDepthFromDepthStencil); blit_in(ds, sv, sizeof sv, 32, sizeof sv, 32, 16, 0, MTLBlitOptionStencilFromDepthStencil);
    // ③ D32F
    id<MTLTexture> d32 = mk(MTLPixelFormatDepth32Float, 32, 16, 1, 1, RT);
    float dv3[32 * 16]; for (int i = 0; i < 32 * 16; i++) dv3[i] = 0.625f; blit_in(d32, dv3, sizeof dv3, 32 * 4, sizeof dv3, 32, 16, 0, MTLBlitOptionNone);
    // ④ ⑤ 多重采样
    id<MTLTexture> msc = mk(MTLPixelFormatRGBA8Unorm, 32, 16, 1, 4, RT), msd = mk(MTLPixelFormatDepth32Float, 32, 16, 1, 4, RT);
    clear_ms(msc, 0.2); clear_ms(msd, 0.25);
    serial_put(9001, bc); serial_put(9002, ds); serial_put(9003, d32); serial_put(9004, msc); serial_put(9005, msd);
    char path[] = "/tmp/t_nvn_frec_tex_XXXXXX"; int fd = mkstemp(path); REQUIRE(fd >= 0); close(fd);
    uint64_t bytes = 0; int skipped = -1, saved = fr_dump_gpu(path, &bytes, &skipped);
    VERIFY(saved == 5 && skipped == 0, "录：存 %d 张（期望 5）、不存 %d 张（期望 0）、%llu 字节", saved, skipped, (unsigned long long)bytes);
    // 盖成别的内容
    uint8_t z0[sizeof bc0] = {0}, z1[sizeof bc1] = {0}; blit_in(bc, z0, sizeof z0, 4 * 8, sizeof z0, 16, 8, 0, MTLBlitOptionNone); blit_in(bc, z1, sizeof z1, 2 * 8, sizeof z1, 8, 4, 1, MTLBlitOptionNone);
    float one[32 * 16]; uint8_t s0[32 * 16] = {0}; for (int i = 0; i < 32 * 16; i++) one[i] = 1.0f;
    blit_in(ds, one, sizeof one, 32 * 4, sizeof one, 32, 16, 0, MTLBlitOptionDepthFromDepthStencil); blit_in(ds, s0, sizeof s0, 32, sizeof s0, 32, 16, 0, MTLBlitOptionStencilFromDepthStencil);
    blit_in(d32, one, sizeof one, 32 * 4, sizeof one, 32, 16, 0, MTLBlitOptionNone);
    clear_ms(msc, 0); clear_ms(msd, 1.0);
    int put = 0, miss = 0; fr_restore_gpu(path, &put, &miss); unlink(path);
    VERIFY(put == 5 && miss == 0, "放：写回 %d 张（期望 5）、没写回 %d 张", put, miss);
    id<MTLBuffer> r0 = blit_out(bc, sizeof bc0, 4 * 8, sizeof bc0, 16, 8, 0, MTLBlitOptionNone), r1 = blit_out(bc, sizeof bc1, 2 * 8, sizeof bc1, 8, 4, 1, MTLBlitOptionNone);
    VERIFY(!memcmp(r0.contents, bc0, sizeof bc0) && !memcmp(r1.contents, bc1, sizeof bc1), "① BC1 两级块字节逐字节同（首字节 %u / %u，期望 %u / %u）", ((uint8_t *)r0.contents)[0], ((uint8_t *)r1.contents)[0], bc0[0], bc1[0]);
    id<MTLBuffer> rd = blit_out(ds, sizeof dv, 32 * 4, sizeof dv, 32, 16, 0, MTLBlitOptionDepthFromDepthStencil), rs = blit_out(ds, sizeof sv, 32, sizeof sv, 32, 16, 0, MTLBlitOptionStencilFromDepthStencil);
    VERIFY(!memcmp(rd.contents, dv, sizeof dv) && !memcmp(rs.contents, sv, sizeof sv), "② D32F_S8 深度 %.3f（期望 0.375）、模板 %#x（期望 0x5a）", ((float *)rd.contents)[0], ((uint8_t *)rs.contents)[0]);
    id<MTLBuffer> r3 = blit_out(d32, sizeof dv3, 32 * 4, sizeof dv3, 32, 16, 0, MTLBlitOptionNone);
    VERIFY(!memcmp(r3.contents, dv3, sizeof dv3), "③ D32F 深度 %.3f（期望 0.625）", ((float *)r3.contents)[0]);
    id<MTLTexture> mc = resolve_ms(msc); id<MTLBuffer> r4 = blit_out(mc, 32 * 16 * 4, 32 * 4, 32 * 16 * 4, 32, 16, 0, MTLBlitOptionNone); const uint8_t *c4 = r4.contents; int all4 = 1;
    for (int i = 0; i < 32 * 16; i++) all4 &= abs(c4[4 * i] - 51) <= 1 && abs(c4[4 * i + 1] - 102) <= 1 && abs(c4[4 * i + 2] - 153) <= 1 && c4[4 * i + 3] == 255;
    VERIFY(all4, "④ 多重采样颜色解析后 (%u, %u, %u, %u)（期望 51 / 102 / 153 / 255，±1）", c4[0], c4[1], c4[2], c4[3]);
    id<MTLTexture> md = resolve_ms(msd); id<MTLBuffer> r5 = blit_out(md, 32 * 16 * 4, 32 * 4, 32 * 16 * 4, 32, 16, 0, MTLBlitOptionNone); const float *d5 = r5.contents; int all5 = 1;
    for (int i = 0; i < 32 * 16; i++) all5 &= d5[i] == 0.25f;
    VERIFY(all5, "⑤ 多重采样深度解析（样本 0）%.3f（期望 0.250）", d5[0]);
  }
    if (failures) { printf("✗ t_nvn_frec_tex：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_frec_tex：%u 项全过（帧录 GPU 贴图：压缩 / 深度模板 / 深度 / 多重采样颜色 / 多重采样深度 存放还原）\n", checks); return 0;
}
