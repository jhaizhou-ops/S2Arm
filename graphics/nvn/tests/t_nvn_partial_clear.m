// 公开 NVN bootstrap / DeviceGetProcAddress → 真实命令录制、Metal 提交、公开纹理读回。
// 覆盖 float / int / uint ClearTexture；--baseline 仅复现局部区域一个旧缺口，默认执行全部用例。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t texture_offset = 2 << 20;
static unsigned cases, texels, checks;
static const char *phase = "初始化";
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 1 << 20 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNtexture object; int size, levels, layers, bytes; } image;
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    const char *names[] = {"nvnCommandBufferClearTexture","nvnCommandBufferClearTexturei","nvnCommandBufferClearTextureui","nvnTextureReadTexels"};
    for (unsigned i=0; i<sizeof names/sizeof names[0]; i++) REQUIRE((void *)API(nvnDeviceGetProcAddress)(&device,names[i]) == load(names[i]));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&qb)); REQUIRE(posix_memalign(&storage,65536,POOL_SIZE)==0); memset(storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
}
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
static void make_image(image *out, NVNformat format, int bytes, int size, int layers, int levels) {
    out->size=size; out->levels=levels; out->layers=layers; out->bytes=bytes;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,layers>1?NVN_TEXTURE_TARGET_2D_ARRAY:NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize3D)(&b,size,size,layers); API(nvnTextureBuilderSetLevels)(&b,levels); API(nvnTextureBuilderSetFormat)(&b,format);
    size_t alignment=API(nvnTextureBuilderGetStorageAlignment)(&b), size_bytes=API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && size_bytes); texture_offset=(texture_offset+alignment-1)/alignment*alignment;
    REQUIRE(texture_offset+size_bytes<=POOL_SIZE); API(nvnTextureBuilderSetStorage)(&b,&pool,(ptrdiff_t)texture_offset); texture_offset+=size_bytes;
    REQUIRE(API(nvnTextureInitialize)(&out->object,&b));
}
static void make_view(NVNtextureView *v, int mip, int layer, int count, NVNformat format) {
    API(nvnTextureViewSetDefaults)(v); API(nvnTextureViewSetLevels)(v,mip,1); API(nvnTextureViewSetLayers)(v,layer,count);
    if (format) API(nvnTextureViewSetFormat)(v,format);
}
static void clear_full(image *t, int mip, int layer, int is_uint, const void *rgba) {
    NVNtextureView v; make_view(&v,mip,layer,1,0); int n=t->size>>mip;
    NVNcopyRegion r={0,0,0,n,n,1};
    if (is_uint) API(nvnCommandBufferClearTextureui)(&commands,&t->object,&v,&r,rgba,15);
    else API(nvnCommandBufferClearTexture)(&commands,&t->object,&v,&r,rgba,15);
}
static void clear_full_i(image *t, int mip, int layer, const int rgba[4]) {
    NVNtextureView v; make_view(&v,mip,layer,1,0); int n=t->size>>mip;
    NVNcopyRegion r={0,0,0,n,n,1};
    API(nvnCommandBufferClearTexturei)(&commands,&t->object,&v,&r,rgba,15);
}
static void compare_texels(const image *t, int mip, int layer, const uint8_t *actual, const uint8_t *expected) {
    int n=t->size>>mip;
    for (int y=0; y<n; y++) for (int x=0; x<n; x++) {
        size_t at=(size_t)(y*n+x)*t->bytes; texels++;
        if (!memcmp(actual+at,expected+at,(size_t)t->bytes)) continue;
        fprintf(stderr,"FAIL [%s] mip%d layer%d texel(%d,%d) got",phase,mip,layer,x,y);
        for (int b=0; b<t->bytes; b++) fprintf(stderr," %02x",actual[at+b]); fprintf(stderr," expected");
        for (int b=0; b<t->bytes; b++) fprintf(stderr," %02x",expected[at+b]); fputc('\n',stderr); exit(1);
    }
}
// 每个 texel 独立检查：区域外用 before，区域内用手算的 after；不读取被测内部状态或模拟 GPU 指令。
static void check_region(image *t, int mip, int layer, const void *before, const void *after, const NVNcopyRegion *changed) {
    int n=t->size>>mip; uint8_t actual[8*8*16], expected[8*8*16]; REQUIRE(n<=8 && t->bytes<=16);
    NVNtextureView v; make_view(&v,mip,layer,1,0); NVNcopyRegion r={0,0,0,n,n,1};
    memset(actual,0xA5,sizeof actual); API(nvnTextureReadTexels)(&t->object,&v,&r,actual);
    for (int y=0; y<n; y++) for (int x=0; x<n; x++) {
        int inside=changed && x>=changed->xoffset && x<changed->xoffset+changed->width && y>=changed->yoffset && y<changed->yoffset+changed->height;
        memcpy(expected+(size_t)(y*n+x)*t->bytes,inside?after:before,(size_t)t->bytes);
    }
    compare_texels(t,mip,layer,actual,expected);
}
static void done(void) { cases++; printf("PASS %s\n",phase); fflush(stdout); }
static const float initial_f[4]={0,.25f,.5f,1}, source_f[4]={1,.5f,.25f,0};
static const uint8_t initial_8[4]={0,64,128,255}, source_8[4]={255,128,64,0};
static const NVNcopyRegion middle={2,1,0,3,4,1};
static void baseline(void) {
    phase="baseline：RGBA8 局部区域，完整颜色通道"; image t; make_image(&t,NVN_FORMAT_RGBA8,4,8,1,1);
    begin(); clear_full(&t,0,0,0,initial_f);
    API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&middle,source_f,15); submit();
    check_region(&t,0,0,initial_8,source_8,&middle); API(nvnTextureFinalize)(&t.object); done();
}
static void masks(void) {
    phase="RGBA8 全部 16 种通道掩码"; image t; make_image(&t,NVN_FORMAT_RGBA8,4,8,1,1);
    // R/G/B/A 分别取 1/2/4/8；所有预期逐项列出，避免复制生产端格式/掩码映射。
    static const uint8_t expected[16][4]={
        {0,64,128,255},{255,64,128,255},{0,128,128,255},{255,128,128,255},
        {0,64,64,255},{255,64,64,255},{0,128,64,255},{255,128,64,255},
        {0,64,128,0},{255,64,128,0},{0,128,128,0},{255,128,128,0},
        {0,64,64,0},{255,64,64,0},{0,128,64,0},{255,128,64,0},
    };
    for (int mask=0; mask<16; mask++) {
        char name[96]; snprintf(name,sizeof name,"RGBA8 mask=%#x，范围外与未写通道保留",mask); phase=name;
        begin(); clear_full(&t,0,0,0,initial_f);
        API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&middle,source_f,mask); submit();
        check_region(&t,0,0,initial_8,expected[mask],&middle); done();
    }
    phase="RGBA8 整层范围仍服从部分 R/B 写掩码";
    const NVNcopyRegion whole={0,0,0,8,8,1};
    begin(); clear_full(&t,0,0,0,initial_f);
    API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&whole,source_f,5); submit();
    check_region(&t,0,0,initial_8,expected[5],&whole); done();
    API(nvnTextureFinalize)(&t.object);
}
static void formats(void) {
    image t; const NVNcopyRegion r={1,2,0,4,3,1};
    const float initial_float[4]={-2,.25f,4,1}, values_float[4]={-3.5f,8,16777216,.5f}, expected_float[4]={-3.5f,.25f,16777216,1};
    phase="RGBA32F 局部 R/B 保留负值与精确浮点"; make_image(&t,NVN_FORMAT_RGBA32F,16,8,1,1);
    begin(); clear_full(&t,0,0,0,initial_float); API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&r,values_float,5); submit();
    check_region(&t,0,0,initial_float,expected_float,&r); API(nvnTextureFinalize)(&t.object); done();
    const uint32_t initial_uint[4]={3,5,7,11}, values_uint[4]={UINT32_MAX,16777217,0x80000001u,42};
    const uint32_t expected_ga[4]={3,16777217,7,42}, expected_rb[4]={UINT32_MAX,5,0x80000001u,11};
    phase="RGBA32UI 局部 G/A，2^24+1 不经过 float"; make_image(&t,NVN_FORMAT_RGBA32UI,16,8,1,1);
    begin(); clear_full(&t,0,0,1,initial_uint); API(nvnCommandBufferClearTextureui)(&commands,&t.object,NULL,&r,values_uint,10); submit();
    check_region(&t,0,0,initial_uint,expected_ga,&r); done();
    phase="RGBA32UI 局部 R/B，UINT_MAX 与 0x80000001 精确保留";
    begin(); clear_full(&t,0,0,1,initial_uint); API(nvnCommandBufferClearTextureui)(&commands,&t.object,NULL,&r,values_uint,5); submit();
    check_region(&t,0,0,initial_uint,expected_rb,&r); API(nvnTextureFinalize)(&t.object); done();
    const uint32_t initial_ui8[4]={1,17,128,254}, values_ui8[4]={255,128,17,0};
    const uint8_t before_ui8[4]={1,17,128,254}, after_ui8[4]={1,128,17,254};
    phase="RGBA8UI 局部 G/B 保留 R/A"; make_image(&t,NVN_FORMAT_RGBA8UI,4,8,1,1);
    begin(); clear_full(&t,0,0,1,initial_ui8); API(nvnCommandBufferClearTextureui)(&commands,&t.object,NULL,&r,values_ui8,6); submit();
    check_region(&t,0,0,before_ui8,after_ui8,&r); API(nvnTextureFinalize)(&t.object); done();
    const uint8_t r8_before=64,r8_after=255; const float r8_initial[4]={.25f,0,0,1};
    phase="R8 缺失 G 通道的掩码不改变 R"; make_image(&t,NVN_FORMAT_R8,1,8,1,1);
    begin(); clear_full(&t,0,0,0,r8_initial);
    API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&r,source_f,2); submit();
    check_region(&t,0,0,&r8_before,&r8_before,&r); done();
    phase="R8 局部 R 清除"; begin(); API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&r,source_f,1); submit();
    check_region(&t,0,0,&r8_before,&r8_after,&r); API(nvnTextureFinalize)(&t.object); done();
}
static void format_views(void) {
    image t; NVNtextureView v; const NVNcopyRegion r={1,1,0,5,2,1};
    const uint32_t ui[4]={17,128,255,3}; const uint8_t after[4]={0,128,128,3};
    phase="RGBA8 → RGBA8UI 视图，局部 G/A 按整数解释"; make_image(&t,NVN_FORMAT_RGBA8,4,8,1,1); make_view(&v,0,0,1,NVN_FORMAT_RGBA8UI);
    begin(); clear_full(&t,0,0,0,initial_f); API(nvnCommandBufferClearTextureui)(&commands,&t.object,&v,&r,ui,10); submit();
    check_region(&t,0,0,initial_8,after,&r); API(nvnTextureFinalize)(&t.object); done();
    const float before_f[4]={.25f,.5f,.75f,1};
    const uint32_t before_bits[4]={0x3e800000,0x3f000000,0x3f400000,0x3f800000};
    const uint32_t value_bits[4]={0x3f800001,UINT32_MAX,16777217,0x80000001u};
    const uint32_t after_bits[4]={0x3f800001,0x3f000000,16777217,0x3f800000};
    phase="RGBA32F → RGBA32UI 视图，局部 R/B 原始位不转换"; make_image(&t,NVN_FORMAT_RGBA32F,16,8,1,1); make_view(&v,0,0,1,NVN_FORMAT_RGBA32UI);
    begin(); clear_full(&t,0,0,0,before_f); API(nvnCommandBufferClearTextureui)(&commands,&t.object,&v,&r,value_bits,5); submit();
    check_region(&t,0,0,before_bits,after_bits,&r); API(nvnTextureFinalize)(&t.object); done();
}
static void signed_formats(void) {
    image t; const NVNcopyRegion r={1,2,0,4,3,1}, whole={0,0,0,8,8,1};
    const int initial[4]={-3,5,-7,11}, values[4]={INT32_MIN,INT32_MAX,-16777217,16777217};
    const int rb[4]={INT32_MIN,5,-16777217,11}, ga[4]={-3,INT32_MAX,-7,16777217};
    phase="RGBA32I 局部 R/B：INT_MIN 与 -2^24-1 精确保留"; make_image(&t,NVN_FORMAT_RGBA32I,16,8,1,1);
    begin(); clear_full_i(&t,0,0,initial); API(nvnCommandBufferClearTexturei)(&commands,&t.object,NULL,&r,values,5); submit();
    check_region(&t,0,0,initial,rb,&r); done();
    phase="RGBA32I 局部 G/A：INT_MAX 与 2^24+1 精确保留";
    begin(); clear_full_i(&t,0,0,initial); API(nvnCommandBufferClearTexturei)(&commands,&t.object,NULL,&r,values,10); submit();
    check_region(&t,0,0,initial,ga,&r); done();
    phase="RGBA32I 整层部分 R/B 掩码仍保留 G/A";
    begin(); clear_full_i(&t,0,0,initial); API(nvnCommandBufferClearTexturei)(&commands,&t.object,NULL,&whole,values,5); submit();
    check_region(&t,0,0,initial,rb,&whole); API(nvnTextureFinalize)(&t.object); done();
    const int before8[4]={17,22,-33,-44}, value8[4]={-128,-1,0,127};
    const int8_t expected_before8[4]={17,22,-33,-44}, expected_after8[4]={-128,22,0,-44};
    phase="RGBA8I 局部 R/B：负值、零与未写负通道"; make_image(&t,NVN_FORMAT_RGBA8I,4,8,1,1);
    begin(); clear_full_i(&t,0,0,before8); API(nvnCommandBufferClearTexturei)(&commands,&t.object,NULL,&r,value8,5); submit();
    check_region(&t,0,0,expected_before8,expected_after8,&r); API(nvnTextureFinalize)(&t.object); done();
    NVNtextureView v; const uint32_t before_ui[4]={3,5,7,11}, after_ui[4]={0x80000000u,5,0xfeffffffu,11};
    phase="RGBA32UI → RGBA32I 视图：局部负数按有符号值写入"; make_image(&t,NVN_FORMAT_RGBA32UI,16,8,1,1); make_view(&v,0,0,1,NVN_FORMAT_RGBA32I);
    begin(); clear_full(&t,0,0,1,before_ui); API(nvnCommandBufferClearTexturei)(&commands,&t.object,&v,&r,values,5); submit();
    check_region(&t,0,0,before_ui,after_ui,&r); API(nvnTextureFinalize)(&t.object); done();
}
static void signed_mip_layers_snapshot(void) {
    phase="signed mip1 / view layer1+z1：局部 G/A 与参数录制快照";
    image t; make_image(&t,NVN_FORMAT_RGBA32I,16,8,4,3);
    const int before[4]={-3,5,-7,11}, after[4]={-3,INT32_MAX,-7,16777217};
    begin();
    for (int mip=0; mip<3; mip++) for (int layer=0; layer<4; layer++) clear_full_i(&t,mip,layer,before);
    NVNtextureView v; make_view(&v,1,1,3,NVN_FORMAT_RGBA32I); NVNcopyRegion r={1,1,1,2,2,2};
    int values[4]={INT32_MIN,INT32_MAX,-16777217,16777217};
    API(nvnCommandBufferClearTexturei)(&commands,&t.object,&v,&r,values,10);
    memset(values,0,sizeof values); r=(NVNcopyRegion){0,0,0,8,8,1}; make_view(&v,0,0,1,NVN_FORMAT_RGBA32UI); submit();
    const NVNcopyRegion expected_rect={1,1,0,2,2,1};
    for (int mip=0; mip<3; mip++) for (int layer=0; layer<4; layer++)
        check_region(&t,mip,layer,before,after,mip==1 && layer>=2?&expected_rect:NULL);
    API(nvnTextureFinalize)(&t.object); done();
}
static void mip_layers_snapshot(void) {
    phase="mip1 / view layer1+z1 的连续两层，参数录制快照"; image t; make_image(&t,NVN_FORMAT_RGBA8,4,8,4,3);
    begin();
    for (int mip=0; mip<3; mip++) for (int layer=0; layer<4; layer++) {
        const float value[4]={layer*.25f,mip*.25f,.5f,1}; clear_full(&t,mip,layer,0,value);
    }
    NVNtextureView v; make_view(&v,1,1,3,NVN_FORMAT_RGBA8); NVNcopyRegion r={1,1,1,2,2,2}; float value[4]={1,0,.25f,0};
    API(nvnCommandBufferClearTexture)(&commands,&t.object,&v,&r,value,5);
    memset(value,0,sizeof value); r=(NVNcopyRegion){0,0,0,8,8,1}; make_view(&v,0,0,1,NVN_FORMAT_RGBA8UI); submit();
    const uint8_t quarter[4]={0,64,128,191}, after[4]={255,64,64,255}; const NVNcopyRegion expected_rect={1,1,0,2,2,1};
    for (int mip=0; mip<3; mip++) for (int layer=0; layer<4; layer++) {
        const uint8_t before[4]={quarter[layer],quarter[mip],128,255};
        check_region(&t,mip,layer,before,after,mip==1 && layer>=2?&expected_rect:NULL);
    }
    API(nvnTextureFinalize)(&t.object); done();
}
static void ordered_paths(void) {
    phase="同一提交：整层快路 → 局部 → 整层快路 → 局部"; image t; make_image(&t,NVN_FORMAT_RGBA8,4,8,3,1);
    const float green[4]={0,1,0,1}; const uint8_t green8[4]={0,255,0,255}, rb[4]={255,64,64,255};
    begin(); for (int layer=0; layer<3; layer++) clear_full(&t,0,layer,0,initial_f);
    NVNtextureView v; make_view(&v,0,0,1,0); API(nvnCommandBufferClearTexture)(&commands,&t.object,&v,&middle,source_f,5);
    clear_full(&t,0,1,0,green); make_view(&v,0,2,1,0); API(nvnCommandBufferClearTexture)(&commands,&t.object,&v,&middle,source_f,5); submit();
    check_region(&t,0,0,initial_8,rb,&middle); check_region(&t,0,1,green8,green8,NULL); check_region(&t,0,2,initial_8,rb,&middle);
    API(nvnTextureFinalize)(&t.object); done();
}
static void pending_target_and_state(void) {
    image a,b; make_image(&a,NVN_FORMAT_RGBA8,4,8,1,1); const NVNtexture *rt[]={&a.object};
    const float blue[4]={0,0,1,1}, red[4]={1,0,0,1}; const uint8_t blue8[4]={0,0,255,255}, magenta[4]={255,0,255,255};
    phase="pending ClearColor 蓝 → 同纹理局部 R=1：内品红外蓝";
    begin(); API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL); API(nvnCommandBufferSetScissor)(&commands,0,0,8,8);
    API(nvnCommandBufferClearColor)(&commands,0,blue,15); API(nvnCommandBufferClearTexture)(&commands,&a.object,NULL,&middle,red,1); submit();
    check_region(&a,0,0,blue8,magenta,&middle); API(nvnTextureFinalize)(&a.object); done();
    phase="纹理区域 clear 忽略公开 scissor/channel mask，保留后续 RT 目标";
    make_image(&a,NVN_FORMAT_RGBA8,4,4,1,1); make_image(&b,NVN_FORMAT_RGBA8,4,8,1,1); rt[0]=&a.object;
    const NVNcopyRegion right={4,3,0,3,3,1}; const uint8_t rb[4]={255,64,64,255}, green8[4]={0,255,0,255}; const float green[4]={0,1,0,1};
    NVNchannelMaskState mask; API(nvnChannelMaskStateSetDefaults)(&mask); API(nvnChannelMaskStateSetChannelMask)(&mask,0,0,0,0,0);
    begin(); clear_full(&b,0,0,0,initial_f); API(nvnCommandBufferSetRenderTargets)(&commands,1,rt,NULL,NULL,NULL);
    API(nvnCommandBufferSetScissor)(&commands,0,0,4,4); API(nvnCommandBufferClearColor)(&commands,0,blue,15);
    API(nvnCommandBufferBindChannelMaskState)(&commands,&mask); API(nvnCommandBufferSetScissor)(&commands,0,0,0,0);
    API(nvnCommandBufferClearTexture)(&commands,&b.object,NULL,&right,source_f,5);
    API(nvnChannelMaskStateSetDefaults)(&mask); API(nvnCommandBufferBindChannelMaskState)(&commands,&mask);
    API(nvnCommandBufferSetScissor)(&commands,0,0,4,4); API(nvnCommandBufferClearColor)(&commands,0,green,15); submit();
    check_region(&a,0,0,green8,green8,NULL); check_region(&b,0,0,initial_8,rb,&right);
    API(nvnTextureFinalize)(&a.object); API(nvnTextureFinalize)(&b.object); done();
}
static void cpu_initial_upgrade(void) {
    phase="CPU WriteTexels 初始纹理升级后，区域外 / GBA 逐 texel 保留"; image t; make_image(&t,NVN_FORMAT_RGBA8,4,8,1,1);
    uint8_t input[8*8*4],expected[sizeof input];
    for (int y=0; y<8; y++) for (int x=0; x<8; x++) {
        uint8_t *p=input+(y*8+x)*4; p[0]=(uint8_t)(x+16*y); p[1]=(uint8_t)(20+x); p[2]=(uint8_t)(80+y); p[3]=(uint8_t)(200-x-y);
    }
    memcpy(expected,input,sizeof expected); for (int y=1; y<5; y++) for (int x=2; x<5; x++) expected[(y*8+x)*4]=255;
    NVNcopyRegion whole={0,0,0,8,8,1}; API(nvnTextureWriteTexels)(&t.object,NULL,&whole,input);
    memset((uint8_t *)storage+READ_OFFSET,0xA5,sizeof input); begin();
    API(nvnCommandBufferClearTexture)(&commands,&t.object,NULL,&middle,source_f,1);
    // ReadTexels 对 CPU 写入纹理可以返回 CPU 快照；此用例必须从 GPU 下载，不能以旧 CPU 内容判定升级结果。
    NVNbufferAddress destination=API(nvnMemoryPoolGetBufferAddress)(&pool)+READ_OFFSET;
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,&t.object,NULL,&whole,destination,0); submit();
    compare_texels(&t,0,0,(const uint8_t *)storage+READ_OFFSET,expected); API(nvnTextureFinalize)(&t.object); done();
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc>2 || (argc==2 && strcmp(argv[1],"--baseline"))) { fprintf(stderr,"用法：%s [--baseline]\n",argv[0]); return 2; }
    setup(); baseline();
    if (argc==1) { masks(); formats(); format_views(); mip_layers_snapshot(); ordered_paths(); pending_target_and_state(); cpu_initial_upgrade(); signed_formats(); signed_mip_layers_snapshot(); }
    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue); API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device); free(storage);
    printf("✓ t_nvn_partial_clear：%u 组、%u 个真实 GPU texel、%u 条公开 API / 完成状态检查%s\n",cases,texels,checks,argc==2?"（baseline 子集）":""); return 0;
}}
