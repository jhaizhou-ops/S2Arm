// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 颜色附件免加载的前瞻（pass_color_unwritten）遇到几何绘制（11-07 金刚真机 GPU hang + 地面成块黑洞：诊断局同帧「color attachment ser=4619 was not loaded
//   (proven unwritten to the pass end) but a draw wrote it: lookahead wrong」，写它的是直通快路的几何绘制 gs dda4fd846f421f3b_bgs3）。
// 前瞻原先把「带几何阶段、过得了 geo_draw 早退检查的绘制」一律当「先结束本遍」。两处不成立：
//   · 几何连段（nvn_geometry.inc geo_run_*）进行中，下一笔几何绘制不结束主遍，它的主遍绘制（道 2）接着画进同一个遍；
//   · draw() 里几何路径的间接计数多绘制过了计数（mdi_cnt && !mdi_live）直接返回：不画、也不结束遍（计数已读过、缓存着时连 mdi_wait 都不走）。
// 期望按构造写死：8×1 的 RGBA32F 附件 A（颜色 0）、B（颜色 1），都先填 0.25；F0 只写颜色 0（0.5，全屏），F1 只写颜色 1 的左半（0.75，x ≥ 4 丢弃）。
//   几何程序 G = {顶点（带抓顶点入口）, F0, 几何阶段（3 个输出顶点）}，查几何变体换成恒查不到（不真画，只要它在命令流里的样子）。
//   A 连段：按 geo_draw 在段里的做法，段开着（geo_run_begin），道 2 里先以 F0 画第一笔几何绘制的主遍（开遍，前瞻看到命令流 [G 的绘制][结束]），
//     再以 F1 画第二笔几何绘制的主遍（段里不结束遍，同一个遍）→ 期望：省读入 +0（照常读入）、「lookahead wrong」红行 +0、B 左半 0.75、右半保留 0.25、A 全 0.5
//   B 负对照：[F0 开遍][绑 G][G 的绘制（不在段里：开遍的不是段里的主遍）][结束] → G 先结束遍，B 到遍结束没人写 → 省读入 +1、B 全 0.25（没读入也没写回）
//   C 多绘制过了计数：[绑 G][G 多绘制第 0 笔（计数 0：读计数、缓存）][绑 P0][F0 开遍][绑 G][G 多绘制第 1 笔（缓存着、直接返回，不结束遍）][绑 P1][F1][结束]
//     → 期望：省读入 +0、红行 +0、B 左半 0.75、右半保留 0.25
//   D 诊断开关 DM_NVN_NOLOAD=0（真机 A/B 判因果用）：同 B 的命令流 → 省读入 +0（照常读入）、B 全 0.25（读入后原样写回）
//   E 红行现场（g_nlw / g_pass_geo）：按 A 的段里两笔主遍，第一笔之后把 B 的条目人为标成「没读入」（模拟前瞻判错）→ 红行计数 +1；首写现场 wwhy 2（颜色写掩码）、
//     precise 1、fs 是 F1 的键、gs 是 G 的几何阶段键、geo_program 1、geo_run 1；本遍几何笔数 2
// 反证：去掉 pass_color_unwritten 开头「段开着就返回 0」→ A 红（省读入 +1、红行 +1）；去掉扫描里「几何绘制带 mdi_cnt 就停」→ C 红（同上）；两处都改成恒返回 0 → B 红（+0）；
//   开关不读 DM_NVN_NOLOAD → D 红（+1）
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

static NvShader *lookup_none(NSString *k, int st) { (void)k; (void)st; return nil; }
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
static tex_t A,B; static id<MTLBuffer> buf; static prog_t p0,p1,pg;
static uint64_t red0;
static void begin(void) {   // 附件填 0.25、开提交、程序 P0、附件 A / B
    float *f=buf.contents; for (int i=0;i<64;i++) f[i]=0.25f; xfer(&A,buf,1); xfer(&B,buf,1);
    red0=g_noload_wrong;
    nvn_be_sub_begin(); state_reset(); S.prog=&p0; rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=2; R.rt.color[0]=&A; R.rt.color[1]=&B; R.has_rt=1; g_pso_dirty=1; args_dirty_all();
}
static void end(float a[8], float b[8], uint64_t *red) {   // 收尾：交 GPU、读回 A / B 红通道；red = 「lookahead wrong」红行计数增量
    rp_flush();
    uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    float *f=buf.contents;
    memset(f,0,256); xfer(&A,buf,0); for (int i=0;i<8;i++) a[i]=f[i*4];
    memset(f,0,256); xfer(&B,buf,0); for (int i=0;i<8;i++) b[i]=f[i*4];
    *red=g_noload_wrong-red0;
}
static int all(const float *v, int lo, int hi, float want) { for (int i=lo;i<hi;i++) if (v[i]!=want) return 0; return 1; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_noload_geo_map_XXXXXX",user[]="/tmp/t_noload_geo_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    setenv("DM_NVN_ENC_THREAD","1",1);   // 几何连段只在录制线程开着时成立（iOS 缺省开）
    unsetenv("DM_NVN_TBDR"); unsetenv("DM_NVN_UNWRITTEN_DC"); mtl_init(); REQUIRE(!g_m3); REQUIRE(rec_on()); REQUIRE(!tbdr_on());
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    g_geo_lookup=lookup_none;   // G 的绘制在 geo_draw 里查不到变体就返回（结束遍之后）：本单测只要它在命令流里的样子
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; if(!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *vs=[NvShader new]; vs->stage=0; vs->fn=[lib newFunctionWithName:@"triangle"]; strlcpy(vs->key,"aaaaaaaaaaaaaaaa_b",sizeof vs->key); vs->rf.pos_attr=-1; vs->rf.has_user=1;
    NvShader *vg=[NvShader new]; vg->stage=0; vg->fn=vs->fn; vg->geo_fn=vs->fn; strlcpy(vg->key,"bbbbbbbbbbbbbbbb_b",sizeof vg->key); vg->rf.pos_attr=-1; vg->rf.has_user=1;   // 带抓顶点入口（只看非空）
    NvShader *f0=[NvShader new]; f0->stage=1; f0->fn=[lib newFunctionWithName:@"only0"]; strlcpy(f0->key,"cccccccccccccccc_b",sizeof f0->key); f0->rf.pos_attr=-1; f0->rf.has_user=2; f0->rf.color_known=1; f0->rf.color_mask=1;
    NvShader *f1=[NvShader new]; f1->stage=1; f1->fn=[lib newFunctionWithName:@"only1_left"]; strlcpy(f1->key,"dddddddddddddddd_b",sizeof f1->key); f1->rf.pos_attr=-1; f1->rf.has_user=2; f1->rf.color_known=1; f1->rf.color_mask=2;
    NvShader *gs=[NvShader new]; gs->stage=2; strlcpy(gs->key,"dda4fd846f421f3b_b",sizeof gs->key); gs->geo_vertices=3; gs->geo_invocations=1; gs->geo_output=7;
    REQUIRE(vs->fn && f0->fn && f1->fn);
    NvProg *g0=[NvProg new]; g0->sh[0]=vs; g0->sh[1]=f0; NvProg *g1=[NvProg new]; g1->sh[0]=vs; g1->sh[1]=f1;
    NvProg *gg=[NvProg new]; gg->sh[0]=vg; gg->sh[1]=f0; gg->sh[2]=gs;
    p0=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p0.serial,g0);
    p1=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p1.serial,g1);
    pg=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(pg.serial,gg);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    texture(&A,pool,0); texture(&B,pool,65536);
    // 主遍绘制的索引 {0,1,2} 与间接参数 {3,1,0,0,0}（geo_draw 给主遍的 g_geo_indices / g_geo_args 的样子），以及多绘制的计数 0
    enum { IDX=0x20000, ARGS=0x20100, CNT=0x20200 };
    uint32_t *ix=(uint32_t *)(memory+IDX); ix[0]=0; ix[1]=1; ix[2]=2;
    uint32_t *ag=(uint32_t *)(memory+ARGS); ag[0]=3; ag[1]=1; ag[2]=0; ag[3]=0; ag[4]=0;
    uint64_t gbase; { void *mb; uint64_t mo; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)memory,1<<20,&mb,&mo,&gbase)); }
    buf=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    const p_bind_program_id b0={.prog=&p0,.serial=p0.serial,.stages=0x1f}, b1={.prog=&p1,.serial=p1.serial,.stages=0x1f}, bg={.prog=&pg,.serial=pg.serial,.stages=0x1f};
    float a[8], b[8]; uint64_t n, red;

    // A 连段：两笔几何绘制的主遍画进同一个遍
    {
        NvProg *r0=[NvProg new]; r0->sh[0]=vs; r0->sh[1]=f0; NvProg *r1=[NvProg new]; r1->sh[0]=vs; r1->sh[1]=f1;
        begin(); state_op(OP_BIND_PROGRAM,&bg,(uint32_t)((8+sizeof bg+7)&~7u)); REQUIRE(S.prog && prog_get(S.prog)->sh[2]==gs);   // 照命令流的样子绑（前瞻还原状态后按各阶段绑定重算程序）
        uint64_t n0=g_noload_n;
        geo_run_begin(); REQUIRE(g_gr.active);
        g_geo_indices=gbase+IDX; g_geo_index_bytes=12; g_geo_args=gbase+ARGS;
        g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);   // 第一笔主遍之后的命令流：第二笔几何绘制
        g_geo_program=r0; geo_lane(2); if (!g_enc) { g_game_barrier=1; main_barrier_reset(); }
        g_exec_next=g_ops; draw(&d,NULL); g_exec_next=NULL; geo_lane(0);
        int opened=g_enc!=nil;
        const op_hdr tail={OP_END,sizeof(op_hdr)};   // 第二笔主遍之后：提交结束
        g_geo_program=r1; geo_lane(2); g_exec_next=(const uint8_t *)&tail; draw(&d,NULL); g_exec_next=NULL; geo_lane(0);
        g_geo_program=nil; args_dirty_all(); int still=g_gr.active;
        n=g_noload_n-n0;
        geo_run_flush(); rp_end();
        end(a,b,&red);
        REQUIRE(opened && still);
        CHECK(n==0 && red==0,"A 几何连段：第一笔主遍开遍、第二笔主遍接着画进同一遍 → 照常读入（省读入 +%llu，期望 +0），「lookahead wrong」红行 +%llu（期望 +0）",(unsigned long long)n,(unsigned long long)red);
        CHECK(all(b,0,4,0.75f) && all(b,4,8,0.25f) && all(a,0,8,0.5f),"A 读回 B 左半 0.75（%.2f %.2f）、右半保留 0.25（%.2f %.2f）；A 全 0.5（%.2f … %.2f）",b[0],b[3],b[4],b[7],a[0],a[7]);
    }
    // B 负对照：普通绘制开遍，后面一笔不在段里的几何绘制先结束遍
    {
        begin(); uint64_t n0=g_noload_n;
        g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_BIND_PROGRAM,&bg,sizeof bg); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
        nvn_be_exec(g_ops); n=g_noload_n-n0;
        end(a,b,&red);
        CHECK(n==1 && red==0,"B 负对照 [F0 开遍][绑 G][G 的绘制][结束]：G 先结束遍 → 不读入（省读入 +%llu，期望 +1），红行 +%llu（期望 +0）",(unsigned long long)n,(unsigned long long)red);
        CHECK(all(b,0,8,0.25f) && all(a,0,8,0.5f),"B 读回 B 全 0.25（%.2f … %.2f）、A 全 0.5（%.2f … %.2f）：没读入也没写回",b[0],b[7],a[0],a[7]);
    }
    // C 几何多绘制过了计数：不画、也不结束遍
    {
        *(uint32_t *)(memory+CNT)=0;
        p_draw m0=d, m1=d; m0.mdi_cnt=m1.mdi_cnt=(uint64_t)(uintptr_t)(memory+CNT); m0.mdi_i=0; m1.mdi_i=1;
        begin(); uint64_t n0=g_noload_n;
        g_on=0; put(OP_BIND_PROGRAM,&bg,sizeof bg); put(OP_DRAW,&m0,sizeof m0); put(OP_BIND_PROGRAM,&b0,sizeof b0); put(OP_DRAW,&d,sizeof d);
        put(OP_BIND_PROGRAM,&bg,sizeof bg); put(OP_DRAW,&m1,sizeof m1); put(OP_BIND_PROGRAM,&b1,sizeof b1); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
        nvn_be_exec(g_ops); n=g_noload_n-n0;
        end(a,b,&red);
        CHECK(n==0 && red==0,"C [G 多绘制 0][F0 开遍][G 多绘制 1（过了计数，不结束遍）][F1][结束] → 照常读入（省读入 +%llu，期望 +0），红行 +%llu（期望 +0）",(unsigned long long)n,(unsigned long long)red);
        CHECK(all(b,0,4,0.75f) && all(b,4,8,0.25f) && all(a,0,8,0.5f),"C 读回 B 左半 0.75（%.2f %.2f）、右半保留 0.25（%.2f %.2f）；A 全 0.5（%.2f … %.2f）",b[0],b[3],b[4],b[7],a[0],a[7]);
    }
    // D 诊断开关关掉免加载
    {
        setenv("DM_NVN_NOLOAD","0",1); g_noload_on=-1;
        begin(); uint64_t n0=g_noload_n;
        g_on=0; put(OP_DRAW,&d,sizeof d); put(OP_BIND_PROGRAM,&bg,sizeof bg); put(OP_DRAW,&d,sizeof d); put(OP_END,NULL,0);
        nvn_be_exec(g_ops); n=g_noload_n-n0; int off=g_noload_on;
        end(a,b,&red);
        unsetenv("DM_NVN_NOLOAD"); g_noload_on=-1;
        CHECK(off==0 && n==0 && red==0 && all(b,0,8,0.25f),"D DM_NVN_NOLOAD=0（开关 %d，期望 0）：同 B 的命令流照常读入（省读入 +%llu，期望 +0），红行 +%llu（期望 +0），B 全 0.25（%.2f … %.2f）",off,(unsigned long long)n,(unsigned long long)red,b[0],b[7]);
    }
    // E 红行现场
    {
        NvProg *r0=[NvProg new]; r0->sh[0]=vs; r0->sh[1]=f0; NvProg *r1=[NvProg new]; r1->sh[0]=vs; r1->sh[1]=f1;
        begin(); state_op(OP_BIND_PROGRAM,&bg,(uint32_t)((8+sizeof bg+7)&~7u));
        geo_run_begin(); REQUIRE(g_gr.active);
        g_geo_indices=gbase+IDX; g_geo_index_bytes=12; g_geo_args=gbase+ARGS;
        g_geo_program=r0; geo_lane(2); if (!g_enc) { g_game_barrier=1; main_barrier_reset(); }
        draw(&d,NULL); geo_lane(0);
        int k=-1; for (int i=0;i<g_nsd;i++) if (g_sd[i].depth==0 && g_sd[i].idx==1) k=i;
        REQUIRE(k>=0 && !g_sd[k].wrote); g_sd[k].lskip=1;   // 模拟前瞻判错：B 当成「没读入」
        g_geo_program=r1; geo_lane(2); draw(&d,NULL); geo_lane(0);
        g_geo_program=nil; args_dirty_all();
        nl_wit w=g_nlw[k]; uint32_t pg_n=g_pass_geo;
        geo_run_flush(); rp_end();
        end(a,b,&red);
        CHECK(red==1 && w.wwhy==2 && w.prec==1 && !strcmp(w.fs,f1->key) && !strcmp(w.gs,gs->key) && w.geo==1 && w.run==1 && pg_n==2,
              "E 红行 +%llu（期望 +1）；首写现场 wwhy=%d（2）precise=%d（1）fs=%s（%s）gs=%s（%s）geo_program=%d（1）geo_run=%d（1）；本遍几何笔数 %u（2）",
              (unsigned long long)red,w.wwhy,w.prec,w.fs,f1->key,w.gs,gs->key,w.geo,w.run,pg_n);
    }
    g_geo_lookup=geo_lookup_shader;
    unlink(map); unlink(user);
} printf("%s t_nvn_noload_geo：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
