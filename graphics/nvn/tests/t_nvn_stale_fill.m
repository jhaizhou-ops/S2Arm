// 公开 NVN bootstrap → CPU_NO_ACCESS 池的初始内容：GPU 写过的页不当新贴图的初始内容（8496774df），没写过的照从存储填；存储里有 Inf / NaN 的浮点贴图也不当（10-28 喷3）。
// 存储整块填 0x11223344；A 在偏移 0 当渲染目标清红并 Finalize，B 同偏移同尺寸另一格式（避开同描述共用表）不写直接读回，C 在 1 MB 处不写读回。
// 读回一律在提交内 CopyTextureToBuffer（Metal 贴图在提交线程上首次建，才会走初始内容填充）。DM_NVN_STALE_FILL=1 时 B 期望回到图案（旧行为，反证）。
// D 组（共享贴图上的附件）：D1 在 3 MB 处先只读（Metal 贴图由它建、不记页），D2 同偏移同描述（共用 D1 的 Metal 贴图）只当一次渲染目标清蓝就 Finalize，
// D3 同偏移另一格式不写读回：D2 的写落在这些页上，期望全 0；DM_NVN_STALE_FILL=1 时期望回到图案（反证）。
// E 组（存储里有 Inf / NaN 的浮点贴图）：E1 在 2 MB 处 RGBA16F 读回图案（0x3344 / 0x1122 都是有限半精度，照填）；E2 在 2 MB + 256 KB 处建池前写满半精度 NaN（0x7e00），
// 期望全 0；DM_NVN_NONFINITE_FILL=1 时期望拿回 NaN（反证）。
// F 组（按页，审计 #743 P1-1）：F1 在 3.5 MB 处 32×32 RGBA8（存储正好一个 4 KB 页）当渲染目标清绿；F2 同偏移 64×64 RGBA8UI（4 个页）不写读回：
// 只有 F1 那一页的 1024 个 texel 是 0，其余 3072 个照从存储填（图案）。按计数核，不依赖块线性布局；DM_NVN_STALE_FILL=1 时期望全是图案（反证）。
// 以下各组同样按计数核（64×64 RGBA8 的存储 16384 字节、无填充，每 4 字节一个 texel），DM_NVN_STALE_FILL=1 时被 GPU 写过的字节照取（期望另列）：
// G（字节粒度）：G1 在 1.5 MB 处 16×16 RGBA8（存储不足 4 KB）清红，G2 紧挨着（G1 末尾、同一个 4 KB 页）64×64 RGBA8UI 不写读回：期望 4096 个全是图案（与 G1 不重叠）。
// H（只设渲染目标不画）：H1 在 0.5 MB 处先读回（建出 Metal 贴图），再 SetRenderTargets 挂上又卸下、不清不画；H2 同偏移 RGBA8UI 读回：期望全是图案。
// I（IMAGE 旗标不等于写）：I1 在 2.5 MB 处带 NVN_TEXTURE_FLAGS_IMAGE，只读回；I2 同偏移 RGBA8UI 读回：期望全是图案。
// J（本后端执行的写落进客体内存，字节与过期内容相同）：J1 在 3.75 MB 处清红；再拷缓冲（来源是同一图案）写前 8 KB、ClearBuffer（同一图案字）写其后 4 KB；
//   J2 同偏移 RGBA8UI 读回：期望 3072 个图案、1024 个 0（只按内容判就分不出这两段已是当前的）。
// K（CPU 写过）：另一块存储建 CPU 可写池 K0，K1 清红；CPU 把前 8 KB 写成另一图案 0x55667788；K1、K0 销毁，同一存储重建 CPU_NO_ACCESS 池，K2 读回：
//   期望 2048 个新图案、2048 个 0。
// L（重建不洗白）：再一块存储 CPU_NO_ACCESS 池 L0，L1 清红；L1、L0 销毁、同一存储重建 CPU_NO_ACCESS 池（期间没有任何写），L2 读回：期望 4096 个全是 0。
// M（CPU 可写池里游戏自己写的 NaN 是数据，照收）：另一块存储写满半精度 NaN（没有 GPU 写过），建 CPU 可写池、RGBA16F 读回：期望全是 NaN（与 DM_NVN_NONFINITE_FILL 无关）。
// N（CPU 可写池按写入账去过期字节，11-01 双人成行反射立方体数组）：再一块存储写满半精度 NaN，建 CPU 可写池，N1 RGBA16F 当渲染目标清红；N2 同偏移 RG32F 不写读回：
//   GPU 写过的字节不当初始内容，期望全 0；DM_NVN_STALE_FILL=1 时期望拿回存储里的 NaN（反证）。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
extern void dm_guest_write_prepare(void *addr, size_t len);   // 宿主写游戏内存前的同一入口：放开写跟踪设的只读页（游戏线程写时是缺页处理放开；单测没装缺页处理）
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool tex_pool, cmd_pool;
static NVNcommandBuffer commands;
static void *tex_storage, *cmd_storage;
static unsigned cases, texels, checks, count_fails;   // count_fails: expect_counts 不中止，后面各组照跑，末尾报
static const char *phase = "初始化";
enum { TEX_POOL_SIZE = 4 << 20, CMD_POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 2 << 20, N = 64, C_OFFSET = 1 << 20, D_OFFSET = 3 << 20, E1_OFFSET = 2 << 20, E2_OFFSET = (2 << 20) + (256 << 10), F_OFFSET = (3 << 20) + (512 << 10), G_OFFSET = (1 << 20) + (512 << 10), H_OFFSET = 512 << 10, I_OFFSET = (2 << 20) + (512 << 10), J_OFFSET = (3 << 20) + (768 << 10), SRC_OFFSET = 3 << 20, SIDE_SIZE = 64 << 10 };
static const uint32_t PATTERN = 0x11223344u, PATTERN2 = 0x55667788u;
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void make_pool(NVNmemoryPool *p, void *s, size_t size, int flags) {
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,s,size); API(nvnMemoryPoolBuilderSetFlags)(&pb,flags); REQUIRE(API(nvnMemoryPoolInitialize)(p,&pb));
}
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(posix_memalign(&tex_storage,65536,TEX_POOL_SIZE)==0);
    for (size_t i=0; i<TEX_POOL_SIZE/4; i++) ((uint32_t *)tex_storage)[i]=PATTERN;   // 池的初始内容：建池前写好，之后 CPU 不再碰
    for (size_t i=0; i<(size_t)N*N*4; i++) ((uint16_t *)((uint8_t *)tex_storage+E2_OFFSET))[i]=0x7e00;   // E2：半精度 NaN
    make_pool(&tex_pool,tex_storage,TEX_POOL_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(posix_memalign(&cmd_storage,65536,CMD_POOL_SIZE)==0); memset(cmd_storage,0,CMD_POOL_SIZE);
    make_pool(&cmd_pool,cmd_storage,CMD_POOL_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&cmd_pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static size_t make_tex_p(NVNtexture *t, NVNmemoryPool *pool, size_t pool_size, NVNformat format, size_t offset, int w, int h, int flags) {   // 返回存储大小
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b,w,h); API(nvnTextureBuilderSetLevels)(&b,1);
    API(nvnTextureBuilderSetFormat)(&b,format); if (flags) API(nvnTextureBuilderSetFlags)(&b,flags);
    size_t alignment=API(nvnTextureBuilderGetStorageAlignment)(&b), size=API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && size && offset%alignment==0 && offset+size<=pool_size && size<=C_OFFSET);   // A / B / C / D 各自的范围互不碰页
    API(nvnTextureBuilderSetStorage)(&b,pool,(ptrdiff_t)offset); REQUIRE(API(nvnTextureInitialize)(t,&b));
    return size;
}
static size_t make_tex_n(NVNtexture *t, NVNformat format, size_t offset, int w, int h) { return make_tex_p(t,&tex_pool,TEX_POOL_SIZE,format,offset,w,h,0); }
static void make_tex(NVNtexture *t, NVNformat format, size_t offset) { make_tex_n(t,format,offset,N,N); }
// 读回：在已开录的提交里拷到命令池的 READ_OFFSET；调用方 submit 后比对
static void record_read(NVNtexture *t) {
    memset((uint8_t *)cmd_storage+READ_OFFSET,0xA5,N*N*8);
    NVNcopyRegion whole={0,0,0,N,N,1};
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,t,NULL,&whole,API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+READ_OFFSET,0);
}
static void expect_all(const uint8_t want[4]) {
    const uint8_t *got=(const uint8_t *)cmd_storage+READ_OFFSET;
    for (int i=0; i<N*N; i++, texels++) {
        if (!memcmp(got+i*4,want,4)) continue;
        fprintf(stderr,"FAIL [%s] texel(%d,%d) got %02x %02x %02x %02x expected %02x %02x %02x %02x\n",phase,i%N,i/N,
                got[i*4],got[i*4+1],got[i*4+2],got[i*4+3],want[0],want[1],want[2],want[3]); exit(1);
    }
}
static void expect_all8(const uint8_t want[8]) {   // RGBA16F：每 texel 8 字节
    const uint8_t *got=(const uint8_t *)cmd_storage+READ_OFFSET;
    for (int i=0; i<N*N; i++, texels++) {
        if (!memcmp(got+i*8,want,8)) continue;
        fprintf(stderr,"FAIL [%s] texel(%d,%d) got %02x%02x %02x%02x %02x%02x %02x%02x\n",phase,i%N,i/N,got[i*8+1],got[i*8],got[i*8+3],got[i*8+2],got[i*8+5],got[i*8+4],got[i*8+7],got[i*8+6]); exit(1);
    }
}
static void clear_rt(NVNtexture *t, int w, int h, const float c[4]) {   // 已开录：挂成渲染目标清色再卸下
    const NVNtexture *rt[]={t};
    API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL); API(nvnCommandBufferSetScissor)(&commands,0,0,w,h);
    API(nvnCommandBufferSetViewport)(&commands,0,0,w,h); API(nvnCommandBufferClearColor)(&commands,0,c,15);
    API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL);
}
// 读回按计数核：全 0 / 图案 / 第二图案 / 其他各多少个 texel
static void expect_counts(unsigned want0, unsigned want_p, unsigned want_p2) {
    static const uint8_t z[4]={0,0,0,0}, p1[4]={0x44,0x33,0x22,0x11}, p2[4]={0x88,0x77,0x66,0x55};
    const uint8_t *got=(const uint8_t *)cmd_storage+READ_OFFSET; unsigned n0=0, np=0, np2=0, other=0;
    for (int i=0; i<N*N; i++, texels++) { if (!memcmp(got+i*4,z,4)) n0++; else if (!memcmp(got+i*4,p1,4)) np++; else if (!memcmp(got+i*4,p2,4)) np2++; else other++; }
    if (n0!=want0 || np!=want_p || np2!=want_p2 || other) { fprintf(stderr,"FAIL [%s] 全 0 texel %u、图案 %u、第二图案 %u、其他 %u（期望 %u / %u / %u / 0）\n",phase,n0,np,np2,other,want0,want_p,want_p2); count_fails++; }
}
// 另起一块存储（图案）上的池：K / L 组的「销毁再重建」
static void *side_storage(void) { void *s=NULL; REQUIRE(posix_memalign(&s,65536,SIDE_SIZE)==0); for (size_t i=0; i<SIDE_SIZE/4; i++) ((uint32_t *)s)[i]=PATTERN; return s; }
static unsigned fails_seen;
static void done(void) { cases++; printf("%s %s\n",count_fails>fails_seen?"FAIL":"PASS",phase); fails_seen=count_fails; fflush(stdout); }
int main(int argc, char **argv) { @autoreleasepool {
    (void)argv; if (argc!=1) { fprintf(stderr,"用法：[DM_NVN_STALE_FILL=1] %s\n",argv[0]); return 2; }
    const char *e=getenv("DM_NVN_STALE_FILL"); int old=e && !strcmp(e,"1");
    static const uint8_t red[4]={0xff,0,0,0xff}, zero[4]={0,0,0,0}, pattern[4]={0x44,0x33,0x22,0x11};   // 0x11223344 的小端字节
    setup();
    NVNtexture a,b,c;
    phase="A：偏移 0 RGBA8 当渲染目标清红，GPU 写落在 A 上"; make_tex(&a,NVN_FORMAT_RGBA8,0);
    const NVNtexture *rt[]={&a}; const float redf[4]={1,0,0,1};
    begin(); API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL); API(nvnCommandBufferSetScissor)(&commands,0,0,N,N);
    API(nvnCommandBufferSetViewport)(&commands,0,0,N,N); API(nvnCommandBufferClearColor)(&commands,0,redf,15);
    API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL); record_read(&a); submit();
    expect_all(red); API(nvnTextureFinalize)(&a); done();
    phase="C：偏移 1 MB RGBA8 从没被 GPU 写过，初始内容照旧从存储填"; make_tex(&c,NVN_FORMAT_RGBA8,C_OFFSET);
    begin(); record_read(&c); submit(); expect_all(pattern); API(nvnTextureFinalize)(&c); done();
    phase=old?"B（DM_NVN_STALE_FILL=1 反证）：同偏移 RGBA8UI 拿到存储里的过期图案":"B：同偏移 RGBA8UI 不写，GPU 写过的页不当初始内容，读回全 0";
    make_tex(&b,NVN_FORMAT_RGBA8UI,0);
    begin(); record_read(&b); submit(); expect_all(old?pattern:zero); API(nvnTextureFinalize)(&b); done();
    int unshared=old;
    NVNtexture d1,d2,d3; const float bluef[4]={0,0,1,1}; static const uint8_t blue[4]={0,0,0xff,0xff};
    phase="D1：偏移 3 MB RGBA8 先只读，Metal 贴图由它建，初始内容照旧从存储填"; make_tex(&d1,NVN_FORMAT_RGBA8,D_OFFSET);
    begin(); record_read(&d1); submit(); expect_all(pattern); done();
    phase="D2：同偏移同描述（共用 D1 的 Metal 贴图）只当一次渲染目标清蓝"; make_tex(&d2,NVN_FORMAT_RGBA8,D_OFFSET);
    const NVNtexture *rt2[]={&d2};
    begin(); API(nvnCommandBufferSetRenderTargets)(&commands,1,rt2,NULL,NULL,NULL); API(nvnCommandBufferSetScissor)(&commands,0,0,N,N);
    API(nvnCommandBufferSetViewport)(&commands,0,0,N,N); API(nvnCommandBufferClearColor)(&commands,0,bluef,15);
    API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL); record_read(&d2); submit();
    expect_all(blue); API(nvnTextureFinalize)(&d2); done();
    phase=unshared?"D3（反证）：同偏移 RGBA8UI 拿到存储里的过期图案":"D3：同偏移 RGBA8UI 不写，D2 写过的页不当初始内容，读回全 0";
    make_tex(&d3,NVN_FORMAT_RGBA8UI,D_OFFSET);
    begin(); record_read(&d3); submit(); expect_all(unshared?pattern:zero); API(nvnTextureFinalize)(&d3); API(nvnTextureFinalize)(&d1); done();
    const char *nf=getenv("DM_NVN_NONFINITE_FILL"); int keep_nan=nf && !strcmp(nf,"1");
    static const uint8_t pattern8[8]={0x44,0x33,0x22,0x11,0x44,0x33,0x22,0x11}, nan8[8]={0,0x7e,0,0x7e,0,0x7e,0,0x7e}, zero8[8]={0};
    NVNtexture e1,e2;
    phase="E1：偏移 2 MB RGBA16F，存储全是有限半精度，初始内容照旧从存储填"; make_tex(&e1,NVN_FORMAT_RGBA16F,E1_OFFSET);
    begin(); record_read(&e1); submit(); expect_all8(pattern8); API(nvnTextureFinalize)(&e1); done();
    phase=keep_nan?"E2（DM_NVN_NONFINITE_FILL=1 反证）：存储里的 NaN 照旧当初始内容":"E2：偏移 2 MB + 256 KB RGBA16F，存储全是 NaN，不当初始内容，读回全 0";
    make_tex(&e2,NVN_FORMAT_RGBA16F,E2_OFFSET);
    begin(); record_read(&e2); submit(); expect_all8(keep_nan?nan8:zero8); API(nvnTextureFinalize)(&e2); done();
    NVNtexture f1,f2; const float greenf[4]={0,1,0,1}; static const uint8_t green[4]={0,0xff,0,0xff};
    phase="F1：偏移 3.5 MB 32×32 RGBA8（一个 4 KB 页）当渲染目标清绿"; REQUIRE(make_tex_n(&f1,NVN_FORMAT_RGBA8,F_OFFSET,N/2,N/2)==4096);
    const NVNtexture *rt3[]={&f1};
    begin(); API(nvnCommandBufferSetRenderTargets)(&commands,1,rt3,NULL,NULL,NULL); API(nvnCommandBufferSetScissor)(&commands,0,0,N/2,N/2);
    API(nvnCommandBufferSetViewport)(&commands,0,0,N/2,N/2); API(nvnCommandBufferClearColor)(&commands,0,greenf,15);
    API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL); submit(); API(nvnTextureFinalize)(&f1); (void)green; done();
    phase=old?"F2（DM_NVN_STALE_FILL=1 反证）：同偏移 64×64 RGBA8UI 全是存储图案":"F2：同偏移 64×64 RGBA8UI（4 页、只有第一页被 GPU 写过）不写读回：只有那页的 texel 是 0，其余照从存储填";
    REQUIRE(make_tex_n(&f2,NVN_FORMAT_RGBA8UI,F_OFFSET,N,N)==4*4096);
    begin(); record_read(&f2); submit();
    { const uint8_t *got=(const uint8_t *)cmd_storage+READ_OFFSET; unsigned nz=0, np=0, other=0;
      for (int i=0; i<N*N; i++, texels++) { if (!memcmp(got+i*4,zero,4)) nz++; else if (!memcmp(got+i*4,pattern,4)) np++; else other++; }
      if (nz!=(old?0u:1024u) || np!=(old?4096u:3072u) || other) { fprintf(stderr,"FAIL [%s] 全 0 texel %u、图案 texel %u、其他 %u（期望 %u / %u / 0）\n",phase,nz,np,other,old?0u:1024u,old?4096u:3072u); exit(1); } }
    API(nvnTextureFinalize)(&f2); done();
    const float redf2[4]={1,0,0,1};
    NVNtexture g1,g2;
    phase="G1：偏移 1.5 MB 16×16 RGBA8（存储不足 4 KB）当渲染目标清红"; size_t gs=make_tex_n(&g1,NVN_FORMAT_RGBA8,G_OFFSET,16,16); REQUIRE(gs>0 && gs<4096);
    begin(); clear_rt(&g1,16,16,redf2); submit(); API(nvnTextureFinalize)(&g1); done();
    phase=old?"G2（DM_NVN_STALE_FILL=1 反证）：紧挨 G1、同一 4 KB 页的 64×64 RGBA8UI 全是图案":"G2：紧挨 G1（同一 4 KB 页、字节不重叠）的 64×64 RGBA8UI 不写读回：全是图案";
    REQUIRE(make_tex_n(&g2,NVN_FORMAT_RGBA8UI,G_OFFSET+gs,N,N)==4*4096);
    begin(); record_read(&g2); submit(); expect_counts(0,4096,0); API(nvnTextureFinalize)(&g2); done();
    NVNtexture h1,h2;
    phase="H1：偏移 0.5 MB RGBA8 先读回（建出 Metal 贴图），再只设成渲染目标、不清不画"; make_tex(&h1,NVN_FORMAT_RGBA8,H_OFFSET);
    begin(); record_read(&h1); { const NVNtexture *rt[]={&h1}; API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL); API(nvnCommandBufferSetRenderTargets)(&commands,0,NULL,NULL,NULL,NULL); }
    submit(); expect_all(pattern); API(nvnTextureFinalize)(&h1); done();
    phase="H2：同偏移 RGBA8UI 读回：只挂上没写，全是图案"; make_tex(&h2,NVN_FORMAT_RGBA8UI,H_OFFSET);
    begin(); record_read(&h2); submit(); expect_counts(0,4096,0); API(nvnTextureFinalize)(&h2); done();
    NVNtexture i1,i2;
    phase="I1：偏移 2.5 MB RGBA8 带 IMAGE 旗标，只读回"; REQUIRE(make_tex_p(&i1,&tex_pool,TEX_POOL_SIZE,NVN_FORMAT_RGBA8,I_OFFSET,N,N,NVN_TEXTURE_FLAGS_IMAGE)==4*4096);
    begin(); record_read(&i1); submit(); expect_all(pattern); API(nvnTextureFinalize)(&i1); done();
    phase="I2：同偏移 RGBA8UI 读回：IMAGE 旗标本身不是写，全是图案"; make_tex(&i2,NVN_FORMAT_RGBA8UI,I_OFFSET);
    begin(); record_read(&i2); submit(); expect_counts(0,4096,0); API(nvnTextureFinalize)(&i2); done();
    NVNtexture j1,j2;
    phase="J1：偏移 3.75 MB RGBA8 清红，再拷缓冲写前 8 KB、ClearBuffer 写其后 4 KB（字节与存储里的过期图案相同）"; make_tex(&j1,NVN_FORMAT_RGBA8,J_OFFSET);
    for (size_t i=0; i<8192/4; i++) ((uint32_t *)((uint8_t *)cmd_storage+SRC_OFFSET))[i]=PATTERN;
    begin(); clear_rt(&j1,N,N,redf2); submit(); API(nvnTextureFinalize)(&j1);
    { NVNbufferAddress tb=API(nvnMemoryPoolGetBufferAddress)(&tex_pool)+J_OFFSET;
      begin(); API(nvnCommandBufferCopyBufferToBuffer)(&commands,API(nvnMemoryPoolGetBufferAddress)(&cmd_pool)+SRC_OFFSET,tb,8192,0); API(nvnCommandBufferClearBuffer)(&commands,tb+8192,4096,PATTERN); submit(); }
    done();
    phase=old?"J2（DM_NVN_STALE_FILL=1 反证）：同偏移 RGBA8UI 全是图案":"J2：同偏移 RGBA8UI 读回：拷缓冲 / ClearBuffer 写过的 12 KB 是图案，剩下 4 KB 是 0";
    make_tex(&j2,NVN_FORMAT_RGBA8UI,J_OFFSET);
    begin(); record_read(&j2); submit(); if (old) expect_counts(0,4096,0); else expect_counts(1024,3072,0); API(nvnTextureFinalize)(&j2); done();
    void *ks=side_storage(); NVNmemoryPool kp; NVNtexture k1,k2;
    phase="K1：另一块存储的 CPU 可写池 RGBA8 清红，CPU 再把前 8 KB 写成另一图案，贴图与池销毁";
    make_pool(&kp,ks,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&k1,&kp,SIDE_SIZE,NVN_FORMAT_RGBA8,0,N,N,0)==4*4096);
    begin(); clear_rt(&k1,N,N,redf2); submit();
    dm_guest_write_prepare(ks,8192); for (size_t i=0; i<8192/4; i++) ((volatile uint32_t *)ks)[i]=PATTERN2;
    API(nvnTextureFinalize)(&k1); API(nvnMemoryPoolFinalize)(&kp); done();
    phase=old?"K2（DM_NVN_STALE_FILL=1 反证）：同一存储重建 CPU_NO_ACCESS 池，RGBA8UI 前 8 KB 新图案、其余旧图案":"K2：同一存储重建 CPU_NO_ACCESS 池，RGBA8UI 读回：CPU 写过的 8 KB 是新图案，没写过的 8 KB 是 0";
    make_pool(&kp,ks,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&k2,&kp,SIDE_SIZE,NVN_FORMAT_RGBA8UI,0,N,N,0)==4*4096);
    begin(); record_read(&k2); submit(); if (old) expect_counts(0,2048,2048); else expect_counts(2048,0,2048); API(nvnTextureFinalize)(&k2); API(nvnMemoryPoolFinalize)(&kp); done();
    void *ls=side_storage(); NVNmemoryPool lp; NVNtexture l1,l2;
    phase="L1：再一块存储的 CPU_NO_ACCESS 池 RGBA8 清红，贴图与池销毁";
    make_pool(&lp,ls,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&l1,&lp,SIDE_SIZE,NVN_FORMAT_RGBA8,0,N,N,0)==4*4096);
    begin(); clear_rt(&l1,N,N,redf2); submit(); API(nvnTextureFinalize)(&l1); API(nvnMemoryPoolFinalize)(&lp); done();
    phase=old?"L2（DM_NVN_STALE_FILL=1 反证）：同一存储重建，RGBA8UI 全是图案":"L2：同一存储重建 CPU_NO_ACCESS 池（期间没有任何写），RGBA8UI 读回：全是 0（重建不洗白）";
    make_pool(&lp,ls,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&l2,&lp,SIDE_SIZE,NVN_FORMAT_RGBA8UI,0,N,N,0)==4*4096);
    begin(); record_read(&l2); submit(); if (old) expect_counts(0,4096,0); else expect_counts(4096,0,0); API(nvnTextureFinalize)(&l2); API(nvnMemoryPoolFinalize)(&lp); done();
    void *ms=side_storage(); NVNmemoryPool mp; NVNtexture m1;
    for (size_t i=0; i<(size_t)N*N*4; i++) ((uint16_t *)ms)[i]=0x7e00;   // 建池前游戏写好的初值：半精度 NaN
    phase="M：CPU 可写池 RGBA16F，存储全是游戏写的 NaN（没有 GPU 写过），照当初始内容，读回全是 NaN";
    make_pool(&mp,ms,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&m1,&mp,SIDE_SIZE,NVN_FORMAT_RGBA16F,0,N,N,0)==8*4096);
    begin(); record_read(&m1); submit(); expect_all8(nan8); API(nvnTextureFinalize)(&m1); API(nvnMemoryPoolFinalize)(&mp); done();
    void *ns=side_storage(); NVNmemoryPool np; NVNtexture n1,n2; const float redh[4]={1,0,0,1};
    for (size_t i=0; i<(size_t)N*N*4; i++) ((uint16_t *)ns)[i]=0x7e00;
    phase="N1：CPU 可写池（存储全是 NaN）RGBA16F 当渲染目标清红";
    make_pool(&np,ns,SIDE_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(make_tex_p(&n1,&np,SIDE_SIZE,NVN_FORMAT_RGBA16F,0,N,N,0)==8*4096);
    begin(); clear_rt(&n1,N,N,redh); submit(); API(nvnTextureFinalize)(&n1); done();
    phase=old?"N2（DM_NVN_STALE_FILL=1 反证）：同偏移 RG32F 拿回存储里的 NaN":"N2：同偏移 RG32F 不写读回，N1 写过的字节不当初始内容，读回全 0";
    REQUIRE(make_tex_p(&n2,&np,SIDE_SIZE,NVN_FORMAT_RG32F,0,N,N,0)==8*4096);
    begin(); record_read(&n2); submit(); expect_all8(old?nan8:zero8); API(nvnTextureFinalize)(&n2); API(nvnMemoryPoolFinalize)(&np); done();
    free(ks); free(ls); free(ms); free(ns);
    if (count_fails) { fprintf(stderr,"FAIL t_nvn_stale_fill：%u 组按计数核不符\n",count_fails); return 1; }
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&tex_pool); API(nvnMemoryPoolFinalize)(&cmd_pool); API(nvnDeviceFinalize)(&device); free(tex_storage); free(cmd_storage);
    printf("✓ t_nvn_stale_fill%s%s：%u 组、%u 个真实 GPU texel、%u 条公开 API / 完成状态检查\n",old?"（DM_NVN_STALE_FILL=1）":"",keep_nan?"（DM_NVN_NONFINITE_FILL=1）":"",cases,texels,checks); return 0;
}}
