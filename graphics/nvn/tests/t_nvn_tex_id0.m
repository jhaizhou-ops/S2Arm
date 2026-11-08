// 纹理池 ID 0 是池的第一项，与别的 ID 一样（11-02 牧场物语 0100C2D00EBD4000 3D 主画面整幅模糊）：游戏把深度缓冲（1280×720，ser 2403）注册在纹理池 ID 0
//   （宿主报保留 256 个描述符，它不理会，真机上照样能用），最终景深合成拿「纹理 0 + 采样器 881」采样它算每个像素的清晰权重。宿主处处把 tid 0 当「没绑」
//   （tid <= 0 / tid ? … : 0），给了占位贴图读 0 → 权重全取模糊图。公开 NVN 接口录制 + 生产 nvn_mtl.m（包含）+ 真 Metal 设备。
// 期望（按 NVN 语义手写：句柄 = 纹理 ID | 采样器 ID << 20，ID 是所绑纹理池里的下标；与被测实现无关）：
//   ① 第一个池（宿主表基址 0）ID 0 注册贴图 A → tex_by_id(0) / tex_fast_rid(0) 都是 A 的 Metal 贴图
//   ② 第二个池（基址 b > 0）ID 0 注册贴图 B；录 SetTexturePool(第二个池) + BindTexture(片元槽 3, 0 | 5 << 20) 提交 → 回放态槽 3 的纹理 ID = b（不是 0），解析成 B
//   ③ 没注册的 ID（第一个池 ID 7）→ 仍然没有（nil），不变
//   ④ 绘制时真走编码路径（encode_args 的 TEX 绑定，景深合成那条）：计算着色器从纹理槽 3（句柄 = ID 0 | 采样器 0）read 第一个像素写进存储缓冲；
//      注册在 ID 0 的贴图 C 存储整块填 0x40 → 读到 64 / 255（真贴图）；占位贴图读 0
//   反证（11-02 手工核过）：同一测试编改前的 nvn_mtl.m / hle_nvn.c / nvn_obj.h：② 不通（第二个池的 ID 0 没加基址）、④ 读到 0（编码时 tid 0 当没绑、给占位贴图）；
//      ① 改前也通（tex_by_id / tex_fast_rid 本来收 0，丢的是调用方 tid ? … : 0），只作正对照
// ⓪ 句柄 0 读到空项（11-04 巫师3 / 6 款普查各一条「【红】 texture ID 0 not registered」）：着色器声明了、游戏从没绑的槽，状态里是句柄 0 = 纹理 ID 0。
//   ID 0 还没注册时，真机读池第 0 项、Ryujinx 读到空描述符（地址 0）→ 不建贴图、后端绑全 0 的占位贴图（TexturePool.GetInternal / DescriptorSetUpdater 的
//   _dummyTexture），不报错。期望（按这条语义手写）：
//   ⓪a 任何 ID 都没注册时 tex_by_id(0) = nil（读 0），日志里没有「【红】 texture ID 0」——这不是注册漏；
//   ⓪b 随后查没注册的 ID 7 → 照样报「【红】 texture ID 7 not registered」（改前句柄 0 先占掉这条只报一次的红，后面真正的注册漏全被吞）；
//   ⓪c ID 0 之后注册上（①）→ 记一行「texture ID 0 registered … after 1 reads as an empty slot」（不报红：真机上先读空、后读到贴图也是这样）
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static NVNtexturePool pool_a, pool_b;
static uint8_t *memory; static unsigned checks, fails;
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20 };
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
static void make_tex(NVNtexture *t, ptrdiff_t off) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, 16, 16); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetStorage)(&b, &pool, off); REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static id<MTLTexture> by_id(int tid) { pthread_mutex_lock(&g_rmu); id<MTLTexture> t = tex_by_id(tid); pthread_mutex_unlock(&g_rmu); return t; }
// 标准错误（MLOG 写在那里）临时转进一个文件，读回这一段日志
static char g_log[8192]; static int g_saved_err = -1; static FILE *g_logf;
static void log_begin(void) { fflush(stderr); g_logf = tmpfile(); REQUIRE(g_logf); g_saved_err = dup(2); dup2(fileno(g_logf), 2); }
static const char *log_end(void) {
    fflush(stderr); dup2(g_saved_err, 2); close(g_saved_err);
    rewind(g_logf); size_t n = fread(g_log, 1, sizeof g_log - 1, g_logf); g_log[n] = 0; fclose(g_logf); fputs(g_log, stderr); return g_log;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&memory, 65536, POOL_SIZE)); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
    REQUIRE(API(nvnTexturePoolInitialize)(&pool_a, &pool, COMMAND_SIZE, 512));
    REQUIRE(API(nvnTexturePoolInitialize)(&pool_b, &pool, COMMAND_SIZE + 65536, 512));
    int base_b = nvn_dpool_base(&pool_b, 1); REQUIRE(nvn_dpool_base(&pool_a, 1) == 0 && base_b > 0);
    NVNtexture a = {0}, b = {0}; make_tex(&a, 2 << 20); make_tex(&b, 3 << 20);
    {   // ⓪a / ⓪b：还没注册任何贴图
        log_begin(); id<MTLTexture> e0 = by_id(0); const char *lg = log_end();
        VERIFY(e0 == nil && !strstr(lg, "【红】 texture ID 0"), "⓪a 没注册的 ID 0（句柄 0 的空槽）：读 0（%s）、不报注册漏的红（%s）", e0 ? "得到贴图" : "nil", strstr(lg, "【红】 texture ID 0") ? "报了" : "没报");
        log_begin(); id<MTLTexture> e7 = by_id(7); lg = log_end();
        VERIFY(e7 == nil && strstr(lg, "【红】 texture ID 7 not registered"), "⓪b 随后没注册的 ID 7：照样报红（%s）", strstr(lg, "【红】 texture ID 7 not registered") ? "报了" : "没报：被句柄 0 那条吞了");
    }
    log_begin();
    API(nvnTexturePoolRegisterTexture)(&pool_a, 0, &a, NULL); API(nvnTexturePoolRegisterTexture)(&pool_b, 0, &b, NULL);
    { const char *lg = log_end(); VERIFY(strstr(lg, "texture ID 0 registered") && strstr(lg, "after 1 reads as an empty slot") && !strstr(lg, "【红】"),
                                         "⓪c ID 0 读过 1 次空项后注册上：记一行先空后有（不报红）"); }
    id<MTLTexture> ma = tex_mtl((const tex_t *)&a), mb = tex_mtl((const tex_t *)&b); REQUIRE(ma && mb && ma != mb);
    id<MTLTexture> r0 = by_id(0); void *tv = NULL; pthread_mutex_lock(&g_rmu); uint64_t rid = tex_fast_rid(0, &tv); pthread_mutex_unlock(&g_rmu);
    VERIFY(r0 == ma, "① 第一个池 ID 0：tex_by_id(0) 是注册的贴图 A（得 %p，期望 %p）", (__bridge void *)r0, (__bridge void *)ma);
    VERIFY(tv == (__bridge void *)ma && rid, "① 第一个池 ID 0：tex_fast_rid(0) 是贴图 A、资源号非 0（得 %p / %llu）", tv, (unsigned long long)rid);
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferSetTexturePool)(&commands, &pool_b);
    API(nvnCommandBufferBindTexture)(&commands, NVN_SHADER_STAGE_FRAGMENT, 3, (NVNtextureHandle)(0 | 5ull << 20));
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue);
    int tid3 = (int)(tex_slot_h(S.tex[NVN_SHADER_STAGE_FRAGMENT], S.img[NVN_SHADER_STAGE_FRAGMENT], 3) & 0xfffff);
    VERIFY(tid3 == base_b, "② 第二个池 ID 0 绑到片元槽 3：回放态纹理 ID %d（期望第二个池的基址 %d）", tid3, base_b);
    id<MTLTexture> r3 = by_id(tid3);
    VERIFY(r3 == mb, "② 解析成第二个池 ID 0 的贴图 B（得 %p，期望 %p）", (__bridge void *)r3, (__bridge void *)mb);
    VERIFY(by_id(7) == nil, "③ 没注册的 ID 7：仍然没有");
    {   // ④ 编码路径：计算着色器的 TEX 绑定（槽 3）→ encode_args → tex_fast_rid
        NSError *err = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { texture2d<float> t [[id(0)]]; device float4 *out [[id(1)]]; };\n"
            "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.out[0] = a.t.read(uint2(0)); }\n" options:o error:&err];
        REQUIRE(lib);
        NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"rd"]; REQUIRE(cs->fn);
        cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
        NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"tex", @"reg": @3, @"arg_id": @0, @"msl_type": @"texture2d<float>" }, @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES } ] };
        char e2[512]; REQUIRE(!nvn_refl_from_json(refl, &cs->rf, e2, sizeof e2));
        prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
        NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
        // 新贴图 C：存储先整块填 0x40（16×16 RGBA8，块线性布局下整块同值 = 每个像素 (64,64,64,64)）再建，注册到第一个池 ID 0（换下 A）；派发前不在主线程碰它，
        //   第一次建在提交线程（初始内容只在那里从存储填：tex_init_fill）
        memset(memory + (5 << 20), 0x40, 1 << 16); NVNtexture c = {0}; make_tex(&c, 5 << 20); API(nvnTexturePoolRegisterTexture)(&pool_a, 0, &c, NULL);
        float *out = (float *)(memory + (4 << 20)); for (int i = 0; i < 4; i++) out[i] = -1;
        nvn_be_sub_begin();
        S.tex_base = 0; S.tex[5][3] = 0;   // 句柄 0 = 纹理 ID 0 | 采样器 0（第一个池；景深合成那支是 0 | 881 << 20，读 read 不用采样器）
        S.cprog = &pg; S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)out, .size = 16}; g_args_dirty[5] = 1;
        p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
        uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
        float want = 64.0f / 255.0f; int ok = 1; for (int i = 0; i < 4; i++) ok &= fabsf(out[i] - want) < 1e-3f;
        VERIFY(ok, "④ 编码路径：槽 3 句柄 ID 0 读到真贴图 C (%.4f, %.4f, %.4f, %.4f)（期望各 %.4f；占位贴图读 0）", out[0], out[1], out[2], out[3], want);
    }
    printf("%s t_nvn_tex_id0：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
