// Native host lifecycle: preflight while guest allocators are still callable, wake waits
// before joining guest threads, then drain GPU/compiler callbacks before releasing memory.
int dm_vk_restart_check(void) {
    int result = 0;
    pthread_mutex_lock(&g_object_mu);
    for (VkInstance i = g_instances; i && !result; i = i->session_next) {
        if (i->custom_allocator) result = -ENOTSUP;
        pthread_mutex_lock(&i->debug_mu);
        for (debug_callback *c = i->debug; c; c = c->next)
            if (c->custom_allocator) result = -ENOTSUP;
        pthread_mutex_unlock(&i->debug_mu);
    }
    pthread_mutex_unlock(&g_object_mu);
    if (result) LOG("[vk] 【红】 restart cannot free live debug objects with guest allocation callbacks after guest threads exit");
    return result;
}

int dm_vk_request_stop(void) {
    atomic_store(&g_stopping, 1);
    pthread_mutex_lock(&g_done_mu);
    pthread_cond_broadcast(&g_done_cv);
    pthread_mutex_unlock(&g_done_mu);
    return 0;
}

int dm_vk_shutdown_session(void) {
    int rc = dm_vk_restart_check();
    if (rc) return rc;
    dm_vk_request_stop();
    // Guest threads have joined. Their final submit is now stable; callbacks can still
    // dereference query pools/events, so retain every object until the final callback ends.
    pthread_mutex_lock(&g_qmu); uint64_t target = g_ev_val; pthread_mutex_unlock(&g_qmu);
    uint64_t start = now_ns();
    pthread_mutex_lock(&g_done_mu);
    while (atomic_load(&g_done) < target) {
        if (now_ns() - start >= 10000000000ull) {
            pthread_mutex_unlock(&g_done_mu);
            LOG("[vk] 【红】 restart GPU drain timed out: done %llu / submitted %llu", (unsigned long long)atomic_load(&g_done), (unsigned long long)target);
            return -ETIMEDOUT;
        }
        struct timespec step = {0, 100000000};
        pthread_cond_timedwait_relative_np(&g_done_cv, &g_done_mu, &step);
    }
    pthread_mutex_unlock(&g_done_mu);
    dispatch_semaphore_t compilerDone = dispatch_semaphore_create(0);
    dispatch_barrier_async(rt_queue(), ^{ dispatch_semaphore_signal(compilerDone); });
    if (dispatch_semaphore_wait(compilerDone, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        LOG("[vk] 【红】 restart shader compiler drain timed out");
        return -ETIMEDOUT;
    }
    @autoreleasepool {
        // Two passes: descriptor cleanup needs its layout's count. Do not free any object
        // storage until every ARC resource and nested allocation has been released.
        size_t count = 0;
        for (vk_object *node = g_objects; node; node = node->next) {
            count++;
            switch (node->kind) {
                case O_MEMORY: { VkDeviceMemory m = node->ptr; m->buf = nil; atomic_store(&m->raw, NULL); break; }
                case O_BUFFER_VIEW: ((VkBufferView)node->ptr)->tex = nil; break;
                case O_IMAGE: { VkImage im = node->ptr; wd_release(im->wid); im->tex = nil; break; }
                case O_IMAGE_VIEW: { VkImageView v = node->ptr; wd_release(v->wid); v->tex = nil; break; }
                case O_SAMPLER: ((VkSampler)node->ptr)->s = nil; break;
                case O_SHADER: { VkShaderModule m = node->ptr; m->fn = m->fn_d = nil; m->spv = nil; break; }
                case O_PIPELINE: { VkPipeline p = node->ptr; p->pso = nil; p->dss = nil; p->dsd = nil; p->dss_dyn = nil; p->cps = nil; p->se_spv = nil; p->se_pd = nil; p->pso_se = nil; p->cps_se = nil; break; }
                case O_SET: { VkDescriptorSet set = node->ptr;
                    for (uint32_t k = 0; k < set->L->total; k++) { set->d[k].buf = nil; set->d[k].tex = nil; set->d[k].smp = nil; }
                    free(set->d); break; }
                case O_LAYOUT: free(((VkDescriptorSetLayout)node->ptr)->imm); break;
                case O_COMMAND: free(((VkCommandBuffer)node->ptr)->buf); break;
                case O_QUERY: { VkQueryPool q = node->ptr; free(q->val); free(q->ticket); break; }
                case O_PLAIN: break;
            }
        }
        while (g_objects) { vk_object *node = g_objects; g_objects = node->next; free(node->ptr); free(node); }
        while (g_instances) debug_instance_release(g_instances, NULL);
        while (g_rt) { rt_ent *entry = g_rt; g_rt = entry->next; entry->fn = entry->fn_d = nil; free(entry); }
        free(g_sh); g_sh = NULL; g_nsh = 0; g_lib = nil;
        g_util_lib = nil; g_util_kernels = nil; g_clear_pipelines = nil; g_clear_depth = nil; g_blit_pipelines = nil;
        g_blit_samplers[0] = g_blit_samplers[1] = nil; g_query_none = nil; g_resolve_tmp = nil;
        g_wd_chunk = nil;
        for (int k = 0; k < 8; k++) { g_wd_pool[k].b = nil; g_wd_pool[k].until = 0; }
        g_wd_chunk_off = 0; g_wd_npool = 0;
        memset(g_wd_b, 0, sizeof g_wd_b); memset(g_wd_last, 0, sizeof g_wd_last);
        memset(g_wd_bound, 0, sizeof g_wd_bound); memset(g_wd_sides, 0, sizeof g_wd_sides);
        g_wd = -1; g_wd_sh = g_wd_mode = g_wd_side_on = g_wd_row_on = 0; g_wd_c0 = 0; g_wd_d0 = ~0u;
        atomic_store(&g_wd_ids, 0x40000000u);
        g_wd_reuse = g_wd_chunks = g_wd_draws = g_wd_core = g_wd_rw = g_wd_big = g_wd_fragx = 0;
        g_wd_prof = -1; g_wd_prof_t = g_wd_prof_n = 0;
        memset(g_gt, 0, sizeof g_gt); memset(g_done_ns, 0, sizeof g_done_ns);
        g_ev_val = g_frames = g_next_acq = 0;
        atomic_store(&g_done, 0); atomic_store(&g_mem_bytes, 0);
        atomic_store(&g_n_draw, 0); atomic_store(&g_n_pass, 0); atomic_store(&g_n_submit, 0); atomic_store(&g_n_copy, 0); atomic_store(&g_n_pso, 0);
        atomic_store(&g_bad_feat, 0); atomic_store(&g_bad_err, 0);
        for (int k = 0; k < OKB_N; k++) atomic_store(&g_okb[k], 0);
        atomic_store(&g_render_encoders, 0); atomic_store(&g_indirect_buffers, 0); atomic_store(&g_indirect_bytes, 0);
        atomic_store(&g_rt_miss, 0); atomic_store(&g_rt_ok, 0); atomic_store(&g_rt_bad, 0); atomic_store(&g_rt_disk, 0); atomic_store(&g_rt_saved, 0);
        g_dss_off = nil; g_ev = nil; g_q = nil; g_dev = nil;
        atomic_store(&g_stopping, 0);
        LOG("[vk] session disposed: %zu objects, final GPU submit %llu drained", count, (unsigned long long)target);
    }
    return 0;
}
