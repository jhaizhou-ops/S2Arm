// Production history functions, real public NVN texture/record lifetimes and GPU
// clear/readback. No allocator substitution, OOM injection or mirrored oracle.
#ifndef NVN_RT_HISTORY_SOURCE
#define NVN_RT_HISTORY_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_RT_HISTORY_SOURCE
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define API(name) ((NVNT_##name)entry(#name))
static void *entry(const char *name) { void *p=h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
static NVNdevice device;
static NVNmemoryPool pool;
static NVNtextureBuilder builder;
static uint8_t *memory;

static void texture(NVNtexture *t) { memset(t,0,sizeof *t); REQUIRE(API(nvnTextureInitialize)(t,&builder)); }
// A texture object over its own storage (offset into the pool) and format: the storage-keyed history (g_rt_seen_mem) tells these apart
static void texture_at(NVNtexture *t, ptrdiff_t off, NVNformat fmt) {
    API(nvnTextureBuilderSetStorage)(&builder,&pool,off); API(nvnTextureBuilderSetFormat)(&builder,fmt); texture(t);
    API(nvnTextureBuilderSetStorage)(&builder,&pool,0); API(nvnTextureBuilderSetFormat)(&builder,NVN_FORMAT_RGBA8);
}
static const tex_t *desc(const NVNtexture *t) { return (const tex_t *)t; }
static int safe(const NVNtexture *t) { return rt_fresh_now(desc(t)) && rt_seen_steady(desc(t)); }
static void mark(const NVNtexture *t, int fresh) { rt_seen_mark(desc(t)); if (fresh) rt_fresh_mark(desc(t)); }

static void semantics(void) {
    NVNtexture a,b; texture(&a); texture_at(&b,65536,NVN_FORMAT_RGBA8);
    nvn_be_set_frame(10); mark(&a,1);
    CHECK(!safe(&a),"first attachment is fresh but has no previous-frame evidence");
    mark(&a,1); CHECK(!safe(&a),"same-frame repetitions do not manufacture a previous frame");
    mark(&b,1);
    nvn_be_set_frame(11); mark(&a,1); CHECK(safe(&a),"consecutive frames retain the original predicate");
    nvn_be_set_frame(13); mark(&a,1); CHECK(safe(&a),"two-frame gap remains eligible");
    mark(&b,1); CHECK(!safe(&b),"three-frame gap refuses the first returning draw");
    nvn_be_set_frame(14); mark(&b,1); CHECK(safe(&b),"returning target recovers on the next consecutive frame");
    mark(&a,0); CHECK(!safe(&a),"loaded history without a current clear is never skip-safe");
    rt_fresh_mark(desc(&a)); CHECK(safe(&a),"a later current-frame clear retains the preceding attachment evidence");
    uint64_t before=(uint64_t)(uintptr_t)nvn_hm_get(&g_rt_seen,&desc(&a)->serial);
    mark(&a,0); CHECK(before==(uint64_t)(uintptr_t)nvn_hm_get(&g_rt_seen,&desc(&a)->serial),"same-frame mark preserves packed last/previous exactly");
    CHECK(rt_fresh_now(NULL) && rt_seen_steady(NULL),"empty attachment keeps its neutral predicate");
    NVNtexture absent; texture(&absent);
    nvn_be_set_frame(UINT32_MAX);
    CHECK(!rt_fresh_now(desc(&absent)) && !safe(&absent),"32-bit zero tag does not make an absent target fresh/steady");
    mark(&a,1); CHECK(rt_fresh_now(desc(&a)) && !rt_seen_steady(desc(&a)),"tag wrap records freshness without inventing previous-frame evidence");
    nvn_be_set_frame((uint64_t)UINT32_MAX+1); mark(&a,1); CHECK(!safe(&a),"first nonzero tag conservatively rebuilds previous-frame evidence");
    nvn_be_set_frame((uint64_t)UINT32_MAX+2); mark(&a,1); CHECK(safe(&a),"normal consecutive eligibility resumes after wrap");
    API(nvnTextureFinalize)(&absent); API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b);
}

// 11-06: a new texture object over the same storage every frame (dynamic resolution, per-frame G-buffer objects) is steady through its storage;
//   another storage, or the same storage in another format, is not. Hand-computed: frame 40 first sight → not steady; frame 41 new object, same storage + format → steady;
//   same storage, R32F → not steady; storage at 128 KiB → not steady
static void storage_steady(void) {
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    NVNtexture f0,f1,other_fmt,other_mem; texture_at(&f0,0,NVN_FORMAT_RGBA8);
    nvn_be_set_frame(40); mark(&f0,1);
    CHECK(!safe(&f0),"storage history: first sight of the storage is not steady");
    nvn_be_set_frame(41); texture_at(&f1,0,NVN_FORMAT_RGBA8); mark(&f1,1);
    CHECK(desc(&f1)->serial!=desc(&f0)->serial && safe(&f1),"new object over the same storage and format on the next frame is steady");
    texture_at(&other_fmt,0,NVN_FORMAT_R32F); rt_fresh_mark(desc(&other_fmt));
    CHECK(!rt_seen_steady(desc(&other_fmt)),"same storage in another format is not steady");
    texture_at(&other_mem,131072,NVN_FORMAT_RGBA8); rt_fresh_mark(desc(&other_mem));
    CHECK(!rt_seen_steady(desc(&other_mem)),"another storage is not steady");
    API(nvnTextureFinalize)(&f0); API(nvnTextureFinalize)(&f1); API(nvnTextureFinalize)(&other_fmt); API(nvnTextureFinalize)(&other_mem);
}

static void growth(void) {
    enum { FRAMES=256, PER_FRAME=128 };
    unsigned fresh_max=0, seen_max=0; int bounded=1;
    for (unsigned f=0;f<FRAMES;f++) {
        nvn_be_set_frame(1000+f);
        for (unsigned i=0;i<PER_FRAME;i++) {
            NVNtexture t; texture(&t); mark(&t,1);
            API(nvnTextureFinalize)(&t);
        }
        if (g_rt_fresh.n>fresh_max) fresh_max=g_rt_fresh.n;
        if (g_rt_seen.n>seen_max) seen_max=g_rt_seen.n;
        bounded &= g_rt_fresh.n<=PER_FRAME && g_rt_seen.n<=3*PER_FRAME;
    }
    CHECK(bounded,"32768 actual texture serials: fresh peak=%u <=128, seen peak=%u <=384; capacities=%u/%u",
          fresh_max,seen_max,g_rt_fresh.cap,g_rt_seen.cap);
    nvn_be_set_frame(2000);
    NVNtexture t; texture(&t); mark(&t,1);
    CHECK(g_rt_fresh.n==1 && g_rt_seen.n==1,"large frame jump retires every old serial: fresh=%u seen=%u",g_rt_fresh.n,g_rt_seen.n);
    API(nvnTextureFinalize)(&t);
}

static void wrapped_probe_chain(void) {
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    REQUIRE(g_rt_seen.cap==64);
    // Actual public API serials chosen to collide at slot 63 in a 64-slot table.
    // Alternating old/current entries force backward-shift deletion across zero.
    NVNtexture chosen[8]; unsigned n=0;
    while(n<8) {
        texture(&chosen[n]);
        uint64_t ser=desc(&chosen[n])->serial;
        if ((nvn_hm_hash(&ser,8)&63)==63) n++;
        else API(nvnTextureFinalize)(&chosen[n]);
    }
    nvn_be_set_frame(20);
    for(unsigned i=0;i<8;i++) if(!(i&1)) mark(&chosen[i],1);
    nvn_be_set_frame(22);
    for(unsigned i=0;i<8;i++) if(i&1) mark(&chosen[i],1);
    uint64_t packed[8];
    for(unsigned i=0;i<8;i++) packed[i]=(uint64_t)(uintptr_t)nvn_hm_get(&g_rt_seen,&desc(&chosen[i])->serial);
    nvn_be_set_frame(23); mark(&chosen[1],1);
    unsigned stale=0, kept=0; int unchanged=1;
    for(unsigned i=0;i<8;i++) { int present=nvn_hm_get(&g_rt_seen,&desc(&chosen[i])->serial)!=NULL;
        if(i&1) { kept+=present; if(i!=1) unchanged &= packed[i]==(uint64_t)(uintptr_t)nvn_hm_get(&g_rt_seen,&desc(&chosen[i])->serial); }
        else stale+=present; }
    CHECK(!stale && kept==4,"wrapped collision chain: expired=%u (expected 0), retained=%u (expected 4)",stale,kept);
    CHECK(unchanged && safe(&chosen[1]),"pruning preserves retained packed values and consecutive-frame eligibility");
    for(unsigned i=0;i<8;i++) API(nvnTextureFinalize)(&chosen[i]);
}

static void gpu_replay(void) {
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    // Recreate the pool after the real session reset.
    nvn_be_pool_add(memory,1<<20);
    NVNtexture t; texture(&t);
    NVNcommandBuffer cmd={0}; REQUIRE(API(nvnCommandBufferInitialize)(&cmd,&device));
    API(nvnCommandBufferAddCommandMemory)(&cmd,&pool,65536,4096);
    API(nvnCommandBufferBeginRecording)(&cmd);
    const NVNtexture *targets[]={&t};
    API(nvnCommandBufferSetRenderTargets)(&cmd,1,targets,NULL,NULL,NULL);
    float red[]={1,0,0,1}; API(nvnCommandBufferClearColor)(&cmd,0,red,15);
    uint64_t handle=API(nvnCommandBufferEndRecording)(&cmd);
    op_hdr rh; memcpy(&rh,(const void *)(uintptr_t)handle,sizeof rh); REQUIRE(rh.op==OP_SET_RT);
    p_set_rt decoded; const p_set_rt *record=set_rt_rec((const void *)(uintptr_t)(handle+sizeof(op_hdr)),rh.size,&decoded);
    tex_t snapshot=*record->color[0];
    CHECK(snapshot.serial==desc(&t)->serial && record->color[0]!=desc(&t),"public SetRenderTargets owns an actual serial snapshot");
    API(nvnTextureFinalize)(&t);
    REQUIRE(!nvn_be_tex_is_live(snapshot.serial));
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment float4 green() { return float4(0,1,0,1); }\n";
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!lib) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvShader *vs=[NvShader new], *fs=[NvShader new]; vs->fn=[lib newFunctionWithName:@"triangle"]; fs->fn=[lib newFunctionWithName:@"green"];
    REQUIRE(vs->fn && fs->fn); vs->stage=0; fs->stage=1; vs->rf.pos_attr=-1; fs->rf.color_known=1; fs->rf.color_mask=1;
    strlcpy(vs->key,"rt-history-vs",sizeof vs->key); strlcpy(fs->key,"rt-history-fs",sizeof fs->key);
    NvProg *program=[NvProg new]; program->sh[0]=vs; program->sh[1]=fs;
    prog_t gp={.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(gp.serial,program);
    p_draw triangle={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    for(unsigned frame=30;frame<=31;frame++) {
        nvn_be_set_frame(frame); nvn_be_sub_begin();
        nvn_be_exec((const uint8_t *)(uintptr_t)handle);
        S.prog=&gp; draw(&triangle,NULL);
        CHECK(skip_safe(vs,fs)==(frame==31),"real draw's production skip_safe frame%u preserves first/consecutive decision",frame);
        uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        CHECK(rt_fresh_now(&snapshot) && rt_seen_steady(&snapshot)==(frame==31),"finalized serial replay frame%u retains freshness/steady predicate",frame);
        id<MTLTexture> image=tex_mtl(&snapshot); REQUIRE(image);
        id<MTLBuffer> out=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; REQUIRE(out);
        memset(out.contents,0xa5,1024);
        id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
        [b copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1)
            toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
        unsigned wrong=0; const uint8_t *p=out.contents;
        for(unsigned y=0;y<4;y++) for(unsigned x=0;x<4;x++) wrong+=p[y*256+x*4]!=0 || p[y*256+x*4+1]!=255 || p[y*256+x*4+2]!=0 || p[y*256+x*4+3]!=255;
        CHECK(!wrong,"finalized command replay frame%u: 16 real GPU green pixels, wrong=%u",frame,wrong);
    }
    API(nvnCommandBufferFinalize)(&cmd);
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    CHECK(!g_rt_seen.n && !g_rt_fresh.n,"drained production session reset empties both histories");
    nvn_be_set_frame(31);
    rt_seen_mark(&snapshot); rt_fresh_mark(&snapshot);
    CHECK(!rt_seen_steady(&snapshot) && rt_fresh_now(&snapshot),"same frame number after session reset has no previous session evidence");
}

int main(void) {
    @autoreleasepool {
        alarm(90); setenv("DM_NVN_FIRST_SKIP","1",1); setenv("DM_PRESENT_LINK","0",1);
        mtl_init(); printf("BACKEND %s\n",g_m3?"Metal3":"Metal4");
        REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
        NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
        API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,1<<20); REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb));
        API(nvnTextureBuilderSetDefaults)(&builder); API(nvnTextureBuilderSetDevice)(&builder,&device);
        API(nvnTextureBuilderSetSize2D)(&builder,4,4); API(nvnTextureBuilderSetFormat)(&builder,NVN_FORMAT_RGBA8);
        API(nvnTextureBuilderSetStorage)(&builder,&pool,0);
        semantics(); storage_steady(); wrapped_probe_chain(); growth(); gpu_replay();
        REQUIRE(!nvn_be_shutdown_session());
        free(memory);
    }
    printf("%s t_nvn_rt_history: %u checks, %u failures\n",failures?"✗":"✓",checks,failures);
    return failures?1:0;
}
