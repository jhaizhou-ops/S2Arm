// 虚拟池里不对齐宿主页的映射，缓冲也要让 GPU 读到（审计 #1592 P1-112）。生产 nvn_mtl.m 编进本 TU（取它的 gpu_addr_want / nvn_be_addr：顶点 / 常量 / 索引 / 拷贝绑定解析走的就是这两条），
// NVN 对象走公开接口（hle_nvn.c 的 MemoryPoolInitialize / MapVirtual / QueueSubmitCommands），GPU 读回用本单测自带的 Metal 计算核（按解析出的缓冲 + 偏移逐字拷出）。
// 期望按 NVN 语义手写，不由被测实现推出：MapVirtual 以 4 KB 为粒度，虚拟偏移 v 处读到的是请求挂上的物理页内容；没挂的页不给读；CPU 写物理池后，GPU 下次提交读到新值。
//   苹果宿主页 16 KB：物理源 = 物理池 + 0x11000（4 KB 对齐、16 KB 不对齐）、虚拟偏移 0x3000，这种请求旧实现只进页表，缓冲地址解析不到任何内存池（顶点读 0、常量读零库）。
// 物理池每个 32 位字写「0xC0000000 | 字号」，读回逐字比对：
//   ① 顶点缓冲 [0x3000, +0x8000) ← 物理 0x11000：按首字节解析（同 bind_vbufs）成功、缓冲从偏移起至少 0x8000 字节、GPU 读回 = 物理 0x11000 起的 0x2000 个字；
//   ② 常量缓冲 [0x5000, +0x1000)（同 encode_args 的 cb 绑定解析）：读回 = 物理 0x13000 起；
//   ③ CPU 改物理 0x12000 处一个字、空提交一次：GPU 再读顶点缓冲那一字 = 新值；
//   ④ 再把虚拟 [0x3000, +0x1000) 改挂物理 0x31000（仍不对齐）：读回该 4 KB = 物理 0x31000 起，其后 4 KB 不变；
//   ⑤ 对齐的 16 KB 别名 [0x20000, +0x4000) ← 物理 0x20000，再按 4 KB 撤掉 [0x21000, +0x1000)：0x20000 处仍读物理 0x20000，0x21000 处读 0（旧实现别名还在、读到旧物理页）；
//   ⑥ 没挂任何页的地址（虚拟 0x30000）：解析失败（不给假内存），拷贝缓冲路照报红；
//   ⑦ 拷贝（CopyBufferToBuffer 经 nvn_be_addr）从虚拟 0x3000 + 0x40 读 4 字节 = ④ 后的物理 0x31040 处的字
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <signal.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
extern void *h_nvnBootstrapLoader(const char *name);
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e != NULL); return e; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNmemoryPool *phys; int64_t poff, voff; uint64_t size; int32_t storage_class, _pad; } t_map_req;   // NVNmappingRequest，0x28 字节
enum { PHYS_SIZE = 0x40000, CMD_SIZE = 4 << 20, READ_OFFSET = 2 << 20 };
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool phys, cmd_pool, vp; static NVNcommandBuffer commands;
static uint32_t *pw; static uint8_t *cmd_storage;
static id<MTLComputePipelineState> g_cp; static id<MTLCommandQueue> g_tq;
// 写保护缺页：生产里 crash.c 的信号处理先问 s2a_direct_fault（脏页跟踪认领）；单测不链 crash.c，照它装一个
extern int s2a_direct_fault(void *addr, int is_write, void *uctx);
static void on_fault(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static uint32_t word(uint64_t poff) { return 0xC0000000u | (uint32_t)(poff / 4); }
static void pool_init(NVNmemoryPool *p, void *storage, uint64_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, size); API(nvnMemoryPoolBuilderSetFlags)(&pb, flags); REQUIRE(API(nvnMemoryPoolInitialize)(p, &pb));
}
static int vmap(NVNmemoryPool *ph, int64_t poff, int64_t voff, uint64_t size) { t_map_req r = {ph, poff, voff, size, 0, 0}; return API(nvnMemoryPoolMapVirtual)(&vp, 1, (const NVNmappingRequest *)&r); }
static uint64_t vaddr(uint64_t voff) { return (uint64_t)(uintptr_t)((const pool_t *)&vp)->mem + voff; }   // 缓冲的宿主地址（录制入口把 GPU 地址换成它）
static void submit_empty(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands, &cmd_pool, 0, 1 << 20); API(nvnCommandBufferBeginRecording)(&commands);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0); API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue);
}
// GPU 从解析出的缓冲 + 偏移拷 n 个字出来（真 Metal 计算派发）
static int gpu_read(id<MTLBuffer> b, uint64_t off, uint32_t *out, uint32_t n) {
    id<MTLBuffer> dst = [g_dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared]; memset(dst.contents, 0xA5, n * 4);
    id<MTLCommandBuffer> cb = [g_tq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_cp]; [ce setBuffer:b offset:off atIndex:0]; [ce setBuffer:dst offset:0 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    memcpy(out, dst.contents, n * 4); return cb.status == MTLCommandBufferStatusCompleted;
}
// 按绑定的解析（首字节查、整段要）读 n 个字，逐字比 want(i)；→ 不符个数，解析失败 = -1
static long bound_read(uint64_t a, uint64_t size, uint32_t *got, uint32_t n) {
    void *mb; uint64_t mo, gpu, pav;
    if (!gpu_addr_want(a, 1, size, &mb, &mo, &gpu, &pav)) return -1;
    if (pav < size) return -2;   // 缓冲从偏移起不够 size 字节：着色器读过界
    return gpu_read((__bridge id<MTLBuffer>)mb, mo, got, n) ? 0 : -3;
}
static long cmp(const uint32_t *got, uint32_t n, uint64_t poff, uint32_t *first_bad) {
    long bad = 0; for (uint32_t i = 0; i < n; i++) if (got[i] != word(poff + 4ull * i)) { if (!bad++) *first_bad = i; } return bad;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    { struct sigaction sa = {0}; sa.sa_sigaction = on_fault; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL); }
    char dir[256]; snprintf(dir, sizeof dir, "%s/t_nvn_vpool_unaligned.%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid()); mkdir(dir, 0700); setenv("S2A_GAME_DATA", dir, 1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(posix_memalign((void **)&cmd_storage, 65536, CMD_SIZE) == 0); memset(cmd_storage, 0, CMD_SIZE);
    pool_init(&cmd_pool, cmd_storage, CMD_SIZE, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign((void **)&pw, 65536, PHYS_SIZE) == 0);
    for (uint64_t o = 0; o < PHYS_SIZE; o += 4) pw[o / 4] = word(o);
    pool_init(&phys, pw, PHYS_SIZE, NVN_MEMORY_POOL_FLAGS_PHYSICAL | NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device)); static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
    memset(&vp, 0, sizeof vp); pool_init(&vp, NULL, 0x40000, NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS);
    REQUIRE(getpagesize() == 16384);   // 本单测造的「不对齐」以 16 KB 宿主页为准
    NSError *er = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nkernel void cp(device const uint *s [[buffer(0)]], device uint *d [[buffer(1)]], uint i [[thread_position_in_grid]]) { d[i] = s[i]; }" options:nil error:&er];
    REQUIRE(lib != nil); g_cp = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cp"] error:&er]; REQUIRE(g_cp != nil); g_tq = [g_dev newCommandQueue];
    static uint32_t got[0x2000]; uint32_t fb = 0; long r, bad;

    VERIFY(vmap(&phys, 0x11000, 0x3000, 0x8000), "映射 虚拟 0x3000+0x8000 ← 物理 0x11000（4 KB 对齐、16 KB 不对齐）回成功");
    r = bound_read(vaddr(0x3000), 0x8000, got, 0x2000); bad = r ? -1 : cmp(got, 0x2000, 0x11000, &fb);
    VERIFY(r == 0 && bad == 0, "① 顶点缓冲 0x3000+0x8000：解析 %ld（期望 0）、0x2000 个字里不符 %ld（期望 0；首个不符第 %u 字 = %#x，期望 %#x）", r, bad, fb, got[fb], word(0x11000 + 4ull * fb));
    r = bound_read(vaddr(0x5000), 0x1000, got, 0x400); bad = r ? -1 : cmp(got, 0x400, 0x13000, &fb);
    VERIFY(r == 0 && bad == 0, "② 常量缓冲 0x5000+0x1000：解析 %ld、不符 %ld（期望 0 / 0）", r, bad);
    pw[0x12000 / 4] = 0x12345678u; submit_empty();
    r = bound_read(vaddr(0x3000), 0x8000, got, 0x2000);
    VERIFY(r == 0 && got[0x1000 / 4] == 0x12345678u, "③ CPU 改物理 0x12000、空提交后 GPU 读虚拟 0x4000 = %#x（期望 0x12345678）", r ? 0u : got[0x1000 / 4]);
    pw[0x12000 / 4] = word(0x12000); submit_empty();
    VERIFY(vmap(&phys, 0x31000, 0x3000, 0x1000), "④ 虚拟 0x3000+0x1000 改挂物理 0x31000 回成功");
    r = bound_read(vaddr(0x3000), 0x2000, got, 0x800); bad = r ? -1 : cmp(got, 0x400, 0x31000, &fb) + cmp(got + 0x400, 0x400, 0x12000, &fb);
    VERIFY(r == 0 && bad == 0, "④ 读回 0x3000 起 4 KB = 物理 0x31000、其后 4 KB = 物理 0x12000：解析 %ld、不符 %ld（期望 0 / 0）", r, bad);
    VERIFY(vmap(&phys, 0x20000, 0x20000, 0x4000), "⑤ 对齐的 16 KB 别名 虚拟 0x20000 ← 物理 0x20000 回成功");
    VERIFY(vmap(NULL, 0, 0x21000, 0x1000), "⑤ 按 4 KB 撤掉虚拟 0x21000 回成功");
    r = bound_read(vaddr(0x20000), 0x4000, got, 0x1000); bad = r ? -1 : cmp(got, 0x400, 0x20000, &fb);
    long zero = 0; if (!r) for (int i = 0x400; i < 0x800; i++) zero += got[i] != 0;
    VERIFY(r == 0 && bad == 0 && zero == 0, "⑤ 0x20000 处读物理 0x20000（不符 %ld）、撤掉的 0x21000 处读 0（非 0 %ld 个，首字 %#x）：解析 %ld", bad, zero, r ? 0u : got[0x400], r);
    { void *mb; uint64_t mo, gpu, pav; VERIFY(!gpu_addr_want(vaddr(0x30000), 1, 0x100, &mb, &mo, &gpu, &pav), "⑥ 没挂任何页的虚拟 0x30000：解析失败（不给假内存）"); }
    { uint32_t *out = (uint32_t *)(cmd_storage + READ_OFFSET); *out = 0xA5A5A5A5u;
      API(nvnCommandBufferAddCommandMemory)(&commands, &cmd_pool, 0, 1 << 20); API(nvnCommandBufferBeginRecording)(&commands);
      API(nvnCommandBufferCopyBufferToBuffer)(&commands, API(nvnMemoryPoolGetBufferAddress)(&vp) + 0x3040, API(nvnMemoryPoolGetBufferAddress)(&cmd_pool) + READ_OFFSET, 4, 0);
      NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue);
      VERIFY(*out == word(0x31040), "⑦ CopyBufferToBuffer 从虚拟 0x3040 读到 %#x（期望物理 0x31040 的 %#x）", *out, word(0x31040)); }
    API(nvnMemoryPoolFinalize)(&vp); rmdir(dir);
  }
  printf("%s t_nvn_vpool_unaligned %u/%u（虚拟池 4 KB 对齐、16 KB 不对齐的映射：顶点 / 常量 / 拷贝缓冲经页表副本让 GPU 读到，CPU 改写下次提交跟上、改挂与撤页跟上、没挂的页不给读）\n", failures ? "✗" : "✓", checks - failures, checks);
  return failures != 0;
}
