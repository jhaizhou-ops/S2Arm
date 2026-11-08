// Original MSL, real production loader/prewarm/prefetch/runtime entries and GPU
// readback. NVN_SHADER_FLIGHT_SOURCE also accepts the exact pre-fix source.
#ifndef NVN_SHADER_FLIGHT_SOURCE
#define NVN_SHADER_FLIGHT_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_SHADER_FLIGHT_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while(0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)
static NSString *root, *fallback;
static NSString *const vertex_source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float value; };\n"
"struct L { float4 p [[position]]; float value; uint layer [[render_target_array_index]]; };\n"
"float4 pos(uint i) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"vertex V plain(uint i [[vertex_id]]) { return {pos(i),0.25}; }\n"
"vertex V zero(uint i [[vertex_id]]) { return {pos(i),0.5}; }\n"
"vertex L layered(uint i [[vertex_id]]) { return {pos(i),0.75,1}; }\n"
"vertex L layered_zero(uint i [[vertex_id]]) { return {pos(i),1.0,1}; }\n"
"fragment float4 color(V v [[stage_in]]) { return float4(v.value,0,0,1); }\n";
static NSString *const compute_source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"struct Inputs { device uint *p [[id(0)]]; };\n"
"kernel void output(constant Inputs &a [[buffer(0)]]) { *a.p=0x1234abcd; }\n";

// 本测扮演链了 S2A.Aot 的 App：兜底目录的 json 要带与它相同的翻译器指纹才载（nvn_mtl.m fb_json_current，dlsym 在主程序里找到它）
const char *s2a_dsh_xfp(void) { return "0123456789abcdef"; }
static NSDictionary *reflection(NSString *entry) {
    return @{@"chain":@DMSH_CHAIN,@"xfp":@"0123456789abcdef",@"route":@"B",@"bindings":@[],@"entry":entry,
        @"entry_z":@"zero",@"entry_layer":@"layered",@"entry_layer_z":@"layered_zero",
        @"gs_slice":@{@"loc":@0,@"comp":@"x"}};
}
static void write_text(NSString *path, NSString *text) {
    NSError *error=nil; REQUIRE([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]);
}
static void fixture(NSString *key, NSString *source, NSString *entry) {
    write_text([fallback stringByAppendingPathComponent:[key stringByAppendingString:@".metal"]],source);
    NSMutableDictionary *metadata=[reflection(entry) mutableCopy];
    if([source isEqual:compute_source] && [entry isEqual:@"output"]) metadata[@"bindings"]=@[@{@"kind":@"sbuf",@"reg":@0,@"arg_id":@0,
        @"msl_name":@"p",@"msl_type":@"device uint *",@"rw":@YES}];
    NSData *json=[NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil]; REQUIRE(json);
    REQUIRE([json writeToFile:[fallback stringByAppendingPathComponent:[key stringByAppendingString:@".json"]] atomically:YES]);
}
static NvShader *prefetch(NSString *key) {
    uint8_t md[8]; const char *s=key.UTF8String;
    for(int i=0;i<8;i++) { unsigned v; REQUIRE(sscanf(s+2*i,"%2x",&v)==1); md[i]=(uint8_t)v; }
    nvn_be_shader_prefetch(md);
    uint64_t deadline=bp_now()+10000000000ull;
    while(bp_now()<deadline) {
        NvShader *found=nil;
        os_unfair_lock_lock(&g_warm_lock);
        for(WarmItem *item in g_warm_items) if(item->kind==3 && [item->key isEqual:key]) { found=item->shader; break; }
        os_unfair_lock_unlock(&g_warm_lock);
        if(found) return found;
        usleep(1000);
    }
    REQUIRE(0 && "prefetch must enqueue a real shader"); return nil;
}
static void compute_gpu(NvShader *shader) {
    REQUIRE(shader && shader->fn);
    NSError *error=nil; id<MTLComputePipelineState> p=[g_dev newComputePipelineStateWithFunction:shader->fn error:&error]; REQUIRE(p);
    id<MTLBuffer> out=[g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared]; REQUIRE(out); *(uint32_t *)out.contents=0;
    REQUIRE(shader->arg_len==8);   // 参数块按反射算长度、每个编号 8 字节放 GPU 地址（与生产 encode_args 同法；不再向 Metal 要编码器对象，nvn_mtl.m shader_args_init）
    id<MTLBuffer> arguments=[g_dev newBufferWithLength:shader->arg_len options:MTLResourceStorageModeShared]; REQUIRE(arguments);
    *(uint64_t *)arguments.contents=out.gpuAddress;
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
    id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder]; [e setComputePipelineState:p]; [e useResource:out usage:MTLResourceUsageWrite];
    [e setBuffer:arguments offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    CHECK(*(uint32_t *)out.contents==0x1234abcd,"compute GPU uint expected=0x1234abcd actual=0x%08x",*(uint32_t *)out.contents);
}
static void vertex_gpu(NvShader *shader, float expected, int layer) {
    REQUIRE(shader && shader->fn);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:vertex_source options:dm_msl_opts() error:&error]; REQUIRE(lib);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=shader->fn;
    pd.fragmentFunction=[lib newFunctionWithName:@"color"]; pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
    pd.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle;
    id<MTLRenderPipelineState> p=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
    if(!p) fprintf(stderr,"PSO: %s\n",error.localizedDescription.UTF8String); REQUIRE(p);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:NO];
    td.textureType=MTLTextureType2DArray; td.arrayLength=2; td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate;
    id<MTLTexture> target=[g_dev newTextureWithDescriptor:td]; REQUIRE(target);
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor]; rp.renderTargetArrayLength=layer?2:1;
    rp.colorAttachments[0].texture=target; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].storeAction=MTLStoreActionStore; rp.colorAttachments[0].clearColor=MTLClearColorMake(-1,-1,-1,-1);
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:p];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    id<MTLBuffer> out=[g_dev newBufferWithLength:512 options:MTLResourceStorageModeShared]; REQUIRE(out);
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:layer?1:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(2,2,1)
        toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:512]; [blit endEncoding];
    [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    unsigned wrong=0; float first=*(float *)out.contents;
    for(unsigned y=0;y<2;y++) for(unsigned x=0;x<2;x++) {
        const float *v=(const float *)((const uint8_t *)out.contents+y*256+x*16);
        wrong+=v[0]!=expected || v[1]!=0 || v[2]!=0 || v[3]!=1;
    }
    CHECK(!wrong,"vertex GPU %s slice=%d expected red=%.2f actual=%.2f wrong pixels=%u",shader->ventry.UTF8String,layer,expected,first,wrong);
}
static void independent_keys(void) {
    NSString *slow=@"4444444444444444_b", *fast=@"5555555555555555_b";
    fixture(slow,vertex_source,@"plain"); fixture(fast,vertex_source,@"plain");
    NSString *json_path=[g_msl_dir stringByAppendingPathComponent:[slow stringByAppendingString:@".json"]];
    NSData *json=[NSData dataWithContentsOfFile:[fallback stringByAppendingPathComponent:[slow stringByAppendingString:@".json"]]];
    REQUIRE(json && [json writeToFile:json_path atomically:YES]);
    NSString *path=[g_msl_dir stringByAppendingPathComponent:[slow stringByAppendingString:@".metallib"]];
    REQUIRE(!mkfifo(path.fileSystemRepresentation,0600));
    dispatch_semaphore_t started=dispatch_semaphore_create(0), slow_done=dispatch_semaphore_create(0), fast_done=dispatch_semaphore_create(0);
    __block NvShader *a=nil, *b=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        dispatch_semaphore_signal(started); a=warm_shader(slow,0); dispatch_semaphore_signal(slow_done);
    } });
    REQUIRE(!dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,10000000000ll)));
#ifdef NVN_SHADER_FLIGHT_IMPL
    uint64_t deadline=bp_now()+10000000000ull;
    while(!atomic_load(&g_shader_build_live) && bp_now()<deadline) sched_yield();
    REQUIRE(atomic_load(&g_shader_build_live));
#endif
    // lib_from_file really opens this FIFO; there is no substituted loader.
    CHECK(dispatch_semaphore_wait(slow_done,dispatch_time(DISPATCH_TIME_NOW,100000000ll))!=0,"first identity waits in real library file open");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        b=shader_get(fast,0); dispatch_semaphore_signal(fast_done);
    } });
    int progressed=!dispatch_semaphore_wait(fast_done,dispatch_time(DISPATCH_TIME_NOW,10000000000ll));
    CHECK(progressed && b && b->fn,"different identity completes while first library input is unavailable");
#ifdef NVN_SHADER_FLIGHT_IMPL
    uint64_t waits=atomic_load(&g_shader_waits);
    uint64_t frame_ns_before=0, pso_ns=0, frame_wait_before=g_bp_lib_wait_ns, builds_before=g_bp_lib_n;
    nvn_be_create_ns(&frame_ns_before,&pso_ns);
    dispatch_semaphore_t follower_done=dispatch_semaphore_create(0); __block NvShader *follower=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        follower=shader_get(slow,0); dispatch_semaphore_signal(follower_done);
    } });
    const uint8_t md[8]={0x44,0x44,0x44,0x44,0x44,0x44,0x44,0x44}; nvn_be_shader_prefetch(md);
    deadline=bp_now()+10000000000ull;
    while(atomic_load(&g_shader_waits)<waits+2 && bp_now()<deadline) sched_yield();
    CHECK(atomic_load(&g_shader_waits)==waits+2,"runtime and actual prefetch join the blocked warm attempt");
    CHECK(dispatch_semaphore_wait(follower_done,dispatch_time(DISPATCH_TIME_NOW,10000000ll))!=0,"submit load is genuinely blocked while the shared library input is unavailable");
#endif
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_NONBLOCK); REQUIRE(fd>=0);
    close(fd); // An empty FIFO is correctly rejected, never treated as a library.
    REQUIRE(!dispatch_semaphore_wait(slow_done,dispatch_time(DISPATCH_TIME_NOW,10000000000ll)));
    if(!progressed) REQUIRE(!dispatch_semaphore_wait(fast_done,dispatch_time(DISPATCH_TIME_NOW,10000000000ll)));
    CHECK(!a,"empty library input is a real construction failure");
#ifdef NVN_SHADER_FLIGHT_IMPL
    REQUIRE(!dispatch_semaphore_wait(follower_done,dispatch_time(DISPATCH_TIME_NOW,10000000000ll)));
    CHECK(!follower,"an existing waiter receives the failed attempt, without fake success");
    uint64_t frame_ns_after=0; nvn_be_create_ns(&frame_ns_after,&pso_ns);
    CHECK(g_bp_lib_n==builds_before && g_bp_lib_wait_ns>frame_wait_before &&
        frame_ns_after-frame_ns_before==g_bp_lib_wait_ns-frame_wait_before,
        "failed shared submit wait enters frame time without a fake construction: %.3f ms",(frame_ns_after-frame_ns_before)/1e6);
#endif
    REQUIRE(!unlink(path.fileSystemRepresentation)); REQUIRE(!unlink(json_path.fileSystemRepresentation));
    a=warm_shader(slow,0); CHECK(a && a->fn,"failed library input can retry the available fallback");
}
#ifdef NVN_SHADER_FLIGHT_IMPL
static void retirement_prefetch(void) {
    NSString *layer_key=@"8888888888888888_b", *depth_key=@"9999999999999999_b";
    fixture(layer_key,vertex_source,@"plain"); fixture(depth_key,vertex_source,@"plain");
    // Real loader objects, but neither is the ordinary GL vertex identity
    // consumed by the next session's prefetch.
    NvShader *layer=shader_load_depth(layer_key,0,1,0,NULL,NULL);
    NvShader *depth=shader_load_depth(depth_key,0,0,1,NULL,NULL);
    REQUIRE(layer && depth && [layer->ventry isEqual:@"layered"] && [depth->ventry isEqual:@"zero"]);
    nvn_be_set_depth_zero(0);
    REQUIRE(!nvn_be_request_stop());
    REQUIRE(!nvn_be_shutdown_session());
    nvn_be_begin_session();

    uint64_t requests=atomic_load(&g_shader_requests);
    const uint8_t md[8]={0x11,0x11,0x11,0x11,0x11,0x11,0x11,0x11};
    nvn_be_shader_prefetch(md);
    shpre_sync();
    os_unfair_lock_lock(&g_warm_lock);
    NSUInteger handoffs=g_warm_items.count;
    os_unfair_lock_unlock(&g_warm_lock);
    CHECK(!g_shpre_n && atomic_load(&g_shader_requests)==requests && !handoffs,
        "retired cached ordinary shader causes no next-session load or prefetch handoff (loads=%llu handoffs=%lu)",
        (unsigned long long)g_shpre_n,(unsigned long)handoffs);

    NvShader *plain_layer=prefetch(layer_key), *plain_depth=prefetch(depth_key);
    CHECK(plain_layer!=layer && [plain_layer->ventry isEqual:@"plain"] &&
        plain_depth!=depth && [plain_depth->ventry isEqual:@"plain"],
        "layer-only and other-depth caches still prefetch their missing ordinary identities after retirement");
    shpre_sync();
    CHECK(g_shpre_n==2,"next-session prefetch loads only the two missing ordinary identities (actual=%llu)",
        (unsigned long long)g_shpre_n);
    warm_claim();
}
#endif
int main(void) { @autoreleasepool {
    char tmp[]="/tmp/t_nvn_shader_flight_XXXXXX"; REQUIRE(mkdtemp(tmp)); root=@(tmp);
    fallback=[root stringByAppendingPathComponent:@"fallback"];
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *map=[root stringByAppendingPathComponent:@"shader_map.tsv"];
    write_text(map,@"original\t0\tvertex\t1111111111111111\noriginal\t0\tvertex\t2222222222222222\noriginal\t0\tvertex\t3333333333333333\noriginal\t0\tvertex\t4444444444444444\noriginal\t0\tvertex\t8888888888888888\noriginal\t0\tvertex\t9999999999999999\noriginal\t0\tvertex\taaaaaaaaaaaaaaaa\noriginal\t0\tvertex\tbbbbbbbbbbbbbbbb\noriginal\t0\tgeometry\tcccccccccccccccc\noriginal\t0\tgeometry\tdddddddddddddddd\n");
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"b-" DMSH_CHAIN]
        withIntermediateDirectories:YES attributes:nil error:nil]);
    setenv("DM_NVN_SHMAP",map.fileSystemRepresentation,1); setenv("DM_MSL_DIR",root.fileSystemRepresentation,1);
    setenv("DM_MSL_FALLBACK",fallback.fileSystemRepresentation,1); setenv("DM_PSO_MANIFEST","off",1);
    setenv("DM_PSO_ARCHIVE","0",1); setenv("DM_PSO_USER",[root stringByAppendingPathComponent:@"user.tsv"].fileSystemRepresentation,1);
    mtl_init(); shmap_load(); printf("GPU %s; backend %s\n",g_dev.name.UTF8String,g_m3?"Metal3":"Metal4");
#ifndef NVN_SHADER_FLIGHT_IMPL
    g_warm_dict=[NSMutableDictionary dictionary];
#endif
    NSString *key=@"1111111111111111_b"; fixture(key,vertex_source,@"plain");
    int before=atomic_load(&g_vs_loaded);
    NvShader *warm=warm_shader(key,0), *pre=prefetch(key), *runtime=shader_get(key,0);
    int constructed=atomic_load(&g_vs_loaded)-before;
    CHECK(constructed==1,"production warm + prefetch + runtime: actual vertex constructions=%d (expected 1)",constructed);
    CHECK(warm && warm==pre && pre==runtime,"three production entries retain the same shader/function identity");
    vertex_gpu(runtime,0.25f,0);

    key=@"2222222222222222_b"; fixture(key,vertex_source,@"plain"); before=atomic_load(&g_vs_loaded);
    dispatch_apply(16,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i) { @autoreleasepool { REQUIRE(warm_shader(key,0)); } });
    constructed=atomic_load(&g_vs_loaded)-before;
    CHECK(constructed==1,"16 concurrent production warm requests: actual vertex constructions=%d (expected 1)",constructed);
    independent_keys();

    key=@"3333333333333333_b"; fixture(key,vertex_source,@"plain");
    NvShader *gs=warm_shader(key,2), *warm_vs=warm_shader(key,0), *vs=shader_get(key,0);
    CHECK(gs && vs && gs!=warm_vs && warm_vs==vs && gs->stage==2 && vs->stage==0 && vs->fn,"stage is part of identity: warm slice geometry differs from warm/runtime vertex");
    if(vs && vs->fn) vertex_gpu(vs,0.25f,0);
    NvShader *layer=shader_get_layer(runtime); CHECK(layer && layer!=runtime,"layer is part of identity"); vertex_gpu(layer,0.75f,1);
    // New requests have distinct identities; no already-bound NvProg is rebound.
    nvn_be_set_depth_zero(1); NvShader *zero=shader_get(@"1111111111111111_b",0);
    CHECK(zero && zero!=runtime && [zero->ventry isEqual:@"zero"],"depth convention is captured in vertex identity"); vertex_gpu(zero,0.5f,0);
    NvShader *layer_zero=shader_get_layer(zero); vertex_gpu(layer_zero,1.0f,1);
    NvShader *old_bound=warm_shader(@"2222222222222222_b",0);
    nvn_be_set_depth_zero(0);
    NvShader *captured_layer=shader_get_layer(old_bound);
    CHECK(captured_layer && [captured_layer->ventry isEqual:@"layered_zero"],"a bound shader's layer load keeps its captured depth after a mode change");
    vertex_gpu(captured_layer,1.0f,1);
    CHECK(shader_get(@"1111111111111111_b",0)==runtime,"returning to the previous depth convention reuses its object");

    key=@"6666666666666666_b"; CHECK(!warm_shader(key,5),"missing reflection is a failed warm request");
    fixture(key,compute_source,@"output"); NvShader *retry=warm_shader(key,5);
    CHECK(retry && retry->fn,"a later available runtime fallback retries after a warm miss");
    if(retry) { CHECK(shader_get(key,5)==retry,"runtime uses successful retry"); compute_gpu(retry); }
    key=@"7777777777777777_b"; fixture(key,compute_source,@"absent");
    CHECK(!warm_shader(key,5),"missing real Metal function fails rather than caching a successful object");
    fixture(key,compute_source,@"output"); retry=warm_shader(key,5);
    CHECK(retry && retry->fn,"failed function construction does not poison the corrected input"); if(retry && retry->fn) compute_gpu(retry);
#ifdef NVN_SHADER_FLIGHT_IMPL
    // 往前看急载（shader_urgent，11-02 firstuse-lib）：本提交后面要用、还没载的着色器在急载通道上载好，提交线程画到它时直接取缓存（同一对象）；
    //   通道宽度在 2..SHQ_MAX；正在停会话时不排新活。期望按规则写：载好 = 缓存里有该身份且有函数、急载计数 +1；停止中 = 缓存里没有、计数不变
    key=@"aaaaaaaaaaaaaaaa_b"; fixture(key,vertex_source,@"plain");
    uint64_t un=atomic_load(&g_shurg_n); shader_urgent(@"aaaaaaaaaaaaaaaa",0); shpre_sync();
    os_unfair_lock_lock(&g_shader_lock); NvShader *ug=g_shcache[shader_identity(key,0,0,atomic_load(&g_depth_zero))]; os_unfair_lock_unlock(&g_shader_lock);
    CHECK(ug && ug->fn && atomic_load(&g_shurg_n)==un+1 && shader_get(key,0)==ug,"lookahead load: cached before its draw, the draw takes the same object (urgent loads +%llu)",
        (unsigned long long)(atomic_load(&g_shurg_n)-un));
    CHECK(g_shurg.n>=2 && g_shurg.n<=SHQ_MAX && g_shpre.n==g_shurg.n,"lanes: prefetch %d / lookahead %d, within 2..%d",g_shpre.n,g_shurg.n,SHQ_MAX);
    key=@"bbbbbbbbbbbbbbbb_b"; fixture(key,vertex_source,@"plain"); un=atomic_load(&g_shurg_n);
    atomic_store(&g_shpre_stopping,1); shader_urgent(@"bbbbbbbbbbbbbbbb",0); shpre_sync(); atomic_store(&g_shpre_stopping,0);
    os_unfair_lock_lock(&g_shader_lock); ug=g_shcache[shader_identity(key,0,0,atomic_load(&g_depth_zero))]; os_unfair_lock_unlock(&g_shader_lock);
    CHECK(!ug && atomic_load(&g_shurg_n)==un,"session stopping: the lookahead queues no load");
    // P1-91 几何阶段进预取 / 急载：映射表里阶段为 geometry 的键，ProgramSetShaders 时在预取通道载、往前看时在急载通道载，提交线程画到它时取缓存里同一对象、
    //   不再自己构造。期望按规则写：预取计数 +1、急载计数 +1；之后 shader_get 拿到同一对象、构造数不再涨（0 次）
    key=@"cccccccccccccccc_b"; fixture(key,vertex_source,@"plain");   // 有库的几何着色器（反射里去掉 gs_slice）
    { NSMutableDictionary *m=[reflection(@"plain") mutableCopy]; [m removeObjectForKey:@"gs_slice"];
      REQUIRE([[NSJSONSerialization dataWithJSONObject:m options:0 error:nil] writeToFile:[fallback stringByAppendingPathComponent:[key stringByAppendingString:@".json"]] atomically:YES]); }
    uint64_t pn=g_shpre_n; const uint8_t gmd[8]={0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc}; nvn_be_shader_prefetch(gmd); shpre_sync();
    os_unfair_lock_lock(&g_shader_lock); NvShader *gp=g_shcache[shader_identity(key,2,0,0)]; os_unfair_lock_unlock(&g_shader_lock);
    uint64_t builds=atomic_load(&g_shader_builds); NvShader *gget=shader_get(key,2);
    CHECK(gp && gp->fn && gp->stage==2 && g_shpre_n==pn+1 && gget==gp && atomic_load(&g_shader_builds)==builds,
        "geometry prefetch: loaded off the submit thread (prefetch loads +%llu, expected +1), its draw takes the same object (submit-thread constructions +%llu, expected 0)",
        (unsigned long long)(g_shpre_n-pn),(unsigned long long)(atomic_load(&g_shader_builds)-builds));
    key=@"dddddddddddddddd_b"; fixture(key,vertex_source,@"plain");   // 只写层的几何着色器（gs_slice 桩，没有函数）
    un=atomic_load(&g_shurg_n); shader_urgent(@"dddddddddddddddd",2); shpre_sync();
    os_unfair_lock_lock(&g_shader_lock); ug=g_shcache[shader_identity(key,2,0,0)]; os_unfair_lock_unlock(&g_shader_lock);
    builds=atomic_load(&g_shader_builds); gget=shader_get(key,2);
    CHECK(ug && ug->stage==2 && !ug->fn && ug->gs_loc==0 && atomic_load(&g_shurg_n)==un+1 && gget==ug && atomic_load(&g_shader_builds)==builds,
        "geometry lookahead load: cached before its draw (urgent loads +%llu, expected +1), the draw takes the same object (submit-thread constructions +%llu, expected 0)",
        (unsigned long long)(atomic_load(&g_shurg_n)-un),(unsigned long long)(atomic_load(&g_shader_builds)-builds));
    retirement_prefetch();
    printf("LOAD requests=%llu hits=%llu waits=%llu wait_ms=%.3f submit_wait_ms=%.3f builds=%llu failures=%llu active=%llu\n",
        (unsigned long long)atomic_load(&g_shader_requests),(unsigned long long)atomic_load(&g_shader_hits),
        (unsigned long long)atomic_load(&g_shader_waits),atomic_load(&g_shader_wait_ns)/1e6,g_bp_lib_wait_ns/1e6,(unsigned long long)atomic_load(&g_shader_builds),
        (unsigned long long)atomic_load(&g_shader_failures),(unsigned long long)atomic_load(&g_shader_build_live));
#endif
    REQUIRE([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    printf("%s t_nvn_shader_flight: %u checks, %u failures\n",failures?"✗":"✓",checks,failures);
    return failures?1:0;
} }
