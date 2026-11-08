// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 未写附件不写回（udc_on）在 TBDR 组关时（缺省）也生效（10-30 帧率能耗线：四款大作「省掉未写附件写回」都是 0 MB）。期望按构造写死：
//   8×1 的 RGBA32F 附件 A（颜色 0）、B（颜色 1），同一遍装入（不清屏）；着色器只写颜色 0。
//   ① B 本遍没写 → 写回改 DontCare：省下 B 的整张 8 × 1 × 16 = 128 字节，读回 B 仍是预先填的 0.25；
//   ② A 写了 → 照常写回：读回 A = 着色器写的 0.5，且 A 不计入省下的字节。
//   反证：改前 sd_finish 在 tbdr_on() 为假时一律 Store，省下 0 字节（本单测 ① 红）
#ifndef NVN_UDC_SOURCE
#define NVN_UDC_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_UDC_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct O { float4 a [[color(0)]]; };\n"
"fragment O only0() { return {float4(0.5f)}; }\n";

static void texture(tex_t *t, pool_t *pool, size_t off) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA32F,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=8,.height=1,.depth=1,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void udc_xfer(tex_t *t, id<MTLBuffer> b, int up) {
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    if (up) [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8,1,1) toTexture:tex_mtl(t) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    else [e copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,1,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
}

int main(void) { @autoreleasepool {
    char map[]="/tmp/t_udc_map_XXXXXX",user[]="/tmp/t_udc_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_UNWRITTEN_DC"); mtl_init(); printf("BACKEND Metal%d，TBDR 组 %s\n",g_m3?3:4,tbdr_on()?"开":"关（缺省）");
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; REQUIRE(lib);
    NvProg *program=[NvProg new];
    NvShader *vs=[NvShader new]; vs->stage=0; vs->fn=[lib newFunctionWithName:@"triangle"]; strlcpy(vs->key,"aaaaaaaaaaaaaaaa_b",sizeof vs->key); vs->rf.pos_attr=-1; vs->rf.has_user=1;
    NvShader *fs=[NvShader new]; fs->stage=1; fs->fn=[lib newFunctionWithName:@"only0"]; strlcpy(fs->key,"cccccccccccccccc_b",sizeof fs->key); fs->rf.pos_attr=-1; fs->rf.has_user=2; fs->rf.color_known=1; fs->rf.color_mask=1;
    REQUIRE(vs->fn && fs->fn); program->sh[0]=vs; program->sh[1]=fs;
    prog_t p={.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p.serial,program);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    tex_t a,b; texture(&a,pool,0); texture(&b,pool,65536);
    id<MTLBuffer> buf=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    float *f=buf.contents; for (int i=0;i<32;i++) f[i]=0.25f; udc_xfer(&a,buf,1); udc_xfer(&b,buf,1);
    uint64_t s0=nvn_be_udc_saved_bytes();
    nvn_be_sub_begin(); state_reset(); S.prog=&p; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=2; R.rt.color[0]=&a; R.rt.color[1]=&b; R.has_rt=1; g_pso_dirty=1; args_dirty_all();
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; draw(&d,NULL); rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint64_t saved=nvn_be_udc_saved_bytes()-s0;
    memset(f,0,256); udc_xfer(&b,buf,0); float bv=f[0], bl=f[7*4+3];
    memset(f,0,256); udc_xfer(&a,buf,0); float av=f[0], al=f[7*4+3];
    CHECK(saved==128,"① 本遍没写的附件 B 写回改 DontCare：省下 %llu 字节（期望 8 × 1 × 16 = 128）",(unsigned long long)saved);
    CHECK(bv==0.25f && bl==0.25f,"① B 读回仍是预先填的 0.25（第 0 / 7 像素 %.4f / %.4f）",bv,bl);
    CHECK(av==0.5f && al==0.5f,"② 写了的附件 A 照常写回：读回 0.5（第 0 / 7 像素 %.4f / %.4f）",av,al);
    unlink(map); unlink(user);
} printf("%s t_nvn_udc：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
