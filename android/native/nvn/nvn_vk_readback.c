// NVN ReadTexels（纹理读回）：按内容归属选 guest 内存或 GPU 图像两条路径。
//
// 为什么不是“一律 GPU 读回”：CPU 填写过的纹理，其事实来源是 guest 池里的块线性存储；把它先
// 上传成图像再读回来既多一次上传，也会在图像是转换格式（BC compute 解码）时给出错误的字节。
// 王国之泪启动期（渲染 114 帧后）在 nx-120 线程读回的正是这种“CPU 刚填好、还没被 draw 用过”的
// BC4 材质贴图，所以 guest 路径是它能过关的那条。GPU 写过的纹理（渲染目标 / clear / B2T 拷贝）
// 则以图像为事实来源：先要完成证明，再从图像按区域拷回。
#include "nvn_vk_readback.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include "nvn_vk_session.h"
#include "nvn_vk_format.h"
#include "nvn_vk_first_draw.h"
#include "nvn_vk_readback_plan.h"
#include "nvn_deswizzle.h"
#include "nvn_tex.h"

// 读回是罕见路径（启动期 / 截图），但逐笔日志不能无界：前 16 笔 + 之后每 1024 笔一条。
static void rb_log(const tex_t *t, unsigned level, unsigned layer0, const NVNcopyRegion *r,
                   size_t row, size_t img, const char *path, const char *extra) {
    static unsigned n;
    const unsigned seq = __atomic_fetch_add(&n, 1, __ATOMIC_RELAXED);
    if (seq >= 16 && (seq & 1023u)) return;
    __android_log_print(ANDROID_LOG_INFO, "S2Arm",
        "read texels #%u: ser=%llu fmt=0x%x tgt=%d %ux%ux%u lv=%u levels=%u layer=%u region=%d,%d,%d %dx%dx%d "
        "row=%zu img=%zu via=%s %s",
        seq, (unsigned long long)(t ? t->serial : 0), t ? t->d.format : 0, t ? t->d.target : 0,
        t ? t->d.width : 0, t ? t->d.height : 0, t ? t->d.depth : 0,
        level, t ? t->d.levels : 0, layer0,
        r ? r->xoffset : 0, r ? r->yoffset : 0, r ? r->zoffset : 0,
        r ? r->width : 0, r ? r->height : 0, r ? r->depth : 0,
        row, img, path, extra ? extra : "");
}

// 失败原因统一带上可定位上下文：serial / 尺寸 / 格式 / level / layer / 区域。
static int rb_fail(char *why, size_t why_size, const tex_t *t, unsigned level, unsigned layer0,
                   const NVNcopyRegion *r, const char *fmt, ...) {
    if (!why || !why_size) return -1;
    char detail[192] = "";
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(detail, sizeof detail, fmt, ap);
    va_end(ap);
    snprintf(why, why_size,
             "readback failed: %s | ser=%llu fmt=0x%x tgt=%d %ux%ux%u lv=%u/%u layer=%u region=%d,%d,%d %dx%dx%d",
             detail, (unsigned long long)(t ? t->serial : 0), t ? t->d.format : 0, t ? t->d.target : 0,
             t ? t->d.width : 0, t ? t->d.height : 0, t ? t->d.depth : 0, level,
             t ? (t->d.levels ? t->d.levels : 1u) : 0, layer0,
             r ? r->xoffset : 0, r ? r->yoffset : 0, r ? r->zoffset : 0,
             r ? r->width : 0, r ? r->height : 0, r ? r->depth : 0);
    return -1;
}

static int rb_mul(size_t a, size_t b, size_t *out) {
    if (a && b > SIZE_MAX / a) return -1;
    *out = a * b;
    return 0;
}

// ---- 内容归 CPU：按 NVN 块线性存储 deswizzle 后按行距/层距打包 ------------------------
static int rb_read_guest(const tex_t *t, const struct nvn_vk_rb_plan *p, uint8_t *dst,
                         char *why, size_t why_size) {
    const nvn_texdesc *d = &t->d;
    const uint32_t bw = (uint32_t)p->bw, bh = (uint32_t)p->bh, bpb = (uint32_t)p->bpb;
    const uint32_t lw = p->level_w, lh = p->level_h, ld = p->level_d;
    const uint32_t lp = (lw + bw - 1u) / bw * bpb;   // 该 level 的一行字节数（块行）
    const uint32_t lr = (lh + bh - 1u) / bh;         // 该 level 的块行数
    const uint32_t x0 = (p->x / bw) * bpb;
    const uint32_t y0 = p->y / bh;
    const uint32_t wb = p->copy_row_bytes;
    const int linear = (d->flags & (0x10 | 0x40)) != 0;   // LINEAR / LINEAR_RENDER_TARGET

    if (linear) {
        // 线性纹理的行主序存储：没有块线性反混淆，按 stride 逐行取（与上传路径同口径）。
        if (p->is3d) return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                                    "3D LINEAR texture has no per-slice linear storage in the NVN layout");
        if (p->level != 0) return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                                          "LINEAR texture level %u has no per-level storage offset", p->level);
        const uint32_t align = (d->flags & 0x40) ? 128u : 32u;
        uint32_t pitch = d->stride ? d->stride : (lp + align - 1u) & ~(align - 1u);
        if (pitch < lp) return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                                       "LINEAR texture stride %u B is smaller than the level row %u B", pitch, lp);
        for (uint32_t z = 0; z < p->nz; z++) {
            size_t layer_off = 0;
            if (rb_mul((size_t)(p->layer0 + p->z + z), (size_t)t->L.layer_size, &layer_off))
                return rb_fail(why, why_size, t, p->level, p->layer0, NULL, "linear layer offset overflows size_t");
            const uint8_t *base = t->mem + layer_off;
            for (uint32_t y = 0; y < p->block_rows; y++) {
                const size_t off = (size_t)(y0 + y) * pitch + x0;
                if (layer_off + off + wb > t->L.size)
                    return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                                   "linear readback row %u + %u B runs past the texture storage (%llu B)",
                                   y0 + y, wb, (unsigned long long)t->L.size);
                memcpy(dst + z * p->dst_img + (size_t)y * p->dst_row, base + off, wb);
            }
        }
        return 0;
    }

    // 块线性：deswizzle 到该 level 的紧凑线性布局，再按区域取块行。
    size_t lin_bytes = 0;
    if (p->is3d) {
        if (rb_mul((size_t)lp * lr, ld, &lin_bytes)) {
            return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                           "3D level linear buffer overflows size_t (row %u x %u rows x %u slices)", lp, lr, ld);
        }
    } else if (rb_mul((size_t)lp, lr, &lin_bytes)) {
        return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                       "level linear buffer overflows size_t (row %u x %u rows)", lp, lr);
    }
    uint8_t *lin = (uint8_t *)malloc(lin_bytes ? lin_bytes : 1);
    if (!lin) {
        return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                       "cannot allocate %llu B to deswizzle level %u (guest-memory readback path)",
                       (unsigned long long)lin_bytes, p->level);
    }
    int rc = 0;
    if (p->is3d) {
        // nvn_deswizzle 对 3D 一次解码该 level 的全部 depth 切片：切片 k 在 k*row*rows 处。
        if (nvn_deswizzle(d, p->level, 0, t->mem, lin, lp)) {
            free(lin);
            return rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                           "nvn_deswizzle failed for 3D level %u (format 0x%x, %ux%ux%u, storage %llu B)",
                           p->level, d->format, lw, lh, ld, (unsigned long long)t->L.size);
        }
        const size_t slice = (size_t)lp * lr;
        for (uint32_t z = 0; z < p->nz; z++) {
            const uint8_t *src = lin + (size_t)(p->z + z) * slice;
            for (uint32_t y = 0; y < p->block_rows; y++)
                memcpy(dst + z * p->dst_img + (size_t)y * p->dst_row,
                       src + (size_t)(y0 + y) * lp + x0, wb);
        }
    } else {
        for (uint32_t z = 0; z < p->nz; z++) {
            const uint32_t layer = p->layer0 + p->z + z;
            if (nvn_deswizzle(d, p->level, layer, t->mem, lin, lp)) {
                rc = rb_fail(why, why_size, t, p->level, p->layer0, NULL,
                             "nvn_deswizzle failed for level %u layer %u (format 0x%x, %ux%u, storage %llu B, "
                             "layer_size %llu B)", p->level, layer, d->format, lw, lh,
                             (unsigned long long)t->L.size, (unsigned long long)t->L.layer_size);
                break;
            }
            for (uint32_t y = 0; y < p->block_rows; y++)
                memcpy(dst + z * p->dst_img + (size_t)y * p->dst_row,
                       lin + (size_t)(y0 + y) * lp + x0, wb);
        }
    }
    free(lin);
    return rc;
}

// ---- 会话入口 -----------------------------------------------------------------
int nvn_vk_session_read_texels(struct nvn_vk_session *s, const tex_t *t, unsigned level, unsigned layer0,
                               const NVNcopyRegion *r, uint8_t *dst, size_t row, size_t img,
                               char *why, size_t why_size) {
    if (why && why_size) why[0] = 0;
    if (!s || !s->ready) return rb_fail(why, why_size, t, level, layer0, r, "session not ready");
    if (!t) return rb_fail(why, why_size, NULL, level, layer0, r, "null texture object");
    if (!r) return rb_fail(why, why_size, t, level, layer0, NULL, "null copy region");
    if (!dst) return rb_fail(why, why_size, t, level, layer0, r, "null destination pointer");
    if (!t->mem) return rb_fail(why, why_size, t, level, layer0, r,
                                "texture has no CPU storage (pool memory missing) and no GPU image to read");
    if (t->d.samples > 1) {
        return rb_fail(why, why_size, t, level, layer0, r,
                       "multisampled texture (samples=%d) readback is not bridged (needs a resolve path)",
                       t->d.samples);
    }

    int bw = 1, bh = 1;
    const int bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    struct nvn_vk_rb_desc desc;
    memset(&desc, 0, sizeof desc);
    desc.nvn_format = (uint32_t)t->d.format;
    desc.target = t->d.target;
    desc.bpb = bpb; desc.bw = bw; desc.bh = bh;
    desc.flags = (uint32_t)t->d.flags;
    desc.width = t->d.width; desc.height = t->d.height; desc.depth = t->d.depth;
    desc.levels = t->d.levels;
    desc.layers = (uint32_t)(t->L.layers ? t->L.layers : 1u);

    struct nvn_vk_rb_region region;
    region.x = r->xoffset; region.y = r->yoffset; region.z = r->zoffset;
    region.width = r->width; region.height = r->height; region.depth = r->depth;

    struct nvn_vk_rb_plan plan;
    char pwhy[NVN_VK_RB_WHY_MAX] = "";
    if (nvn_vk_readback_plan(&desc, level, layer0, &region, row, img, &plan, pwhy, sizeof pwhy))
        return rb_fail(why, why_size, t, level, layer0, r, "%s", pwhy[0] ? pwhy : "readback plan failed");

    // 批 A：按本次请求覆盖的子资源（level + layer0..layer0+nz-1）判定内容归属，而不是整图 gpu_written。
    // 全部 CPU 子资源 → 直接读 guest；否则先把待合并的 CPU 更新落到图像、再按完成证明读图像。
    // 读图像不写回 guest、不改子资源状态（dst ≠ guest 池已同步）。
    const unsigned rb_layers = (unsigned)(plan.nz ? plan.nz : 1u);
    const int guest_ok = nvn_vk_texcache_read_guest_ok(&s->textures, t->serial, level, layer0, rb_layers);
    if (guest_ok) {
        rb_log(t, level, layer0, r, plan.dst_row, plan.dst_img, "guest-memory",
               (t->has_layout ? "(packaged layout; subresources all CPU)" : "(CPU-written; subresources all CPU)"));
        int rc = rb_read_guest(t, &plan, dst, why, why_size);
        if (rc) rb_log(t, level, layer0, r, plan.dst_row, plan.dst_img, "guest-memory", "FAILED");
        return rc;
    }

    // 内容归 GPU：先要帧队列的完成证明（已提交/已录制的 GPU 工作全部完成后）再拷图像。
    // 这里不绕过帧队列：pass_break(1) 会封口未提交前缀并按队列顺序等完成，失败即如实失败。
    if (nvn_vk_first_draw_pass_break(1) != 0) {
        const char *first = nvn_vk_first_draw_first_error();
        return rb_fail(why, why_size, t, level, layer0, r,
                       "GPU content readback has no completion proof for earlier GPU work: %s",
                       first && first[0] ? first : "frame queue did not complete");
    }
    char twhy[192] = "";
    struct nvn_vk_tex *tx = nvn_vk_session_tex(s, t, twhy, sizeof twhy);
    if (!tx || !tx->image)
        return rb_fail(why, why_size, t, level, layer0, r, "GPU image not resolvable: %s",
                       twhy[0] ? twhy : "texture cache returned no image");
    {
        char extra[224];
        snprintf(extra, sizeof extra, "(image fmt=%d vk_format=0x%x nvn=0x%x; subresources level=%u layer=%u..%u not all CPU)",
                 (int)tx->vk_format, (unsigned)tx->vk_format, (unsigned)tx->nvn_format,
                 level, layer0, layer0 + rb_layers - 1);
        rb_log(t, level, layer0, r, plan.dst_row, plan.dst_img, "gpu-image", extra);
    }
    int rc = nvn_vk_readback_gpu(&s->device, tx, &plan, dst, why, why_size);
    if (rc) rb_log(t, level, layer0, r, plan.dst_row, plan.dst_img, "gpu-image", "FAILED");
    return rc;
}

void nvn_vk_session_read_texels_release(struct nvn_vk_session *s) {
    if (!s) return;
    nvn_vk_readback_gpu_release(&s->device);
}
