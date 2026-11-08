// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 到遍结束都不写的颜色附件不读入（g_noload_mask / pass_color_unwritten，11-05 能耗线：金刚一帧 790 个几何绘制遍各读入两张 960×540 颜色却一笔不写，每帧读入 4590 MB）。
// 期望按构造写死：8×1 的 RGBA32F 附件 A（颜色 0）、B（颜色 1），都先填 0.25；程序 P0 只写颜色 0（0.5，全屏），P1 只写颜色 1 的左半（0.75，x ≥ 4 丢弃）。
// 命令流交 nvn_be_exec 回放（前瞻要从命令流往后看）：
//   ① [绘制 P0][结束]：B 到遍结束没人写 → 不读入（省读入计数 +1），遍末不写回；读回 B 仍全是 0.25，A 全是 0.5
//   ② 负对照 [绘制 P0][绑 P1][绘制 P1][结束]：同一遍后面有一笔写 B → B 照常读入（计数 +0）；读回 B 左半 0.75、右半仍 0.25（没读入的话右半是未定义内容）
//   ③ [绘制 P0][绘制 P0][结束]：两笔都不写 B → 不读入（计数 +1），B 仍全 0.25
// 反证：去掉 pass_color_unwritten（g_noload_mask 恒 0）→ ① ③ 计数不涨（红）；把前瞻改成「只看开遍那一笔」→ ② 计数 +1、B 右半不是 0.25（红）
//   ④ 上一笔留下的输出映射不漏进下一遍的前瞻（11-06 王国之泪：遍内片上读取 ⑤ 那笔的映射「颜色 0 → 附件 0、其余不写」留在 g_udc_lmap，
//      下一遍开遍前瞻按它判附件 1 没人写、不读入，后面写附件 1 的分块灯光只留下画到的块，其余块全黑）：先回放一遍「P0 按映射 {0, 不写…} 取管线」
//      （同 ⑤ / 延后回放给 g_pso_lmap 的做法），再回放 ② 的命令流 → 期望同 ②：B 照常读入（+0），左半 0.75、右半保留 0.25
//   反证：去掉 draw() 开头清 g_udc_lmap / g_udc_fsfn 那一行 → ④ 计数 +1、B 右半不是 0.25（红）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct O0 { float4 a [[color(0)]]; };\n"
"struct O1 { float4 b [[color(1)]]; };\n"
"fragment O0 only0() { return {float4(0.5f)}; }\n"
"fragment O1 only1_left(float4 p [[position]]) { if (p.x >= 4.0f) discard_fragment(); return {float4(0.75f)}; }\n";

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
static uint8_t g_ops[1024]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static tex_t A,B; static id<MTLBuffer> buf; static prog_t p0,p1;
// 回放一段命令流（开头程序 P0、附件 A / B），读回 A / B 的 8 个像素红通道
static uint64_t run(float a[8], float b[8]) {
    float *f=buf.contents; for (int i=0;i<64;i++) f[i]=0.25f; xfer(&A,buf,1); xfer(&B,buf,1);
    uint64_t n0=g_noload_n;
    nvn_be_sub_begin(); state_reset(); S.prog=&p0; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=2; R.rt.color[0]=&A; R.rt.color[1]=&B; R.has_rt=1; g_pso_dirty=1; args_dirty_all();
    nvn_be_exec(g_ops); rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    memset(f,0,256); xfer(&A,buf,0); for (int i=0;i<8;i++) a[i]=f[i*4];
    memset(f,0,256); xfer(&B,buf,0); for (int i=0;i<8;i++) b[i]=f[i*4];
    return g_noload_n-n0;
}
static int all(const float *v, int lo, int hi, float want) { for (int i=lo;i<hi;i++) if (v[i]!=want) return 0; return 1; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_noload_map_XXXXXX",user[]="/tmp/t_noload_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_UNWRITTEN_DC"); mtl_init(); printf("BACKEND Metal%d，TBDR 组 %s\n",g_m3?3:4,tbdr_on()?"开":"关（缺省）");
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *vs=[NvShader new]; vs->stage=0; vs->fn=[lib newFunctionWithName:@"triangle"]; strlcpy(vs->key,"aaaaaaaaaaaaaaaa_b",sizeof vs->key); vs->rf.pos_attr=-1; vs->rf.has_user=1;
    NvShader *f0=[NvShader new]; f0->stage=1; f0->fn=[lib newFunctionWithName:@"only0"]; strlcpy(f0->key,"cccccccccccccccc_b",sizeof f0->key); f0->rf.pos_attr=-1; f0->rf.has_user=2; f0->rf.color_known=1; f0->rf.color_mask=1;
    NvShader *f1=[NvShader new]; f1->stage=1; f1->fn=[lib newFunctionWithName:@"only1_left"]; strlcpy(f1->key,"dddddddddddddddd_b",sizeof f1->key); f1->rf.pos_attr=-1; f1->rf.has_user=2; f1->rf.color_known=1; f1->rf.color_mask=2;
    REQUIRE(vs->fn && f0->fn && f1->fn);
    NvProg *g0=[NvProg new]; g0->sh[0]=vs; g0->sh[1]=f0; NvProg *g1=[NvProg new]; g1->sh[0]=vs; g1->sh[1]=f1;
    p0=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p0.serial,g0);
    p1=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p1.serial,g1);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    texture(&A,pool,0); texture(&B,pool,65536);
    buf=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    const p_bind_program_id b1={.prog=&p1,.serial=p1.serial,.stages=0x1f};
    float a[8], b[8]; uint64_t n;

    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    n=run(a,b);
    CHECK(n==1,"① [P0][结束]：B 到遍结束没人写 → 不读入（省读入 +%llu，期望 +1）",(unsigned long long)n);
    CHECK(all(b,0,8,0.25f) && all(a,0,8,0.5f),"① 读回 B 全 0.25（%.2f … %.2f）、A 全 0.5（%.2f … %.2f）：没读入也没写回垃圾",b[0],b[7],a[0],a[7]);

    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_BIND_PROGRAM,&b1,sizeof b1); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    n=run(a,b);
    CHECK(n==0,"② 负对照 [P0][绑 P1][P1][结束]：后面那笔写 B → 照常读入（省读入 +%llu，期望 +0）",(unsigned long long)n);
    CHECK(all(b,0,4,0.75f) && all(b,4,8,0.25f),"② 读回 B 左半 0.75（%.2f %.2f）、右半保留 0.25（%.2f %.2f）",b[0],b[3],b[4],b[7]);

    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    n=run(a,b);
    CHECK(n==1 && all(b,0,8,0.25f),"③ [P0][P0][结束]：两笔都不写 B → 不读入（+%llu，期望 +1），B 仍全 0.25（%.2f … %.2f）",(unsigned long long)n,b[0],b[7]);

    static const uint8_t only0_map[8]={0,0xff,0xff,0xff,0xff,0xff,0xff,0xff};   // 物理附件 → 逻辑颜色：只有附件 0 写（同 fb_tile_try 给只写颜色 0 的着色器的映射）
    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    g_pso_lmap=only0_map; g_pso_dirty=1; run(a,b); g_pso_lmap=NULL;
    CHECK(all(a,0,8,0.5f),"④ 前置：P0 按映射 {0, 不写…} 画完，A 全 0.5（%.2f … %.2f）",a[0],a[7]);
    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_BIND_PROGRAM,&b1,sizeof b1); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    n=run(a,b);
    CHECK(n==0,"④ 上一笔的映射之后再回放 [P0][绑 P1][P1][结束]：后面那笔写 B → 照常读入（省读入 +%llu，期望 +0）",(unsigned long long)n);
    CHECK(all(b,0,4,0.75f) && all(b,4,8,0.25f),"④ 读回 B 左半 0.75（%.2f %.2f）、右半保留 0.25（%.2f %.2f）：不读入的话右半是未定义内容",b[0],b[3],b[4],b[7]);

    // ⑤ 满屏起 16:9 页（g_wd_side_on）：draw() 在本笔精确记账之前用 clr_tri 清颜色 0 的两侧条带。前瞻看不到这次清除（不在命令流里），
    //   照常判 B 到遍结束不写、不读入。清除只写颜色 0：B 不能因此被记「写过」——记了就遍末写回没读入的片上内容，B 成垃圾（11-07 鬼灭快速移动地面黑洞）
    uint64_t w0=g_noload_wrong;
    g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
    g_wd_sides[0]=0; g_wd_sides[1]=2; g_wd_sides[2]=6; g_wd_sides[3]=8; g_wd_side_on=1;
    n=run(a,b);
    CHECK(g_wd_side_on==0,"⑤ 前置：起页清条带走到了（g_wd_side_on 被清回 0）");
    CHECK(n==1 && g_noload_wrong==w0,"⑤ [清 A 两侧条带][P0][结束]：B 不读入（+%llu，期望 +1）、「lookahead wrong」+%llu（期望 +0）",(unsigned long long)n,(unsigned long long)(g_noload_wrong-w0));
    CHECK(all(b,0,8,0.25f) && all(a,0,8,0.5f),"⑤ 读回 B 全 0.25（%.2f … %.2f）、A 全 0.5（%.2f … %.2f）：B 没被当成写过而写回垃圾",b[0],b[7],a[0],a[7]);
    unlink(map); unlink(user);
} printf("%s t_nvn_noload：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
