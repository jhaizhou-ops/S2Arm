// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 计算派发前先落挂起的整幅清除（照上游参考实现（MIT）0a759de7 的 dispatch rp_flush）。
//   NVN 语义：命令按录制顺序生效。[设目标 A][整幅清 1.0][派发：往 A(0,0) 写 7.0] → 清除在派发之前，A 最终 = (0,0) 7.0、其余 1.0。
//   旧代码：整幅清除、后面没有绘制时只记在 R.clear_c 里等下一个开遍的绘制；dispatch() 只调 rp_end()（没有遍可结束），派发先写 7.0，
//   提交末尾 rp_flush 才开遍落清除 → 整张 1.0，派发的写被盖掉（上游时之笛曝光图被迟到的清除覆盖同族）。
// 期望按构造写死：4×4 R32F 图像贴图 A 初值 0.25；计算着色器只往 (0,0) 写 7.0。命令流交 nvn_be_exec 回放：
//   ① [设目标 A][清 1.0][派发][结束]：读回 (0,0) 7.0、其余 15 个 1.0（旧代码：16 个全 1.0）
//   ② [清 1.0][设目标 A][派发][结束]：清除先成「等着的清除」（lc_push），派发前 lc_land 落地 → 同 ①（新旧都对：说明 ① 红只因挂起清除没落）
//   ③ 对照 [设目标 A][派发][结束]：没有清除 → (0,0) 7.0、其余 0.25（证明框架本身没问题）
// 反证：dispatch() 里那行 rp_flush() 改回 rp_end() → ① 红，② ③ 绿
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

enum { W = 4, H = 4, TID = 9 };
static tex_t A; static id<MTLBuffer> buf; static prog_t pc;
static void xfer(int up) {
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    if (up) [e copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256*H sourceSize:MTLSizeMake(W,H,1) toTexture:tex_mtl(&A) destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    else [e copyFromTexture:tex_mtl(&A) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*H];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
}
static uint8_t g_ops[2048]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static void run(float out[W*H]) {
    float *f=buf.contents; for (int y=0;y<H;y++) for (int x=0;x<W;x++) f[y*64+x]=0.25f; xfer(1);
    nvn_be_sub_begin(); state_reset(); rp_flush(); memset(&R.rt,0,sizeof R.rt); R.has_rt=0; R.has_sc=0;
    S.cprog=&pc; S.img[5][0]=TID; args_dirty_all();
    nvn_be_exec(g_ops);
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    memset(f,0,256*H); xfer(0); for (int y=0;y<H;y++) for (int x=0;x<W;x++) out[y*W+x]=f[y*64+x];
}
static int rest(const float *v, float want) { for (int i=1;i<W*H;i++) if (v[i]!=want) return 0; return 1; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    unsetenv("DM_NVN_LAZY_CLEAR"); mtl_init();
    printf("BACKEND Metal%d\n",g_m3?3:4);
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *e=nil; MTLCompileOptions *o=[MTLCompileOptions new]; o.languageVersion=MTLLanguageVersion2_3;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { texture2d<float, access::write> cp_i0 [[id(0)]]; };\n"
        "kernel void wr(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.cp_i0.write(float4(7.0), uint2(0)); }\n" options:o error:&e];
    if (!lib) fprintf(stderr,"MSL: %s\n",e.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *cs=[NvShader new]; cs->stage=5; cs->fn=[lib newFunctionWithName:@"wr"]; REQUIRE(cs->fn);
    cs->ae=[cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len=cs->ae.encodedLength;
    char err[256]=""; REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"img", @"reg": @0, @"arg_id": @0, @"msl_name": @"cp_i0", @"msl_type": @"texture2d<float, access::write>" } ] }, &cs->rf, err, sizeof err));
    pc=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; NvProg *np=[NvProg new]; np->sh[5]=cs; serial_put(pc.serial,np);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);   // 活到进程结束：生产池是不拷贝的 MTLBuffer
    *pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    memset(&A,0,sizeof A); A.magic=MAGIC('T','E','X',0); A.serial=nvn_new_serial();
    A.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_R32F,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=W,.height=H,.depth=1,.levels=1};
    A.pool=pool; A.off=0; A.mem=memory; nvn_tex_layout(&A.d,&A.L); nvn_be_tex_init(&A); REQUIRE(tex_mtl(&A)); nvn_be_reg_tex(TID,&A,NULL);
    buf=[g_dev newBufferWithLength:256*H options:MTLResourceStorageModeShared]; REQUIRE(buf);
    p_set_rt rt; memset(&rt,0,sizeof rt); rt.n=1; rt.color[0]=&A;
    static uint8_t rtrec[512]; const uint32_t rtn=(uint32_t)set_rt_size(&rt); REQUIRE(rtn<=sizeof rtrec); set_rt_put(rtrec,&rt);
    const p_clear_color c1={.index=0,.mask=0xf,.rgba={1,1,1,1}};
    const p_dispatch d={.x=1,.y=1,.z=1};
    float a[W*H];

    g_on=0; put(OP_SET_RT,rtrec,rtn); put(OP_CLEAR_COLOR,&c1,sizeof c1); put(OP_DISPATCH,&d,sizeof d); put(OP_END,NULL,0); run(a);
    CHECK(a[0]==7.0f && rest(a,1.0f),"① [设目标][清 1.0][派发]：(0,0) %.2f、(1,0) %.2f、(3,3) %.2f（期望 7.00 / 1.00 / 1.00：清除先于派发落地）",a[0],a[1],a[15]);

    g_on=0; put(OP_CLEAR_COLOR,&c1,sizeof c1); put(OP_SET_RT,rtrec,rtn); put(OP_DISPATCH,&d,sizeof d); put(OP_END,NULL,0);
    // ② 的清除要在设目标之前就有目标可清：先把 R.rt 指向 A（同游戏「先设目标、清、再设一次目标」）
    float *f=buf.contents; for (int y=0;y<H;y++) for (int x=0;x<W;x++) f[y*64+x]=0.25f; xfer(1);
    nvn_be_sub_begin(); state_reset(); rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=1; R.rt.color[0]=&A; R.has_rt=1; R.has_sc=0;
    S.cprog=&pc; S.img[5][0]=TID; args_dirty_all(); uint64_t l0=g_lc_landed;
    nvn_be_exec(g_ops);
    { uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
    memset(f,0,256*H); xfer(0); for (int y=0;y<H;y++) for (int x=0;x<W;x++) a[y*W+x]=f[y*64+x];
    CHECK(a[0]==7.0f && rest(a,1.0f) && g_lc_landed>l0,"② [清 1.0][设目标][派发]（等着的清除）：(0,0) %.2f、其余 %.2f，派发前落地 %llu 次（期望 7.00 / 1.00 / ≥1）",a[0],a[1],(unsigned long long)(g_lc_landed-l0));

    g_on=0; put(OP_SET_RT,rtrec,rtn); put(OP_DISPATCH,&d,sizeof d); put(OP_END,NULL,0); run(a);
    CHECK(a[0]==7.0f && rest(a,0.25f),"③ 对照 [设目标][派发]：(0,0) %.2f、其余 %.2f（期望 7.00 / 0.25）",a[0],a[1]);

    printf("%s t_nvn_dispatch_clear：%u 项，%u 项失败（计算派发前落挂起的整幅清除）\n",failures?"✗":"✓",checks,failures);
    return failures!=0;
} }
