// Public NVN bootstrap -> recorded production commands -> actual texture readback.
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef NVN_BACKEND_SOURCE
#define NVN_BACKEND_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_BACKEND_SOURCE

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t next_offset = 2 << 20;
static unsigned checks, cases;
static const char *phase = "setup";
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, SIZE = 8, LEVELS = 3, LAYERS = 2 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNtexture object; int bytes, stencil; } image;

static void begin(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE);
    API(nvnCommandBufferBeginRecording)(&commands);
}
static void submit(void) {
    NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle != 0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    const char *names[] = {"nvnCommandBufferClearDepthStencil","nvnCommandBufferSetRenderTargets","nvnTextureReadTexels"};
    for (unsigned i=0;i<sizeof names/sizeof names[0];i++) REQUIRE((void *)API(nvnDeviceGetProcAddress)(&device,names[i]) == load(names[i]));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&qb)); REQUIRE(posix_memalign(&storage,65536,POOL_SIZE) == 0); memset(storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void make_image(image *out, NVNformat format, int bytes, int stencil) {
    out->bytes = bytes; out->stencil = stencil;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D_ARRAY);
    API(nvnTextureBuilderSetSize3D)(&b,SIZE,SIZE,LAYERS); API(nvnTextureBuilderSetLevels)(&b,LEVELS); API(nvnTextureBuilderSetFormat)(&b,format);
    size_t alignment = API(nvnTextureBuilderGetStorageAlignment)(&b), bytes_needed = API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && bytes_needed); next_offset = (next_offset+alignment-1)/alignment*alignment;
    REQUIRE(next_offset+bytes_needed <= POOL_SIZE); API(nvnTextureBuilderSetStorage)(&b,&pool,(ptrdiff_t)next_offset); next_offset += bytes_needed;
    REQUIRE(API(nvnTextureInitialize)(&out->object,&b));
}
static void view(NVNtextureView *v, int level, int layer) {
    API(nvnTextureViewSetDefaults)(v); API(nvnTextureViewSetLevels)(v,level,1); API(nvnTextureViewSetLayers)(v,layer,1);
}
static void target(image *depth, image *color, int level, int layer) {
    NVNtextureView v; view(&v,level,layer); int n = SIZE >> level;
    const NVNtexture *colors[] = {color ? &color->object : NULL}; const NVNtextureView *views[] = {&v};
    API(nvnCommandBufferSetRenderTargets)(&commands,color ? 1 : 0,colors,views,&depth->object,&v);
    API(nvnCommandBufferSetViewport)(&commands,0,0,n,n); API(nvnCommandBufferSetScissor)(&commands,0,0,n,n);
}
static void seed(image *depth) {
    begin();
    for (int l=0;l<LEVELS;l++) for (int z=0;z<LAYERS;z++) {
        target(depth,NULL,l,z); API(nvnCommandBufferClearDepthStencil)(&commands,0.5f,1,0xa5,depth->stencil ? 0xff : 0);
    }
    submit();
}
typedef struct { const char *name; int level,layer,x,y,w,h,dm,sm,mid,pending; } test_case;
static const test_case tests[] = {
    {"no-encoder-depth-scissor",0,0,2,1,3,4,1,0,0,0},
    {"no-encoder-stencil-scissor",0,0,2,1,3,4,0,0xff,0,0},
    {"no-encoder-stencil-mask",0,0,0,0,8,8,0,0x0f,0,0},
    {"mid-pass-stencil-mask",0,0,0,0,8,8,0,0x50,1,0},
    {"mip1-layer1-depth-stencil",1,1,1,1,2,2,1,0x5a,0,0},
    {"mip2-layer1-clipped",2,1,-1,0,2,1,1,0xff,0,0},
    {"empty-scissor",0,0,0,0,0,0,1,0xff,0,0},
    {"full-depth-only",0,0,0,0,8,8,1,0,0,0},
    {"full-stencil-only",0,0,0,0,8,8,0,0xff,0,0},
    {"zero-write-masks",0,0,1,1,3,3,0,0,0,0},
    {"stencil-high-bits-only",0,0,0,0,8,8,0,0x100,0,0},
    {"stencil-high-bits-partial",0,0,0,0,8,8,0,0x10f,0,0},
    {"pending-full-before-local",1,1,1,1,2,2,1,0,0,1},
    {"mid-pass-depth-scissor",0,0,2,1,3,4,1,0,1,0},
};
// Observe the real production holder, without using the NVN combined-format
// ReadTexels packing as the stencil oracle. Metal exposes these as two planes.
static void read_planes(image *t, int level, int layer, float *depth, uint8_t *stencil) {
    id<MTLTexture> mt = tex_mtl((const tex_t *)&t->object); REQUIRE(mt != nil);
    int n = SIZE >> level; REQUIRE(mt.mipmapLevelCount == LEVELS && mt.arrayLength == LAYERS);
    REQUIRE(MAX(mt.width >> level,1ul) == (NSUInteger)n && MAX(mt.height >> level,1ul) == (NSUInteger)n);
    id<MTLDevice> dev = mt.device; id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> d = [dev newBufferWithLength:256*n options:MTLResourceStorageModeShared];
    id<MTLBuffer> s = t->stencil ? [dev newBufferWithLength:256*n options:MTLResourceStorageModeShared] : nil;
    REQUIRE(q && d && (!t->stencil || s));
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:mt sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,n,1)
        toBuffer:d destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*n
        options:t->stencil ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
    if (s) [b copyFromTexture:mt sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,n,1)
        toBuffer:s destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*n options:MTLBlitOptionStencilFromDepthStencil];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted && !cb.error);
    for (int y=0;y<n;y++) {
        memcpy(depth+y*n,(const uint8_t *)d.contents+y*256,n*4);
        if (s) memcpy(stencil+y*n,(const uint8_t *)s.contents+y*256,n);
    }
}
static void verify(image *t, const test_case *c, int initial) {
    for (int l=0;l<LEVELS;l++) for (int z=0;z<LAYERS;z++) {
        int n = SIZE >> l; float depth[SIZE*SIZE]; uint8_t stencil[SIZE*SIZE];
        read_planes(t,l,z,depth,stencil);
        if (!t->stencil) {
            float public_depth[SIZE*SIZE]; NVNtextureView v; view(&v,l,z); NVNcopyRegion r = {0,0,0,n,n,1};
            API(nvnTextureReadTexels)(&t->object,&v,&r,public_depth); REQUIRE(!memcmp(public_depth,depth,n*n*4));
        }
        for (int y=0;y<n;y++) for (int x=0;x<n;x++) {
            int selected = !initial && l == c->level && z == c->layer;
            int inside = selected && x >= c->x && y >= c->y && x < c->x+c->w && y < c->y+c->h;
            float expected = selected && c->pending ? 0.75f : 0.5f;
            if (inside && c->dm) expected = 0.25f;
            float actual = depth[y*n+x];
            if (actual != expected) fprintf(stderr,"depth mip%d layer%d (%d,%d) expected %.2f got %.2f\n",l,z,x,y,expected,actual);
            REQUIRE(actual == expected);
            if (t->stencil) {
                uint8_t actual_stencil = stencil[y*n+x];
                uint8_t expected_stencil = inside ? (uint8_t)((0xa5 & ~c->sm) | (0x3c & c->sm)) : 0xa5;
                if (actual_stencil != expected_stencil) fprintf(stderr,"stencil mip%d layer%d (%d,%d) expected %#x got %#x\n",l,z,x,y,expected_stencil,actual_stencil);
                REQUIRE(actual_stencil == expected_stencil);
            }
        }
    }
}
static void run(image *depth, image *color, const test_case *c) {
    phase = c->name; seed(depth); verify(depth,c,1);
    begin(); target(depth,color,c->level,c->layer);
    if (c->pending) API(nvnCommandBufferClearDepthStencil)(&commands,0.75f,1,0,0);
    if (c->mid) { const float rgba[] = {1,0,0,1}; API(nvnCommandBufferClearColor)(&commands,0,rgba,1); }
    API(nvnCommandBufferSetScissor)(&commands,c->x,c->y,c->w,c->h);
    API(nvnCommandBufferClearDepthStencil)(&commands,0.25f,c->dm,0x3c,depth->stencil ? c->sm : 0); submit();
    verify(depth,c,0); cases++; printf("PASS %s format=%s\n",phase,depth->stencil ? "D32FS8" : "D32F");
}
int main(int argc, char **argv) { @autoreleasepool {
    REQUIRE(argc <= 2); setup(); image depth,combined,color;
    make_image(&depth,NVN_FORMAT_DEPTH32F,4,0); make_image(&combined,NVN_FORMAT_DEPTH32F_STENCIL8,8,1); make_image(&color,NVN_FORMAT_RGBA8,4,0);
    for (unsigned i=0;i<sizeof tests/sizeof tests[0];i++) {
        if (argc == 2 && strcmp(argv[1],tests[i].name)) continue;
        if (!tests[i].sm || tests[i].dm) run(&depth,&color,&tests[i]);
        run(&combined,&color,&tests[i]);
    }
    REQUIRE(cases > 0); API(nvnTextureFinalize)(&depth.object); API(nvnTextureFinalize)(&combined.object); API(nvnTextureFinalize)(&color.object);
    printf("✓ t_nvn_scissored_ds cases=%u checks=%u backend=%s\n",cases,checks,getenv("NXGAL_BE") ?: "default"); return 0;
} }
