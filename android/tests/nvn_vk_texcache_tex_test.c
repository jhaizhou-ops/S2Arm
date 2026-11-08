// 前端 tex_t → 纹理缓存的目标分类与真实图内容：
//   - 线性 2D / 块线性多级 2D / 3D 建图（原有用例）
//   - CUBEMAP(8)：6 个面各自独立颜色，逐面 GPU 读回必须等于写入颜色，视图类型必须是 CUBE
//   - CUBEMAP_ARRAY(9)：12 个层-面，视图类型 CUBE_ARRAY，抽查层内容
//   - 2D_MULTISAMPLE(5) / 2D_MULTISAMPLE_ARRAY(6)：没有采样/resolve 通路，必须明确拒绝并写对原因
//     （旧实现把 5/6 当立方体，测试也用 5 号验证“cube 被拒绝”，掩盖了真正的 8/9 未按 cube 建图）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_vk_texcache.h"
#include "nvn_vk_format.h"
#include "nvn_deswizzle.h"
#include "nvn_tex.h"

static int read_layer(struct s2a_vk_device *d, VkImage image, uint32_t layer,
                      uint32_t w, uint32_t h, uint8_t *out, size_t bytes) {
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = bytes; bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buffer = VK_NULL_HANDLE;
    if (vkCreateBuffer(d->device, &bi, NULL, &buffer) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(d->device, buffer, &req);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(d, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    int rc = -1;
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(d->device, &ai, NULL, &memory) != VK_SUCCESS ||
        vkBindBufferMemory(d->device, buffer, memory, 0) != VK_SUCCESS ||
        vkMapMemory(d->device, memory, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) goto done;
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = d->command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(d->device, &ca, &cmd) != VK_SUCCESS) goto done;
    VkCommandBufferBeginInfo cb = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cb);
    VkBufferImageCopy region = {0};
    region.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, layer, 1 };
    region.imageExtent = (VkExtent3D){ w, h, 1 };
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &region);
    VkBufferMemoryBarrier barrier = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = buffer; barrier.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &barrier, 0, NULL);
    vkEndCommandBuffer(cmd);
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    vkCreateFence(d->device, &fi, NULL, &fence);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    if (vkQueueSubmit(d->queue, 1, &si, fence) == VK_SUCCESS &&
        vkWaitForFences(d->device, 1, &fence, VK_TRUE, UINT64_MAX) == VK_SUCCESS) {
        memcpy(out, mapped, bytes);
        rc = 0;
    }
    vkDestroyFence(d->device, fence, NULL);
    vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
done:
    if (mapped) vkUnmapMemory(d->device, memory);
    vkDestroyBuffer(d->device, buffer, NULL);
    if (memory) vkFreeMemory(d->device, memory, NULL);
    return rc;
}

// 一张全是 color 的 4x4 RGBA8 线性面。
static void fill_face(uint8_t *face, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int i = 0; i < 16; i++) { face[i * 4 + 0] = r; face[i * 4 + 1] = g; face[i * 4 + 2] = b; face[i * 4 + 3] = a; }
}

// 按目标规定的层-面数生成块线性存储，每层独立颜色，返回 storage（调用方 free）。
static uint8_t *make_storage(const tex_t *t, uint32_t layer_faces, uint8_t *expected_rgba) {
    nvn_texlayout L; nvn_tex_layout(&t->d, &L);
    size_t size = L.size ? (size_t)L.size : 0x10000;
    if (size < 0x10000) size = 0x10000;
    uint8_t *storage = calloc(1, size + 0x1000);
    if (!storage) return NULL;
    uint8_t face[64];
    for (uint32_t i = 0; i < layer_faces && i < 64; i++) {
        fill_face(face, (uint8_t)(16 + i * 20), (uint8_t)(200 - i * 8), (uint8_t)(60 + i * 5), 255);
        expected_rgba[i * 4 + 0] = face[0]; expected_rgba[i * 4 + 1] = face[1];
        expected_rgba[i * 4 + 2] = face[2]; expected_rgba[i * 4 + 3] = face[3];
        if (nvn_swizzle(&t->d, 0, i, face, 16, storage)) { free(storage); return NULL; }
    }
    return storage;
}

int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_texcache c; if (nvn_vk_texcache_init(&c, &d, why, sizeof why)) { printf("FAIL texcache: %s\n", why); return 1; }
    int failures = 0;
    uint8_t green[64]; fill_face(green, 0, 255, 0, 255);   // fill_face 填满 16 个像素（64 B），2x2 采样只用前 16 B

    // ---- 1. 线性 2D ----
    tex_t t; memset(&t, 0, sizeof t);
    t.magic = 0x54584554; t.d.target = 1; t.d.format = NVN_FORMAT_RGBA8;
    t.d.width = 2; t.d.height = 2; t.d.depth = 1; t.d.stride = 8; t.mem = green; t.serial = 7;
    char r1[160] = "";
    struct nvn_vk_tex *a = nvn_vk_texcache_get_tex(&c, &t, r1, sizeof r1);
    if (!a) { failures++; printf("FAIL linear 2D rejected: %s\n", r1); }
    else if (a->view_type != VK_IMAGE_VIEW_TYPE_2D) { failures++; printf("FAIL linear 2D view type=%d\n", (int)a->view_type); }

    // ---- 2. 块线性、两个 mip ----
    uint8_t storage[4096] = {0};
    t.d.stride = 0; t.d.levels = 2;
    uint8_t g1[4] = {0, 255, 0, 255};
    (void)nvn_swizzle(&t.d, 0, 0, green, 8, storage);
    (void)nvn_swizzle(&t.d, 1, 0, g1, 4, storage);
    t.mem = storage; char r2[160] = "";
    struct nvn_vk_tex *b = nvn_vk_texcache_get_tex(&c, &t, r2, sizeof r2);
    if (!b) { failures++; printf("FAIL block-linear 2-level rejected: %s\n", r2); }
    else if (b->levels != 2) { failures++; printf("FAIL block-linear levels=%u\n", b->levels); }

    // ---- 3. 3D ----
    uint8_t storage3d[4096] = {0};
    t.d.target = 2; t.d.depth = 2; t.d.levels = 1; t.mem = storage3d;
    nvn_texdesc ld3 = t.d; ld3.depth = 2;
    (void)nvn_swizzle(&ld3, 0, 0, green, 8, storage3d);
    char r3[160] = "";
    struct nvn_vk_tex *c3 = nvn_vk_texcache_get_tex(&c, &t, r3, sizeof r3);
    if (!c3) { failures++; printf("FAIL 3D rejected: %s\n", r3); }
    else if (c3->depth != 2) { failures++; printf("FAIL 3D depth=%u\n", c3->depth); }
    else if (c3->views_cap < (int)c3->depth + 1) {
        failures++; printf("FAIL 3D view table cap=%d (want >= depth+1=%u)\n", c3->views_cap, c3->depth + 1);
    }
    else {
        // 3D 视图层号 = 深度切片：单切片附件必须是可挂 framebuffer 的 2D 视图；
        // 越界（slice 2 of depth 2）仍准确拒绝，不钳位。
        view_t v3; memset(&v3, 0, sizeof v3);
        v3.set_layers = 1; v3.min_layer = 1; v3.nlayers = 1;
        char r3a[192] = ""; VkFormat f3a = VK_FORMAT_UNDEFINED;
        VkImageView a3 = nvn_vk_texcache_attachment_view(&c, c3, &v3, &f3a, r3a, sizeof r3a);
        if (!a3) { failures++; printf("FAIL 3D slice-1 attachment view: %s\n", r3a); }
        v3.min_layer = 2;
        char r3b[192] = "";
        VkImageView b3 = nvn_vk_texcache_attachment_view(&c, c3, &v3, &f3a, r3b, sizeof r3b);
        if (b3 || !strstr(r3b, "layer 2+1 of 2")) {
            failures++; printf("FAIL 3D slice out-of-range: view=%p why=%s\n", (void *)b3, r3b);
        }
        if (a3 && f3a != nvn_vk_format((uint32_t)NVN_FORMAT_RGBA8)) { failures++; printf("FAIL 3D slice attachment format=%d\n", (int)f3a); }
    }

    // ---- 4. CUBEMAP(8)：6 面独立颜色，GPU 逐面读回 ----
    tex_t cube; memset(&cube, 0, sizeof cube);
    cube.magic = 0x54584554; cube.d.target = 8; cube.d.format = NVN_FORMAT_RGBA8;
    cube.d.width = 4; cube.d.height = 4; cube.d.depth = 1; cube.d.levels = 1; cube.serial = 101;
    uint8_t exp_cube[64 * 4];
    cube.mem = make_storage(&cube, 6, exp_cube);
    char r4[192] = "";
    uint32_t cube_layers = 0; int cube_view = -1;
    struct nvn_vk_tex *cb = cube.mem ? nvn_vk_texcache_get_tex(&c, &cube, r4, sizeof r4) : NULL;
    if (!cb) { failures++; printf("FAIL cubemap(8) rejected: %s\n", cube.mem ? r4 : "storage alloc"); }
    else {
        cube_layers = cb->layers; cube_view = (int)cb->view_type;
        if (cb->view_type != VK_IMAGE_VIEW_TYPE_CUBE) { failures++; printf("FAIL cubemap view type=%d (want CUBE=%d)\n", (int)cb->view_type, (int)VK_IMAGE_VIEW_TYPE_CUBE); }
        if (cb->layers != 6) { failures++; printf("FAIL cubemap layers=%u\n", cb->layers); }
        for (uint32_t f = 0; f < 6; f++) {
            uint8_t got[64];
            if (read_layer(&d, cb->image, f, 4, 4, got, sizeof got)) { failures++; printf("FAIL cubemap face %u readback\n", f); break; }
            if (memcmp(got, exp_cube + f * 4, 4)) {
                failures++;
                printf("FAIL cubemap face %u got=%02x%02x%02x%02x want=%02x%02x%02x%02x\n", f,
                       got[0], got[1], got[2], got[3],
                       exp_cube[f*4+0], exp_cube[f*4+1], exp_cube[f*4+2], exp_cube[f*4+3]);
            }
        }
    }
    free(cube.mem);

    // ---- 5. CUBEMAP_ARRAY(9)：12 个层-面 ----
    tex_t ca; memset(&ca, 0, sizeof ca);
    ca.magic = 0x54584554; ca.d.target = 9; ca.d.format = NVN_FORMAT_RGBA8;
    ca.d.width = 4; ca.d.height = 4; ca.d.depth = 12; ca.d.levels = 1; ca.serial = 102;
    uint8_t exp_ca[64 * 4];
    ca.mem = make_storage(&ca, 12, exp_ca);
    char r5[192] = "";
    uint32_t ca_layers = 0; int ca_view = -1;
    struct nvn_vk_tex *cba = ca.mem ? nvn_vk_texcache_get_tex(&c, &ca, r5, sizeof r5) : NULL;
    if (!cba) { failures++; printf("FAIL cubemap-array(9) rejected: %s\n", ca.mem ? r5 : "storage alloc"); }
    else {
        ca_layers = cba->layers; ca_view = (int)cba->view_type;
        if (cba->view_type != VK_IMAGE_VIEW_TYPE_CUBE_ARRAY) { failures++; printf("FAIL cube-array view type=%d (want %d)\n", (int)cba->view_type, (int)VK_IMAGE_VIEW_TYPE_CUBE_ARRAY); }
        if (cba->layers != 12) { failures++; printf("FAIL cube-array layers=%u\n", cba->layers); }
        uint32_t probe[3] = {0, 6, 11};
        for (int k = 0; k < 3; k++) {
            uint8_t got[64]; uint32_t f = probe[k];
            if (read_layer(&d, cba->image, f, 4, 4, got, sizeof got)) { failures++; printf("FAIL cube-array layer %u readback\n", f); break; }
            if (memcmp(got, exp_ca + f * 4, 4)) {
                failures++;
                printf("FAIL cube-array layer %u got=%02x%02x%02x%02x want=%02x%02x%02x%02x\n", f,
                       got[0], got[1], got[2], got[3],
                       exp_ca[f*4+0], exp_ca[f*4+1], exp_ca[f*4+2], exp_ca[f*4+3]);
            }
        }
    }
    free(ca.mem);

    // ---- 6. 真实的 2D_MULTISAMPLE(5) / 2D_MULTISAMPLE_ARRAY(6)：明确拒绝，原因必须说多采样 ----
    uint8_t ms_storage[4096] = {0};
    tex_t ms; memset(&ms, 0, sizeof ms);
    ms.magic = 0x54584554; ms.d.format = NVN_FORMAT_RGBA8; ms.d.width = 4; ms.d.height = 4; ms.d.levels = 1;
    ms.mem = ms_storage; ms.serial = 103;
    for (int target = 5; target <= 6; target++) {
        char r[192] = "";
        ms.d.target = target; ms.d.samples = 4;
        struct nvn_vk_tex *got = nvn_vk_texcache_get_tex(&c, &ms, r, sizeof r);
        if (got) { failures++; printf("FAIL target %d (multisample) was created instead of rejected\n", target); }
        else if (!strstr(r, "multisampl")) { failures++; printf("FAIL target %d rejected with a wrong reason: %s\n", target, r); }
        else printf("INFO target %d: rejected with %s\n", target, r);
    }

    // 槽位会被后续纹理复用（同一个 CPU 地址），所以打印检查当时记录的真实值，而不是事后解引用。
    printf("linear=%p block=%p 3d=%p cube=%p layers=%u view=%d cube-array=%p layers=%u view=%d\n",
           (void *)a, (void *)b, (void *)c3, (void *)cb, cube_layers, cube_view,
           (void *)cba, ca_layers, ca_view);
    // ---- 9. 注册视图的消费：默认整幅复用、mip/层子视图独立且可复用、越界/跨类格式明确失败 ----
    {
        tex_t vt; memset(&vt, 0, sizeof vt);
        vt.magic = 0x54584554; vt.d.target = 4; vt.d.format = NVN_FORMAT_RGBA8;
        vt.d.width = 4; vt.d.height = 4; vt.d.depth = 2; vt.d.levels = 2; vt.serial = 301;
        static uint8_t vstorage[16384];
        memset(vstorage, 0, sizeof vstorage);
        uint8_t vpx[64]; fill_face(vpx, 0, 255, 0, 255);   // fill_face 填 16 像素 = 64 B
        vt.mem = vstorage;
        for (int lv = 0; lv < 2; lv++)
            for (int ly = 0; ly < 2; ly++) (void)nvn_swizzle(&vt.d, lv, ly, vpx, 8, vstorage);
        char rv[192] = "";
        struct nvn_vk_tex *tv = nvn_vk_texcache_get_tex(&c, &vt, rv, sizeof rv);
        if (!tv) { failures++; printf("FAIL view-chain texture: %s\n", rv); }
        else if (tv->layers != 2 || tv->levels != 2) { failures++; printf("FAIL view-chain dims levels=%u layers=%u\n", tv->levels, tv->layers); }
        else {
            int vf = 0;
            if (nvn_vk_texcache_view(&c, tv, NULL, rv, sizeof rv) != tv->view) { vf++; printf("FAIL view-chain default view not reused\n"); }
            view_t v; memset(&v, 0, sizeof v);
            v.set_levels = 1; v.base_level = 1; v.nlevels = 1;
            v.set_layers = 1; v.min_layer = 1; v.nlayers = 1;
            VkImageView v1 = nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv);
            VkImageView v2 = nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv);
            if (!v1 || v1 == tv->view) { vf++; printf("FAIL view-chain subresource view: %s\n", rv); }
            else if (v1 != v2) { vf++; printf("FAIL view-chain identical view request not reused\n"); }
            v.min_layer = 0;
            VkImageView v3 = nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv);
            if (!v3 || v3 == v1) { vf++; printf("FAIL view-chain different layer range got the same view\n"); }
            memset(&v, 0, sizeof v); v.set_levels = 1; v.base_level = 3; v.nlevels = 1;
            if (nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv)) { vf++; printf("FAIL view-chain out-of-range mip accepted\n"); }
            memset(&v, 0, sizeof v); v.set_format = 1; v.format = NVN_FORMAT_RGBA8_SRGB;
            if (!nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv)) { vf++; printf("FAIL view-chain RGBA8->sRGB view rejected: %s\n", rv); }
            memset(&v, 0, sizeof v); v.set_format = 1; v.format = NVN_FORMAT_RGBA32F;
            if (nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv)) { vf++; printf("FAIL view-chain cross-class format override accepted\n"); }
            memset(&v, 0, sizeof v); v.set_target = 1; v.target = 2;   // 3D 视图
            v.set_levels = 1; v.base_level = 0; v.nlevels = 1;
            if (!nvn_vk_texcache_view(&c, tv, &v, rv, sizeof rv)) { vf++; printf("FAIL view-chain target override rejected: %s\n", rv); }
            failures += vf;
            if (!vf) printf("INFO view-chain: default reused, subresource views distinct+reused, out-of-range/cross-class rejected\n");
        }
    }

    // ---- 10. F0.5 上传退休：正常上传逐项回收；提交后完成未知时 staging/CB/fence/image 全部保留，
    // 不能返回可采样条目；未提交失败则全部回收。 ----
    {
        static uint8_t up_storage[4096];
        tex_t ut;
        memset(&ut, 0, sizeof ut);
        ut.magic = 0x54584554; ut.d.target = 1; ut.d.format = NVN_FORMAT_RGBA8;
        ut.d.width = 2; ut.d.height = 2; ut.d.depth = 1; ut.d.levels = 1; ut.mem = up_storage; ut.serial = 401;
        char ur[192] = "";
        struct nvn_vk_tex_upload_stats u0, u1;

        nvn_vk_texcache_upload_stats(&u0);
        struct nvn_vk_tex *ok = nvn_vk_texcache_get_tex(&c, &ut, ur, sizeof ur);
        nvn_vk_texcache_upload_stats(&u1);
        if (!ok) {
            failures++; printf("FAIL upload-accounting normal create: %s\n", ur);
        } else if (u1.uncompleted != u0.uncompleted ||
                   u1.commands_freed - u0.commands_freed != u1.commands_created - u0.commands_created ||
                   u1.fences_freed - u0.fences_freed != u1.fences_created - u0.fences_created ||
                   u1.staging_freed - u0.staging_freed != u1.staging_created - u0.staging_created) {
            failures++; printf("FAIL upload-accounting: cmd %llu/%llu fence %llu/%llu staging %llu/%llu\n",
                              (unsigned long long)(u1.commands_created - u0.commands_created),
                              (unsigned long long)(u1.commands_freed - u0.commands_freed),
                              (unsigned long long)(u1.fences_created - u0.fences_created),
                              (unsigned long long)(u1.fences_freed - u0.fences_freed),
                              (unsigned long long)(u1.staging_created - u0.staging_created),
                              (unsigned long long)(u1.staging_freed - u0.staging_freed));
        } else {
            printf("INFO upload-accounting: staging=%llu cmd=%llu fence=%llu reclaimed once\n",
                   (unsigned long long)(u1.staging_created - u0.staging_created),
                   (unsigned long long)(u1.commands_created - u0.commands_created),
                   (unsigned long long)(u1.fences_created - u0.fences_created));
        }

        // 完成未知：不能返回“可采样”的条目，对象全部保留。
        ut.mem = up_storage; ut.serial = 402;
        nvn_vk_texcache_upload_stats(&u0);
        nvn_vk_texcache_set_upload_fault(1);
        struct nvn_vk_tex *bad = nvn_vk_texcache_get_tex(&c, &ut, ur, sizeof ur);
        nvn_vk_texcache_set_upload_fault(0);
        nvn_vk_texcache_upload_stats(&u1);
        if (bad) {
            failures++; printf("FAIL upload-incomplete returned a sampleable entry\n");
        } else if (u1.uncompleted - u0.uncompleted != 1 || u1.retained_entries - u0.retained_entries < 1 ||
                   u1.images_retained - u0.images_retained != 1 ||
                   u1.staging_freed != u0.staging_freed || u1.commands_freed != u0.commands_freed ||
                   u1.fences_freed != u0.fences_freed) {
            failures++; printf("FAIL upload-incomplete retention: uncompleted=%llu retained=%u->%u images=%llu "
                              "staging_freed=%llu->%llu cmd_freed=%llu->%llu\n",
                              (unsigned long long)(u1.uncompleted - u0.uncompleted), u0.retained_entries, u1.retained_entries,
                              (unsigned long long)(u1.images_retained - u0.images_retained),
                              (unsigned long long)u0.staging_freed, (unsigned long long)u1.staging_freed,
                              (unsigned long long)u0.commands_freed, (unsigned long long)u1.commands_freed);
        } else {
            printf("INFO upload-incomplete: rejected (no sampleable entry), staging/CB/fence/image retained\n");
        }

        // 未提交失败：对象全部回收，且不登记图像。
        ut.serial = 403;
        nvn_vk_texcache_upload_stats(&u0);
        nvn_vk_texcache_set_upload_fault(2);
        struct nvn_vk_tex *bad2 = nvn_vk_texcache_get_tex(&c, &ut, ur, sizeof ur);
        nvn_vk_texcache_set_upload_fault(0);
        nvn_vk_texcache_upload_stats(&u1);
        if (bad2) {
            failures++; printf("FAIL upload-unsubmitted returned an entry\n");
        } else if (u1.unsubmitted - u0.unsubmitted != 1 || u1.retained_entries != u0.retained_entries ||
                   u1.staging_freed - u0.staging_freed != 1 || u1.commands_freed - u0.commands_freed != 1 ||
                   u1.fences_freed - u0.fences_freed != 1 || u1.images_retained != u0.images_retained) {
            failures++; printf("FAIL upload-unsubmitted accounting: unsub=%llu retained=%u->%u staging=%llu/%llu\n",
                              (unsigned long long)(u1.unsubmitted - u0.unsubmitted), u0.retained_entries, u1.retained_entries,
                              (unsigned long long)(u1.staging_created - u0.staging_created),
                              (unsigned long long)(u1.staging_freed - u0.staging_freed));
        } else {
            printf("INFO upload-unsubmitted: staging/CB/fence reclaimed, no image retained\n");
        }

        // 注入后正常上传仍可用（账本不阻塞新条目）。
        ut.serial = 404;
        char ur2[192] = "";
        struct nvn_vk_tex *again = nvn_vk_texcache_get_tex(&c, &ut, ur2, sizeof ur2);
        if (!again) { failures++; printf("FAIL upload recovery after injected failures: %s\n", ur2); }
        else printf("INFO upload recovery: new entry created after injected failures\n");
        (void)ok;
    }

    printf("nvn-vk-texcache-tex: %s\n", failures ? "FAIL" : "ok");
    nvn_vk_texcache_destroy(&c); s2a_vk_device_destroy(&d, 0);
    return failures ? 1 : 0;
}
