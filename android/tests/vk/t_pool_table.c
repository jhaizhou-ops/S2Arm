// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Exercise the real Vulkan backend with real objects and the validation layer.
// The original fixture supplies its platform hooks and device wrappers.
#define main pool_existing_suite_main
#include "t_backend_vk.c"
#undef main
extern int nvn_gpu_vk_test_pool_live(nvn_gpu_pool_table);
extern int nvn_gpu_vk_test_pool_refs(nvn_gpu_pool_table);
extern void nvn_gpu_vk_test_pool_hook(void (*)(nvn_gpu_pool_table));
extern uint64_t nvn_gpu_vk_test_pool_sets(int which);   // 整池组读数（只增不清零）：0 要的组数 1 备忘命中 2 新建 3 因反馈拷贝在用绕开备忘 4 整池写入的描述符项数
extern void nvn_gpu_vk_test_pool_memo_refresh(void);    // 改了 nvk_pool_memo 的读值后，让后端下一笔绑定就重读
static void release_in_bind(nvn_gpu_pool_table t) { nvn_gpu_pool_release(t); }
// 让真 GPU 停在「已提交、围栏未到」：被测那次提交先扣在主机侧，放行时才真正交给驱动。
// 不用「命令缓冲开头等事件、主机再 vkSetEvent」——命令缓冲在途时主机设它正在等的事件违反
// VUID-vkSetEvent-event-09543（新版校验层报）；1.1 设备又没有时间线信号量可「先等后发」。
// 扣住期间后端看到的就是一个真实未发的围栏（vkGetFenceStatus = VK_NOT_READY），与在途等价。
#define POOL_HOLD_MAX 4
static int pool_test_hold;       // 置 1：下一次提交扣住
static int pool_test_held;       // 已扣住、未放行（等待线程也读，原子访问）
static VkFence pool_test_fence;
static VkQueue pool_hold_queue;
static uint32_t pool_hold_count;
static VkSubmitInfo pool_hold_submits[POOL_HOLD_MAX];
static VkCommandBuffer pool_hold_cbs[POOL_HOLD_MAX][8];
static VkSemaphore pool_hold_waits[POOL_HOLD_MAX][8], pool_hold_signals[POOL_HOLD_MAX][8];
static VkPipelineStageFlags pool_hold_stages[POOL_HOLD_MAX][8];
VKAPI_ATTR VkResult VKAPI_CALL __real_vkBeginCommandBuffer(VkCommandBuffer, const VkCommandBufferBeginInfo *);
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkBeginCommandBuffer(VkCommandBuffer cb, const VkCommandBufferBeginInfo *bi) {
    return __real_vkBeginCommandBuffer(cb, bi);
}
VKAPI_ATTR VkResult VKAPI_CALL __real_vkQueueSubmit(VkQueue, uint32_t, const VkSubmitInfo *, VkFence);
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkQueueSubmit(VkQueue q, uint32_t count, const VkSubmitInfo *submits, VkFence fence) {
    if (!pool_test_hold) return __real_vkQueueSubmit(q, count, submits, fence);
    pool_test_hold = 0;
    if (count > POOL_HOLD_MAX) return VK_ERROR_OUT_OF_HOST_MEMORY;
    for (uint32_t i = 0; i < count; i++) {
        const VkSubmitInfo *si = &submits[i];
        if (si->pNext || si->commandBufferCount > 8 || si->waitSemaphoreCount > 8 || si->signalSemaphoreCount > 8)
            return VK_ERROR_OUT_OF_HOST_MEMORY;   // 扣不住的形状：让用例在 commit 处红，不静默放过
        pool_hold_submits[i] = *si;
        memcpy(pool_hold_cbs[i], si->pCommandBuffers, si->commandBufferCount * sizeof(VkCommandBuffer));
        memcpy(pool_hold_waits[i], si->pWaitSemaphores, si->waitSemaphoreCount * sizeof(VkSemaphore));
        memcpy(pool_hold_stages[i], si->pWaitDstStageMask, si->waitSemaphoreCount * sizeof(VkPipelineStageFlags));
        memcpy(pool_hold_signals[i], si->pSignalSemaphores, si->signalSemaphoreCount * sizeof(VkSemaphore));
        pool_hold_submits[i].pCommandBuffers = pool_hold_cbs[i];
        pool_hold_submits[i].pWaitSemaphores = pool_hold_waits[i];
        pool_hold_submits[i].pWaitDstStageMask = pool_hold_stages[i];
        pool_hold_submits[i].pSignalSemaphores = pool_hold_signals[i];
    }
    pool_hold_queue = q; pool_hold_count = count; pool_test_fence = fence;
    __atomic_store_n(&pool_test_held, 1, __ATOMIC_RELEASE);
    return VK_SUCCESS;
}
static int pool_fence_held(VkFence f) {
    return __atomic_load_n(&pool_test_held, __ATOMIC_ACQUIRE) && f == pool_test_fence;
}
static VkResult pool_hold_release(void) {
    if (!__atomic_load_n(&pool_test_held, __ATOMIC_ACQUIRE)) return VK_ERROR_UNKNOWN;
    // 先真正提交、再撤「扣住」：等待线程只在提交返回之后才会进驱动等这个围栏
    VkResult r = __real_vkQueueSubmit(pool_hold_queue, pool_hold_count, pool_hold_submits, pool_test_fence);
    __atomic_store_n(&pool_test_held, 0, __ATOMIC_RELEASE);
    return r;
}

// 整池组备忘用例：同一段里连画两笔（两笔的差别见 mode），提交、等完，返回这一段的读数差，并核输出缓冲里的像素（来自第二笔用的那一组描述符）。
//   mode 0：两笔之间只把同样的池快照再绑一遍（回放每笔都这么做）→ 备忘开着时第二笔直接用第一笔写好的组；
//   mode 1：第二笔前把贴图池换成另一张快照（指针不同、第 64 项内容不同）→ 必须新建 + 重写，第二笔读到的是新快照；
//   mode 2：第二笔前把普通绑定（输出缓冲）换成另一块 → 必须新建，两块输出各是各自那一笔的像素。
// d 返回读数差：0 要的组数 1 备忘命中 2 新建 3 绕开备忘 4 整池写入的描述符项数。
static uint64_t g_pool_memo_ticket = 100;
static void pool_memo_seg(nvn_gpu_pipe pipe, int mode, nvn_gpu_buf out, nvn_gpu_buf out_b, nvn_gpu_pool_table t0, nvn_gpu_pool_table t1,
                          nvn_gpu_pool_table smp, uint64_t d[5], const float *want, const float *want_b, const char *what) {
    nvn_gpu_err err = {0}; uint64_t s0[5];
    for (int i = 0; i < 5; i++) s0[i] = nvn_gpu_vk_test_pool_sets(i);
    nvn_gpu_cmd c = begin_cmd(); nvn_gpu_set_pipe(c, pipe);
    nvn_gpu_binding b = {.ent=2, .cls=NVN_GPU_RES_SSBO}; b.u.b.buf = out; b.u.b.len = 7 * 16;
    nvn_gpu_bind(c, NVN_GPU_SH_CS, &b, 1);
    nvn_gpu_rc r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 0, t0, &err);
    CHECK(nvn_gpu_ok(r), "%s: pool image bind: rc=%d %s", what, r.code, err.why);
    r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 1, smp, &err);
    CHECK(nvn_gpu_ok(r), "%s: pool sampler bind: rc=%d %s", what, r.code, err.why);
    nvn_gpu_dispatch(c, pipe, 7, 1, 1, NULL, 0);
    if (mode == 0) {
        r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 0, t0, &err); CHECK(nvn_gpu_ok(r), "%s: rebind image: rc=%d %s", what, r.code, err.why);
        r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 1, smp, &err); CHECK(nvn_gpu_ok(r), "%s: rebind sampler: rc=%d %s", what, r.code, err.why);
    } else if (mode == 1) {
        r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 0, t1, &err); CHECK(nvn_gpu_ok(r), "%s: replace image table: rc=%d %s", what, r.code, err.why);
    } else {
        b.u.b.buf = out_b; nvn_gpu_bind(c, NVN_GPU_SH_CS, &b, 1);
    }
    nvn_gpu_dispatch(c, pipe, 7, 1, 1, NULL, 0);
    const uint64_t ticket = g_pool_memo_ticket++;
    r = nvn_gpu_cmd_commit(c, ticket, on_done, NULL, &err);
    CHECK(nvn_gpu_ok(r), "%s: commit: rc=%d %s", what, r.code, err.why);
    if (nvn_gpu_ok(r)) {
        r = nvn_gpu_fence_wait(ticket, 5000000000ull, &err);
        CHECK(nvn_gpu_ok(r), "%s: fence: rc=%d %s", what, r.code, err.why);
        const float *got = (const float *)buf_cpu(out), *got_b = out_b ? (const float *)buf_cpu(out_b) : NULL;
        for (unsigned i = 0; i < 28; i++) {
            CHECK(got[i] >= want[i] - .01f && got[i] <= want[i] + .01f, "%s output[%u]: expected %.2f got %.2f", what, i, want[i], got[i]);
            if (mode == 2 && got_b) CHECK(got_b[i] >= want_b[i] - .01f && got_b[i] <= want_b[i] + .01f, "%s second output[%u]: expected %.2f got %.2f", what, i, want_b[i], got_b[i]);
        }
    }
    for (int i = 0; i < 5; i++) d[i] = nvn_gpu_vk_test_pool_sets(i) - s0[i];
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 2;
    char why[256] = {0}; nvn_gpu_err err = {0}; nvn_gpu_pool_table retired_old = NULL;
    if (s2a_vk_device_create(&g_dev, why, sizeof why)) {
        fprintf(stderr, "pool test device unavailable: %s\n", why); return 2;
    }
    printf("device: %s\n", g_dev.properties.deviceName);
    if (!g_dev.descriptor_indexing_enabled ||
        g_dev.properties.limits.maxPerStageDescriptorSampledImages < 66 ||
        g_dev.properties.limits.maxPerStageDescriptorSamplers < 66 ||
        g_dev.properties.limits.maxDescriptorSetSampledImages < 66 ||
        g_dev.properties.limits.maxDescriptorSetSamplers < 66) {
        fprintf(stderr, "pool test requires actual descriptor indexing and 66 descriptors per kind\n");
        s2a_vk_device_destroy(&g_dev, 0); return 2;
    }
    memset(&g_desc, 0, sizeof g_desc); g_desc.host_device = &g_dev;
    if (!open_backend()) { s2a_vk_device_destroy(&g_dev, 0); return 2; }
    nvn_gpu_tex tex = make_tex(2, 1, NVN_FORMAT_RGBA8, NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_CPU_UPLOAD);
    nvn_gpu_tex blue = make_tex(1, 1, NVN_FORMAT_RGBA8, NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_CPU_UPLOAD);
    nvn_gpu_tex dummy = make_tex(1, 1, NVN_FORMAT_RGBA8, NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_CPU_UPLOAD);
    nvn_gpu_tex wrong = make_tex_target(1, 1, 2, NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGBA8, NVN_GPU_TEX_SAMPLED);
    nvn_gpu_tex integer = make_tex(1, 1, NVN_FORMAT_RGBA8UI, NVN_GPU_TEX_SAMPLED);
    nvn_gpu_view view = tex ? make_view(tex) : NULL, bv = blue ? make_view(blue) : NULL;
    nvn_gpu_view dv = dummy ? make_view(dummy) : NULL, wv = wrong ? make_view(wrong) : NULL;
    nvn_gpu_view iv = integer ? make_view(integer) : NULL;
    samp_par sp = {0}; sp.ws = sp.wt = sp.wr = NVN_WRAP_MODE_CLAMP_TO_EDGE;
    nvn_gpu_samp samp = NULL, linear = NULL;
    nvn_gpu_rc r = nvn_gpu_samp_create(&sp, &samp, &err);
    sp.minf = NVN_MIN_FILTER_LINEAR; sp.magf = NVN_MAG_FILTER_LINEAR;
    nvn_gpu_rc r2 = nvn_gpu_samp_create(&sp, &linear, &err);
    if (!view || !bv || !dv || !wv || !iv || !nvn_gpu_ok(r) || !nvn_gpu_ok(r2) || !samp || !linear) { fprintf(stderr, "pool fixture resource creation failed\n"); g_fail++; goto done; }
    nvn_gpu_pool_item items[65] = {{0}};
    nvn_gpu_pool_table table = NULL;
    nvn_gpu_pool_desc desc = {.kind = NVN_GPU_POOL_IMAGE, .count = 65, .items = items};
    desc.dummy.view = dv;
    items[0].state = NVN_GPU_POOL_READY; items[0].resource.view = view;
    items[3].state = NVN_GPU_POOL_READY; items[3].resource.view = wv;
    items[4].state = NVN_GPU_POOL_READY; items[4].resource.view = iv;
    items[64].state = NVN_GPU_POOL_READY; items[64].resource.view = bv;
    r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(nvn_gpu_ok(r) && table, "pool image 65: expected snapshot, got rc=%d why=%s", r.code, err.why);
    nvn_gpu_pool_table image_table = table;
    memset(items, 0, sizeof items); items[0].state = NVN_GPU_POOL_READY; items[0].resource.samp = samp; items[64].state = NVN_GPU_POOL_READY; items[64].resource.samp = linear;
    desc.kind = NVN_GPU_POOL_SAMPLER; desc.dummy.samp = samp; table = NULL;
    r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(nvn_gpu_ok(r) && table, "pool sampler 65: expected snapshot, got rc=%d why=%s", r.code, err.why);
    nvn_gpu_pool_table sampler_table = table;
    if (image_table && sampler_table) {
        // Seven independently calculated reads: distinct IDs, nearest vs linear,
        // empty slot, wrong image dimension, and out-of-range sentinel.
        nvn_gpu_layout_ent ents[3] = {0};
        ents[0] = (nvn_gpu_layout_ent){.set=0, .cls=NVN_GPU_RES_TEX, .access=NVN_GPU_ACC_R, .binding=0, .count=66, .stages=1u<<NVN_GPU_SH_CS};
        ents[1] = (nvn_gpu_layout_ent){.set=0, .cls=NVN_GPU_RES_SAMP, .access=NVN_GPU_ACC_R, .binding=1, .count=66, .stages=1u<<NVN_GPU_SH_CS};
        ents[2] = (nvn_gpu_layout_ent){.set=0, .cls=NVN_GPU_RES_SSBO, .access=NVN_GPU_ACC_W, .binding=2, .count=1, .stages=1u<<NVN_GPU_SH_CS};
        ents[0].src_kind = NVN_RB_TEXP; ents[1].src_kind = NVN_RB_SAMPP;
        nvn_gpu_layout layout = {.ent=ents, .nent=3}; nvn_gpu_shader sh = NULL;
        nvn_gpu_layout_ent small[3]; memcpy(small, ents, sizeof small); small[0].count = small[1].count = 64;
        nvn_gpu_layout small_layout = {.ent=small, .nent=3};
        nvn_gpu_shader small_sh = load_one_shader(argv[1], "pool_table_small.comp", NVN_GPU_SH_CS, &small_layout);
        if (small_sh) {
            uint32_t saved = g_dev.properties.limits.maxPerStageResources;
            g_dev.properties.limits.maxPerStageResources = 64;
            nvn_gpu_stage_desc small_cs = {0}; small_cs.sh = small_sh; nvn_gpu_pipe small_pipe = NULL;
            memset(&err, 0, sizeof err);
            nvn_gpu_rc small_rc = nvn_gpu_cpipe_get(&small_cs, NVN_GPU_PIPE_SYNC, &small_pipe, &err);
            CHECK(small_rc.code == NVN_GPU_E_UNSUPPORTED && !small_pipe && strstr(err.why, "maxPerStageResources"),
                  "small pool pipeline aggregate 64 images + 1 SSBO must reject: rc=%d %s", small_rc.code, err.why);
            g_dev.properties.limits.maxPerStageResources = saved;
            nvn_gpu_shader_release(small_sh);
        }
        nvn_gpu_pipe pipe = mk_cpipe(argv[1], "pool_table.comp", &layout, &sh);
        if (pipe && argc == 3 && !strcmp(argv[2], "race")) {
            nvn_gpu_pool_item race_items[65] = {{0}};
            nvn_gpu_pool_desc race_desc = {.kind=NVN_GPU_POOL_IMAGE, .count=65, .items=race_items}; race_desc.dummy.view = dv;
            nvn_gpu_pool_table race_table = NULL;
            r = nvn_gpu_pool_create(&race_desc, &race_table, &err);
            CHECK(nvn_gpu_ok(r) && race_table, "race fixture table create");
            if (race_table) {
                nvn_gpu_cmd race_cmd = begin_cmd(); nvn_gpu_set_pipe(race_cmd, pipe);
                nvn_gpu_vk_test_pool_hook(release_in_bind);
                r = nvn_gpu_pool_bind(race_cmd, NVN_GPU_SH_CS, 0, race_table, &err);
                CHECK(r.code == NVN_GPU_E_ARG, "release wins bind race: rc=%d %s", r.code, err.why);
                nvn_gpu_cmd_abort(race_cmd);
            }
        }
        if (pipe) {
            // The image table needs 66 resources, but the same stage also has one SSBO.
            // Samplers do not count against maxPerStageResources (Vulkan limits).
            uint32_t saved = g_dev.properties.limits.maxPerStageResources;
            g_dev.properties.limits.maxPerStageResources = 66;
            // Use a fresh shader identity: the already-built pipe is valid in the real device's immutable
            // limits and is now cached; this synthetic lower limit must exercise an actual new build.
            nvn_gpu_shader over_sh = load_one_shader(argv[1], "pool_table.comp", NVN_GPU_SH_CS, &layout);
            CHECK(over_sh != NULL, "pipeline aggregate resources fresh shader");
            if (over_sh) {
                nvn_gpu_stage_desc over_cs = {0}; over_cs.sh = over_sh; nvn_gpu_pipe over_pipe = NULL;
                memset(&err, 0, sizeof err);
                nvn_gpu_rc over_rc = nvn_gpu_cpipe_get(&over_cs, NVN_GPU_PIPE_SYNC, &over_pipe, &err);
                CHECK(over_rc.code == NVN_GPU_E_UNSUPPORTED && !over_pipe && strstr(err.why, "maxPerStageResources"),
                      "pipeline aggregate resources must reject before Vulkan pipeline creation: rc=%d %s", over_rc.code, err.why);
                nvn_gpu_shader_release(over_sh);
            }
            nvn_gpu_cmd probe = begin_cmd(); nvn_gpu_set_pipe(probe, pipe);
            memset(&err, 0, sizeof err);
            nvn_gpu_rc limit_rc = nvn_gpu_pool_bind(probe, NVN_GPU_SH_CS, 0, image_table, &err);
            CHECK(limit_rc.code == NVN_GPU_E_UNSUPPORTED && strstr(err.why, "maxPerStageResources"),
                  "aggregate stage resources 66 images + 1 SSBO exceed 66: rc=%d %s", limit_rc.code, err.why);
            nvn_gpu_cmd_abort(probe); g_dev.properties.limits.maxPerStageResources = saved;
        }
        uint32_t output_initial[28]; for (unsigned i = 0; i < 28; i++) output_initial[i] = 0x7fc00000u;
        nvn_gpu_buf output = make_buf(sizeof output_initial, NVN_GPU_MEM_SHARED, output_initial);
        nvn_gpu_buf output2 = make_buf(sizeof output_initial, NVN_GPU_MEM_SHARED, output_initial);
        nvn_gpu_pool_item replacement[65] = {{0}};
        replacement[0].state = NVN_GPU_POOL_READY; replacement[0].resource.view = view;
        replacement[3].state = NVN_GPU_POOL_READY; replacement[3].resource.view = wv;
        replacement[4].state = NVN_GPU_POOL_READY; replacement[4].resource.view = iv;
        replacement[64].state = NVN_GPU_POOL_READY; replacement[64].resource.view = view;
        nvn_gpu_pool_desc rd = {.kind=NVN_GPU_POOL_IMAGE, .count=65, .items=replacement}; rd.dummy.view = dv;
        nvn_gpu_pool_table newer = NULL; r = nvn_gpu_pool_create(&rd, &newer, &err);
        CHECK(nvn_gpu_ok(r) && newer, "replacement pool create: %d %s", r.code, err.why);
        if (pipe && output && output2 && newer) {
            pool_test_fence = VK_NULL_HANDLE; g_fence_held = pool_fence_held;
            nvn_gpu_cmd c = begin_cmd();
            const uint8_t zero[4] = {0}, gradient[8] = {255,0,0,255, 0,255,0,255}, blue_px[4] = {0,0,255,255};
            nvn_gpu_tex_upload(c, dummy, 0, 0, NULL, zero, 4, 4);
            nvn_gpu_tex_upload(c, tex, 0, 0, NULL, gradient, 8, 8);
            nvn_gpu_tex_upload(c, blue, 0, 0, NULL, blue_px, 4, 4);
            nvn_gpu_set_pipe(c, pipe);
            nvn_gpu_binding b = {.ent=2, .cls=NVN_GPU_RES_SSBO}; b.u.b.buf=output; b.u.b.len=7*16;
            nvn_gpu_bind(c, NVN_GPU_SH_CS, &b, 1);
            r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 0, image_table, &err);
            CHECK(nvn_gpu_ok(r), "pool image bind: rc=%d %s", r.code, err.why);
            r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 1, sampler_table, &err);
            CHECK(nvn_gpu_ok(r), "pool sampler bind: rc=%d %s", r.code, err.why);
            int held = nvn_gpu_vk_test_pool_refs(image_table);
            CHECK(held > 0, "pool command must hold snapshot reference");
            if (!held) { nvn_gpu_cmd_abort(c); goto gpu_done; }
            nvn_gpu_dispatch(c, pipe, 7, 1, 1, NULL, 0);
            nvn_gpu_pool_table old = image_table; retired_old = old;
            nvn_gpu_pool_release(image_table); image_table = NULL;
            nvn_gpu_view_release(bv); bv = NULL; // only the old snapshot owns this image view now
            r = nvn_gpu_pool_bind(c, NVN_GPU_SH_CS, 0, newer, &err);
            CHECK(nvn_gpu_ok(r), "replacement pool bind: rc=%d %s", r.code, err.why);
            b.u.b.buf = output2; nvn_gpu_bind(c, NVN_GPU_SH_CS, &b, 1);
            nvn_gpu_dispatch(c, pipe, 7, 1, 1, NULL, 0);
            nvn_gpu_pool_release(newer); newer = NULL;
            nvn_gpu_pool_release(sampler_table); sampler_table = NULL;
            pool_test_hold = 1;
            r = nvn_gpu_cmd_commit(c, 1, on_done, NULL, &err);
            CHECK(pool_test_held, "pool dispatch submit was not held");
            CHECK(pool_test_fence && vkGetFenceStatus(g_dev.device, pool_test_fence) == VK_NOT_READY,
                  "real GPU fence must be unsignaled while the submit is held");
            CHECK(nvn_gpu_fence_done() < 1 && nvn_gpu_vk_test_pool_live(old), "released old table must survive before real fence completes");
            if (pool_test_held) { VkResult hr = pool_hold_release(); CHECK(hr == VK_SUCCESS, "release held submit: %d", hr); }
            CHECK(nvn_gpu_ok(r), "pool dispatch commit: rc=%d %s", r.code, err.why);
            if (nvn_gpu_ok(r)) {
                r = nvn_gpu_fence_wait(1, 5000000000ull, &err);
                CHECK(nvn_gpu_ok(r), "pool dispatch fence: rc=%d %s", r.code, err.why);
                const float expected[28] = {0,1,0,1, .5f,.5f,0,1, 0,0,1,1, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0};
                const float *got = (const float *)buf_cpu(output);
                for (unsigned i = 0; i < 28; i++)
                    CHECK(got[i] >= expected[i] - .01f && got[i] <= expected[i] + .01f,
                          "pool dispatch output[%u]: expected %.2f got %.2f", i, expected[i], got[i]);
                const float expected2[28] = {0,1,0,1, .5f,.5f,0,1, 0,1,0,1, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0};
                got = (const float *)buf_cpu(output2);
                for (unsigned i = 0; i < 28; i++)
                    CHECK(got[i] >= expected2[i] - .01f && got[i] <= expected2[i] + .01f,
                          "replacement output[%u]: expected %.2f got %.2f", i, expected2[i], got[i]);
            }
gpu_done:
            pool_test_hold = 0;
            if (pool_test_held) (void)pool_hold_release();   // 中途失败也要把扣住的提交交出去，围栏才会到
            g_fence_held = NULL;
        }
        // ---- 整池数组组备忘（nvk_pool_memo）：同一段里「布局 + 普通绑定 + 池快照」都相同的整池组只建一次、只写一次整张表 ----
        // 修前每一笔绘制 / 派发都新建一个只装它的描述符池、分一组、把整张表重写一遍；修后键相同的第二笔直接用第一笔写好的组。
        // 键里有池快照的指针和普通绑定：换了快照或换了输出缓冲，必须重新建 + 重写（读到的是各自的内容）。
        if (pipe && tex && blue && view && dv && samp && linear) {
            nvn_gpu_view bluev = make_view(blue);
            nvn_gpu_pool_item mi[65] = {{0}}, ms[65] = {{0}};
            nvn_gpu_pool_desc mid = {.kind=NVN_GPU_POOL_IMAGE, .count=65, .items=mi}, msd = {.kind=NVN_GPU_POOL_SAMPLER, .count=65, .items=ms};
            mid.dummy.view = dv; msd.dummy.samp = samp;
            mi[0].state = NVN_GPU_POOL_READY; mi[0].resource.view = view;
            mi[64].state = NVN_GPU_POOL_READY; mi[64].resource.view = bluev;
            ms[0].state = NVN_GPU_POOL_READY; ms[0].resource.samp = samp;
            ms[64].state = NVN_GPU_POOL_READY; ms[64].resource.samp = linear;
            nvn_gpu_pool_table tx = NULL, ty = NULL, ts = NULL;   // X：第 64 项是蓝；Y：第 64 项是渐变图（和 X 只差这一项）；ts：采样器表
            r = nvn_gpu_pool_create(&mid, &tx, &err); CHECK(nvn_gpu_ok(r) && tx, "pool memo table X create: rc=%d %s", r.code, err.why);
            mi[64].resource.view = view;
            r = nvn_gpu_pool_create(&mid, &ty, &err); CHECK(nvn_gpu_ok(r) && ty, "pool memo table Y create: rc=%d %s", r.code, err.why);
            r = nvn_gpu_pool_create(&msd, &ts, &err); CHECK(nvn_gpu_ok(r) && ts, "pool memo sampler table create: rc=%d %s", r.code, err.why);
            if (bluev) nvn_gpu_view_release(bluev);   // 表 X 自己持有一份
            nvn_gpu_buf mo[6]; for (int i = 0; i < 6; i++) mo[i] = make_buf(sizeof output_initial, NVN_GPU_MEM_SHARED, output_initial);   // 每段各用各的输出缓冲，前一段的像素不会遮住后一段的错
            const float want_x[28] = {0,1,0,1, .5f,.5f,0,1, 0,0,1,1, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0};
            const float want_y[28] = {0,1,0,1, .5f,.5f,0,1, 0,1,0,1, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0};
            uint64_t d[5];
            if (tx && ty && ts && mo[0] && mo[1] && mo[2] && mo[3] && mo[4] && mo[5]) {
#define POOL_MEMO_EXPECT(what, e0, e1, e2, e4) \
                CHECK(d[0] == (e0) && d[1] == (e1) && d[2] == (e2) && d[4] == (e4), \
                      what ": need/hit/made/elems expected %d/%d/%d/%d, got %llu/%llu/%llu/%llu", (e0), (e1), (e2), (e4), \
                      (unsigned long long)d[0], (unsigned long long)d[1], (unsigned long long)d[2], (unsigned long long)d[4])
                // 两笔之间只重绑同样的池快照：要 2 组、命中 1 组、新建 1 组，整池只写一次（66 张贴图 + 66 个采样器 = 132 项）
                pool_memo_seg(pipe, 0, mo[0], NULL, tx, NULL, ts, d, want_x, NULL, "pool memo same key");
                POOL_MEMO_EXPECT("pool memo same key", 2, 1, 1, 132);
                // 第二笔换了贴图池快照（只有第 64 项不同）：不得命中，必须读到新快照里的内容（输出第 2 个像素的蓝变绿）
                pool_memo_seg(pipe, 1, mo[1], NULL, tx, ty, ts, d, want_y, NULL, "pool memo table change");
                POOL_MEMO_EXPECT("pool memo table change", 2, 0, 2, 264);
                // 第二笔换了普通绑定（输出缓冲）：不得命中
                pool_memo_seg(pipe, 2, mo[2], mo[3], tx, NULL, ts, d, want_x, want_x, "pool memo binding change");
                POOL_MEMO_EXPECT("pool memo binding change", 2, 0, 2, 264);
                // 开关 nvk_pool_memo=0：回到每笔都新建 + 整池重写；再开回来恢复命中
                g_pool_memo_flag = 0; nvn_gpu_vk_test_pool_memo_refresh();
                pool_memo_seg(pipe, 0, mo[4], NULL, tx, NULL, ts, d, want_x, NULL, "pool memo off");
                POOL_MEMO_EXPECT("pool memo off", 2, 0, 2, 264);
                g_pool_memo_flag = -1; nvn_gpu_vk_test_pool_memo_refresh();
                pool_memo_seg(pipe, 0, mo[5], NULL, tx, NULL, ts, d, want_x, NULL, "pool memo back on");
                POOL_MEMO_EXPECT("pool memo back on", 2, 1, 1, 132);
#undef POOL_MEMO_EXPECT
            }
            g_pool_memo_flag = -1; nvn_gpu_vk_test_pool_memo_refresh();
            for (int i = 0; i < 6; i++) if (mo[i]) nvn_gpu_buf_release(mo[i], NULL, NULL);
            if (tx) nvn_gpu_pool_release(tx);
            if (ty) nvn_gpu_pool_release(ty);
            if (ts) nvn_gpu_pool_release(ts);
        }
        if (newer) nvn_gpu_pool_release(newer);
        if (output2) nvn_gpu_buf_release(output2, NULL, NULL);
        if (output) nvn_gpu_buf_release(output, NULL, NULL);
        if (sh) nvn_gpu_shader_release(sh);
    }
    if (image_table) nvn_gpu_pool_release(image_table);
    if (sampler_table) nvn_gpu_pool_release(sampler_table);
    int enabled = g_dev.descriptor_indexing_enabled; g_dev.descriptor_indexing_enabled = 0; table = NULL;
    memset(&err, 0, sizeof err); r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(r.code == NVN_GPU_E_UNSUPPORTED && !table && err.why[0], "pool missing feature: expected named unsupported, got rc=%d", r.code);
    g_dev.descriptor_indexing_enabled = enabled;
    if (table) { nvn_gpu_pool_release(table); table = NULL; }
    items[3].state = NVN_GPU_POOL_UNAVAILABLE; table = NULL; memset(&err, 0, sizeof err);
    r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(r.code == NVN_GPU_E_UNSUPPORTED && !table && strstr(err.why, "unavailable"),
          "registered unavailable resource must reject: rc=%d %s", r.code, err.why);
    if (table) { nvn_gpu_pool_release(table); table = NULL; }
    items[3].state = NVN_GPU_POOL_EMPTY;
    uint32_t saved_limit = g_dev.properties.limits.maxPerStageDescriptorSamplers;
    g_dev.properties.limits.maxPerStageDescriptorSamplers = 65;
    table = NULL; memset(&err, 0, sizeof err); r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(r.code == NVN_GPU_E_UNSUPPORTED && !table && strstr(err.why, "limit"),
          "65 plus sentinel exceeds reduced stage sampler limit: rc=%d %s", r.code, err.why);
    g_dev.properties.limits.maxPerStageDescriptorSamplers = saved_limit;
    if (table) { nvn_gpu_pool_release(table); table = NULL; }
    uint32_t saved_resources = g_dev.properties.limits.maxPerStageResources;
    g_dev.properties.limits.maxPerStageResources = 1;
    memset(&err, 0, sizeof err); r = nvn_gpu_pool_create(&desc, &table, &err);
    CHECK(nvn_gpu_ok(r) && table, "samplers must not count against maxPerStageResources: rc=%d %s", r.code, err.why);
    g_dev.properties.limits.maxPerStageResources = saved_resources;
    if (table) nvn_gpu_pool_release(table);
 done:
    if (linear) nvn_gpu_samp_release(linear);
    if (samp) nvn_gpu_samp_release(samp);
    if (iv) nvn_gpu_view_release(iv);
    if (wv) nvn_gpu_view_release(wv);
    if (dv) nvn_gpu_view_release(dv);
    if (bv) nvn_gpu_view_release(bv);
    if (view) nvn_gpu_view_release(view);
    if (integer) nvn_gpu_tex_release(integer);
    if (wrong) nvn_gpu_tex_release(wrong);
    if (dummy) nvn_gpu_tex_release(dummy);
    if (blue) nvn_gpu_tex_release(blue);
    if (tex) nvn_gpu_tex_release(tex);
    r = nvn_gpu_close(5000000000ull, &err);
    CHECK(nvn_gpu_ok(r), "pool close: rc=%d why=%s", r.code, err.why);
    if (retired_old) CHECK(!nvn_gpu_vk_test_pool_live(retired_old), "old table must retire by close");
    s2a_vk_device_destroy(&g_dev, 0);
    printf("pool table initial behavior failures=%d\n", g_fail);
    return g_fail ? 1 : 0;
}
