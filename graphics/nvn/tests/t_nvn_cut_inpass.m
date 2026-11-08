// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 遍内切段（11-07 Switch2 线时之笛 GPU 空等）：一遍画得多时，GPU 先前的活已跑完（在途 0）就在两笔绘制之间结束编码器、提交一段，下一笔重开本遍。
//   时之笛主遍 800–1200 笔，旧代码要整遍编完才在下一个换目标点交出去，GPU 每帧在它之前干等 1.6 ms（Duo 诊断局 v80n_d_n1b，单帧最多 3.6 ms）。
// 期望按语义手写，不由被测实现推出（DM_NVN_CUT=4，8×1 的 RGBA32F 目标 A 先填 0.25；命令流 [设目标 A][清 0][剪裁像素 i][绘制 0.5]×8 交 nvn_be_exec 回放）：
//   ① GPU 闲（在途 0）：第 5 笔前攒够 4 笔 → 遍内提交 1 次（分段计数 +1），本遍开了 2 个渲染编码器；读回 8 个像素全 0.5
//      （前 4 笔画在第一个编码器、提交后第二个编码器 Load 接着画：重开时若再清一次或不读入，前 4 个像素就不是 0.5）
//   ② GPU 忙（在途计数直接置 1 模拟，同 t_nvn_cut_busy）：不拆遍，分段计数 +0，渲染编码器 1 个；读回同样全 0.5
// 第 9 笔不存在，所以 ① 只有一个够数的切段点，结果与 GPU 跑多快无关。
// 反证：去掉 nvn_be_exec 里 OP_DRAW 前的 sub_cut_pass() → ① 红（提交 0 次、编码器 1 个），② 照绿
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
static uint8_t g_ops[4096]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static tex_t A; static id<MTLBuffer> buf; static prog_t p0;
// 回放一次；busy：回放期间把在途计数置 1（GPU 忙）。出参：分段提交次数、渲染编码器个数
static void run(int busy, float a[8], uint64_t *cuts, uint64_t *passes) {
    float *f=buf.contents; for (int i=0;i<64;i++) f[i]=0.25f; xfer(&A,buf,1);
    for (int i=0;i<200 && atomic_load(&g_seg_inflight);i++) usleep(10000);
    REQUIRE(!atomic_load(&g_seg_inflight));
    nvn_be_sub_begin(); state_reset(); S.prog=&p0; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.has_rt=0; R.has_sc=0; g_pso_dirty=1; args_dirty_all();
    uint64_t c0=g_cuts, p0n=g_stat_pass;
    if (busy) atomic_fetch_add(&g_seg_inflight,1);
    nvn_be_exec(g_ops); rp_flush();
    if (busy) atomic_fetch_sub(&g_seg_inflight,1);
    *cuts=g_cuts-c0; *passes=g_stat_pass-p0n;
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    memset(f,0,256); xfer(&A,buf,0); for (int i=0;i<8;i++) a[i]=f[i*4];
}
static int all(const float *v, float want) { for (int i=0;i<8;i++) if (v[i]!=want) return 0; return 1; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_cutin_map_XXXXXX",user[]="/tmp/t_cutin_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("NXGAL_BE"); setenv("DM_NVN_ENC_THREAD","0",1); setenv("DM_NVN_CUT","4",1); unsetenv("DM_NVN_CUT_BUSY");
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_LAZY_CLEAR"); mtl_init(); REQUIRE(!rec_on()); REQUIRE(cut_draws()==4);
    printf("BACKEND Metal%d，TBDR 组 %s\n",g_m3?3:4,tbdr_on()?"开":"关（缺省）");
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
    const p_clear_color c0={.index=0,.mask=0xf,.rgba={0,0,0,0}};
    p_set_rt rt; memset(&rt,0,sizeof rt); rt.n=1; rt.color[0]=&A;
    static uint8_t rtrec[512]; const uint32_t rtn=(uint32_t)set_rt_size(&rt); REQUIRE(rtn<=sizeof rtrec); set_rt_put(rtrec,&rt);
    g_on=0; put(OP_SET_RT,rtrec,rtn); put(OP_CLEAR_COLOR,&c0,sizeof c0);
    for (int i=0;i<8;i++) { const p_scissor s={i,0,1,1}; put(OP_SCISSOR,&s,sizeof s); put(OP_DRAW,&d,sizeof d); }
    put(OP_END,NULL,0);
    float a[8]; uint64_t cuts, passes;
    // 预热一遍（结果不判）：进程里第一笔会触发管线预测（pso_predict_rest），它存还状态后按各阶段绑定重取程序（prog_resolve），本单测直接设的 S.prog 会被取成空、后面的笔不画
    run(0,a,&cuts,&passes);

    run(0,a,&cuts,&passes);
    CHECK(cuts==1 && passes==2,"① GPU 闲、一遍 8 笔（DM_NVN_CUT=4）：遍内提交 %llu 次（期望 1）、渲染编码器 %llu 个（期望 2）",(unsigned long long)cuts,(unsigned long long)passes);
    CHECK(all(a,0.5f),"① 拆遍后读回 %.2f %.2f %.2f %.2f | %.2f %.2f %.2f %.2f（期望全 0.50：前 4 笔在第一个编码器，重开 Load 不清）",a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7]);

    run(1,a,&cuts,&passes);
    CHECK(cuts==0 && passes==1,"② GPU 忙：遍内提交 %llu 次（期望 0）、渲染编码器 %llu 个（期望 1）",(unsigned long long)cuts,(unsigned long long)passes);
    CHECK(all(a,0.5f),"② 读回 %.2f … %.2f（期望全 0.50）",a[0],a[7]);
    unlink(map); unlink(user);
} printf("%s t_nvn_cut_inpass：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
