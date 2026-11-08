// GPU 贴图转随包贴图时留住 GPU 写过的级（11-04 巫师3 凯尔莫罕远景植被品红块）。公开 NVN bootstrap + 录制 + Metal 回放 + 提交内拷出。
// 巫师3 换高清贴图的做法（帧录像 r1 的客体内存量出来的）：新建整条 mip 链的 ASTC 贴图，低级（L1 起）用 CopyTextureToTexture 从旧贴图拷过去，
//   最高级 L0 由 CPU 从文件写进存储。Switch 上贴图就是那块内存，GPU 拷贝落进 L1 起的字节；本后端拷贝落在 Metal 贴图里，客体字节还是 0。
//   先拷后写时，贴图第一次被用（拷贝目标）建成 GPU 贴图；之后 CPU 写 L0，贴图转成随包贴图（nvn_be_tex_cpu_written → tex_mtl_ 新 NvPkg），
//   整条链按客体内存重传：L1 起全零，ASTC 全零块解码是错误色品红。Ryujinx 按子资源记脏：CPU 改过的那级重同步，GPU 改过的级留着。
// 期望（按 NVN 语义手写，与被测实现无关）：拷进去的级读回拷进去的块，CPU 写的块读回 CPU 写的块，没人写过的读回 0。
//   A：WriteTexels 写 L0 的块 (0,0)（直接标 CPU 写过）。B：CPU 直接写存储里 L0 块 (0,0) 的 16 字节（偏移 0：块线性存储的第一个 GOB 的头 16 字节就是块 (0,0)），
//   写跟踪在下一次提交时认出 CPU 写过（nvn_ft_poll）——巫师3 的实际路径。
//   每组：源 S（192×192、1 级 = 32×32 块，块 i 的 16 字节 = i 的低字节加 0..15、首字节再异或 0x5A）；目标 T（384×384、2 级：L0 64×64 块 64 KB，
//   L1 32×32 块从存储 64 KB 处起，与 L0 不同页，巫师3 的 1024×1024 也是这样），存储全 0。
//   ① 提交 1：S → T 的 L1，提交内读回 T 的 L1 = S（拷贝本身对，修前修后都绿）。② CPU 写 T 的 L0 块 (0,0) = tblk。
//   ③ 提交 2：读回 T 的 L1 = S（修前：转随包整条重传，读回全 0 → 红）；读回 T 的 L0：块 0 = tblk，其余 4095 块全 0。
//   ④ CPU 再写 L0 块 (0,0) = tblk2 → 随包贴图按脏页重传：L1 仍 = S（转随包时记成 GPU 写过的页，NvPkg pgpu），L0 块 0 = tblk2。
//   反证：把 tex_mtl_ 里转随包时的 carry_gpu 去掉，③④ 的 L1 读回全 0。
//   已知边界（不测）：L0 与 L1 同在一个 4 KB 页的小贴图，CPU 写 L0 那页按页重传会带走 L1（按页记脏，本后端不把 GPU 的写回写客体内存）。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
extern void dm_guest_write_prepare(void *addr, size_t len);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool tex_pool, cmd_pool; static NVNcommandBuffer commands;
static uint8_t *tex_storage, *cmd_storage; static unsigned checks, fails;
static const char *phase = "初始化";
enum { TEX_POOL_SIZE = 4 << 20, CMD_POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, L1_AT = 0, L0_AT = 64 << 10, SB = 32 * 32, TB = 64 * 64 };
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup [%s] %s:%d %s\n", phase, __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s [%s] ", ok_ ? "PASS" : "FAIL", phase); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)load(#name))
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void make_pool(NVNmemoryPool *p, void *s, size_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, s, size); API(nvnMemoryPoolBuilderSetFlags)(&pb, flags); REQUIRE(API(nvnMemoryPoolInitialize)(p, &pb));
}
static void make_tex(NVNtexture *t, size_t offset, int w, int h, int levels) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, w, h); API(nvnTextureBuilderSetLevels)(&b, levels);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA_ASTC_6x6);
    size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b), size = API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(al && size && offset % al == 0 && offset + size <= TEX_POOL_SIZE && size <= (256u << 10));
    API(nvnTextureBuilderSetStorage)(&b, &tex_pool, (ptrdiff_t)offset); REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &cmd_pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void record_read(NVNtexture *t, int level, int w, int h, size_t at) {   // 一级拷到命令池 READ_OFFSET + at（块按行紧排）
    NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetLevels)(&v, level, 1);
    NVNcopyRegion r = {0, 0, 0, w, h, 1};
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, t, &v, &r, API(nvnMemoryPoolGetBufferAddress)(&cmd_pool) + READ_OFFSET + at, 0);
}
static const uint8_t *got(size_t at) { return cmd_storage + READ_OFFSET + at; }
static void blk(uint8_t *b, uint8_t base) { for (int i = 0; i < 16; i++) b[i] = (uint8_t)(base + i); }
static uint8_t g_src[SB * 16];
static unsigned l0_rest_nonzero(void) { unsigned n = 0; for (int i = 1; i < TB; i++) { const uint8_t *q = got(L0_AT) + 16 * i; for (int k = 0; k < 16; k++) if (q[k]) { n++; break; } } return n; }
static unsigned l1_diff(void) { unsigned n = 0; for (int i = 0; i < SB; i++) n += memcmp(got(L1_AT) + 16 * i, g_src + 16 * i, 16) != 0; return n; }
static void write_l0(NVNtexture *t, size_t t_off, const uint8_t *b, int direct) {
    if (!direct) { NVNcopyRegion r = {0, 0, 0, 6, 6, 1}; API(nvnTextureWriteTexels)(t, NULL, &r, b); return; }
    uint8_t *m = tex_storage + t_off; dm_guest_write_prepare(m, 16); memcpy(m, b, 16);
}
static void read_both(NVNtexture *t) {
    memset(cmd_storage + READ_OFFSET, 0xA5, L0_AT + TB * 16);
    begin(); record_read(t, 1, 192, 192, L1_AT); record_read(t, 0, 384, 384, L0_AT); submit();
}
static void run(const char *name, size_t s_off, size_t t_off, int direct) {
    phase = name;
    NVNtexture s, t; make_tex(&s, s_off, 192, 192, 1); make_tex(&t, t_off, 384, 384, 2);
    for (int i = 0; i < SB; i++) { blk(g_src + 16 * i, (uint8_t)i); g_src[16 * i] ^= 0x5A; }
    uint8_t tblk[16], tblk2[16]; blk(tblk, 0xA0); blk(tblk2, 0x40);
    NVNcopyRegion r = {0, 0, 0, 192, 192, 1};
    API(nvnTextureWriteTexels)(&s, NULL, &r, g_src);
    NVNtextureView l1; API(nvnTextureViewSetDefaults)(&l1); API(nvnTextureViewSetLevels)(&l1, 1, 1);
    memset(cmd_storage + READ_OFFSET, 0xA5, SB * 16);
    begin(); API(nvnCommandBufferCopyTextureToTexture)(&commands, &s, NULL, &r, &t, &l1, &r, 0); record_read(&t, 1, 192, 192, L1_AT); submit();
    VERIFY(l1_diff() == 0, "① 提交 1 拷进 L1 后读回 = 源（%u / %d 块不同）", l1_diff(), SB);
    write_l0(&t, t_off, tblk, direct);
    read_both(&t);
    unsigned d = l1_diff(), z = 0; for (int i = 0; i < SB; i++) { const uint8_t *q = got(L1_AT) + 16 * i; int nz = 0; for (int k = 0; k < 16; k++) nz |= q[k]; z += !nz; }
    VERIFY(d == 0, "③ CPU 写 L0 之后 L1 仍 = 拷进去的源（%u / %d 块不同，其中全 0 块 %u：全 0 = 按客体内存整条重传丢了 GPU 拷贝）", d, SB, z);
    VERIFY(!memcmp(got(L0_AT), tblk, 16) && !l0_rest_nonzero(), "③ L0 块 0 = CPU 写的块（首字节 %02x），其余 %d 块全 0（非 0 %u 块）", got(L0_AT)[0], TB - 1, l0_rest_nonzero());
    write_l0(&t, t_off, tblk2, direct);
    read_both(&t);
    VERIFY(l1_diff() == 0, "④ CPU 再写 L0、按脏页重传之后 L1 仍 = 源（%u / %d 块不同）", l1_diff(), SB);
    VERIFY(!memcmp(got(L0_AT), tblk2, 16) && !l0_rest_nonzero(), "④ L0 块 0 = 新写的块（首字节 %02x），其余全 0（非 0 %u 块）", got(L0_AT)[0], l0_rest_nonzero());
    API(nvnTextureFinalize)(&t); API(nvnTextureFinalize)(&s);
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&tex_storage, 65536, TEX_POOL_SIZE)); memset(tex_storage, 0, TEX_POOL_SIZE);
    make_pool(&tex_pool, tex_storage, TEX_POOL_SIZE, NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);   // 巫师3 的贴图池：CPU 可写（读文件进来）
    REQUIRE(!posix_memalign((void **)&cmd_storage, 65536, CMD_POOL_SIZE)); memset(cmd_storage, 0, CMD_POOL_SIZE);
    make_pool(&cmd_pool, cmd_storage, CMD_POOL_SIZE, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
    run("A：WriteTexels 写 L0", 0, 256 << 10, 0);
    run("B：CPU 直接写存储里的 L0（写跟踪认出）", 1 << 20, (1 << 20) + (256 << 10), 1);
    printf("%s t_nvn_promote_keep：%u 项，%u 项不通\n", fails ? "✗" : "✓", checks, fails);   // 门禁认「✓ t_」结论行（runtime/gate.sh）
    return fails ? 1 : 0;
} }
