// 单测 t_m3enc：Metal 3 编码器（卡 M3-6 / #113；gal_be.h 表中「编码器」）。
// 一个进程只初始化一次（nxgal_init 是单例），Metal 4 / Metal 3 各起一个子进程跑同一组只用拷贝 / 整清 / 读回的工作，读回字节写进文件：
//   ① 缓冲：写数据、整段拷贝、按字节值填、按 32 位花样填、同缓冲重叠拷贝（暂存中转两条拷贝）、64 段链式拷贝（第 k+1 段拷自第 k 段，次序错一条结果就不对）；
//   ② 预载：新缓冲之间的拷贝进预载命令缓冲，同一次提交里在录流再读它（预载必须排在在录缓冲之前）；
//   ③ 贴图：RGBA8 写数据 → 贴图拷贝 → 读回；渲染目标整清（通道开头 load = Clear）→ 读回；D32 整清 → 读回；贴图拷到缓冲 → 读缓冲；
//   ④ 只有 Metal 3：计算编码器本体（nxgal_test_m3_cmp_enc，setBuffer 绑定，不经参数表）两条相依派发（编码器内屏障）+ blit 拷出（编码器之间的栅栏）；
//      试一次绘制：参数绑定（M3-7）未合入，应报红跳过、计数 +1、不崩。
// 期望值全部手算（不跑被测实现推），并且两个子进程的读回逐字节相同。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_be.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

void nxgal_test_be(int32_t out[5]);
void nxgal_test_m3enc(uint64_t out[8]);
id nxgal_test_m3_cmp_enc(void);
id<MTLBlitCommandEncoder> gal_blit_enc(void) API_AVAILABLE(macos(26.0), ios(26.0));   // gal_core.m：Metal 3 下是 MTLBlitCommandEncoder
uint64_t gal_commit(void) API_AVAILABLE(macos(26.0), ios(26.0));
void gal_wait(uint64_t f) API_AVAILABLE(macos(26.0), ios(26.0));
extern id<MTLDevice> g_gdev;

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { R32Uint = 10, R8G8B8A8Unorm = 36, D32Float = 51 };
static FILE *g_out;
static void dump(const void *p, size_t n) { fwrite(p, 1, n, g_out); }
static nxgal_tex_info info2d(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }

enum { N = 4096 };
static void t_bufs(void) {
    printf("· ① 缓冲：写 / 拷 / 填 / 重叠拷 / 64 段链式拷\n");
    static uint8_t src[N], want[N], got[N];
    for (int i = 0; i < N; i++) src[i] = (uint8_t)(i * 7 + 3);
    uint32_t a = nxgal_buf_create(N, 0), b = nxgal_buf_create(N, 0);
    nxgal_buf_set_data(a, 0, src, N);
    nxgal_buf_copy(a, b, 0, 0, N);                     // b = a
    nxgal_buf_clear(b, 256, 512, 0x5a5a5a5a);          // 字节值相同：fillBuffer
    nxgal_buf_clear(b, 1024, 1000, 0xdeadbeef);        // 32 位花样：暂存块 + 拷贝
    nxgal_buf_copy(b, b, 2048, 2048 + 100, 1000);      // 同缓冲重叠：暂存中转（memmove 语义）
    memcpy(want, src, N); memset(want + 256, 0x5a, 512);
    for (int k = 0; k < 1000; k += 4) { uint32_t v = 0xdeadbeef; memcpy(want + 1024 + k, &v, 4); }
    memmove(want + 2148, want + 2048, 1000);
    CHECK(nxgal_buf_get_data(b, 0, N, got) == 0, "读回 b 失败");
    int bad = 0; for (int i = 0; i < N; i++) if (got[i] != want[i] && bad++ < 3) printf("  ✗ b[%d] 期望 %02x 实得 %02x\n", i, want[i], got[i]);
    CHECK(!bad, "b 共 %d 字节不符", bad); dump(got, N);
    // 链式：c 的第 0 段写数据，第 k+1 段拷自第 k 段，同一次提交里录 63 条相依拷贝
    uint32_t c = nxgal_buf_create(64 * 64, 0);
    nxgal_buf_set_data(c, 0, src, 64);
    for (int k = 0; k < 63; k++) nxgal_buf_copy(c, c, k * 64, (k + 1) * 64, 64);
    CHECK(nxgal_buf_get_data(c, 0, 64 * 64, got) == 0, "读回 c 失败");
    bad = 0; for (int k = 0; k < 64; k++) if (memcmp(got + k * 64, src, 64) && bad++ < 3) printf("  ✗ 链式第 %d 段不等于第 0 段\n", k);
    CHECK(!bad, "链式拷贝 %d 段不符（相依拷贝次序乱了）", bad); dump(got, 64 * 64);
    nxgal_buf_delete(a); nxgal_buf_delete(b); nxgal_buf_delete(c);
}

static void t_preload(int m3) {
    printf("· ② 预载：新缓冲间拷贝进预载，同一次提交里在录流再读它\n");
    static uint8_t src[N], got[N];
    for (int i = 0; i < N; i++) src[i] = (uint8_t)(255 - i);
    uint32_t s = nxgal_buf_create(N, 0), d = nxgal_buf_create(N, 0), e = nxgal_buf_create(N, 0), x = nxgal_buf_create(16, 0), y = nxgal_buf_create(16, 0);
    nxgal_buf_set_data(s, 0, src, N); nxgal_flush();
    uint64_t z[2] = {0, 0}; nxgal_buf_set_data(x, 0, z, 16); nxgal_buf_copy(x, y, 0, 0, 16);   // 开一条在录命令缓冲
    nxgal_buf_copy(s, d, 0, 0, N);    // d 本次提交没被用过 → 预载
    uint64_t st[8]; nxgal_test_m3enc(st);
    if (m3) CHECK(st[7] == 1, "Metal 3 预载命令缓冲没开（拷贝没进预载？）");
    nxgal_buf_copy(d, e, 0, 0, N);    // 在录流读 d：要看到预载写的
    CHECK(nxgal_buf_get_data(e, 0, N, got) == 0, "读回 e 失败");
    CHECK(!memcmp(got, src, N), "e 不等于 s：预载没排在在录缓冲之前"); dump(got, N);
    nxgal_buf_delete(s); nxgal_buf_delete(d); nxgal_buf_delete(e); nxgal_buf_delete(x); nxgal_buf_delete(y);
}

static void t_tex(void) {
    printf("· ③ 贴图：写 → 拷 → 读；整清颜色 / 深度 → 读；拷到缓冲\n");
    enum { W = 64, H = 32 };
    static uint8_t px[W * H * 4], got[W * H * 4];
    for (int i = 0; i < W * H * 4; i++) px[i] = (uint8_t)(i * 13 + 1);
    nxgal_tex_info i = info2d(W, H, R8G8B8A8Unorm, 4);
    uint32_t t0 = nxgal_tex_create(&i), t1 = nxgal_tex_create(&i), t2 = nxgal_tex_create(&i);
    nxgal_tex_set_data(t0, -1, -1, NULL, px, sizeof px);
    nxgal_tex_copy(t0, t1, 0, 0);
    CHECK(nxgal_tex_get_data(t1, 0, 0, got, sizeof got) == sizeof got, "读回 t1 字节数不对");
    CHECK(!memcmp(got, px, sizeof px), "贴图拷贝结果不对"); dump(got, sizeof got);
    nxgal_set_render_targets(&t2, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    float c[4] = {0.2f, 0.4f, 0.6f, 1.0f}; nxgal_clear_color(0, 0, 1, 0xf, c);
    CHECK(nxgal_tex_get_data(t2, 0, 0, got, sizeof got) == sizeof got, "读回 t2 字节数不对");
    int bad = 0; for (int k = 0; k < W * H; k++) { uint8_t e[4] = {51, 102, 153, 255}; if (memcmp(got + k * 4, e, 4)) bad++; }
    CHECK(!bad, "整清颜色 %d / %d 像素不符", bad, W * H); dump(got, sizeof got);
    nxgal_tex_info di = info2d(32, 32, D32Float, 4);
    uint32_t dt = nxgal_tex_create(&di);
    nxgal_set_render_targets(NULL, 0, dt); nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0);
    static float dg[32 * 32];
    CHECK(nxgal_tex_get_data(dt, 0, 0, dg, sizeof dg) == sizeof dg, "读回深度字节数不对");
    bad = 0; for (int k = 0; k < 32 * 32; k++) if (dg[k] != 0.5f) bad++;
    CHECK(!bad, "整清深度 %d / 1024 像素不符", bad); dump(dg, sizeof dg);
    uint32_t b = nxgal_buf_create(W * H * 4, 0);
    nxgal_buf_range r = {b, 0, W * H * 4, 1};
    nxgal_tex_copy_to_buffer(t0, &r, 0, 0, W * 4);
    CHECK(nxgal_buf_get_data(b, 0, W * H * 4, got) == 0, "读回贴图→缓冲失败");
    CHECK(!memcmp(got, px, sizeof px), "贴图拷到缓冲结果不对"); dump(got, sizeof got);
    nxgal_set_render_targets(NULL, 0, 0);
    nxgal_tex_release(t0); nxgal_tex_release(t1); nxgal_tex_release(t2); nxgal_tex_release(dt); nxgal_buf_delete(b);
}

// ④ Metal 3 计算编码器本体：k1 写 x[i] = i，k2 读改写 x[i] = x[i] * 2 + 1（同一编码器，靠编码器内屏障），再 blit 拷出（靠编码器之间的栅栏）
// 只看后端、不判系统版本：这条路径只用老接口，26 以下真机正是它要覆盖的地方（gal_blit_enc 声明上的 26 标注是 Metal 4 口径，macOS 15.7 实测能跑）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
static void t_m3_compute(void) {
    printf("· ④ Metal 3 计算编码器：两条相依派发 + blit 拷出；试一次绘制应报红跳过\n");
    NSError *err = nil;
    id<MTLLibrary> lib = [g_gdev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void k1(device uint *x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] = i; }\n"
        "kernel void k2(device uint *x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] = x[i] * 2 + 1; }\n" options:nil error:&err];
    CHECK(lib != nil, "编测试计算核失败：%s", err.localizedDescription.UTF8String); if (!lib) return;
    id<MTLComputePipelineState> p1 = [g_gdev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k1"] error:&err];
    id<MTLComputePipelineState> p2 = [g_gdev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k2"] error:&err];
    enum { M = 1024 };
    id<MTLBuffer> x = [g_gdev newBufferWithLength:M * 4 options:MTLResourceStorageModePrivate], o = [g_gdev newBufferWithLength:M * 4 options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> e = nxgal_test_m3_cmp_enc();
    CHECK([e conformsToProtocol:@protocol(MTLComputeCommandEncoder)], "计算编码器类型不对");
    [e setComputePipelineState:p1]; [e setBuffer:x offset:0 atIndex:0]; [e dispatchThreads:MTLSizeMake(M, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    e = nxgal_test_m3_cmp_enc();   // 同一编码器第二条：前面加编码器内屏障
    uint64_t st[8]; nxgal_test_m3enc(st); CHECK(st[0] == 3, "第二次取计算编码器应续用（当前类型 %llu，期望 3）", (unsigned long long)st[0]);
    [e setComputePipelineState:p2]; [e setBuffer:x offset:0 atIndex:0]; [e dispatchThreads:MTLSizeMake(M, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    id<MTLBlitCommandEncoder> bl = gal_blit_enc();
    CHECK([bl conformsToProtocol:@protocol(MTLBlitCommandEncoder)], "拷贝编码器不是 MTLBlitCommandEncoder");
    [bl copyFromBuffer:x sourceOffset:0 toBuffer:o destinationOffset:0 size:M * 4];
    gal_wait(gal_commit());
    const uint32_t *v = o.contents; int bad = 0;
    for (uint32_t i = 0; i < M; i++) if (v[i] != i * 2 + 1 && bad++ < 3) printf("  ✗ x[%u] 期望 %u 实得 %u\n", i, i * 2 + 1, v[i]);
    CHECK(!bad, "计算 → 拷出共 %d 个不符（编码器内屏障或编码器之间的栅栏失效）", bad);
    nxgal_test_m3enc(st); uint64_t d0 = st[2];
    nxgal_draw(3, 1, 0, 0);
    nxgal_test_m3enc(st);
    CHECK(st[2] == d0 + 1, "绘制应因参数绑定未合入报红跳过（跳过计数 %llu → %llu）", (unsigned long long)d0, (unsigned long long)st[2]);
    CHECK(st[6] == 1, "Metal 3 编码器之间的栅栏没建");
    printf("  · blit 拆编码器 %llu 次；跳过 绘制 %llu / 派发 %llu / 遍内清屏 %llu / 辅助绘制 %llu\n",
           (unsigned long long)st[1], (unsigned long long)st[2], (unsigned long long)st[3], (unsigned long long)st[4], (unsigned long long)st[5]);
}
#pragma clang diagnostic pop

static int run_child(const char *expect, const char *out) {
    int m3 = !strcmp(expect, "mtl3");
    g_out = fopen(out, "wb"); if (!g_out) { printf("  ✗ 开输出文件失败：%s\n", out); return 1; }
    CHECK(nxgal_init(0) == 0, "nxgal_init 失败"); if (g_fail) return 1;
    int32_t be[5]; nxgal_test_be(be);
    CHECK(be[0] == (m3 ? GAL_BE_MTL3 : GAL_BE_MTL4), "后端 %d ≠ 期望 %s", be[0], expect);
    @autoreleasepool { t_bufs(); t_preload(m3); t_tex(); if (m3) t_m3_compute(); }
    fclose(g_out);
    printf("  子进程（%s）：%d / %d 项通过\n", expect, g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}

static int run_case(const char *be, const char *out) {
    printf("== %s\n", be ? "NXGAL_BE=mtl3（Metal 3）" : "缺省（Metal 4）");
    char self[4096]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz)) { printf("  ✗ 取本可执行文件路径失败\n"); return 1; }
    pid_t pid = fork();
    if (pid == 0) {
        if (be) setenv("NXGAL_BE", be, 1); else unsetenv("NXGAL_BE");
        execl(self, self, "--child", be ? be : "mtl4", out, (char *)NULL);
        _exit(127);
    }
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
}

static int slurp(const char *p, uint8_t **d, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return 0;
    fseek(f, 0, SEEK_END); *n = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    *d = malloc(*n ? *n : 1); size_t r = fread(*d, 1, *n, f); fclose(f); return r == *n;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc >= 4 && !strcmp(argv[1], "--child")) return run_child(argv[2], argv[3]);
    const char *tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    char o4[4096], o3[4096]; snprintf(o4, sizeof o4, "%s/t_m3enc_%d_4.bin", tmp, getpid()); snprintf(o3, sizeof o3, "%s/t_m3enc_%d_3.bin", tmp, getpid());
    int r4 = run_case(NULL, o4), r3 = run_case("mtl3", o3);
    CHECK(r4 == 0, "Metal 4 子进程退出码 %d", r4);
    CHECK(r3 == 0, "Metal 3 子进程退出码 %d", r3);
    uint8_t *d4 = NULL, *d3 = NULL; size_t n4 = 0, n3 = 0;
    int ok = slurp(o4, &d4, &n4) && slurp(o3, &d3, &n3);
    CHECK(ok && n4 > 0 && n4 == n3 && !memcmp(d4, d3, n4), "两个后端的读回不逐字节相同（Metal 4 %zu 字节 / Metal 3 %zu 字节）", n4, n3);
    if (ok) printf("· 两个后端读回各 %zu 字节，%s\n", n4, n4 == n3 && !memcmp(d4, d3, n4) ? "逐字节相同" : "不同");
    unlink(o4); unlink(o3); free(d4); free(d3);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
