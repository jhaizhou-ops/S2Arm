// Store-lookahead attachment table at its upper bound (audit #799 F-sd-att-10): one render pass with 8 colour targets
// plus a combined depth-stencil target records 8 + 1 + 1 = 10 entries. Public NVN bootstrap -> recorded production
// commands -> real Metal 3 / Metal 4 replay and submit, built with AddressSanitizer so a write past the table aborts.
// Expected values are the clear values themselves (every attachment is stored: nothing later in the submit clears it again).
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../gfx/nvn/nvn_mtl.m"

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t next_offset = 2 << 20;
static unsigned checks;
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, SIZE = 8, NCOLOR = 8 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&qb)); REQUIRE(posix_memalign(&storage,65536,POOL_SIZE) == 0); memset(storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void make_image(NVNtexture *out, NVNformat format) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b,&device);
    API(nvnTextureBuilderSetTarget)(&b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b,SIZE,SIZE); API(nvnTextureBuilderSetLevels)(&b,1); API(nvnTextureBuilderSetFormat)(&b,format);
    size_t alignment = API(nvnTextureBuilderGetStorageAlignment)(&b), bytes_needed = API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(alignment && bytes_needed); next_offset = (next_offset+alignment-1)/alignment*alignment;
    REQUIRE(next_offset+bytes_needed <= POOL_SIZE); API(nvnTextureBuilderSetStorage)(&b,&pool,(ptrdiff_t)next_offset); next_offset += bytes_needed;
    REQUIRE(API(nvnTextureInitialize)(out,&b));
}
// Depth and stencil planes read straight from the production Metal holder (Metal exposes the combined format as two planes).
static void read_planes(NVNtexture *t, float *depth, uint8_t *stencil) {
    id<MTLTexture> mt = tex_mtl((const tex_t *)t); REQUIRE(mt != nil);
    id<MTLDevice> dev = mt.device; id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> d = [dev newBufferWithLength:256*SIZE options:MTLResourceStorageModeShared];
    id<MTLBuffer> s = [dev newBufferWithLength:256*SIZE options:MTLResourceStorageModeShared];
    REQUIRE(q && d && s);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(SIZE,SIZE,1)
        toBuffer:d destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*SIZE options:MTLBlitOptionDepthFromDepthStencil];
    [b copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(SIZE,SIZE,1)
        toBuffer:s destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*SIZE options:MTLBlitOptionStencilFromDepthStencil];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted && !cb.error);
    for (int y=0;y<SIZE;y++) { memcpy(depth+y*SIZE,(const uint8_t *)d.contents+y*256,SIZE*4); memcpy(stencil+y*SIZE,(const uint8_t *)s.contents+y*256,SIZE); }
}
int main(void) { @autoreleasepool {
    setup(); NVNtexture color[NCOLOR], ds;
    for (int i=0;i<NCOLOR;i++) make_image(&color[i],NVN_FORMAT_RGBA8);
    make_image(&ds,NVN_FORMAT_DEPTH32F_STENCIL8);
    NVNtextureView v; API(nvnTextureViewSetDefaults)(&v);
    const NVNtexture *colors[NCOLOR]; const NVNtextureView *views[NCOLOR];
    for (int i=0;i<NCOLOR;i++) { colors[i] = &color[i]; views[i] = &v; }
    API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferSetRenderTargets)(&commands,NCOLOR,colors,views,&ds,&v);
    API(nvnCommandBufferSetViewport)(&commands,0,0,SIZE,SIZE); API(nvnCommandBufferSetScissor)(&commands,0,0,SIZE,SIZE);
    for (int i=0;i<NCOLOR;i++) { const float rgba[4] = {i & 1, (i >> 1) & 1, (i >> 2) & 1, 1}; API(nvnCommandBufferClearColor)(&commands,i,rgba,0xf); }
    API(nvnCommandBufferClearDepthStencil)(&commands,0.25f,1,0x3c,0xff);
    // Re-targeting inside the list ends the pass there, so with DM_NVN_TBDR=1 the lookahead decision (sdx_decide) also fills all 10 slots
    API(nvnCommandBufferSetRenderTargets)(&commands,1,colors,views,NULL,NULL);
    NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle != 0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
    for (int i=0;i<NCOLOR;i++) {   // RGBA8 bytes of the clear colour: channel 1.0 -> 0xff, 0.0 -> 0x00
        uint8_t px[SIZE*SIZE*4], want[4] = {i & 1 ? 0xff : 0, (i >> 1) & 1 ? 0xff : 0, (i >> 2) & 1 ? 0xff : 0, 0xff};
        NVNcopyRegion r = {0,0,0,SIZE,SIZE,1}; API(nvnTextureReadTexels)(&color[i],&v,&r,px);
        for (int p=0;p<SIZE*SIZE;p++) { if (memcmp(px+p*4,want,4)) fprintf(stderr,"c%d px%d got %02x%02x%02x%02x\n",i,p,px[p*4],px[p*4+1],px[p*4+2],px[p*4+3]); REQUIRE(!memcmp(px+p*4,want,4)); }
    }
    float depth[SIZE*SIZE]; uint8_t stencil[SIZE*SIZE]; read_planes(&ds,depth,stencil);
    for (int p=0;p<SIZE*SIZE;p++) { REQUIRE(depth[p] == 0.25f); REQUIRE(stencil[p] == 0x3c); }
    printf("✓ t_nvn_sd_cap checks=%u backend=%s tbdr=%s\n",checks,getenv("NXGAL_BE") ?: "default",getenv("DM_NVN_TBDR") ?: "0"); return 0;
} }
