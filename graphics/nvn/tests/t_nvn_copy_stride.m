// 用真实图标像素检查完整生产 NVN bootstrap / 注册节 / 跳板 / Metal 拷贝。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../graphics_session.h"

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static const char *phase = "准备";
static unsigned checks;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))
enum { W = 1024, H = 512, LAYERS = 2, ROW = W * 4, IMAGE = ROW * H, PIXELS = IMAGE * LAYERS };
typedef struct { NVNmemoryPool object; void *bytes; size_t size; } memory;
static NVNdevice device;
static NVNqueue queue;
static memory pools[32]; static unsigned npools;
static NVNtexture textures[12]; static unsigned ntextures;
static memory *texture_storage[12];
static NVNtexture *stop_textures[2]; static memory *stop_storage[2];
static NVNcommandBuffer commands[16]; static unsigned ncommands;
static uint8_t *pixels;
static const NVNcopyRegion region = {0, 0, 0, W, H, LAYERS};

static void read_image(const char *path) {
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL); CHECK(source != NULL);
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL); CHECK(image != NULL);
    CHECK(CGImageGetWidth(image) == W && CGImageGetHeight(image) == H * LAYERS);
    pixels = malloc(PIXELS); CHECK(pixels != NULL);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); CHECK(color != NULL);
    CGContextRef context = CGBitmapContextCreate(pixels, W, H * LAYERS, 8, ROW, color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big); CHECK(context != NULL);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, W, H * LAYERS), image);
    CHECK(memcmp(pixels, pixels + IMAGE, IMAGE) != 0);
    CGContextRelease(context); CGColorSpaceRelease(color); CGImageRelease(image); CFRelease(source);
    printf("真实图标：%s，%dx%d RGBA8，上下半图不同\n", path, W, H * LAYERS); fflush(stdout);
}
static memory *new_memory(size_t size) {
    CHECK(npools < sizeof pools / sizeof *pools);
    memory *m = &pools[npools++];
    size_t page = (size_t)getpagesize(); m->size = (size + page - 1) & ~(page - 1);
    CHECK(posix_memalign(&m->bytes, page, m->size) == 0); memset(m->bytes, 0, m->size);
    NVNmemoryPoolBuilder builder = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&builder);
    API(nvnMemoryPoolBuilderSetDevice)(&builder, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&builder, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&builder, m->bytes, m->size);
    CHECK(API(nvnMemoryPoolInitialize)(&m->object, &builder)); return m;
}
static NVNtexture *new_texture(NVNtextureTarget target) {
    CHECK(ntextures < sizeof textures / sizeof *textures);
    NVNtexture *texture = &textures[ntextures++]; NVNtextureBuilder builder = {{0}};
    API(nvnTextureBuilderSetDefaults)(&builder);
    API(nvnTextureBuilderSetDevice)(&builder, &device);
    API(nvnTextureBuilderSetTarget)(&builder, target);
    API(nvnTextureBuilderSetSize3D)(&builder, W, H, LAYERS);
    API(nvnTextureBuilderSetLevels)(&builder, 1);
    API(nvnTextureBuilderSetFormat)(&builder, NVN_FORMAT_RGBA8);
    memory *m = new_memory(API(nvnTextureBuilderGetStorageSize)(&builder));
    texture_storage[ntextures - 1] = m;
    API(nvnTextureBuilderSetStorage)(&builder, &m->object, 0);
    CHECK(API(nvnTextureInitialize)(texture, &builder)); return texture;
}
static NVNcommandBuffer *new_command(void) {
    CHECK(ncommands < sizeof commands / sizeof *commands);
    NVNcommandBuffer *command = &commands[ncommands++]; memory *m = new_memory(65536);
    CHECK(API(nvnCommandBufferInitialize)(command, &device));
    API(nvnCommandBufferAddCommandMemory)(command, &m->object, 0, m->size); return command;
}
static void set_stride(NVNcommandBuffer *c, size_t row, size_t image) {
    API(nvnCommandBufferSetCopyRowStride)(c, (ptrdiff_t)row);
    API(nvnCommandBufferSetCopyImageStride)(c, (ptrdiff_t)image);
}
static void check_stride(NVNcommandBuffer *c, ptrdiff_t row, ptrdiff_t image) {
    NVNcommandBuffer before = *c;
    CHECK(API(nvnCommandBufferGetCopyRowStride)(c) == row);
    CHECK(API(nvnCommandBufferGetCopyImageStride)(c) == image);
    CHECK(memcmp(&before, c, sizeof before) == 0);
}
static void set_without_memory(NVNcommandBuffer *c, size_t row, size_t image) {
    size_t used = API(nvnCommandBufferGetCommandMemoryUsed)(c), free = API(nvnCommandBufferGetCommandMemoryFree)(c);
    set_stride(c, row, image);
    CHECK(API(nvnCommandBufferGetCommandMemoryUsed)(c) == used);
    CHECK(API(nvnCommandBufferGetCommandMemoryFree)(c) == free);
    check_stride(c, row, image);
}
static void cpu_state(void) {
    phase = "CPU stride 默认值、独立状态、录制保持与不耗命令内存";
    NVNcommandBuffer *a = new_command(), *b = new_command();
    check_stride(a, 0, 0); check_stride(b, 0, 0);
    set_without_memory(a, ROW + 256, (ROW + 256) * (H + 1));
    set_without_memory(b, ROW + 512, (ROW + 512) * (H + 2));
    check_stride(a, ROW + 256, (ROW + 256) * (H + 1));
    API(nvnCommandBufferBeginRecording)(a);
    check_stride(a, ROW + 256, (ROW + 256) * (H + 1));
    set_without_memory(a, ROW + 512, (ROW + 512) * (H + 2));
    CHECK(API(nvnCommandBufferEndRecording)(a) != 0);
    check_stride(a, ROW + 512, (ROW + 512) * (H + 2));
    API(nvnCommandBufferSetCopyRowStride)(a, 0);
    check_stride(a, 0, (ROW + 512) * (H + 2));
    API(nvnCommandBufferSetCopyImageStride)(a, 0); check_stride(a, 0, 0);
    check_stride(b, ROW + 512, (ROW + 512) * (H + 2));
    API(nvnCommandBufferFinalize)(a); CHECK(API(nvnCommandBufferInitialize)(a, &device));
    check_stride(a, 0, 0);
    printf("%s：通过\n", phase); fflush(stdout);
}
static void submit(NVNcommandHandle handle) {
    API(nvnQueueSubmitCommands)(&queue, 1, &handle); API(nvnQueueFinish)(&queue);
    CHECK(mtl_last_commit_error() == 0);
}
static void compare(const void *actual_, const void *expected_, size_t size) {
    const uint8_t *actual = actual_, *expected = expected_; checks++;
    if (memcmp(actual, expected, size) == 0) return;
    for (size_t i = 0; i < size; i++) if (actual[i] != expected[i]) {
        fprintf(stderr, "FAIL [%s] 像素/字节偏移 %zu：实际 %u，期望 %u\n", phase, i, actual[i], expected[i]); exit(1);
    }
}
static void check_texture(NVNtexture *texture, const uint8_t *expected) {
    uint8_t *readback = malloc(PIXELS); CHECK(readback != NULL);
    API(nvnTextureReadTexels)(texture, NULL, &region, readback);
    compare(readback, expected, PIXELS); free(readback);
}
static memory *source_buffer(size_t row, size_t image, int swap) {
    memory *m = new_memory(image * LAYERS);
    for (size_t offset = 0; offset < m->size; offset += PIXELS) {
        size_t size = m->size - offset; if (size > PIXELS) size = PIXELS;
        memcpy((uint8_t *)m->bytes + offset, pixels, size);
    }
    for (unsigned z = 0; z < LAYERS; z++) for (unsigned y = 0; y < H; y++)
        memcpy((uint8_t *)m->bytes + z * image + y * row, pixels + ((swap ? LAYERS - 1 - z : z) * H + y) * ROW, ROW);
    return m;
}
static void copy_to_texture(NVNcommandBuffer *c, memory *source, NVNtexture *texture) {
    API(nvnCommandBufferCopyBufferToTexture)(c, API(nvnMemoryPoolGetBufferAddress)(&source->object), texture, NULL, &region, 0);
}
static NVNcommandHandle upload(NVNcommandBuffer *c, memory *source, NVNtexture *texture, size_t row, size_t image) {
    set_stride(c, row, image); API(nvnCommandBufferBeginRecording)(c);
    copy_to_texture(c, source, texture); return API(nvnCommandBufferEndRecording)(c);
}
static void upload_before_begin(void) {
    phase = "Begin 前设置 stride 的真实 GPU 上传";
    size_t row = ROW + 256, image = row * (H + 1);
    memory *source = source_buffer(row, image, 0);
    NVNtexture *texture = new_texture(NVN_TEXTURE_TARGET_2D_ARRAY);
    NVNcommandBuffer *c = new_command();
    set_stride(c, row, image);
    API(nvnCommandBufferBeginRecording)(c);
    API(nvnCommandBufferCopyBufferToTexture)(c, API(nvnMemoryPoolGetBufferAddress)(&source->object), texture, NULL, &region, 0);
    NVNcommandHandle handle = API(nvnCommandBufferEndRecording)(c);
    submit(handle); check_texture(texture, pixels);
    printf("%s：通过\n", phase); fflush(stdout);
}
static void upload_zero_and_3d(void) {
    const NVNtextureTarget targets[] = { NVN_TEXTURE_TARGET_2D_ARRAY, NVN_TEXTURE_TARGET_3D };
    for (unsigned i = 0; i < 2; i++) {
        phase = i ? "3D depth slice 行/层 padding" : "2D array 默认紧排";
        size_t row = i ? ROW + 512 : ROW, image = i ? row * (H + 2) : IMAGE;
        memory *source = source_buffer(row, image, 0);
        NVNtexture *texture = new_texture(targets[i]); NVNcommandBuffer *c = new_command();
        NVNcommandHandle handle = upload(c, source, texture, i ? row : 0, i ? image : 0);
        submit(handle); check_texture(texture, pixels);
        printf("%s：通过\n", phase); fflush(stdout);
    }
}
static void interleaved_uploads(int copy_only, const uint8_t *swapped) {
    size_t row_a = ROW + 256, image_a = row_a * (H + 1), row_b = ROW + 512, image_b = row_b * (H + 2);
    memory *source_a = source_buffer(row_a, image_a, 0), *source_b = source_buffer(row_b, image_b, 1);
    NVNtexture *texture_a = new_texture(NVN_TEXTURE_TARGET_2D_ARRAY), *texture_b = new_texture(NVN_TEXTURE_TARGET_2D_ARRAY);
    NVNtexture *texture_parent = new_texture(NVN_TEXTURE_TARGET_2D_ARRAY);
    NVNcommandBuffer *a = new_command(), *b = new_command(), *parent = new_command();
    phase = "两 CB 交错录制，录制后更改对象 stride";
    set_stride(a, row_a, image_a); set_stride(b, row_b, image_b);
    API(nvnCommandBufferBeginRecording)(a); copy_to_texture(a, source_a, texture_a);
    API(nvnCommandBufferBeginRecording)(b); copy_to_texture(b, source_b, texture_b);
    NVNcommandHandle hb = API(nvnCommandBufferEndRecording)(b);
    set_stride(a, row_b, image_b);
    NVNcommandHandle ha = API(nvnCommandBufferEndRecording)(a);
    submit(hb); submit(ha); check_texture(texture_a, pixels); check_texture(texture_b, swapped);
    printf("%s：通过\n", phase); fflush(stdout);

    phase = "B 提交干扰后重复执行 A 旧 handle";
    NVNcommandHandle overwrite = upload(b, source_b, texture_a, row_b, image_b);
    submit(overwrite); check_texture(texture_a, swapped);
    set_stride(a, 0, 0); set_stride(b, 0, 0);
    submit(hb); submit(ha); check_texture(texture_a, pixels); check_texture(texture_b, swapped);
    printf("%s：通过\n", phase); fflush(stdout);

    for (unsigned copy = 0; copy < 2; copy++) {
        phase = copy ? "CopyCommands 子 handle 与父 CB stride 隔离" : "CallCommands 子 handle 与父 CB stride 隔离";
        set_stride(parent, row_b, image_b); API(nvnCommandBufferBeginRecording)(parent);
        if (copy) API(nvnCommandBufferCopyCommands)(parent, 1, &ha);
        else API(nvnCommandBufferCallCommands)(parent, 1, &ha);
        copy_to_texture(parent, source_b, texture_parent);
        NVNcommandHandle hp = API(nvnCommandBufferEndRecording)(parent);
        if (!copy_only) check_stride(parent, row_b, image_b);
        // 每种子调用和父拷贝都必须改变已核对的真实像素，不能靠先前内容通过。
        submit(upload(b, source_b, texture_a, row_b, image_b)); check_texture(texture_a, swapped);
        submit(upload(b, source_a, texture_parent, row_a, image_a)); check_texture(texture_parent, pixels);
        submit(hp); check_texture(texture_a, pixels); check_texture(texture_parent, swapped);
        if (!copy_only) check_stride(parent, row_b, image_b);
        printf("%s：通过\n", phase); fflush(stdout);
    }

    phase = "同一 handle 两次 copy 之间修改 stride";
    submit(upload(b, source_b, texture_a, row_b, image_b)); check_texture(texture_a, swapped);
    submit(upload(b, source_a, texture_b, row_a, image_a)); check_texture(texture_b, pixels);
    set_stride(a, row_a, image_a); API(nvnCommandBufferBeginRecording)(a);
    copy_to_texture(a, source_a, texture_a);
    set_stride(a, row_b, image_b); copy_to_texture(a, source_b, texture_b);
    NVNcommandHandle mixed = API(nvnCommandBufferEndRecording)(a);
    if (!copy_only) check_stride(a, row_b, image_b);
    set_stride(a, 0, 0); submit(mixed);
    check_texture(texture_a, pixels); check_texture(texture_b, swapped);
    printf("%s：通过\n", phase); fflush(stdout);
}
static void downloads(const uint8_t *swapped) {
    phase = "准备独立下载源：真实 CPU WriteTexels";
    NVNtexture *sources[] = { new_texture(NVN_TEXTURE_TARGET_2D_ARRAY), new_texture(NVN_TEXTURE_TARGET_2D_ARRAY) };
    for (unsigned i = 0; i < 2; i++) { stop_textures[i] = sources[i]; stop_storage[i] = texture_storage[sources[i] - textures]; }
    API(nvnTextureWriteTexels)(sources[0], NULL, &region, pixels);
    API(nvnTextureWriteTexels)(sources[1], NULL, &region, swapped);
    const size_t rows[] = { ROW + 256, ROW + 512, 0, 0 };
    const size_t images[] = { (ROW + 256) * (H + 1), 0, ROW * (H + 2), 0 };
    const char *phases[] = { "独立 T2B 行与层 padding", "独立 T2B 仅行 padding", "独立 T2B 仅层 padding", "独立 T2B 全紧排" };
    memory *outputs[4]; uint8_t *expected[4]; NVNcommandHandle handles[4];
    for (unsigned i = 0; i < 4; i++) {
        phase = phases[i]; size_t row = rows[i] ? rows[i] : ROW, image = images[i] ? images[i] : row * H;
        outputs[i] = new_memory(image * LAYERS);
        const uint8_t *input = i & 1 ? swapped : pixels, *initial = i & 1 ? pixels : swapped;
        for (size_t at = 0; at < outputs[i]->size; at += PIXELS) {
            size_t n = outputs[i]->size - at; if (n > PIXELS) n = PIXELS;
            memcpy((uint8_t *)outputs[i]->bytes + at, initial, n);
        }
        expected[i] = malloc(outputs[i]->size); CHECK(expected[i] != NULL); memcpy(expected[i], outputs[i]->bytes, outputs[i]->size);
        // 独立按字节坐标手算目标地址；行/层 padding 及池尾部保留初始真实图像字节。
        for (unsigned z = 0; z < LAYERS; z++) for (unsigned y = 0; y < H; y++)
            memcpy(expected[i] + z * image + y * row, input + (z * H + y) * ROW, ROW);
        CHECK(memcmp(outputs[i]->bytes, expected[i], outputs[i]->size) != 0);
        NVNcommandBuffer *c = new_command(); set_stride(c, rows[i], images[i]); API(nvnCommandBufferBeginRecording)(c);
        API(nvnCommandBufferCopyTextureToBuffer)(c, sources[i & 1], NULL, &region, API(nvnMemoryPoolGetBufferAddress)(&outputs[i]->object), 0);
        handles[i] = API(nvnCommandBufferEndRecording)(c); set_stride(c, ROW + 768, (ROW + 768) * (H + 3));
    }
    for (int i = 3; i >= 0; i--) {
        phase = phases[i]; submit(handles[i]); compare(outputs[i]->bytes, expected[i], outputs[i]->size); free(expected[i]);
        printf("%s：通过\n", phase); fflush(stdout);
    }
}
static void stopped_texel_writes(const uint8_t *swapped) {
    phase = "停止后 public texel 写入保持 pool 字节";
    NVNT_nvnTextureWriteTexels write = (NVNT_nvnTextureWriteTexels)load("nvnTextureWriteTexels");
    NVNT_nvnTextureWriteTexelsStrided write_strided = (NVNT_nvnTextureWriteTexelsStrided)load("nvnTextureWriteTexelsStrided");
    memory *tight_pool = stop_storage[0], *strided_pool = stop_storage[1];
    CHECK(tight_pool != NULL && strided_pool != NULL);
    uint8_t *tight_before = malloc(tight_pool->size), *strided_before = malloc(strided_pool->size);
    CHECK(tight_before != NULL && strided_before != NULL);
    memcpy(tight_before, tight_pool->bytes, tight_pool->size);
    memcpy(strided_before, strided_pool->bytes, strided_pool->size);
    const size_t write_row = ROW + 64, write_image = write_row * (H + 1), strided_size = write_image * LAYERS;
    uint8_t *strided = malloc(strided_size); CHECK(strided != NULL); memset(strided, 0xa5, strided_size);
    for (unsigned z = 0; z < LAYERS; z++) for (unsigned y = 0; y < H; y++)
        memcpy(strided + z * write_image + y * write_row, pixels + (z * H + y) * ROW, ROW);
    CHECK(s2a_graphics_native_request_stop() == 0);
    write(stop_textures[0], NULL, &region, swapped);
    write_strided(stop_textures[1], NULL, &region, strided, (ptrdiff_t)write_row, (ptrdiff_t)write_image);
    int tight_changed = memcmp(tight_pool->bytes, tight_before, tight_pool->size) != 0;
    int strided_changed = memcmp(strided_pool->bytes, strided_before, strided_pool->size) != 0;
    fprintf(stderr, "[停止后 NVN 写入] WriteTexels pool_changed=%d；WriteTexelsStrided pool_changed=%d\n", tight_changed, strided_changed);
    CHECK(!tight_changed && !strided_changed);
    free(strided); free(strided_before); free(tight_before);
}
int main(int argc, char **argv) {
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--copy-only"))) { fprintf(stderr, "用法：%s [--copy-only]\n", argv[0]); return 2; }
    @autoreleasepool {
        read_image("launchers/macos/Branding/AppIcon-1024.png");
        NVNdeviceBuilder device_builder = {{0}}; NVNqueueBuilder queue_builder = {{0}};
        API(nvnDeviceBuilderSetDefaults)(&device_builder); CHECK(API(nvnDeviceInitialize)(&device, &device_builder));
        API(nvnQueueBuilderSetDefaults)(&queue_builder); API(nvnQueueBuilderSetDevice)(&queue_builder, &device);
        CHECK(API(nvnQueueInitialize)(&queue, &queue_builder));
        CHECK(s2a_graphics_native_begin_session() == 0);
        int copy_only = argc == 2;
        uint8_t *swapped = malloc(PIXELS); CHECK(swapped != NULL);
        memcpy(swapped, pixels + IMAGE, IMAGE); memcpy(swapped + IMAGE, pixels, IMAGE);
        if (!copy_only) cpu_state();
        upload_before_begin();
        upload_zero_and_3d(); interleaved_uploads(copy_only, swapped); downloads(swapped);
        API(nvnQueueFinish)(&queue);
        stopped_texel_writes(swapped);
        for (unsigned i = 0; i < ncommands; i++) API(nvnCommandBufferFinalize)(&commands[i]);
        for (unsigned i = 0; i < ntextures; i++) API(nvnTextureFinalize)(&textures[i]);
        for (unsigned i = 0; i < npools; i++) { API(nvnMemoryPoolFinalize)(&pools[i].object); free(pools[i].bytes); }
        API(nvnQueueFinalize)(&queue); API(nvnDeviceFinalize)(&device); free(pixels); free(swapped);
        printf("✓ t_nvn_copy_stride：%u 条真实 API / GPU 字节断言\n", checks);
    }
    return 0;
}
