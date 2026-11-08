// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 等着的清除（lc_push）必须先于任何写同一目标的遍落地（11-06 一次成功线：塞尔达 御天之剑 HD 开场视频整屏黑，真机 / Mac 同症）。
//   游戏每帧对交换链贴图：整屏清 0,0,0,0 → 再设一次目标（清除转为「等着」）→ 带剪裁清 0,0,0,1（画成三角形，自己开遍）→ 画视频四边形。
//   旧代码只在「绘制开遍」时收等着的清除（lc_take），三角形清除开的遍不收，等着的整屏清除拖到提交末尾才落地，把刚画好的视频盖成全黑。
// 期望按构造写死：8×1 的 RGBA32F 颜色目标 A，先填 0.25；程序 P0 全屏写 0.5。命令流交 nvn_be_exec 回放：
//   ① [整屏清 0][设目标 A][剪裁 x<4][清 1.0][结束]：先落地清 0、再左半清 1.0 → 读回左 4 个 1.0、右 4 个 0.0
//      （旧代码：三角形遍左 1.0 右 0.25，末尾清 0 再盖成全 0）
//   ② [整屏清 0][设目标 A][剪裁 x<4][清 1.0][剪裁全][P0 绘制][结束]：最后一笔写 0.5 → 读回全 0.5（旧代码：全 0，同御天之剑黑屏）
//   ③ 对照 [整屏清 0][设目标 A][P0 绘制][结束]：绘制开遍本来就收等着的清除 → 全 0.5（新旧都对，证明单测框架本身没问题）
// 反证：把 rp_begin_ex_ 开头落地等着清除那行删掉 → ① ② 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct O0 { float4 a [[color(0)]]; };\n"
"fragment O0 half_out() { return {float4(0.5f)}; }\n";

static void texture(tex_t *t, pool_t *pool, size_t off) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA32F,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=8,.height=1,.depth=1,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void xfer(tex_t *t, id<MTLBuffer> b, int up) {
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    if (up) [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8,1,1) toTexture:tex_mtl(t) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    else [e copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,1,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
}
static uint8_t g_ops[2048]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static tex_t A; static id<MTLBuffer> buf; static prog_t p0;
static void run(float a[8]) {
    float *f=buf.contents; for (int i=0;i<64;i++) f[i]=0.25f; xfer(&A,buf,1);
    nvn_be_sub_begin(); state_reset(); S.prog=&p0; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=1; R.rt.color[0]=&A; R.has_rt=1; R.has_sc=0; g_pso_dirty=1; args_dirty_all();
    nvn_be_exec(g_ops); rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    memset(f,0,256); xfer(&A,buf,0); for (int i=0;i<8;i++) a[i]=f[i*4];
}
static int all(const float *v, int lo, int hi, float want) { for (int i=lo;i<hi;i++) if (v[i]!=want) return 0; return 1; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_lcord_map_XXXXXX",user[]="/tmp/t_lcord_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_LAZY_CLEAR"); mtl_init(); printf("BACKEND Metal%d，TBDR 组 %s\n",g_m3?3:4,tbdr_on()?"开":"关（缺省）");
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *vs=[NvShader new]; vs->stage=0; vs->fn=[lib newFunctionWithName:@"triangle"]; strlcpy(vs->key,"aaaaaaaaaaaaaaaa_b",sizeof vs->key); vs->rf.pos_attr=-1; vs->rf.has_user=1;
    NvShader *f0=[NvShader new]; f0->stage=1; f0->fn=[lib newFunctionWithName:@"half_out"]; strlcpy(f0->key,"eeeeeeeeeeeeeeee_b",sizeof f0->key); f0->rf.pos_attr=-1; f0->rf.has_user=2; f0->rf.color_known=1; f0->rf.color_mask=1;
    REQUIRE(vs->fn && f0->fn);
    NvProg *g0=[NvProg new]; g0->sh[0]=vs; g0->sh[1]=f0;
    p0=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p0.serial,g0);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    texture(&A,pool,0);
    buf=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    const p_clear_color c0={.index=0,.mask=0xf,.rgba={0,0,0,0}}, c1={.index=0,.mask=0xf,.rgba={1,1,1,1}};
    p_set_rt rt; memset(&rt,0,sizeof rt); rt.n=1; rt.color[0]=&A;
    static uint8_t rtrec[512]; const uint32_t rtn=(uint32_t)set_rt_size(&rt); REQUIRE(rtn<=sizeof rtrec); set_rt_put(rtrec,&rt);   // 紧凑记录（nvn_obj.h），快照区留空：指针直接指对象
    const p_scissor left={0,0,4,1}, full={0,0,8,1};
    float a[8]; uint64_t l0;

    g_on=0; put(OP_CLEAR_COLOR,&c0,sizeof c0); put(OP_SET_RT,rtrec,rtn); put(OP_SCISSOR,&left,sizeof left); put(OP_CLEAR_COLOR,&c1,sizeof c1); put(OP_END,NULL,0);
    l0=g_lc_landed; run(a);
    CHECK(all(a,0,4,1.0f) && all(a,4,8,0.0f),"① [清 0][设目标][剪裁左半][清 1.0]：读回左 %.2f %.2f、右 %.2f %.2f（期望左 1.00 右 0.00；等着的清 0 先落地，%llu 次）",a[0],a[3],a[4],a[7],(unsigned long long)(g_lc_landed-l0));

    g_on=0; put(OP_CLEAR_COLOR,&c0,sizeof c0); put(OP_SET_RT,rtrec,rtn); put(OP_SCISSOR,&left,sizeof left); put(OP_CLEAR_COLOR,&c1,sizeof c1);
    put(OP_SCISSOR,&full,sizeof full); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    run(a);
    CHECK(all(a,0,8,0.5f),"② 同御天之剑：[清 0][设目标][剪裁左半][清 1.0][全屏绘制 0.5]：读回 %.2f … %.2f（期望全 0.50；旧代码末尾清 0 盖成全 0）",a[0],a[7]);

    g_on=0; put(OP_CLEAR_COLOR,&c0,sizeof c0); put(OP_SET_RT,rtrec,rtn); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    run(a);
    CHECK(all(a,0,8,0.5f),"③ 对照 [清 0][设目标][绘制 0.5]：读回 %.2f … %.2f（期望全 0.50，绘制开遍收等着的清除）",a[0],a[7]);
    unlink(map); unlink(user);
} printf("%s t_nvn_lc_order：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
