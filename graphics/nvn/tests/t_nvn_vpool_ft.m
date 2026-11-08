// 虚拟（稀疏）池上的贴图不进 CPU 写跟踪表（hle_nvn.c ft_add；上游参考实现（MIT）6121fd75 t_sparse_tiles 同一条）。公开 NVN 接口 → 宿主判定 → 真实 Metal 读回，期望按 NVN 语义手写，不由被测实现推出：
//   虚拟池是一段 GPU 地址，CPU 不经它读写（真驱动虚拟池的 nvnMemoryPoolMap 恒为 NULL，见 t_nvn_vpool），它背后的物理页由页表跟（vpool_*）。所以建在虚拟池上的贴图，CPU 从没写过它，
//   宿主就不能把它判成「首用前 CPU 写过」（nvn_ft_written = 0）。虚拟池地址不在脏页跟踪的任何区间里，按「没跟踪就当脏」会一建就判成 CPU 写过——不分池的 CPU 访问标志（0x222 这类可访问标志的虚拟池也一样）。
// 对照：物理池上的贴图，没写判 0，CPU 写了它的字节判 1——证明这条判定本身能红。
// tex_dirty_upload / tex_flush_upload 照缺省开（宿主缺省 = Switch 语义）。
#include "nvn_protos.h"
#include "nvn_obj.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
int nvn_ft_written(const tex_t *t);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool cmd_pool, phys, cpu_pool;
static NVNcommandBuffer commands;
static void *cmd_storage, *phys_storage, *cpu_storage;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { BLOCK = 0x10000, PHYS_SIZE = 16 * BLOCK, CMD_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, W = 256, H = 128, TEX_BYTES = W * H * 4 };   // 贴图 256x128 RGBA8 = 2 块
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
#define CHECK(x, ...) do { checks++; if (!(x)) { fails++; printf("FAIL [%s] %s：",phase,#x); printf(__VA_ARGS__); putchar('\n'); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNmemoryPool *phys; int64_t poff, voff; uint64_t size; int32_t storage_class, _pad; } map_req;   // NVNmappingRequest，0x28 字节
static uint32_t color(int block) { return 0xFF000000u | (uint32_t)(block + 1) * 0x010203u; }
static void fill_blocks(void *storage, size_t size) { for (size_t b=0; b<size/BLOCK; b++) { uint32_t c=color((int)b); for (size_t i=0; i<BLOCK; i+=4) memcpy((uint8_t *)storage+b*BLOCK+i,&c,4); } }
static void pool_init(NVNmemoryPool *p, void *storage, uint64_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,size); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags);
    REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
// 写保护缺页交给直连层的缺页入口（同 t_nvn_ftpoll）：CPU 写被保护的贴图页 → 放开页、记代号、重执行
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void setup(void) {
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(posix_memalign(&cmd_storage,65536,CMD_SIZE)==0); memset(cmd_storage,0,CMD_SIZE);
    pool_init(&cmd_pool,cmd_storage,CMD_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign(&phys_storage,65536,PHYS_SIZE)==0); fill_blocks(phys_storage,PHYS_SIZE);
    pool_init(&phys,phys_storage,PHYS_SIZE,NVN_MEMORY_POOL_FLAGS_PHYSICAL|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign(&cpu_storage,65536,PHYS_SIZE)==0); fill_blocks(cpu_storage,PHYS_SIZE);
    pool_init(&cpu_pool,cpu_storage,PHYS_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static void tex_init(NVNtexture *t, NVNmemoryPool *p, int64_t off) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device); API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,W,H); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);
    REQUIRE(API(nvnTextureBuilderGetStorageSize)(&b)==TEX_BYTES);
    API(nvnTextureBuilderSetStorage)(&b,p,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,&b));
}
// GPU 把整张贴图拷到命令池 READ_OFFSET，数两块色值的纹素数（各半）
static void tex_count(NVNtexture *t, int want_a, int want_b, const char *what) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,TEX_BYTES);
    NVNcopyRegion whole={0,0,0,W,H,1}; NVNbufferAddress dst=API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET;
    begin(); API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,dst,0); submit();
    const uint8_t *p=(const uint8_t *)cmd_storage+READ_OFFSET; uint32_t ca=color(want_a), cb=color(want_b); int na=0, nb=0, other=0;
    for (int i=0; i<W*H; i++) { uint32_t c; memcpy(&c,p+4*i,4); if (c==ca) na++; else if (c==cb) nb++; else other++; }
    CHECK(na==W*H/2 && nb==W*H/2 && !other,"%s：块 %d 的色 %d 个、块 %d 的色 %d 个、别的 %d 个，期望各 %d 个、别的 0",what,want_a,na,want_b,nb,other,W*H/2);
}
// ① / ② 虚拟池（CPU 可访问标志 / CPU_NO_ACCESS 两种），挂物理块 3–4 后建贴图：CPU 没写过它，判 0；GPU 读到挂着的物理块
static void virtual_pool(int flags, const char *name) {
    phase=name; NVNmemoryPool v; memset(&v,0,sizeof v); pool_init(&v,NULL,4*BLOCK,flags);
    map_req r={&phys,3*BLOCK,0,2*BLOCK,0,0}; CHECK(API(nvnMemoryPoolMapVirtual)(&v,1,(const NVNmappingRequest *)&r),"虚拟 [0, 2 块) ← 物理块 3–4 映射成功");
    NVNtexture t; tex_init(&t,&v,0);
    CHECK(nvn_ft_written((const tex_t *)&t)==0,"建好、CPU 没写：不该判成首用前 CPU 写过（实为 1）");
    tex_count(&t,3,4,"贴图读到块 3 与块 4");
    API(nvnTextureFinalize)(&t); API(nvnMemoryPoolFinalize)(&v); cases++;
}
// ③ 对照：物理池（CPU 可写）上的贴图，没写判 0；CPU 改了它的一个字节判 1
static void physical_control(void) {
    phase="对照：物理池贴图 CPU 写后判 1"; NVNtexture t; tex_init(&t,&cpu_pool,6*BLOCK);
    CHECK(nvn_ft_written((const tex_t *)&t)==0,"建好、CPU 没写：判 0");
    ((volatile uint8_t *)cpu_storage)[6*BLOCK+16]=0x5A;
    CHECK(nvn_ft_written((const tex_t *)&t)==1,"CPU 写了贴图字节：判 1");
    API(nvnTextureFinalize)(&t); cases++;
}
int main(void) { @autoreleasepool {
    setup();
    virtual_pool(NVN_MEMORY_POOL_FLAGS_VIRTUAL|NVN_MEMORY_POOL_FLAGS_GPU_CACHED|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED,"① 虚拟池 0x222（CPU 可访问标志）上的贴图");
    virtual_pool(NVN_MEMORY_POOL_FLAGS_VIRTUAL|NVN_MEMORY_POOL_FLAGS_GPU_CACHED|NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS,"② 虚拟池 0x221（CPU_NO_ACCESS）上的贴图");
    physical_control();
    printf("t_nvn_vpool_ft：%u 例 %u 项，失败 %u\n",cases,checks,fails);
    return fails ? 1 : 0;
} }
