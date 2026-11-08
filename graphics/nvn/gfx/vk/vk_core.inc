// Vulkan 1.0 / 1.1 核心里余下的命令（#271 维护方批量补齐）：事件、动态模板掩码、填 / 更新缓冲、清图像 / 清附件、Blit、多重采样解析、查询结果复制、
// 计算管线与派发、次级命令缓冲、多子遍。由 hle_vk.m 在回放（replay）之前 include：用它的录制（rec）、回放状态（rs_t）与编码器收放（end_rp / end_blit / end_ce）。
// Metal 做不了的照规范回「不支持」并报红，不编假成功：在提交之后才由主机置位的事件（GPU 不能回头等）、带基址的派发、分层清附件、换格式或非浮点颜色的局部多重采样解析。

static void wait_done(uint64_t v);   // hle_vk.m (after the replay)

// ---------- 录制 ----------

VK(vkCmdSetEvent, void, VkCommandBuffer cb, VkEvent e, VkPipelineStageFlags st) { (void)st; *(c_event *)rec(cb, C_EVENT, sizeof(c_event)) = (c_event){e, 1}; }
VK(vkCmdResetEvent, void, VkCommandBuffer cb, VkEvent e, VkPipelineStageFlags st) { (void)st; *(c_event *)rec(cb, C_EVENT, sizeof(c_event)) = (c_event){e, 0}; }
VK(vkCmdWaitEvents, void, VkCommandBuffer cb, uint32_t n, const VkEvent *ev, VkPipelineStageFlags src, VkPipelineStageFlags dst, uint32_t nm, const VkMemoryBarrier *m,
   uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *i) {
    c_waitev *x = rec(cb, C_WAITEV, sizeof *x + n * sizeof(VkEvent)); x->n = n; memcpy(x->e, ev, n * sizeof *ev);
    h_vkCmdPipelineBarrier(cb, src, dst, 0, nm, m, nb, b, ni, i);   // its memory barriers order like a pipeline barrier's
}
VK(vkCmdSetStencilCompareMask, void, VkCommandBuffer cb, VkStencilFaceFlags face, uint32_t mask) { *(c_smask *)rec(cb, C_SMASK, sizeof(c_smask)) = (c_smask){face, 0, mask}; }
VK(vkCmdSetStencilWriteMask, void, VkCommandBuffer cb, VkStencilFaceFlags face, uint32_t mask) { *(c_smask *)rec(cb, C_SMASK, sizeof(c_smask)) = (c_smask){face, 1, mask}; }
VK(vkCmdSetDepthBounds, void, VkCommandBuffer cb, float lo, float hi) { (void)cb; (void)lo; (void)hi; }   // the depthBounds feature is not offered: the state is never read
VK(vkCmdSetDeviceMask, void, VkCommandBuffer cb, uint32_t mask) { (void)cb; if (mask != 1) RED1("device mask %#x: the device group has one device", mask); }
VK(vkCmdFillBuffer, void, VkCommandBuffer cb, VkBuffer dst, VkDeviceSize off, VkDeviceSize size, uint32_t data) { *(c_fill *)rec(cb, C_FILL, sizeof(c_fill)) = (c_fill){dst, off, size, data}; }
VK(vkCmdUpdateBuffer, void, VkCommandBuffer cb, VkBuffer dst, VkDeviceSize off, VkDeviceSize size, const void *data) {
    if (size > 65536) { RED1("vkCmdUpdateBuffer of %llu bytes (over 65536)", (unsigned long long)size); return; }
    c_update *x = rec(cb, C_UPDATE, sizeof *x + (size_t)size); x->dst = dst; x->off = off; x->size = size; memcpy(x->data, data, (size_t)size);   // the data is copied when recorded
}
VK(vkCmdClearColorImage, void, VkCommandBuffer cb, VkImage im, VkImageLayout l, const VkClearColorValue *v, uint32_t n, const VkImageSubresourceRange *r) {
    (void)l; c_clrimg *x = rec(cb, C_CLRIMG, sizeof *x + n * sizeof *r); x->im = im; x->ds = 0; x->v.color = *v; x->n = n; memcpy(x->r, r, n * sizeof *r);
}
VK(vkCmdClearDepthStencilImage, void, VkCommandBuffer cb, VkImage im, VkImageLayout l, const VkClearDepthStencilValue *v, uint32_t n, const VkImageSubresourceRange *r) {
    (void)l; c_clrimg *x = rec(cb, C_CLRIMG, sizeof *x + n * sizeof *r); x->im = im; x->ds = 1; x->v.depthStencil = *v; x->n = n; memcpy(x->r, r, n * sizeof *r);
}
VK(vkCmdClearAttachments, void, VkCommandBuffer cb, uint32_t na, const VkClearAttachment *a, uint32_t nr, const VkClearRect *r) {
    c_clratt *x = rec(cb, C_CLRATT, sizeof *x + nr * sizeof *r); x->na = umin(na, 9); x->nr = nr; memcpy(x->a, a, x->na * sizeof *a); memcpy(x->r, r, nr * sizeof *r);
}
VK(vkCmdBlitImage, void, VkCommandBuffer cb, VkImage src, VkImageLayout sl, VkImage dst, VkImageLayout dl, uint32_t n, const VkImageBlit *r, VkFilter filter) {
    (void)sl; (void)dl; c_blit *x = rec(cb, C_BLIT, sizeof *x + n * sizeof *r); x->src = src; x->dst = dst; x->filter = filter; x->n = n; memcpy(x->r, r, n * sizeof *r);
}
VK(vkCmdResolveImage, void, VkCommandBuffer cb, VkImage src, VkImageLayout sl, VkImage dst, VkImageLayout dl, uint32_t n, const VkImageResolve *r) {
    (void)sl; (void)dl; c_resolve *x = rec(cb, C_RESOLVE, sizeof *x + n * sizeof *r); x->src = src; x->dst = dst; x->n = n; memcpy(x->r, r, n * sizeof *r);
}
VK(vkCmdCopyQueryPoolResults, void, VkCommandBuffer cb, VkQueryPool q, uint32_t first, uint32_t n, VkBuffer dst, VkDeviceSize off, VkDeviceSize stride, VkQueryResultFlags fl) {
    *(c_qcopy *)rec(cb, C_QCOPY, sizeof(c_qcopy)) = (c_qcopy){q, first, n, dst, off, stride, fl};
}
VK(vkCmdDispatch, void, VkCommandBuffer cb, uint32_t x, uint32_t y, uint32_t z) { *(c_dispatch *)rec(cb, C_DISPATCH, sizeof(c_dispatch)) = (c_dispatch){x, y, z, 0, 0, 0}; }
VK(vkCmdDispatchBase, void, VkCommandBuffer cb, uint32_t bx, uint32_t by, uint32_t bz, uint32_t x, uint32_t y, uint32_t z) {
    *(c_dispatch *)rec(cb, C_DISPATCH, sizeof(c_dispatch)) = (c_dispatch){x, y, z, bx, by, bz};
}
VK(vkCmdDispatchIndirect, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize off) { *(c_dispatchi *)rec(cb, C_DISPATCHI, sizeof(c_dispatchi)) = (c_dispatchi){b, off}; }
// Secondary command buffers are recorded like primary ones and replayed in place when a primary executes them (inside or outside a render pass, which they continue)
VK(vkCmdExecuteCommands, void, VkCommandBuffer cb, uint32_t n, const VkCommandBuffer *cbs) {
    c_exec *x = rec(cb, C_EXEC, sizeof *x + n * sizeof *cbs); x->n = n; memcpy(x->cb, cbs, n * sizeof *cbs);
}
VK(vkCmdNextSubpass, void, VkCommandBuffer cb, VkSubpassContents sc) { (void)sc; rec(cb, C_NEXTSP, 0); }

// Compute pipelines: the shader's Metal kernel and its workgroup size from the shader table (vk_shaders.py writes w:x.y=z for compute shaders)
VKB(vkCreateComputePipelines, VkResult, VkDevice d, VkPipelineCache c, uint32_t n, const VkComputePipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out) {
    (void)c; dev_init(); VkResult rc = VK_SUCCESS;
    for (uint32_t i = 0; i < n; i++) {
        VkPipeline p = obj_alloc(sizeof *p, O_PIPELINE); p->layout = ci[i].layout; VkShaderModule m = ci[i].stage.module;
        if (ci[i].stage.pSpecializationInfo && ci[i].stage.pSpecializationInfo->mapEntryCount) RED1("specialization constants not implemented");
        mod_ready(m); p->cs = m->si;
        if (m->spv && m->fn) { p->se_spv = m->spv; memcpy(p->se_key, m->key, 17); }   // #800：偏置模拟变体（vk_se_obj）
        if (!m->fn && m->rt && atomic_load_explicit(&m->rt->state, memory_order_acquire) == 0) {   // 还在现编：句柄先交，编好后第一次派发补建（cpipe_finish）
            p->pend_c = m->rt; p->pend_spv = m->spv;
            static _Atomic int k; if (k++ < 20) LOG("[vk] 现编：计算管线 %s 的着色器还在编，句柄先交，编好后第一次派发补建（第 %llu 帧）", m->key, (unsigned long long)g_frames);
        }
        else if (!m->fn || !m->si || !m->si->comp) { LOG("[vk] 【红】 compute pipeline: shader %s is not a compute shader in the library", m->key); p->feat = 1; }
        else if (!m->si->wg[0] || !m->si->wg[1] || !m->si->wg[2]) { LOG("[vk] 【红】 compute shader %s has no workgroup size in the shader table (rebuild the package)", m->key); p->feat = 1; }
        else {
            @autoreleasepool {
                NSError *err = nil; p->cps = [g_dev newComputePipelineStateWithFunction:m->fn error:&err];
                if (!p->cps) LOG("[vk] 【红】 cannot build compute pipeline %s: %s", m->key, err.localizedDescription.UTF8String); else g_n_pso++;
            }
        }
        out[i] = p;
        // P1-46：建不成：这一项交 VK_NULL_HANDLE、整批回失败码，其余照建（同 vkCreateGraphicsPipelines）
        if (!p->cps && !p->pend_c) { RED1("vkCreateComputePipelines：管线没建成：交空句柄、回 VK_ERROR_OUT_OF_DEVICE_MEMORY"); h_vkDestroyPipeline(d, p, a); out[i] = VK_NULL_HANDLE; rc = VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    }
    return rc;
}

// 等现编的计算管线：着色器编好就补建（同 pipe_finish：还在编照跳过、编不过 / 不是计算着色器 / 没有工作组大小报红一次、之后照跳过）
static void cpipe_finish(VkPipeline p) {
    int st = rt_state(p->pend_c); if (!st) return;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu);
    struct rt_ent *e = p->pend_c;
    if (e && !p->cps) @autoreleasepool {
        p->pend_c = NULL;
        if (st == 2 || !e->si.comp || !e->si.wg[0] || !e->si.wg[1] || !e->si.wg[2]) { g_pend_bad++; p->feat = st != 2; LOG("[vk] 【红】 现编：计算管线等的 %s %s，这条管线的派发照安全网跳过", e->key, st == 2 ? "编不过" : "不是计算着色器或没有工作组大小"); }
        else {
            NSError *err = nil; p->cps = [g_dev newComputePipelineStateWithFunction:e->fn error:&err];
            if (!p->cps) { g_pend_bad++; LOG("[vk] 【红】 现编：补建计算管线 %s 被 Metal 拒（%s）", e->key, err.localizedDescription.UTF8String); }
            else { g_n_pso++; g_pend_made++; p->cs = &e->si; if (p->pend_spv) { p->se_spv = p->pend_spv; memcpy(p->se_key, e->key, 17); } }
        }
        p->pend_spv = nil;
    }
    pthread_mutex_unlock(&mu);
}

// ---------- 回放：编码器与工具着色器 ----------
// The compute encoder: transfers and dispatches happen outside a render pass (a pass left open for a copy in the middle resumes at its next draw, as blit() does)
static id<MTLComputeCommandEncoder> cenc(rs_t *s) {
    if (s->re) { end_rp(s, 0); s->cut = 1; }
    end_blit(s);
    if (!s->ce) s->ce = new_ce(s);
    return s->ce;
}
static const char util_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
// vkCmdFillBuffer with a word whose four bytes differ (Metal's fill writes one byte)
"kernel void vk_fill(device uint *d [[buffer(0)]], constant uint2 &p [[buffer(1)]], uint i [[thread_position_in_grid]]) { if (i < p.y) d[i] = p.x; }\n"
// vkCmdCopyQueryPoolResults: per query a value the host already has plus the visibility slots of this submit that count into it
"struct qin { ulong cpu; uint avail, nslot, first, pad; };\n"
"struct qpar { ulong stride; uint flags, n; };\n"
"kernel void vk_qcopy(device const qin *q [[buffer(0)]], device const uint *slots [[buffer(1)]], device const ulong *res [[buffer(2)]], device uchar *dst [[buffer(3)]],\n"
" constant qpar &p [[buffer(4)]], uint i [[thread_position_in_grid]]) {\n"
" if (i >= p.n) return; ulong v = q[i].cpu; for (uint k = 0; k < q[i].nslot; k++) v += res[slots[q[i].first + k]];\n"
" bool ok = q[i].avail != 0; device uchar *o = dst + ulong(i) * p.stride;\n"
" if (p.flags & 1u) { if (ok || (p.flags & 4u)) *(device ulong *)o = ok ? v : 0; if (p.flags & 2u) *((device ulong *)o + 1) = ok ? 1 : 0; }\n"
" else { if (ok || (p.flags & 4u)) *(device uint *)o = ok ? uint(v) : 0u; if (p.flags & 2u) *((device uint *)o + 1) = ok ? 1u : 0u; } }\n"
// vkCmdBlitImage with scaling or flipping: a quad over the destination rectangle sampling the source rectangle (t in [0,1]², y down as in images)
"struct bo { float4 pos [[position]]; float2 uv; };\n"
"vertex bo vk_blit_v(uint vid [[vertex_id]], constant float4 &uv [[buffer(0)]]) {\n"
" float2 t = float2(vid & 1, vid >> 1); bo o; o.pos = float4(t.x * 2 - 1, 1 - t.y * 2, 0, 1); o.uv = mix(uv.xy, uv.zw, t); return o; }\n"
"fragment float4 vk_blit_f(bo in [[stage_in]], texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) { return src.sample(smp, in.uv, level(0)); }\n";
static id<MTLLibrary> g_util_lib;
static NSMutableDictionary *g_util_kernels, *g_clear_pipelines, *g_clear_depth, *g_blit_pipelines;
static id<MTLSamplerState> g_blit_samplers[2];
static id<MTLBuffer> g_query_none;
static id<MTLFunction> util_fn(const char *name) {
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (!g_util_lib) { NSError *e = nil; g_util_lib = [g_dev newLibraryWithSource:@(util_msl) options:nil error:&e]; if (!g_util_lib) LOG("[vk] 【红】 utility shaders: %s", e.localizedDescription.UTF8String); }
    pthread_mutex_unlock(&mu);
    return g_util_lib ? [g_util_lib newFunctionWithName:@(name)] : nil;
}
static id<MTLComputePipelineState> util_kernel(const char *name) {   // replay is serialized by g_qmu
    if (!g_util_kernels) g_util_kernels = [NSMutableDictionary new];
    NSMutableDictionary *cache = g_util_kernels;
    id hit = cache[@(name)]; if (hit) return hit == NSNull.null ? nil : hit;   // 建失败存 NSNull：同一组合不再每笔重建（11-01）
    id<MTLComputePipelineState> ps; id<MTLFunction> fn = util_fn(name); NSError *e = nil;
    ps = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&e] : nil;
    if (ps) cache[@(name)] = ps; else { cache[@(name)] = NSNull.null; LOG("[vk] 【红】 utility kernel %s: %s", name, e.localizedDescription.UTF8String); }
    return ps;
}
static void dispatch1d(id<MTLComputeCommandEncoder> ce, id<MTLComputePipelineState> ps, NSUInteger n) {
    [ce setComputePipelineState:ps]; [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)64, ps.maxTotalThreadsPerThreadgroup), 1, 1)];
}
// Bytes for this submit's staging area (vkCmdUpdateBuffer data, query-copy inputs), sized by the pre-scan in vkQueueSubmit
static NSUInteger stage_take(rs_t *s, NSUInteger n) {
    NSUInteger o = s->sq->stage_used; s->sq->stage_used += (n + 15) & ~(NSUInteger)15;
    if (!s->sq->stage || s->sq->stage_used > s->sq->stage.length) die("[vk] staging area of the submit exhausted");
    return o;
}

// ---------- 回放：各命令 ----------
static void do_event(rs_t *s, const c_event *x) {
    subq_t *q = s->sq;
    if (q->nev == q->evcap) { q->evcap = q->evcap ? q->evcap * 2 : 8; q->ev = realloc(q->ev, q->evcap * sizeof *q->ev); if (!q->ev) die("[vk] out of memory (events)"); }
    q->ev[q->nev].e = x->e; q->ev[q->nev].set = x->set; q->nev++;
}
// The one queue runs everything in order and Metal orders the encoders by their resources, so waiting on an event set by earlier commands is already satisfied.
// An event the host has not set by the time the submit is encoded cannot be waited for on the GPU here
static void do_waitev(rs_t *s, const c_waitev *x) {
    for (uint32_t i = 0; i < x->n; i++) {
        if (atomic_load(&x->e[i]->set)) continue;
        int pending = 0; for (uint32_t k = 0; k < s->sq->nev; k++) if (s->sq->ev[k].e == x->e[i]) pending = s->sq->ev[k].set;
        if (!pending) RED1("vkCmdWaitEvents on an event no earlier command sets and the host has not set: not supported (the GPU does not wait for the host)");
    }
}
// P1-45：缓冲内 [off, off + n) 是否落在它所绑内存（MTLBuffer）里——不溢出的写法。越出的那一笔整条不编码：编了就是 GPU 越界，整次提交报页错误、同提交里界内的命令一起丢
static int mem_range_ok(VkBuffer b, id<MTLBuffer> mb, VkDeviceSize off, VkDeviceSize n) {
    VkDeviceSize len = mb ? mb.length : 0; return b->off <= len && off <= len - b->off && n <= len - b->off - off;
}
static void do_fill(rs_t *s, const c_fill *x) {
    VkBuffer b = x->dst; if (!b || !b->mem) { RED1("vkCmdFillBuffer: the buffer has no bound memory"); return; }
    VkDeviceSize n = x->size == VK_WHOLE_SIZE ? (b->size - x->off) & ~(VkDeviceSize)3 : x->size;
    if (!n) return;
    id<MTLBuffer> mb = mem_buf(b->mem); NSUInteger off = (NSUInteger)(b->off + x->off);
    if (!mem_range_ok(b, mb, x->off, n)) { RED1("vkCmdFillBuffer 越界：偏移 %llu 大小 %llu，缓冲 %llu 字节：不编码", (unsigned long long)x->off, (unsigned long long)x->size, (unsigned long long)b->size); return; }
    uint8_t c = (uint8_t)x->data;
    if (x->data == c * 0x01010101u) { [blit(s, C_FILL) fillBuffer:mb range:NSMakeRange(off, (NSUInteger)n) value:c]; return; }
    id<MTLComputePipelineState> ps = util_kernel("vk_fill"); if (!ps) return;
    id<MTLComputeCommandEncoder> ce = cenc(s); uint32_t p[2] = {x->data, (uint32_t)(n / 4)};
    [ce setBuffer:mb offset:off atIndex:0]; [ce setBytes:p length:sizeof p atIndex:1]; dispatch1d(ce, ps, (NSUInteger)(n / 4));
}
static void do_update(rs_t *s, const c_update *x) {
    VkBuffer b = x->dst; if (!b || !b->mem || !x->size) { if (x->size) RED1("vkCmdUpdateBuffer: the buffer has no bound memory"); return; }
    if (!mem_range_ok(b, mem_buf(b->mem), x->off, x->size)) { RED1("vkCmdUpdateBuffer 越界：偏移 %llu 大小 %llu，缓冲 %llu 字节：不编码", (unsigned long long)x->off, (unsigned long long)x->size, (unsigned long long)b->size); return; }
    NSUInteger o = stage_take(s, (NSUInteger)x->size); memcpy((uint8_t *)s->sq->stage.contents + o, x->data, (size_t)x->size);
    [blit(s, C_UPDATE) copyFromBuffer:s->sq->stage sourceOffset:o toBuffer:mem_buf(b->mem) destinationOffset:(NSUInteger)(b->off + x->off) size:(NSUInteger)x->size];
}
static int fmt_sint(VkFormat f) {
    switch (f) {
        case VK_FORMAT_R8_SINT: case VK_FORMAT_R8G8_SINT: case VK_FORMAT_R8G8B8_SINT: case VK_FORMAT_B8G8R8_SINT: case VK_FORMAT_R8G8B8A8_SINT: case VK_FORMAT_B8G8R8A8_SINT:
        case VK_FORMAT_A8B8G8R8_SINT_PACK32: case VK_FORMAT_A2R10G10B10_SINT_PACK32: case VK_FORMAT_A2B10G10R10_SINT_PACK32: case VK_FORMAT_R16_SINT: case VK_FORMAT_R16G16_SINT:
        case VK_FORMAT_R16G16B16_SINT: case VK_FORMAT_R16G16B16A16_SINT: case VK_FORMAT_R32_SINT: case VK_FORMAT_R32G32_SINT: case VK_FORMAT_R32G32B32_SINT: case VK_FORMAT_R32G32B32A32_SINT: return 1;
        default: return 0;
    }
}
static MTLClearColor clear_color(VkFormat f, const VkClearColorValue *v) {   // the union member the format reads: float, signed or unsigned integer
    const fmt_t *ft = fmt_of(f);
    if (ft && ft->kind == K_INT) {
        if (fmt_sint(f)) return MTLClearColorMake(v->int32[0], v->int32[1], v->int32[2], v->int32[3]);
        return MTLClearColorMake(v->uint32[0], v->uint32[1], v->uint32[2], v->uint32[3]);
    }
    return MTLClearColorMake(v->float32[0], v->float32[1], v->float32[2], v->float32[3]);
}
// vkCmdClearColorImage / vkCmdClearDepthStencilImage (outside a render pass): one Metal pass per level and layer (per slice of a 3D image) that only clears.
// Images get the render-target usage when they are transfer destinations (vkCreateImage)
static void do_clrimg(rs_t *s, const c_clrimg *x) {
    VkImage im = x->im; if (!im || !im->tex) { RED1("clear of an image that was not created"); return; }
    if (!(im->tex.usage & MTLTextureUsageRenderTarget)) { RED1("clear of image format %d: Metal cannot render into it", im->fmt); return; }
    if (s->re) { end_rp(s, 0); s->cut = 1; }
    end_blit(s); end_ce(s);
    for (uint32_t i = 0; i < x->n; i++) {
        const VkImageSubresourceRange *r = &x->r[i];
        uint32_t nl = r->levelCount == VK_REMAINING_MIP_LEVELS ? im->mips - r->baseMipLevel : r->levelCount;
        for (uint32_t l = r->baseMipLevel; l < r->baseMipLevel + nl && l < im->mips; l++) {
            uint32_t layers = im->type == VK_IMAGE_TYPE_3D ? umax(1, im->d >> l) : (r->layerCount == VK_REMAINING_ARRAY_LAYERS ? im->layers - r->baseArrayLayer : r->layerCount);
            uint32_t base = im->type == VK_IMAGE_TYPE_3D ? 0 : r->baseArrayLayer;
            for (uint32_t k = base; k < base + layers && (im->type == VK_IMAGE_TYPE_3D || k < im->layers); k++) {   // P1-45：层数越出图像的不建遍（级别已由 l < im->mips 夹住）
                MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
                if (!x->ds) {
                    d.colorAttachments[0].texture = im->tex; d.colorAttachments[0].level = l;
                    if (im->type == VK_IMAGE_TYPE_3D) d.colorAttachments[0].depthPlane = k; else d.colorAttachments[0].slice = k;
                    d.colorAttachments[0].loadAction = MTLLoadActionClear; d.colorAttachments[0].storeAction = MTLStoreActionStore; d.colorAttachments[0].clearColor = clear_color(im->fmt, &x->v.color);
                } else {   // a depth-stencil format is one attachment in Metal: the aspect not cleared is loaded and stored as it was
                    int cd = (r->aspectMask & VK_IMAGE_ASPECT_DEPTH_BIT) != 0, cs = (r->aspectMask & VK_IMAGE_ASPECT_STENCIL_BIT) != 0;
                    if (fmt_has_depth(im->f)) {
                        d.depthAttachment.texture = im->tex; d.depthAttachment.level = l; d.depthAttachment.slice = k; d.depthAttachment.storeAction = MTLStoreActionStore;
                        d.depthAttachment.loadAction = cd ? MTLLoadActionClear : MTLLoadActionLoad; d.depthAttachment.clearDepth = x->v.depthStencil.depth;
                    }
                    if (fmt_has_stencil(im->f)) {
                        d.stencilAttachment.texture = im->tex; d.stencilAttachment.level = l; d.stencilAttachment.slice = k; d.stencilAttachment.storeAction = MTLStoreActionStore;
                        d.stencilAttachment.loadAction = cs ? MTLLoadActionClear : MTLLoadActionLoad; d.stencilAttachment.clearStencil = x->v.depthStencil.stencil;
                    }
                }
                id<MTLRenderCommandEncoder> e = new_re(s, d); [e endEncoding];
                if (e) { g_render_encoders++; g_n_pass++; }
            }
        }
    }
}
// vkCmdClearAttachments (inside a render pass): a quad per rectangle in the pass being run, writing only the cleared attachments; the encoder stays open and the next
// draw sets its own pipeline and state again. The pipeline is made per attachment signature (formats, which ones are written, sample count)
static id<MTLRenderPipelineState> clratt_pso(rs_t *s, uint32_t cmask, int depth, int stencil) {
    if (!g_clear_pipelines) g_clear_pipelines = [NSMutableDictionary new];
    NSMutableDictionary *cache = g_clear_pipelines;
    const c_brp *c = s->brp; VkRenderPass rp = c->rp; const rsub *sp = &rp->sub[s->sub];
    MTLRenderPassDescriptor *d = s->rpd; NSMutableString *key = [NSMutableString stringWithFormat:@"%u:%d:%d", cmask, depth, stencil];
    NSUInteger samples = 1;
    for (uint32_t i = 0; i < sp->ncol; i++) {
        id<MTLTexture> t = d.colorAttachments[i].texture; int a = sp->col[i];
        [key appendFormat:@"|%lu:%d", t ? (unsigned long)t.pixelFormat : 0ul, a >= 0 ? fmt_sint(rp->att[a].fmt) : 0];
        if (t) samples = t.sampleCount;
    }
    id<MTLTexture> dt = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture;
    if (dt) { [key appendFormat:@"|d%lu", (unsigned long)dt.pixelFormat]; samples = dt.sampleCount; }
    [key appendFormat:@"|s%lu", (unsigned long)samples];   // 采样数进键（审计 #1565 P1-69）：同格式单采样遍先建的管线被多重采样遍命中，校验层断言 colorSampleCount 1 ≠ 4
    id hit = cache[key]; if (hit) return hit == NSNull.null ? nil : hit;   // 建失败存 NSNull：同一组合不再每笔重建（11-01）
    id<MTLRenderPipelineState> ps;
    NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct co {"];
    NSMutableString *body = [NSMutableString string];
    for (uint32_t i = 0; i < sp->ncol; i++) {
        id<MTLTexture> t = d.colorAttachments[i].texture; if (!t) continue; int a = sp->col[i]; const fmt_t *f = fmt_of(rp->att[a].fmt);
        const char *ty = f && f->kind == K_INT ? (fmt_sint(rp->att[a].fmt) ? "int4" : "uint4") : "float4";
        [src appendFormat:@" %s c%u [[color(%u)]];", ty, i, i]; [body appendFormat:@" o.c%u = as_type<%s>(v[%u]);", i, ty, i];
    }
    [src appendFormat:@" };\nvertex float4 vk_clr_v(uint vid [[vertex_id]], constant float &z [[buffer(0)]]) { float2 p = float2(vid == 1 ? 3 : -1, vid == 2 ? 3 : -1); return float4(p, z, 1); }\n"
                       "fragment co vk_clr_f(constant uint4 *v [[buffer(0)]]) { co o;%@ return o; }\n", body];
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { LOG("[vk] 【红】 clear-attachments shader: %s", e.localizedDescription.UTF8String); return nil; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vk_clr_v"]; pd.fragmentFunction = [lib newFunctionWithName:@"vk_clr_f"]; pd.rasterSampleCount = samples;
    for (uint32_t i = 0; i < sp->ncol; i++) {
        id<MTLTexture> t = d.colorAttachments[i].texture; if (!t) continue;
        pd.colorAttachments[i].pixelFormat = t.pixelFormat; pd.colorAttachments[i].writeMask = cmask >> i & 1 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    }
    if (d.depthAttachment.texture) pd.depthAttachmentPixelFormat = d.depthAttachment.texture.pixelFormat;
    if (d.stencilAttachment.texture) pd.stencilAttachmentPixelFormat = d.stencilAttachment.texture.pixelFormat;
    ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { LOG("[vk] 【红】 clear-attachments pipeline: %s", e.localizedDescription.UTF8String); cache[key] = NSNull.null; return nil; }
    cache[key] = ps; return ps;
}
// game = 1：区域是游戏坐标（vkCmdClearAttachments），按被清附件的放宽 / 加高换算到存储（wd_map_span / wd_map_span_y，同拷贝区域口径；审计 P1-79：原先不换算，
//   整张清的区域只盖存储左上那块游戏尺寸，两侧放宽带 / 上下加高带留着旧内容）；0 = 已是存储坐标（wd_page_clear）
static void do_clratt(rs_t *s, const c_clratt *x, int game) {
    if (!s->re && s->cut) resume_rp(s);
    if (!s->re || !s->brp) { RED1("vkCmdClearAttachments outside a render pass"); return; }
    const c_brp *c = s->brp; const rsub *sp = &c->rp->sub[s->sub];
    uint32_t cmask = 0; int depth = 0, stencil = 0; uint32_t v[8][4] = {{0}}; float z = 0; uint32_t sref = 0;
    for (uint32_t i = 0; i < x->na; i++) {
        const VkClearAttachment *a = &x->a[i];
        if (a->aspectMask & VK_IMAGE_ASPECT_COLOR_BIT) { if (a->colorAttachment < sp->ncol && sp->col[a->colorAttachment] >= 0) { cmask |= 1u << a->colorAttachment; memcpy(v[a->colorAttachment], a->clearValue.color.uint32, 16); } }
        if ((a->aspectMask & VK_IMAGE_ASPECT_DEPTH_BIT) && s->rpd.depthAttachment.texture) { depth = 1; z = a->clearValue.depthStencil.depth; }
        if ((a->aspectMask & VK_IMAGE_ASPECT_STENCIL_BIT) && s->rpd.stencilAttachment.texture) { stencil = 1; sref = a->clearValue.depthStencil.stencil; }
    }
    if (!cmask && !depth && !stencil) return;
    id<MTLRenderPipelineState> ps = clratt_pso(s, cmask, depth, stencil); if (!ps) return;
    if (!g_clear_depth) g_clear_depth = [NSMutableDictionary new];
    NSMutableDictionary *dss = g_clear_depth;
    NSNumber *k = @(depth | stencil << 1); id<MTLDepthStencilState> st = dss[k];
    if (!st) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = depth;
        if (stencil) { MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; sd.stencilCompareFunction = MTLCompareFunctionAlways; sd.depthStencilPassOperation = MTLStencilOperationReplace; sd.writeMask = 0xff; dd.frontFaceStencil = sd; dd.backFaceStencil = sd; }
        st = [g_dev newDepthStencilStateWithDescriptor:dd]; dss[k] = st;
    }
    id<MTLRenderCommandEncoder> re = s->re;
    [re setRenderPipelineState:ps]; [re setDepthStencilState:st]; [re setCullMode:MTLCullModeNone]; [re setTriangleFillMode:MTLTriangleFillModeFill];
    [re setDepthBias:0 slopeScale:0 clamp:0]; [re setStencilReferenceValue:sref];
    [re setViewport:(MTLViewport){0, 0, s->rt_w, s->rt_h, 0, 1}];
    [re setVertexBytes:&z length:sizeof z atIndex:0]; [re setFragmentBytes:v length:sizeof v atIndex:0];
    VkImageView mv = NULL;   // 换算按的附件：第一个被清的颜色附件，没有就深度 / 模板（同一遍的附件同一放宽）
    if (game && g_wd > 0) { const VkFramebuffer fb = c->fb; int ai = -1;
        for (uint32_t i = 0; i < sp->ncol && ai < 0; i++) if (cmask >> i & 1) ai = sp->col[i];
        if (ai < 0 && (depth || stencil)) ai = sp->depth;
        if (fb && ai >= 0 && (uint32_t)ai < fb->n) mv = fb->v[ai]; }
    for (uint32_t i = 0; i < x->nr; i++) {
        const VkClearRect *r = &x->r[i];
        if (r->baseArrayLayer || r->layerCount > 1) RED1("vkCmdClearAttachments of layers other than the first: layered rendering not implemented");
        int32_t rx = r->rect.offset.x, ry = r->rect.offset.y; uint32_t rw = r->rect.extent.width, rh = r->rect.extent.height;
        if (mv && mv->img) { wd_map_span(mv->img, mv->lv0, &rx, &rw); wd_map_span_y(mv->img, mv->lv0, &ry, &rh); }
        int64_t x0 = rx < 0 ? 0 : rx, y0 = ry < 0 ? 0 : ry;
        int64_t x1 = (int64_t)rx + rw, y1 = (int64_t)ry + rh;
        if (x1 > s->rt_w) x1 = s->rt_w;
        if (y1 > s->rt_h) y1 = s->rt_h;
        if (x1 <= x0 || y1 <= y0) continue;
        [re setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    s->applied = NULL; s->vp_dirty = s->sc_dirty = 1; s->dyn_dirty = 1;   // the next draw sets its pipeline, viewport, scissor and dynamic state again
}
// 宽屏：本笔起 16:9 原比例页（s2a_widen_page_sides）——颜色附件 0 两侧条带整高清成全 0（同通用模式 ClearCols），按 vkCmdClearAttachments 的路子画
static void wd_page_clear(rs_t *s) {
    int rows = g_wd_row_on; g_wd_side_on = g_wd_row_on = 0;
    _Alignas(c_clratt) uint8_t buf[sizeof(c_clratt) + 4 * sizeof(VkClearRect)]; memset(buf, 0, sizeof buf);
    c_clratt *x = (c_clratt *)buf; x->na = 1; x->a[0].aspectMask = VK_IMAGE_ASPECT_COLOR_BIT; x->a[0].colorAttachment = 0;
    for (int i = 0; i < 4; i += 2)
        if (g_wd_sides[i + 1] > g_wd_sides[i])
            x->r[x->nr++] = (VkClearRect){{{g_wd_sides[i], 0}, {(uint32_t)(g_wd_sides[i + 1] - g_wd_sides[i]), s->rt_h}}, 0, 1};
    for (int i = 0; rows && i < 4; i += 2)   // 窄屏加高的目标起页：上下两条（行，整宽）
        if (g_wd_rows[i + 1] > g_wd_rows[i])
            x->r[x->nr++] = (VkClearRect){{{0, g_wd_rows[i]}, {s->rt_w, (uint32_t)(g_wd_rows[i + 1] - g_wd_rows[i])}}, 0, 1};
    if (x->nr) do_clratt(s, x, 0);
}
// 1:1 拷贝的一条轴夹进两边这一级：两边原点同挪到都 ≥ 0，长度截到两边都还在界内；返回夹后长度（≤ 0 = 夹空，跳过）。界内的不动（P1-22，Blit 等尺寸与局部解析共用）
static int64_t clamp_span(int64_t *s0, int64_t *d0, int64_t n, int64_t slim, int64_t dlim) {
    int64_t o = 0; if (-*s0 > o) o = -*s0; if (-*d0 > o) o = -*d0;
    *s0 += o; *d0 += o; n -= o;
    if (*s0 + n > slim) n = slim - *s0;
    if (*d0 + n > dlim) n = dlim - *d0;
    return n;
}
// P1-68：拷贝里图像这一边的子资源与盒子是否都在图像里（级别 < 级数；非 3D 层 [l0, l0 + nl) 在层数内；原点 ≥ 0、原点 + 尺寸 ≤ 这一级的存储宽高深）。
//   缓冲↔图像拷贝越出的那一条整条不编码（同填充 / 更新 mem_range_ok 口径）；等尺寸图像拷贝的矩形另走 clamp_span 夹进两边
static int img_sub_ok(VkImage im, uint32_t mip, uint32_t l0, uint32_t nl) {
    return im->tex && mip < im->mips && (im->type == VK_IMAGE_TYPE_3D || (nl && (uint64_t)l0 + nl <= im->layers));
}
static int img_box_ok(VkImage im, uint32_t mip, uint32_t l0, uint32_t nl, VkOffset3D o, VkExtent3D e) {
    if (!img_sub_ok(im, mip, l0, nl)) return 0;
    int is3d = im->type == VK_IMAGE_TYPE_3D;
    int64_t W = umax(1, (uint32_t)im->tex.width >> mip), H = umax(1, (uint32_t)im->tex.height >> mip), D = is3d ? umax(1, (uint32_t)im->tex.depth >> mip) : 1, z = is3d ? o.z : 0, dz = is3d ? e.depth : 1;
    return o.x >= 0 && o.y >= 0 && z >= 0 && o.x + (int64_t)e.width <= W && o.y + (int64_t)e.height <= H && z + dz <= D;
}
// 缓冲这一边按 bpr / bpi 排的一块（宽 w、高 h、深 d 个纹素；块压缩按块数）最后一个字节之后的偏移：(d − 1) × bpi + (行块 − 1) × bpr + 列块 × 每块字节
static VkDeviceSize buf_box_bytes(const fmt_t *f, NSUInteger tb, NSUInteger bpr, NSUInteger bpi, uint32_t w, uint32_t h, uint32_t d) {
    if (!w || !h || !d) return 0;
    VkDeviceSize rows = (h + f->bh - 1) / f->bh, cols = (w + f->bw - 1) / f->bw;
    return (VkDeviceSize)(d - 1) * bpi + (rows - 1) * bpr + cols * tb;
}
// vkCmdBlitImage: a copy where nothing is scaled or flipped and the formats match; otherwise a quad per region rendered into the destination level / layer
static void do_blit(rs_t *s, const c_blit *x) {
    VkImage a = x->src, b = x->dst; if (!a || !b || !a->tex || !b->tex) { RED1("vkCmdBlitImage of an image that was not created"); return; }
    for (uint32_t i = 0; i < x->n; i++) {
        const VkImageBlit *r = &x->r[i];
        int32_t sx0 = r->srcOffsets[0].x, sy0 = r->srcOffsets[0].y, sx1 = r->srcOffsets[1].x, sy1 = r->srcOffsets[1].y;
        int32_t dx0 = r->dstOffsets[0].x, dy0 = r->dstOffsets[0].y, dx1 = r->dstOffsets[1].x, dy1 = r->dstOffsets[1].y;
        int32_t sz0 = r->srcOffsets[0].z, sz1 = r->srcOffsets[1].z, dz0 = r->dstOffsets[0].z, dz1 = r->dstOffsets[1].z;
        { static int nlog; if (g_log && nlog < 200 && (a->tex.width != a->w || b->tex.width != b->w)) { nlog++; OLOG("BlitImage %p %ux%u（贴图宽 %lu）[%d,%d) → %p %ux%u（贴图宽 %lu）[%d,%d)", (void *)a, a->w, a->h, (unsigned long)a->tex.width, sx0, sx1,
            (void *)b, b->w, b->h, (unsigned long)b->tex.width, dx0, dx1); } }   // DM_VK_LOG：宽屏合成链定因（10-30 银河2）
        // 宽屏：横向坐标两边各按自己的放宽换算（同 C_COPYI，vk_widen.inc wd_map_span）。10-30 银河2 EFB 按内容判画布放宽后，Blit 进别的目标不换算就只取左边一块。
        //   一边放宽一边没放宽：照样按各自换算（宽场景整幅压进窄目标会横向压缩），报一次红
        { int32_t lo = sx0 < sx1 ? sx0 : sx1; uint32_t w = (uint32_t)(sx0 < sx1 ? sx1 - sx0 : sx0 - sx1), w0 = w; wd_map_span(a, r->srcSubresource.mipLevel, &lo, &w);
          if (sx0 < sx1) { sx0 = lo; sx1 = lo + (int32_t)w; } else { sx1 = lo; sx0 = lo + (int32_t)w; }
          int32_t dl = dx0 < dx1 ? dx0 : dx1; uint32_t dw = (uint32_t)(dx0 < dx1 ? dx1 - dx0 : dx0 - dx1), dw0 = dw; wd_map_span(b, r->dstSubresource.mipLevel, &dl, &dw);
          if (dx0 < dx1) { dx0 = dl; dx1 = dl + (int32_t)dw; } else { dx1 = dl; dx0 = dl + (int32_t)dw; }
          if ((w != w0) != (dw != dw0)) RED1("宽屏：放宽 / 没放宽的图像之间 Blit（源 %u → %u、目标 %u → %u），按各自换算", w0, w, dw0, dw);
          // 纵向同理（窄屏加高，wd_map_span_y）
          int32_t to = sy0 < sy1 ? sy0 : sy1; uint32_t hh = (uint32_t)(sy0 < sy1 ? sy1 - sy0 : sy0 - sy1); wd_map_span_y(a, r->srcSubresource.mipLevel, &to, &hh);
          if (sy0 < sy1) { sy0 = to; sy1 = to + (int32_t)hh; } else { sy1 = to; sy0 = to + (int32_t)hh; }
          int32_t dt = dy0 < dy1 ? dy0 : dy1; uint32_t dh = (uint32_t)(dy0 < dy1 ? dy1 - dy0 : dy0 - dy1); wd_map_span_y(b, r->dstSubresource.mipLevel, &dt, &dh);
          if (dy0 < dy1) { dy0 = dt; dy1 = dt + (int32_t)dh; } else { dy1 = dt; dy0 = dt + (int32_t)dh; } }
        uint32_t nl = umin(r->srcSubresource.layerCount, r->dstSubresource.layerCount);
        if (a->tex.pixelFormat == b->tex.pixelFormat && sx1 - sx0 == dx1 - dx0 && sy1 - sy0 == dy1 - dy0 && sz1 - sz0 == dz1 - dz0 && sx1 > sx0 && sy1 > sy0 && sz1 > sz0) {
            int a3 = a->type == VK_IMAGE_TYPE_3D, b3 = b->type == VK_IMAGE_TYPE_3D;
            uint32_t sm = r->srcSubresource.mipLevel, dm = r->dstSubresource.mipLevel;
            // P1-22：矩形先夹进两边这一级（clamp_span，同 NVN / 通用层剪裁：夹进目标、夹空就跳过），界内的原样整块拷；越出的旧写法把负原点当巨大无符号数交给拷贝编码器
            int64_t x0 = sx0, y0 = sy0, z0 = sz0, X0 = dx0, Y0 = dy0, Z0 = dz0;
            int64_t w = clamp_span(&x0, &X0, sx1 - sx0, umax(1, (uint32_t)a->tex.width >> sm), umax(1, (uint32_t)b->tex.width >> dm));
            int64_t h = clamp_span(&y0, &Y0, sy1 - sy0, umax(1, (uint32_t)a->tex.height >> sm), umax(1, (uint32_t)b->tex.height >> dm));
            int64_t d = clamp_span(&z0, &Z0, sz1 - sz0, a3 ? umax(1, (uint32_t)a->tex.depth >> sm) : 1, b3 ? umax(1, (uint32_t)b->tex.depth >> dm) : 1);
            if (w <= 0 || h <= 0 || d <= 0) continue;
            sx0 = (int32_t)x0; sy0 = (int32_t)y0; sz0 = (int32_t)z0; dx0 = (int32_t)X0; dy0 = (int32_t)Y0; dz0 = (int32_t)Z0;
            sx1 = sx0 + (int32_t)w; sy1 = sy0 + (int32_t)h; sz1 = sz0 + (int32_t)d;
            id<MTLBlitCommandEncoder> be = blit(s, C_BLIT);
            for (uint32_t l = 0; l < nl; l++)
                [be copyFromTexture:a->tex sourceSlice:a3 ? 0 : r->srcSubresource.baseArrayLayer + l sourceLevel:r->srcSubresource.mipLevel sourceOrigin:MTLOriginMake(sx0, sy0, a3 ? sz0 : 0)
                         sourceSize:MTLSizeMake(sx1 - sx0, sy1 - sy0, a3 ? sz1 - sz0 : 1) toTexture:b->tex destinationSlice:b3 ? 0 : r->dstSubresource.baseArrayLayer + l
                   destinationLevel:r->dstSubresource.mipLevel destinationOrigin:MTLOriginMake(dx0, dy0, b3 ? dz0 : 0)];
            g_n_copy++;
            continue;
        }
        if (a->type == VK_IMAGE_TYPE_3D || b->type == VK_IMAGE_TYPE_3D || a->f->kind != K_COLOR || b->f->kind != K_COLOR || a->samples > 1) {
            RED1("vkCmdBlitImage with scaling of format %d → %d (3D, integer, depth or multisampled): not implemented", a->fmt, b->fmt); continue;
        }
        if (!(b->tex.usage & MTLTextureUsageRenderTarget)) { RED1("vkCmdBlitImage into image format %d: Metal cannot render into it", b->fmt); continue; }
        if (!g_blit_pipelines) g_blit_pipelines = [NSMutableDictionary new];
        NSMutableDictionary *cache = g_blit_pipelines;
        id hit = cache[@(b->tex.pixelFormat)]; if (hit == NSNull.null) continue;   // 建失败存 NSNull：同一组合不再每笔重建（11-01）
        id<MTLRenderPipelineState> ps = hit;
        if (!ps) {
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = util_fn("vk_blit_v"); pd.fragmentFunction = util_fn("vk_blit_f");
            pd.colorAttachments[0].pixelFormat = b->tex.pixelFormat; NSError *e = nil;
            ps = pd.vertexFunction ? [g_dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
            if (!ps) { LOG("[vk] 【红】 blit pipeline: %s", e.localizedDescription.UTF8String); cache[@(b->tex.pixelFormat)] = NSNull.null; continue; }
            cache[@(b->tex.pixelFormat)] = ps;
        }
        id<MTLSamplerState> __strong *smp = g_blit_samplers;
        int lin = x->filter == VK_FILTER_LINEAR;
        if (!smp[lin]) { MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = lin ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest; smp[lin] = [g_dev newSamplerStateWithDescriptor:sd]; }
        // destination rectangle with positive size; a flip on either side becomes a reversed source range
        float u0 = sx0, u1 = sx1, v0 = sy0, v1 = sy1;
        if (dx1 < dx0) { int32_t t = dx0; dx0 = dx1; dx1 = t; float f = u0; u0 = u1; u1 = f; }
        if (dy1 < dy0) { int32_t t = dy0; dy0 = dy1; dy1 = t; float f = v0; v0 = v1; v1 = f; }
        uint32_t sw = umax(1, (uint32_t)a->tex.width >> r->srcSubresource.mipLevel), sh = umax(1, (uint32_t)a->tex.height >> r->srcSubresource.mipLevel);
        float uv[4] = {u0 / sw, v0 / sh, u1 / sw, v1 / sh};
        if (s->re) { end_rp(s, 0); s->cut = 1; }
        end_blit(s); end_ce(s);
        for (uint32_t l = 0; l < nl; l++) {
            id<MTLTexture> sv = [a->tex newTextureViewWithPixelFormat:a->tex.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(r->srcSubresource.mipLevel, 1)
                                                               slices:NSMakeRange(r->srcSubresource.baseArrayLayer + l, 1)];
            MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
            d.colorAttachments[0].texture = b->tex; d.colorAttachments[0].level = r->dstSubresource.mipLevel; d.colorAttachments[0].slice = r->dstSubresource.baseArrayLayer + l;
            d.colorAttachments[0].loadAction = MTLLoadActionLoad; d.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = new_re(s, d); if (!re || !sv) { [re endEncoding]; continue; }
            [re setRenderPipelineState:ps]; [re setViewport:(MTLViewport){dx0, dy0, dx1 - dx0, dy1 - dy0, 0, 1}];
            [re setVertexBytes:uv length:sizeof uv atIndex:0]; [re setFragmentTexture:sv atIndex:0]; [re setFragmentSamplerState:smp[lin] atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
            g_render_encoders++; g_n_pass++;
        }
    }
}
// vkCmdResolveImage: a Metal pass over the multisampled level / layer that only resolves into the destination; Metal resolves the whole attachment.
// 只解析一块（P1-22，同 GL 层 glBlitFramebuffer 的解析）：整级解析进同尺寸同格式的单采样暂存，再把这块矩形拷进目标；整级的照旧直接解析进目标
static id<MTLTexture> g_resolve_tmp;   // replay is serialized by g_qmu
// P1-69：renderArea 没盖满帧缓冲时子遍的多重采样解析只作用于区域内（Vulkan 1.1 §7.4）。Metal 的解析存储动作整张写解析附件，所以开遍时不挂解析、多重采样整张存下，
//   这里每一对（同像素格式）先整张解析到临时贴图、再把区域拷进解析附件（同下面 vkCmdResolveImage 的局部解析）；区域按两边各自的宽屏 / 加高换算后夹进两张贴图，夹空跳过
static void part_resolve(rs_t *s) {
    const c_brp *c = s->brp; uint32_t n = s->npres; s->npres = 0;
    if (!c) return;
    VkFramebuffer fb = c->fb; const VkRect2D *ar = &c->area;
    for (uint32_t i = 0; i < n; i++) {
        VkImageView sv = fb->v[s->pres[i][0]], dv = fb->v[s->pres[i][1]]; id<MTLTexture> a = sv->tex, b = dv->tex;
        int32_t sx = ar->offset.x, dx = sx, sy = ar->offset.y, dy = sy; uint32_t sw = ar->extent.width, dw = sw, sh = ar->extent.height, dh = sh;
        if (sv->img) { wd_map_span(sv->img, sv->lv0, &sx, &sw); wd_map_span_y(sv->img, sv->lv0, &sy, &sh); }
        if (dv->img) { wd_map_span(dv->img, dv->lv0, &dx, &dw); wd_map_span_y(dv->img, dv->lv0, &dy, &dh); }
        int64_t x0 = sx, X0 = dx, y0 = sy, Y0 = dy;
        int64_t w = clamp_span(&x0, &X0, umin(sw, dw), (int64_t)a.width, (int64_t)b.width), h = clamp_span(&y0, &Y0, umin(sh, dh), (int64_t)a.height, (int64_t)b.height);
        if (w <= 0 || h <= 0) continue;
        if (!g_resolve_tmp || g_resolve_tmp.width != a.width || g_resolve_tmp.height != a.height || g_resolve_tmp.pixelFormat != a.pixelFormat) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:a.pixelFormat width:a.width height:a.height mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; g_resolve_tmp = [g_dev newTextureWithDescriptor:td];
            if (!g_resolve_tmp) { RED1("renderArea 局部解析：建不出 %lux%lu 临时贴图", (unsigned long)a.width, (unsigned long)a.height); continue; }
        }
        end_blit(s);
        MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor]; MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[0];
        ca.texture = a; ca.loadAction = MTLLoadActionLoad; ca.storeAction = MTLStoreActionStoreAndMultisampleResolve; ca.resolveTexture = g_resolve_tmp;
        id<MTLRenderCommandEncoder> e = new_re(s, d); [e endEncoding];
        if (!e) continue;
        g_render_encoders++; g_n_pass++;
        [blit(s, C_RESOLVE) copyFromTexture:g_resolve_tmp sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)x0, (NSUInteger)y0, 0) sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                  toTexture:b destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake((NSUInteger)X0, (NSUInteger)Y0, 0)];
        g_n_copy++;
    }
    end_blit(s);   // 下一子遍直接开渲染编码器（open_sub 不先收拷贝编码器）
}
static void do_resolve(rs_t *s, const c_resolve *x) {
    VkImage a = x->src, b = x->dst; if (!a || !b || !a->tex || !b->tex) { RED1("vkCmdResolveImage of an image that was not created"); return; }
    if (s->re) { end_rp(s, 0); s->cut = 1; }
    end_blit(s); end_ce(s);
    for (uint32_t i = 0; i < x->n; i++) {
        const VkImageResolve *r = &x->r[i]; uint32_t lw = umax(1, a->w >> r->srcSubresource.mipLevel), lh = umax(1, a->h >> r->srcSubresource.mipLevel);
        uint32_t nl = umin(r->srcSubresource.layerCount, r->dstSubresource.layerCount);
        int part = r->srcOffset.x || r->srcOffset.y || r->dstOffset.x || r->dstOffset.y || r->extent.width < lw || r->extent.height < lh;
        end_blit(s);   // 上一块局部解析留下的拷贝编码器
        if (part && a->tex.pixelFormat == b->tex.pixelFormat && a->f->kind == K_COLOR) {
            uint32_t sm = r->srcSubresource.mipLevel, dm = r->dstSubresource.mipLevel;
            NSUInteger tw = umax(1, (uint32_t)a->tex.width >> sm), th = umax(1, (uint32_t)a->tex.height >> sm);
            int32_t sx = r->srcOffset.x, dx = r->dstOffset.x; uint32_t sw = r->extent.width, dw = r->extent.width;   // 宽屏：横向两边各按自己的放宽换算（同 C_COPYI）
            wd_map_span(a, sm, &sx, &sw); wd_map_span(b, dm, &dx, &dw);
            int32_t sy = r->srcOffset.y, dy = r->dstOffset.y; uint32_t sh = r->extent.height, dh = r->extent.height; wd_map_span_y(a, sm, &sy, &sh); wd_map_span_y(b, dm, &dy, &dh);   // 纵向同理（窄屏加高）
            int64_t x0 = sx, X0 = dx, y0 = sy, Y0 = dy;
            int64_t w = clamp_span(&x0, &X0, umin(sw, dw), (int64_t)tw, umax(1, (uint32_t)b->tex.width >> dm));
            int64_t h = clamp_span(&y0, &Y0, umin(sh, dh), (int64_t)th, umax(1, (uint32_t)b->tex.height >> dm));
            if (w <= 0 || h <= 0 || !nl) continue;
            if (!g_resolve_tmp || g_resolve_tmp.width != tw || g_resolve_tmp.height != th || g_resolve_tmp.pixelFormat != a->tex.pixelFormat) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:a->tex.pixelFormat width:tw height:th mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; g_resolve_tmp = [g_dev newTextureWithDescriptor:td];
                if (!g_resolve_tmp) { RED1("vkCmdResolveImage: cannot allocate the %lux%lu scratch texture", (unsigned long)tw, (unsigned long)th); continue; }
            }
            for (uint32_t l = 0; l < nl; l++) {
                end_blit(s);
                MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor]; MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[0];
                ca.texture = a->tex; ca.level = sm; ca.slice = r->srcSubresource.baseArrayLayer + l; ca.loadAction = MTLLoadActionLoad;
                ca.storeAction = MTLStoreActionStoreAndMultisampleResolve; ca.resolveTexture = g_resolve_tmp;
                id<MTLRenderCommandEncoder> e = new_re(s, d); [e endEncoding];
                if (!e) continue;
                g_render_encoders++; g_n_pass++;
                [blit(s, C_RESOLVE) copyFromTexture:g_resolve_tmp sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)x0, (NSUInteger)y0, 0) sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                          toTexture:b->tex destinationSlice:r->dstSubresource.baseArrayLayer + l destinationLevel:dm destinationOrigin:MTLOriginMake((NSUInteger)X0, (NSUInteger)Y0, 0)];
                g_n_copy++;
            }
            continue;
        }
        if (part) RED1("vkCmdResolveImage of part of an image between formats %d → %d (or not a float colour format): Metal resolves the whole level (%ux%u of %ux%u)", a->fmt, b->fmt, r->extent.width, r->extent.height, lw, lh);
        for (uint32_t l = 0; l < nl; l++) {
            MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor]; MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[0];
            ca.texture = a->tex; ca.level = r->srcSubresource.mipLevel; ca.slice = r->srcSubresource.baseArrayLayer + l; ca.loadAction = MTLLoadActionLoad;
            ca.storeAction = MTLStoreActionStoreAndMultisampleResolve; ca.resolveTexture = b->tex; ca.resolveLevel = r->dstSubresource.mipLevel; ca.resolveSlice = r->dstSubresource.baseArrayLayer + l;
            id<MTLRenderCommandEncoder> e = new_re(s, d); [e endEncoding];
            if (e) { g_render_encoders++; g_n_pass++; }
        }
    }
}
// vkCmdCopyQueryPoolResults: on the GPU, in command order. A query a finished submit wrote has its value on the host; one written earlier in this submit counts its
// visibility slots (already copied to the submit's results at the end of their passes); a timestamp of this submit is known only when the submit completes
static void do_qcopy(rs_t *s, const c_qcopy *x) {
    VkQueryPool q = x->q; VkBuffer b = x->dst; if (!b || !b->mem || !x->n) { if (x->n) RED1("vkCmdCopyQueryPoolResults: the buffer has no bound memory"); return; }
    id<MTLComputePipelineState> ps = util_kernel("vk_qcopy"); if (!ps) return;
    typedef struct { uint64_t cpu; uint32_t avail, nslot, first, pad; } qin;
    NSUInteger qo = stage_take(s, x->n * sizeof(qin)), so = stage_take(s, (s->sq->cap ? s->sq->cap : 1) * 4 * x->n);
    qin *qi = (qin *)((uint8_t *)s->sq->stage.contents + qo); uint32_t *slots = (uint32_t *)((uint8_t *)s->sq->stage.contents + so), ns = 0;
    for (uint32_t i = 0; i < x->n; i++) {
        uint32_t k = x->first + i; qin *o = &qi[i]; memset(o, 0, sizeof *o); o->first = ns;
        if (k >= q->n) continue;
        uint64_t t = q->ticket[k];
        if (t == s->sq->v) {
            if (q->type == VK_QUERY_TYPE_OCCLUSION) { for (uint32_t j = 0; j < s->sq->nvis; j++) if (s->sq->occ[j].q == q && s->sq->occ[j].idx == k) { slots[ns++] = s->sq->occ[j].slot; o->nslot++; } o->avail = 1; }
            else RED1("vkCmdCopyQueryPoolResults of a timestamp written in the same submit: its value is known only when the submit completes");
            continue;
        }
        if (t == FENCE_NONE) continue;   // reset or never written: unavailable
        if (atomic_load(&g_done) < t && (x->fl & VK_QUERY_RESULT_WAIT_BIT)) wait_done(t);   // an earlier submit: its completion does not need the queue lock
        if (atomic_load(&g_done) >= t) { o->avail = 1; o->cpu = q->type == VK_QUERY_TYPE_TIMESTAMP ? g_done_ns[t % DONE_RING] : q->val[k]; }
    }
    struct { uint64_t stride; uint32_t flags, n; } par = {x->stride, (x->fl & VK_QUERY_RESULT_64_BIT ? 1u : 0) | (x->fl & VK_QUERY_RESULT_WITH_AVAILABILITY_BIT ? 2u : 0) | (x->fl & VK_QUERY_RESULT_PARTIAL_BIT ? 4u : 0), x->n};
    if (!g_query_none) g_query_none = [g_dev newBufferWithLength:16 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> none = g_query_none;
    id<MTLComputeCommandEncoder> ce = cenc(s);
    [ce setBuffer:s->sq->stage offset:qo atIndex:0]; [ce setBuffer:s->sq->stage offset:so atIndex:1]; [ce setBuffer:s->sq->results ? s->sq->results : none offset:0 atIndex:2];
    [ce setBuffer:mem_buf(b->mem) offset:(NSUInteger)(b->off + x->off) atIndex:3]; [ce setBytes:&par length:sizeof par atIndex:4];
    dispatch1d(ce, ps, x->n);
}
static int pre_dispatch(rs_t *s) {
    VkPipeline p = s->cpipe;
    if (p && !p->cps && p->pend_c) cpipe_finish(p);   // 等现编的计算管线：编好了就在这里补建
    if (!p || !p->cps) { if (p && p->feat) g_bad_feat++; else g_bad_err++; RED1("dispatch without a usable compute pipeline"); return 0; }
    id<MTLComputeCommandEncoder> ce = cenc(s); if (!ce) return 0;
    float se_tb[31][4]; id<MTLComputePipelineState> se_ps = vk_se_table(s, p->cs, 2, se_tb) ? vk_se_obj(p, 1) : nil;   // #800：偏置模拟版（同 pre_draw）
    [ce setComputePipelineState:se_ps ? se_ps : p->cps]; bind_res(s, p->cs, 2); bind_push(s, p->cs, 2); s->sw = 1;
    if (se_ps) [ce setBytes:se_tb length:sizeof se_tb atIndex:(NSUInteger)p->se_slot];
    return 1;
}
static void do_dispatch(rs_t *s, const c_dispatch *x) {
    if (x->bx || x->by || x->bz) { RED1("vkCmdDispatchBase with a base workgroup (%u, %u, %u): not implemented", x->bx, x->by, x->bz); return; }
    if (!x->x || !x->y || !x->z || !pre_dispatch(s)) return;
    const uint16_t *w = s->cpipe->cs->wg;
    [s->ce dispatchThreadgroups:MTLSizeMake(x->x, x->y, x->z) threadsPerThreadgroup:MTLSizeMake(w[0], w[1], w[2])];
}
static void do_dispatchi(rs_t *s, const c_dispatchi *x) {
    if (!x->b || !x->b->mem) { RED1("vkCmdDispatchIndirect: the buffer has no bound memory"); return; }
    if (!pre_dispatch(s)) return;
    const uint16_t *w = s->cpipe->cs->wg;
    [s->ce dispatchThreadgroupsWithIndirectBuffer:mem_buf(x->b->mem) indirectBufferOffset:(NSUInteger)(x->b->off + x->off) threadsPerThreadgroup:MTLSizeMake(w[0], w[1], w[2])];
}
static void next_subpass(rs_t *s) {
    if (!s->brp) { RED1("vkCmdNextSubpass outside a render pass"); return; }
    if (s->re) end_rp(s, 1); else if (s->cut) { resume_rp(s); end_rp(s, 1); }
    s->cut = 0;
    if (s->sub + 1 >= ((const c_brp *)s->brp)->rp->nsub) { RED1("vkCmdNextSubpass past the last subpass"); return; }
    s->sub++; open_sub(s);
}
