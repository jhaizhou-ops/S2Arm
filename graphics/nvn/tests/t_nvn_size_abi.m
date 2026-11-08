// Authored IR libraries through the real shader loader and public NVN recording.
// Independent physical float readback plus the support address actually bound
// to Metal distinguish GPU output from merely populated CPU producer state.
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static NVNtexturePool descriptors;
static uint8_t *memory;
static size_t next_texture = 2 << 20;
static unsigned checks;
static NSDictionary *assets;
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 256 << 10, RESULT = 1 << 20 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *api(const char *name) { void *p=h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
typedef struct { NVNtexture texture, alias; int w, h; } image;

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(!posix_memalign((void **)&memory,65536,POOL_SIZE)); memset(memory,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,memory,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
    REQUIRE(API(nvnTexturePoolInitialize)(&descriptors,&pool,512<<10,512));
}
static void make_image(image *t,int w,int h,NVNformat format) {
    t->w=w; t->h=h;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D_ARRAY); API(nvnTextureBuilderSetSize3D)(&b,w,h,2);
    API(nvnTextureBuilderSetFormat)(&b,format); API(nvnTextureBuilderSetLevels)(&b,3);
    API(nvnTextureBuilderSetFlags)(&b,NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t alignment=API(nvnTextureBuilderGetStorageAlignment)(&b), bytes=API(nvnTextureBuilderGetStorageSize)(&b); REQUIRE(alignment&&bytes);
    next_texture=(next_texture+alignment-1)/alignment*alignment; REQUIRE(next_texture+bytes<=POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b,&pool,next_texture); next_texture+=bytes;
    REQUIRE(API(nvnTextureInitialize)(&t->texture,&b)); REQUIRE(API(nvnTextureInitialize)(&t->alias,&b));
}
static NVNtextureView selected(void) {
    NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetLevels)(&v,1,1);
    API(nvnTextureViewSetLayers)(&v,1,1); API(nvnTextureViewSetTarget)(&v,NVN_TEXTURE_TARGET_2D); return v;
}
static NvShader *load(NSString *name) {
    NSDictionary *a=assets[name]; REQUIRE(a);
    NSString *stage=a[@"stage"], *key=[a[@"key"] stringByAppendingString:@"_b"];
    NvShader *sh=shader_load(key,[stage isEqual:@"vs"]?0:[stage isEqual:@"ps"]?1:5,0);
    REQUIRE(sh&&sh->size_abi&&sh->size_exact); return sh;
}
static NVNprogram *program(NvShader *vs,NvShader *fs,NvShader *cs) {
    static NVNprogram programs[4]; static unsigned count; REQUIRE(count<4);
    NVNprogram *p=&programs[count++]; REQUIRE(API(nvnProgramInitialize)(p,&device));
    // Authored IR has no Maxwell input. Actual loaded NvShaders enter the same
    // serial cache used by prog_get; no loader/provider/function is replaced.
    prog_t *guest=(prog_t *)p; guest->serial=nvn_new_serial(); NvProg *native=[NvProg new]; native->gp=guest;
    native->sh[0]=vs; native->sh[1]=fs; native->sh[5]=cs; serial_put(guest->serial,native); return p;
}
static void begin(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
}
static void submit(void) {
    NVNcommandHandle h=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h);
    API(nvnQueueSubmitCommands)(&queue,1,&h); API(nvnQueueFinish)(&queue); REQUIRE(!mtl_last_commit_error());
}
static void states(void) {
    NVNpolygonState p; API(nvnPolygonStateSetDefaults)(&p); API(nvnCommandBufferBindPolygonState)(&commands,&p);
    NVNdepthStencilState d; API(nvnDepthStencilStateSetDefaults)(&d); API(nvnCommandBufferBindDepthStencilState)(&commands,&d);
    NVNcolorState c; API(nvnColorStateSetDefaults)(&c); API(nvnCommandBufferBindColorState)(&commands,&c);
    NVNchannelMaskState m; API(nvnChannelMaskStateSetDefaults)(&m); API(nvnCommandBufferBindChannelMaskState)(&commands,&m);
    NVNmultisampleState s; API(nvnMultisampleStateSetDefaults)(&s); API(nvnCommandBufferBindMultisampleState)(&commands,&s);
}
static void target(image *t) {
    NVNtextureView v=selected(); const NVNtexture *colors[]={&t->texture}; const NVNtextureView *views[]={&v};
    API(nvnCommandBufferSetRenderTargets)(&commands,1,colors,views,NULL,NULL);
    API(nvnCommandBufferSetViewport)(&commands,0,0,t->w>>1,t->h>>1); API(nvnCommandBufferSetScissor)(&commands,0,0,t->w>>1,t->h>>1);
}
static void draw_record(NVNprogram *p,NVNtextureHandle handle) {
    API(nvnCommandBufferSetTexturePool)(&commands,&descriptors);
    API(nvnCommandBufferBindTexture)(&commands,NVN_SHADER_STAGE_FRAGMENT,0,handle);
    API(nvnCommandBufferBindProgram)(&commands,p,NVN_SHADER_STAGE_VERTEX_BIT|NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferDrawArrays)(&commands,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
}
static void dispatch_record(NVNprogram *p,NVNtextureHandle handle) {
    API(nvnCommandBufferSetTexturePool)(&commands,&descriptors);
    API(nvnCommandBufferBindTexture)(&commands,NVN_SHADER_STAGE_COMPUTE,0,handle);
    API(nvnCommandBufferBindStorageBuffer)(&commands,NVN_SHADER_STAGE_COMPUTE,0,API(nvnMemoryPoolGetBufferAddress)(&pool)+RESULT,16);
    API(nvnCommandBufferBindProgram)(&commands,p,NVN_SHADER_STAGE_COMPUTE_BIT);
    API(nvnCommandBufferDispatchCompute)(&commands,1,1,1);
}
static void pixels(image *t,int split,int left_w,int left_h,int right_w,int right_h) {
    id<MTLTexture> texture=tex_mtl((const tex_t *)&t->texture); REQUIRE(texture&&texture.pixelFormat==MTLPixelFormatRGBA32Float);
    NSUInteger w=t->w>>1,h=t->h>>1; REQUIRE((texture.width>>1)==w&&(texture.height>>1)==h);
    size_t pitch=(w*16+255)&~(size_t)255;
    id<MTLBuffer> out=[g_dev newBufferWithLength:pitch*h options:MTLResourceStorageModeShared]; REQUIRE(out);
    id<MTLCommandBuffer> cb=q_cb(); id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:1 sourceLevel:1 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
        toBuffer:out destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*h];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    for(NSUInteger y=0;y<h;y++) for(NSUInteger x=0;x<w;x++) {
        const float *v=(const float *)((const uint8_t *)out.contents+y*pitch+x*16);
        int rw=split&&x>=w/2?right_w:left_w, rh=split&&x>=w/2?right_h:left_h;
        REQUIRE(v[0]==rw&&v[1]==rh&&v[2]==0&&v[3]==1);
    }
}
static const uint8_t *arena_span(uint64_t gpu,size_t size) {
    for(NSArray<NvArena *> *arenas in @[g_arenas?:@[],g_sub_arenas?:@[]]) for(NvArena *a in arenas)
        if(gpu>=a->gpu&&gpu-a->gpu<=a->buf.length&&size<=a->buf.length-(gpu-a->gpu)) return (const uint8_t *)a->buf.contents+(gpu-a->gpu);
    REQUIRE(0&&"bound support address must belong to a real live arena"); return NULL;
}
static void bound_table(NvShader *sh,int target_w,int target_h,int sample_w,int sample_h) {
    REQUIRE(sh->nts==1&&sh->ts[0].idx==1&&sh->ts[0].reg==0&&!sh->ts[0].img&&sh->ab_buf);
    int support=-1; for(int i=0;i<sh->rf.nb;i++) if(sh->rf.b[i].kind==NVN_RB_SUPPORT) support=sh->rf.b[i].aid;
    REQUIRE(support>=0); uint64_t gpu; memcpy(&gpu,(const uint8_t *)sh->ab_buf.contents+sh->ab_off+support*8,8); REQUIRE(gpu);
    const uint8_t *data=arena_span(gpu,NVN_SIZE_ABI_REQUIRED);
    const int32_t target[]={target_w,target_h,target_w,target_h},sample[]={sample_w,sample_h,sample_w,sample_h};
    REQUIRE(!memcmp(data+NVN_SIZE_ABI_OFFSET,target,sizeof target)); REQUIRE(!memcmp(data+NVN_SIZE_ABI_OFFSET+16,sample,sizeof sample));
    const int32_t zero[4]={0}; REQUIRE(!memcmp(data+NVN_SIZE_ABI_OFFSET+72*16,zero,sizeof zero));
    REQUIRE(!memcmp(data,support_buf().contents,NVN_SIZE_ABI_OFFSET));
}
// #967 table follows the pass: an exact ABI2 shader without texture entries binds its stage's pass copy (size_abi_pass_support): entry 0 = the attachment's
//   logical / physical size, entries 1-72 zero, the base block below the table, and every draw of the pass on the same base binds the same copy
static uint64_t pass_table(NvShader *sh,int target_w,int target_h) {
    REQUIRE(sh->nts==0&&sh->size_exact&&sh->ab_buf);
    int support=-1; for(int i=0;i<sh->rf.nb;i++) if(sh->rf.b[i].kind==NVN_RB_SUPPORT) support=sh->rf.b[i].aid;
    REQUIRE(support>=0); uint64_t gpu; memcpy(&gpu,(const uint8_t *)sh->ab_buf.contents+sh->ab_off+support*8,8); REQUIRE(gpu);
    const uint8_t *data=arena_span(gpu,NVN_SIZE_ABI_REQUIRED);
    const int32_t target[]={target_w,target_h,target_w,target_h}; REQUIRE(!memcmp(data+NVN_SIZE_ABI_OFFSET,target,sizeof target));
    for(int i=1;i<NVN_SIZE_ABI_COUNT;i++) { const int32_t zero[4]={0}; REQUIRE(!memcmp(data+NVN_SIZE_ABI_OFFSET+i*16,zero,sizeof zero)); }
    REQUIRE(!memcmp(data,support_buf().contents,NVN_SIZE_ABI_OFFSET));
    return gpu;
}
static void wide_target(image *t) {
    NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetLevels)(&v,2,1);
    API(nvnTextureViewSetLayers)(&v,1,1); API(nvnTextureViewSetTarget)(&v,NVN_TEXTURE_TARGET_2D);
    const NVNtexture *colors[]={&t->texture}; const NVNtextureView *views[]={&v};
    API(nvnCommandBufferSetRenderTargets)(&commands,1,colors,views,NULL,NULL);
    API(nvnCommandBufferSetViewport)(&commands,0,0,t->w>>2,t->h>>2); API(nvnCommandBufferSetScissor)(&commands,0,0,t->w>>2,t->h>>2);
    const float zero[]={0,0,0,0}; API(nvnCommandBufferClearColor)(&commands,0,zero,15);
}
static NSData *wide_read(image *t,int physical_width,size_t *pitch) {
    id<MTLTexture> texture=tex_mtl((const tex_t *)&t->texture);
    REQUIRE(texture&&texture.pixelFormat==MTLPixelFormatRGBA32Float&&texture.width==(NSUInteger)physical_width&&texture.height==72);
    NSUInteger w=texture.width>>2,h=texture.height>>2; *pitch=(w*16+255)&~(size_t)255;
    id<MTLBuffer> out=[g_dev newBufferWithLength:*pitch*h options:MTLResourceStorageModeShared]; REQUIRE(out);
    id<MTLCommandBuffer> cb=q_cb(); id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:1 sourceLevel:2 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
        toBuffer:out destinationOffset:0 destinationBytesPerRow:*pitch destinationBytesPerImage:*pitch*h];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    return [NSData dataWithBytes:out.contents length:*pitch*h];
}
static int near(float a,float b) { return isfinite(a)&&isfinite(b)&&fabsf(a-b)<0.0001f; }
// Independent rational oracle. FragCoord is a physical pixel center; the
// authored main first divides it by F. Only the coordinate multiplier uses
// selected-mip P/L; the phase divisor is F here (equal to P/L in wide128,
// otherwise the genuinely negative legacy scale produced by the core).
static int wide_sample_x(int x,int base_l,int base_p) {
    int l=base_l>>2,p=base_p>>2;
    int64_t input=(int64_t)(2*x+1)*base_l/(2*base_p);
    int64_t phase=(int64_t)(2*x+1)*base_l%(2*base_p);
    return (int)((input*p*(2*base_l)+phase*l)/(l*(2*base_l)));
}
static void wide_gpu(int base_l) {
    int base_p=base_l==128?156:161,l=base_l>>2,p=base_p>>2;
    image source,target_image; make_image(&source,base_l,72,NVN_FORMAT_RGBA32F); make_image(&target_image,base_l,72,NVN_FORMAT_RGBA32F);
    NvShader *vs=load(@"fullscreen_vs"),*coord=load(@"frag_coord_ps"),*fetch=load(@"fetch_lod2_ps");
    REQUIRE(coord->fragc&&fetch->fragc&&fetch->exact==1);
    NVNprogram *pattern=program(vs,coord,nil),*copy=program(vs,fetch,nil);
    begin(); states(); wide_target(&source); draw_record(pattern,0); submit();
    size_t source_pitch,target_pitch; NSData *source_data=wide_read(&source,base_p,&source_pitch);
    NVNtextureView input; API(nvnTextureViewSetDefaults)(&input); API(nvnTextureViewSetLevels)(&input,0,3);
    API(nvnTextureViewSetLayers)(&input,1,1); API(nvnTextureViewSetTarget)(&input,NVN_TEXTURE_TARGET_2D);
    API(nvnTexturePoolRegisterTexture)(&descriptors,256,&source.alias,&input);
    NVNtextureHandle handle=API(nvnDeviceGetTexelFetchHandle)(&device,256);
    begin(); states(); wide_target(&target_image); draw_record(copy,handle); submit();
    REQUIRE(g_wd_mode==S2A_WIDEN_SCALEK&&g_wd_rs_data);
    REQUIRE(fetch->nts==1&&fetch->ts[0].idx==1&&fetch->ts[0].reg==0&&!fetch->ts[0].img);
    int aid=-1; for(int i=0;i<fetch->rf.nb;i++) if(fetch->rf.b[i].kind==NVN_RB_SUPPORT) aid=fetch->rf.b[i].aid;
    REQUIRE(aid>=0&&fetch->ab_buf); uint64_t gpu; memcpy(&gpu,(const uint8_t *)fetch->ab_buf.contents+fetch->ab_off+aid*8,8);
    const uint8_t *support=arena_span(gpu,NVN_SIZE_ABI_REQUIRED);
    const int32_t rt[]={l,18,p,18},tex[]={base_l,72,base_p,72};
    REQUIRE(!memcmp(support+NVN_SIZE_ABI_OFFSET,rt,sizeof rt)); REQUIRE(!memcmp(support+NVN_SIZE_ABI_OFFSET+16,tex,sizeof tex));
    REQUIRE(!memcmp(support,g_wd_rs_data,NVN_SIZE_ABI_OFFSET));
    float f,legacy,fy; memcpy(&f,support+192,4); memcpy(&legacy,support+192+16,4); memcpy(&fy,support+1440,4);
    REQUIRE(f==(float)base_p/base_l&&legacy==-f&&fy==1);
    REQUIRE((f==(float)p/l)==(base_l==128));
    pthread_mutex_lock(&g_rmu); id<MTLTexture> actual_view=tex_by_id(256); pthread_mutex_unlock(&g_rmu);
    REQUIRE(actual_view&&actual_view.width==(NSUInteger)base_p&&actual_view.parentRelativeLevel==0&&actual_view.parentRelativeSlice==1&&actual_view.mipmapLevelCount==3);
    REQUIRE(tex_mtl((const tex_t *)&source.texture)==tex_mtl((const tex_t *)&source.alias));
    NSData *target_data=wide_read(&target_image,base_p,&target_pitch);
    unsigned observed=0,legacy_differences=0,no_phase_differences=0;
    const int rows[]={1,3,6,12,16};
    // Both cases cover x=1..36. In wide131 the real viewport width is
    // 32*(161/131)=39.328..., so x=39's center 39.5 is outside raster coverage.
    // Stay inside both the drawn source and destination, not in that cleared edge.
    for(unsigned row=0;row<sizeof rows/sizeof *rows;row++) for(int x=1;x<=36;x++) {
        int y=rows[row],sx=wide_sample_x(x,base_l,base_p);
        REQUIRE(sx>=0&&sx<p&&(2*sx+1)*base_l<2*l*base_p);
        const float *want=(const float *)((const uint8_t *)source_data.bytes+y*source_pitch+sx*16);
        const float *got=(const float *)((const uint8_t *)target_data.bytes+y*target_pitch+x*16);
        REQUIRE(near(want[0],(float)((sx+0.5)*(double)base_l/base_p))&&near(want[1],y+0.5f)&&want[2]==0&&want[3]==1);
        for(int c=0;c<4;c++) REQUIRE(near(got[c],want[c]));
        // The retained whole-helper/base-level mapping returns floor(FragCoord)=x
        // for this authored main. Cross-check these formula differences against
        // today's real production legacy-helper GPU control below.
        if(sx!=x) { const float *old=(const float *)((const uint8_t *)source_data.bytes+y*source_pitch+x*16); REQUIRE(!near(got[0],old[0])); legacy_differences++; }
        int input_x=(int)((int64_t)(2*x+1)*base_l/(2*base_p)),unphased=input_x*p/l;
        if(sx!=unphased) { const float *old=(const float *)((const uint8_t *)source_data.bytes+y*source_pitch+unphased*16); REQUIRE(!near(got[0],old[0])); no_phase_differences++; }
        observed++;
    }
    REQUIRE(observed==180&&no_phase_differences>0);
    REQUIRE(base_l==128?(wide_sample_x(3,base_l,base_p)==3&&!legacy_differences):(wide_sample_x(30,base_l,base_p)==31&&legacy_differences>0));
    // The identical authored fetch IR, compiled with the production default
    // size-table capability=false, executes today's retained legacy helper.
    // Metadata below comes unchanged from Analyze/ScaleMetadata and the loader.
    NSDictionary *legacy_asset=assets[@"legacy_fetch_lod2_ps"]; REQUIRE(legacy_asset);
    NvShader *legacy_fetch=shader_load([legacy_asset[@"key"] stringByAppendingString:@"_b"],1,0);
    REQUIRE(legacy_fetch&&legacy_fetch->size_abi&&!legacy_fetch->size_exact&&legacy_fetch->exact==1&&legacy_fetch->fragc);
    image legacy_image; make_image(&legacy_image,base_l,72,NVN_FORMAT_RGBA32F);
    NVNprogram *legacy_program=program(vs,legacy_fetch,nil);
    begin(); states(); wide_target(&legacy_image); draw_record(legacy_program,handle); submit();
    REQUIRE(g_wd_mode==S2A_WIDEN_SCALEK&&g_wd_rs_data);
    REQUIRE(legacy_fetch->nts==1&&legacy_fetch->ts[0].idx==1&&legacy_fetch->ts[0].reg==0&&!legacy_fetch->ts[0].img);
    int legacy_aid=-1; for(int i=0;i<legacy_fetch->rf.nb;i++) if(legacy_fetch->rf.b[i].kind==NVN_RB_SUPPORT) legacy_aid=legacy_fetch->rf.b[i].aid;
    REQUIRE(legacy_aid>=0&&legacy_fetch->ab_buf); uint64_t legacy_gpu;
    memcpy(&legacy_gpu,(const uint8_t *)legacy_fetch->ab_buf.contents+legacy_fetch->ab_off+legacy_aid*8,8);
    const uint8_t *legacy_support=arena_span(legacy_gpu,NVN_SIZE_ABI_REQUIRED);
    const uint8_t zero_table[NVN_SIZE_ABI_REQUIRED-NVN_SIZE_ABI_OFFSET]={0};
    REQUIRE(!memcmp(legacy_support+NVN_SIZE_ABI_OFFSET,zero_table,sizeof zero_table));
    REQUIRE(!memcmp(legacy_support,g_wd_rs_data,NVN_SIZE_ABI_OFFSET));
    float legacy_f,legacy_scale,legacy_fy;
    memcpy(&legacy_f,legacy_support+192,4); memcpy(&legacy_scale,legacy_support+192+16,4); memcpy(&legacy_fy,legacy_support+1440,4);
    REQUIRE(legacy_f==f&&legacy_scale==-f&&legacy_fy==1);
    size_t legacy_pitch; NSData *legacy_data=wide_read(&legacy_image,base_p,&legacy_pitch);
    unsigned legacy_observed=0,legacy_gpu_differences=0;
    for(unsigned row=0;row<sizeof rows/sizeof *rows;row++) for(int x=1;x<=36;x++) {
        int y=rows[row],sx=wide_sample_x(x,base_l,base_p);
        const float *legacy_got=(const float *)((const uint8_t *)legacy_data.bytes+y*legacy_pitch+x*16);
        const float *legacy_want=(const float *)((const uint8_t *)source_data.bytes+y*source_pitch+x*16);
        const float *exact_want=(const float *)((const uint8_t *)source_data.bytes+y*source_pitch+sx*16);
        const float *exact_got=(const float *)((const uint8_t *)target_data.bytes+y*target_pitch+x*16);
        for(int c=0;c<4;c++) REQUIRE(near(legacy_got[c],legacy_want[c]));
        REQUIRE(near(exact_got[0],exact_want[0]));
        if(sx!=x) { REQUIRE(!near(legacy_got[0],exact_want[0])&&!near(legacy_got[0],exact_got[0])); legacy_gpu_differences++; }
        else REQUIRE(near(legacy_got[0],exact_got[0]));
        legacy_observed++;
    }
    REQUIRE(legacy_observed==180&&legacy_gpu_differences==(base_l==128?0u:40u)&&legacy_gpu_differences==legacy_differences);
    printf("✓ t_nvn_size_abi wide%d %s: 180 real mip2 fetch pixels, F=%g target=%d/%d legacy=%g, formula differences legacy=%u/no-phase=%u; %u checks\n",
        base_l,g_m3?"Metal3":"Metal4",f,p,l,legacy,legacy_differences,no_phase_differences,checks);
    printf("✓ retained production legacy helper GPU control: 180 pixels x→x, ABI2 legacy_1x zero table, same exact oracle differences=%u/180 (not a frozen old-commit host control)\n",legacy_gpu_differences);
}
// 审计缺口族 36（模板参考值）：NVN 正反两面各有参考值，编码器要把两面都交给 Metal（原先只发正面、背面被丢）。假编码器记下收到的值
@interface StencilRefProbe : NSObject
@property uint32_t front, back;
@end
@implementation StencilRefProbe
- (void)setStencilReferenceValue:(uint32_t)v { self.front = self.back = v; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { self.front = f; self.back = b; }
@end
static void stencil_ref_faces(void) {
    StencilRefProbe *e=[StencilRefProbe new]; enc_r_stencil_ref((id<MTL4RenderCommandEncoder>)(id)e,3,7);
    REQUIRE(e.front==3); REQUIRE(e.back==7);   // 旧实现：背面也是 3
}

int main(int argc,char **argv) { @autoreleasepool {
    REQUIRE(argc==2||argc==3); int wide=0;
    stencil_ref_faces();
    if(argc==3) { REQUIRE(!strcmp(argv[2],"wide128")||!strcmp(argv[2],"wide131")); wide=!strcmp(argv[2],"wide128")?128:131; }
    setenv("DM_MSL_DIR",argv[1],1); setenv("S2A_WIDEN_DIRECT",wide?"1":"0",1);
    if(wide) { setenv("S2A_SCREEN_W","2346",1); setenv("S2A_SCREEN_H","1080",1); setenv("S2A_WIDEN_VERIFIED","1",1); setenv("S2A_WIDEN_FULL","1",1); }
    setenv("DM_NVN_SHMAP",[[@(argv[1]) stringByAppendingPathComponent:@"shader_map.tsv"] fileSystemRepresentation],1);
    setenv("DM_NVN_FIRST_SKIP","0",1); setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    NSData *json=[NSData dataWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@"manifest.json"]]; REQUIRE(json);
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]; REQUIRE([manifest[@"chain"] isEqual:@DMSH_CHAIN]);
    assets=manifest[@"assets"]; REQUIRE(assets); setup(); shmap_load();
    if(wide) { wide_gpu(wide); return 0; }
    image source_a,source_b,out_a,out_b; make_image(&source_a,13,9,NVN_FORMAT_RGBA8); make_image(&source_b,21,13,NVN_FORMAT_RGBA8);
    make_image(&out_a,13,9,NVN_FORMAT_RGBA32F); make_image(&out_b,17,11,NVN_FORMAT_RGBA32F);
    NVNtextureView v=selected(); API(nvnTexturePoolRegisterTexture)(&descriptors,256,&source_a.alias,&v);
    API(nvnTexturePoolRegisterTexture)(&descriptors,257,&source_b.alias,&v);
    NVNtextureHandle a=API(nvnDeviceGetTexelFetchHandle)(&device,256),b=API(nvnDeviceGetTexelFetchHandle)(&device,257);
    NvShader *vs=load(@"fullscreen_vs"),*fs=load(@"size_lod0_ps"),*cs=load(@"size_lod0_cs");
    NVNprogram *render=program(vs,fs,nil),*compute=program(nil,nil,cs);
    memset(memory+RESULT,0xcc,16);
    begin(); states(); target(&out_a); draw_record(render,a); dispatch_record(compute,b);
    target(&out_b); draw_record(render,a);
    API(nvnCommandBufferSetScissor)(&commands,(out_b.w>>1)/2,0,(out_b.w>>1)-(out_b.w>>1)/2,out_b.h>>1); draw_record(render,b); submit();
    pixels(&out_a,0,6,4,0,0); pixels(&out_b,1,6,4,10,6);
    const float expected[]={10,6,0,1}; REQUIRE(!memcmp(memory+RESULT,expected,16));
    bound_table(fs,8,5,10,6); bound_table(cs,0,0,10,6);
    REQUIRE(tex_mtl((const tex_t *)&source_a.texture)==tex_mtl((const tex_t *)&source_a.alias));
    pthread_mutex_lock(&g_rmu); id<MTLTexture> selected_a=tex_by_id(256); pthread_mutex_unlock(&g_rmu);
    REQUIRE(selected_a&&selected_a.width==6&&selected_a.height==4&&selected_a.parentRelativeLevel==1&&selected_a.parentRelativeSlice==1);
    uint64_t previous_sub=fs->ab_size_sub;
    begin(); states(); target(&out_a); draw_record(render,b); submit(); pixels(&out_a,0,10,6,0,0);
    REQUIRE(fs->ab_size_sub>previous_sub); bound_table(fs,6,4,10,6);
    // 缺口族 34（Alpha 测试）：size_lod0_ps 输出 alpha 恒 1。先画出 (10,6)；颜色状态开 GREATER、SetAlphaRef 2.0 再画 a（1 > 2 不成立 → 整笔丢弃）→ 仍是 (10,6)；
    //   另一次提交参考值 0.5 → 画上 (6,4)。旧宿主不做 Alpha 测试（SetAlphaRef 空操作）：第一段就读到 (6,4)
    { NVNcolorState gt; API(nvnColorStateSetDefaults)(&gt); API(nvnColorStateSetAlphaTest)(&gt,NVN_ALPHA_FUNC_GREATER);
      begin(); states(); target(&out_a); draw_record(render,b); API(nvnCommandBufferBindColorState)(&commands,&gt); API(nvnCommandBufferSetAlphaRef)(&commands,2.0f); draw_record(render,a); submit();
      pixels(&out_a,0,10,6,0,0);
      begin(); states(); target(&out_a); API(nvnCommandBufferBindColorState)(&commands,&gt); API(nvnCommandBufferSetAlphaRef)(&commands,0.5f); draw_record(render,a); submit();
      pixels(&out_a,0,6,4,0,0); }
    // 缺口族 37（多重采样关，白盒）：关多重采样、4 样本目标 → 管线键 msoff = 1；NVN 缺省（开）→ 0；带 S2A_MSOFF 的特化函数建得出
    { const uint32_t cf[8]={MTLPixelFormatRGBA32Float}; pso_key k; state_reset(); S.ms.enable=0; pso_key_fill(&k,vs,fs,cf,0,0,4,0); REQUIRE(fs->has_atms&&k.msoff==1&&k.at==0);   // 上一组的 GREATER 还在 S 里：先复位
      state_reset(); pso_key_fill(&k,vs,fs,cf,0,0,4,0); REQUIRE(k.msoff==0); REQUIRE(fs_atms_fn(fs,0,0,1)&&fs_atms_fn(fs,0,5,1)); }
    // frag_coord_ps: exact, no texture entries → the pass copy. Two passes of different size in one submission, then a third pass in the next one
    NvShader *coord=load(@"frag_coord_ps"); NVNprogram *coordp=program(vs,coord,nil); image out_c,out_d; make_image(&out_c,13,9,NVN_FORMAT_RGBA32F); make_image(&out_d,17,11,NVN_FORMAT_RGBA32F);
    begin(); states(); target(&out_c); draw_record(coordp,a); draw_record(coordp,a); submit();
    uint64_t c1=pass_table(coord,6,4); REQUIRE(c1==g_size_pass[1].gpu);
    begin(); states(); target(&out_c); draw_record(coordp,a); target(&out_d); draw_record(coordp,a); submit();
    uint64_t c2=pass_table(coord,8,5); REQUIRE(c2!=c1&&c2==g_size_pass[1].gpu);
    REQUIRE(!nvn_be_request_stop()); REQUIRE(!nvn_be_shutdown_session());
    for(int stage=0;stage<6;stage++) REQUIRE(!g_size_cache[stage].gpu&&!g_size_pass[stage].gpu);
    REQUIRE(!fs->ab_buf&&!cs->ab_buf&&!g_wd_rs_gpu&&!g_wd_rs_data); nvn_be_begin_session();
    printf("✓ t_nvn_size_abi %s: real selected-mip alias, GPU draw-dispatch-draw, same-pass binding change, bound ABI2 arena, next-submit freshness, table per pass for no-entry shaders, retirement reset; %u checks\n",g_m3?"Metal3":"Metal4",checks);
    return 0;
} }
