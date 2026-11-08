// 线性贴图超 Metal 2D 上限不杀进程（nvn_mtl.m tex_linear，11-02 Nintendo Switch Sports：游戏建 32768 高的线性 2D 贴图，wd_draw_ 绑定时第一次建 Metal 对象，
//   tex_linear 不查上限就按池缓冲建视图，Metal 校验断言「height (32768) greater than the maximum allowed size of 16384」整局 abort）。
// 公开 NVN 接口在 CPU 可见池里建 LINEAR 的 R8 贴图 → 生产 tex_mtl（包含 nvn_mtl.m）→ 真 Metal 设备，每种情形一个子进程（断言的系统上越界直接杀进程）。
//   断言因系统而异：普查 Air 上 Metal 建描述符时校验并 abort；本机 macOS 26（Darwin 25.4）不校验、照建出 16 × 32768。两种都不该发生：超限一律不建
// 期望（按 Metal 2D 上限 16384 手写，与被测实现无关）：
//   ① 16 × 16384：在上限内，照旧建在池缓冲上（.buffer 非空，线性零拷贝路径真走到）
//   ② 16 × 32768（11-03 起折行，nvn_red.h nvn_fold_k）：k = ⌈32768 / 16384⌉ = 2，行距 256 = P 256 纹素，建在池缓冲上的 (2 − 1)·256 + 16 = 272 × 16384（行距 2 × 256 = 512），进程活着；
//      往池缓冲写逻辑纹素 (3, 20001) = 0xAB（贴图起点 + 20001 × 256 + 3）→ 折行贴图 (3 + (20001 % 2) × 256, 20001 / 2) = (259, 10000) 读到 0xAB，(3, 10000) 读到 0（零拷贝、落点手算）
//   反证（11-02 手工核过，旧口径）：撤掉 tex_linear 的上限检查，② 在本机拿到 16 × 32768 的越界贴图（宽高对不上 32 × 16384，判不通）；在会断言的系统上死于 SIGABRT 同样不通
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device; static NVNmemoryPool pool; static void *storage;
enum { U_POOL = 16 << 20, U_W = 16 };
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
static unsigned checks, fails;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e); return e; }
#define API(name) ((NVNT_##name)load(#name))
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db)); mtl_init();
    REQUIRE(posix_memalign(&storage, 65536, U_POOL) == 0); memset(storage, 0, U_POOL);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, U_POOL); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
}
static void make_lin(NVNtexture *t, int h) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, U_W, h); API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R8);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_LINEAR); API(nvnTextureBuilderSetStride)(&b, 256);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b) <= (size_t)U_POOL);
    API(nvnTextureBuilderSetStorage)(&b, &pool, 0); REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static int child(const char *self, const char *mode) {   // 子进程重新执行自己（posix_spawn，不 fork：Metal 初始化后 fork 不安全）
    fflush(stdout); pid_t p; char *av[] = {(char *)self, (char *)mode, NULL};
    REQUIRE(posix_spawn(&p, self, NULL, NULL, av, environ) == 0);
    int st; waitpid(p, &st, 0); return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        const char *mode = argc > 1 ? argv[1] : "";
        if (!strcmp(mode, "--fit") || !strcmp(mode, "--over")) {
            setup(); NVNtexture t; make_lin(&t, !strcmp(mode, "--fit") ? 16384 : 32768); const tex_t *tt = (const tex_t *)&t;
            id<MTLTexture> mt = tex_mtl(tt);
            if (!strcmp(mode, "--fit")) return mt && mt.buffer ? 0 : 3;
            if (!mt || !mt.buffer || mt.width != 272 || mt.height != 16384 || mt.bufferBytesPerRow != 512) return 4;
            ((uint8_t *)mt.buffer.contents + mt.bufferOffset)[20001 * 256 + 3] = 0xAB;   // 池缓冲里贴图起点 + 逻辑行 × 原行距 + 列
            uint8_t a = 0, z = 1; [mt getBytes:&a bytesPerRow:272 fromRegion:MTLRegionMake2D(259, 10000, 1, 1) mipmapLevel:0]; [mt getBytes:&z bytesPerRow:272 fromRegion:MTLRegionMake2D(3, 10000, 1, 1) mipmapLevel:0];
            return a == 0xAB && z == 0 ? 0 : 5;
        }
        int r = child(argv[0], "--fit");
        VERIFY(r == 0, "① 16 × 16384 线性贴图：建在池缓冲上（子进程结束于 %d，期望 0）", r);
        r = child(argv[0], "--over");
        VERIFY(r == 0, "② 16 × 32768 线性贴图：折成 272 × 16384 建在池缓冲上、逻辑 (3, 20001) 落在 (259, 10000)（子进程结束于 %d，期望 0；4 = 没建 / 尺寸不对，5 = 落点不对；会断言的系统上越界 134）", r);
        printf("%s t_nvn_linear_limit：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
        return fails != 0;
    }
}
