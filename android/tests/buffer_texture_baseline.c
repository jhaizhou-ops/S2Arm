// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Test-only stand-ins around the unchanged current record function. Not a GPU test.
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct s2a_vk_device { int unused; };
struct s2a_replay_texture { VkImage image; uint32_t width, height; };
struct s2a_record_memory {
    void *opaque;
    int (*read)(void *, uint64_t, void *, size_t);
    int (*write)(void *, uint64_t, const void *, size_t);
};
struct rec_keep { VkBuffer buf[1]; VkDeviceMemory mem[1]; int nbuf; };
enum { REC_SUBMIT_INCOMPLETE = 2, REC_SUBMIT_COMPLETED = 1 };
static uint8_t guest_bytes[128], *staging;
static size_t guest_limit;
static unsigned image_dependencies, pixel_bytes;
static int read_guest(void *o, uint64_t addr, void *dst, size_t n) {
    (void)o; if (addr > guest_limit || n > guest_limit - addr) return -1;
    memcpy(dst, guest_bytes + addr, n); return 0;
}
static int write_guest(void *o, uint64_t addr, const void *src, size_t n) {
    (void)o; if (addr > guest_limit || n > guest_limit - addr) return -1;
    memcpy(guest_bytes + addr, src, n); return 0;
}
static int create_visible(struct s2a_vk_device *d, size_t n, VkBuffer *b, VkDeviceMemory *m, void **p) {
    (void)d; staging = malloc(n); if (!staging) return -1;
    memset(staging, 0xcc, n); *p = staging; *b = (VkBuffer)(uintptr_t)1; *m = (VkDeviceMemory)(uintptr_t)1; return 0;
}
static void destroy_visible(struct s2a_vk_device *d, VkBuffer b, VkDeviceMemory m, void *p) {
    (void)d; (void)b; (void)m; free(p); staging = NULL;
}
static VkCommandBuffer begin_command(struct s2a_vk_device *d) { (void)d; return (VkCommandBuffer)(uintptr_t)1; }
static void rec_free_command(struct s2a_vk_device *d, VkCommandBuffer c) { (void)d; (void)c; }
static int submit(struct s2a_vk_device *d, VkCommandBuffer c, struct rec_keep *k) { (void)d; (void)c; (void)k; return REC_SUBMIT_COMPLETED; }
VKAPI_ATTR void VKAPI_CALL vkCmdCopyImageToBuffer(VkCommandBuffer c, VkImage image, VkImageLayout l,
    VkBuffer b, uint32_t n, const VkBufferImageCopy *regions) {
    (void)c; (void)image; (void)l; (void)b;
    for (uint32_t i = 0; i < n; i++) {
        const VkBufferImageCopy *r = regions + i;
        uint32_t pitch = (r->bufferRowLength ? r->bufferRowLength : r->imageExtent.width) * pixel_bytes;
        for (uint32_t y = 0; y < r->imageExtent.height; y++)
            memset(staging + r->bufferOffset + y * pitch, 0x39, r->imageExtent.width * pixel_bytes);
    }
}
VKAPI_ATTR void VKAPI_CALL vkCmdCopyBufferToImage(VkCommandBuffer c, VkBuffer b, VkImage i,
    VkImageLayout l, uint32_t n, const VkBufferImageCopy *r) { (void)c; (void)b; (void)i; (void)l; (void)n; (void)r; }
VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(VkCommandBuffer c, VkPipelineStageFlags a,
    VkPipelineStageFlags b, VkDependencyFlags f, uint32_t nm, const VkMemoryBarrier *m,
    uint32_t nb, const VkBufferMemoryBarrier *bb, uint32_t ni, const VkImageMemoryBarrier *ib) {
    (void)c; (void)a; (void)b; (void)f; (void)nm; (void)m; (void)nb; (void)bb; (void)ib;
    image_dependencies += ni;
}
// Runner extracts this function verbatim from the fixed production vk_record.c.
#include "buffer_texture_record.inc"
struct baseline_region { int xoffset, yoffset, zoffset; };
struct baseline_copy { int flags, has_view; struct baseline_region r; };
static int reject(int result, int code, int op, const char *why) { (void)result; (void)op; (void)why; return code; }
static int legacy_guard(struct baseline_copy copy) {
    int result = 0; struct { int op; } header = {31};
#define fail reject
#define S2A_RECORD_UNSUPPORTED (-3)
#include "buffer_texture_guard.inc"
#undef fail
    return 0;
}
int main(void) {
    int failed = 0; struct s2a_vk_device d = {0};
    struct s2a_replay_texture t = {(VkImage)(uintptr_t)1, 3, 2};
    struct s2a_record_memory m = {NULL, read_guest, write_guest};
    if (legacy_guard((struct baseline_copy){0, 0, {2, 1, 0}}) != 0) { puts("BASELINE RED offset: valid xy region rejected"); failed++; }
    if (legacy_guard((struct baseline_copy){0, 1, {0, 0, 0}}) != 0) { puts("BASELINE RED default-view: presence rejected"); failed++; }
    guest_limit = 6; pixel_bytes = 1;
    if (copy_image_buffer(&d, &t, 0, 0, 0, &m, 0) != 0) { puts("BASELINE RED format: R8 3x2 needs six bytes, fixed-four read overreaches"); failed++; }
    guest_limit = sizeof guest_bytes; pixel_bytes = 4; t.width = t.height = 2;
    memset(guest_bytes, 0xa5, sizeof guest_bytes); image_dependencies = 0;
    if (copy_image_buffer(&d, &t, 0, 12, 32, &m, 1) != 0) return 2;
    if (guest_bytes[8] != 0xa5 || guest_bytes[20] != 0xa5 || guest_bytes[31] != 0xa5) { puts("BASELINE RED padding: entire image_stride overwrites untouched bytes"); failed++; }
    if (!image_dependencies) { puts("BASELINE RED dependency: no image dependency emitted"); failed++; }
    printf("baseline: %d/5 expected assertions failed (stand-ins, no GPU)\n", failed);
    return failed ? 1 : 0;
}
