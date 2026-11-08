// 打包贴图每个核查周期只核一次（11-02 塞尔达户外：和游戏每帧重写的数据同页的贴图每笔重设写保护 + 重算哈希）。公开 NVN 接口 + 生产 nvn_mtl.m（包含）+ 真 Metal 设备 + 真写保护缺页。
// 期望（按 NVN 语义手写，与被测实现无关）：一次提交里的绘制都在提交之后才上 GPU，CPU 在提交之前写的字节对这次提交的每一笔都可见、提交之后写的下一次提交才可见；
//   等别的队列的栅栏（OP_WAIT_SYNC）之后另起一个周期。贴图 16×16 RGBA8，存储整块填同一字节 v → 每个像素读出 v / 255。
//   ① 第一次提交：读到 0x40
//   ② 提交之间 CPU 改成 0x80 → 下一次提交读到 0x80（不用旧字节）
//   ③ 同一周期里第一笔之后同页写了同样的字节（游戏线程写同页别的数据的情形）：第二笔不再核（「同字节跳过」计数不增）；下一次提交核一次（+1）
//   ④ 同一周期里第一笔之后改了字节、再起新周期（同 OP_WAIT_SYNC）：第二笔重核、重传（重传计数 +1）
//   ⑤ 同一周期里第一笔之后改了字节、不换周期 → 下一次提交读到新字节（这次写不能被周期内的复用「吃掉」）
//   反证（11-02 手工核过）：同一测试编改前的 nvn_mtl.m：③ 第二笔照样重核（同字节跳过 +1），其余通，作正对照；
//      第一版把复用放在 tex_mtl 里提前返回（外层 tex_by_id 仍按 nvn_dirty_now 记「核过」）：③ 下一次提交不核、④⑤ 读到旧字节 0x80
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>

extern void *h_nvnBootstrapLoader(const char *name);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNtexturePool tpool;
static uint8_t *memory; static unsigned checks, fails;
enum { POOL_SIZE = 16 << 20, TEX_OFF = 5 << 20, TEX_BYTES = 1 << 16, OUT_OFF = 4 << 20 };
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static prog_t g_pg; static float *g_out;
static void sub_begin(void) { nvn_be_sub_begin(); }
static void draw_read(void) {   // 计算着色器从纹理槽 3（句柄 = ID 0）read 第一个像素写进存储缓冲
    S.tex_base = 0; S.tex[5][3] = 0; S.cprog = &g_pg; S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)g_out, .size = 16}; g_args_dirty[5] = 1;
    p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
}
static float sub_end(void) {
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); return g_out[0];
}
static int near(float a, int v) { return fabsf(a - v / 255.0f) < 1e-3f; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&memory, 65536, POOL_SIZE)); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    REQUIRE(API(nvnTexturePoolInitialize)(&tpool, &pool, 1 << 20, 512));
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, 16, 16); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetStorage)(&b, &pool, TEX_OFF); NVNtexture t = {0}; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    static uint8_t px[16 * 16 * 4]; memset(px, 0x40, sizeof px);
    NVNcopyRegion r = {0, 0, 0, 16, 16, 1}; API(nvnTextureWriteTexels)(&t, NULL, &r, px);   // CPU 写过 → 打包贴图（按客体内存上传、跟踪脏页）
    API(nvnTexturePoolRegisterTexture)(&tpool, 0, &t, NULL);
    NSError *err = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { texture2d<float> t [[id(0)]]; device float4 *out [[id(1)]]; };\n"
        "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.out[0] = a.t.read(uint2(0)); }\n" options:o error:&err];
    REQUIRE(lib);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"rd"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"tex", @"reg": @3, @"arg_id": @0, @"msl_type": @"texture2d<float>" }, @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES } ] };
    char e2[512]; REQUIRE(!nvn_refl_from_json(refl, &cs->rf, e2, sizeof e2));
    memset(&g_pg, 0, sizeof g_pg); g_pg.magic = MAGIC('P', 'R', 'O', 'G'); g_pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(g_pg.serial, np);
    g_out = (float *)(memory + OUT_OFF);
    uint8_t *st = memory + TEX_OFF;

    sub_begin(); draw_read(); float v = sub_end();
    VERIFY(near(v, 0x40), "① 第一次提交读到 0x40（得 %.4f）", v);

    memset(st, 0x80, TEX_BYTES);
    sub_begin(); draw_read(); v = sub_end();
    VERIFY(near(v, 0x80), "② 提交之间改成 0x80 → 下一次提交读到 0x80（得 %.4f）", v);

    uint64_t s0 = g_pkg_same;
    sub_begin(); draw_read(); memset(st, 0x80, TEX_BYTES); draw_read(); (void)sub_end();
    uint64_t s1 = g_pkg_same;
    VERIFY(s1 == s0, "③ 同一周期里同页写同样字节：第二笔不再核（同字节跳过 %llu → %llu，期望不变）", (unsigned long long)s0, (unsigned long long)s1);
    sub_begin(); draw_read(); v = sub_end();
    VERIFY(g_pkg_same == s1 + 1 && near(v, 0x80), "③ 下一次提交核一次：同字节跳过 +1（%llu → %llu）、仍读 0x80（得 %.4f）", (unsigned long long)s1, (unsigned long long)g_pkg_same, v);

    uint64_t u0 = g_pkg_reuploads;
    sub_begin(); draw_read(); memset(st, 0x20, TEX_BYTES); g_pkg_epoch++; draw_read(); (void)sub_end();
    VERIFY(g_pkg_reuploads == u0 + 1, "④ 周期内改字节后另起周期（同 OP_WAIT_SYNC）：第二笔重核重传（重传 %llu → %llu，期望 +1）", (unsigned long long)u0, (unsigned long long)g_pkg_reuploads);
    sub_begin(); draw_read(); v = sub_end();
    VERIFY(near(v, 0x20), "④ 之后的提交读到 0x20（得 %.4f）", v);

    sub_begin(); draw_read(); memset(st, 0x60, TEX_BYTES); draw_read(); (void)sub_end();
    sub_begin(); draw_read(); v = sub_end();
    VERIFY(near(v, 0x60), "⑤ 周期内改了字节（不换周期）→ 下一次提交读到 0x60，不丢这次写（得 %.4f）", v);

    printf("%s t_nvn_pkg_sub：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
