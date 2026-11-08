// S2RF 记录格式的读写与逐字节比对实现（见 rfx.h / FORMAT.md）。
#include "rfx.h"

#include <stdlib.h>
#include <string.h>

// ---------- 小端写 ----------

typedef struct { uint8_t *p; uint32_t len, cap; int err; } rfx_buf;
static void bx(rfx_buf *b, const void *p, uint32_t n) {
    if (b->err) return;
    if (b->len + n > b->cap) {
        uint32_t c = (b->len + n) * 2 + 64;
        uint8_t *q = realloc(b->p, c);
        if (!q) { b->err = 1; return; }
        b->p = q; b->cap = c;
    }
    memcpy(b->p + b->len, p, n); b->len += n;
}
static void b8(rfx_buf *b, uint8_t v) { bx(b, &v, 1); }
static void b16(rfx_buf *b, uint16_t v) { bx(b, &v, 2); }
static void b32(rfx_buf *b, uint32_t v) { bx(b, &v, 4); }
static void b64(rfx_buf *b, uint64_t v) { bx(b, &v, 8); }
static void bstr(rfx_buf *b, const char *s, uint32_t n) { b16(b, (uint16_t)n); if (n) bx(b, s, n); }

// ---------- 写文件 ----------

struct rfx_w { FILE *f; int err; };

rfx_w *rfx_w_open(const char *path, uint32_t kind) {
    FILE *f = fopen(path, "wb");
    if (!f) return NULL;
    rfx_w *w = calloc(1, sizeof *w);
    w->f = f;
    uint32_t h[4] = {RFX_MAGIC, RFX_VERSION, kind, 0};
    if (fwrite(h, 4, 4, f) != 4) w->err = 1;
    return w;
}

int rfx_w_raw(rfx_w *w, uint32_t tag, const void *payload, uint32_t len) {
    if (!w || w->err) return -1;
    uint32_t h[2] = {tag, len};
    if (fwrite(h, 4, 2, w->f) != 2) return w->err = 1, -1;
    if (len && fwrite(payload, 1, len, w->f) != len) return w->err = 1, -1;
    return 0;
}

int rfx_w_region(rfx_w *w, uint64_t addr, uint64_t len, uint64_t prot) {
    uint64_t p[3] = {addr, len, prot};
    return rfx_w_raw(w, RFX_REC_REGION, p, sizeof p);
}

int rfx_w_data(rfx_w *w, uint64_t addr, const void *bytes, uint64_t len) {
    if (len > UINT32_MAX - 16) return -1;
    rfx_buf b = {0};
    b64(&b, addr); b64(&b, len); bx(&b, bytes, (uint32_t)len);
    int r = b.err ? -1 : rfx_w_raw(w, RFX_REC_DATA, b.p, b.len);
    free(b.p);
    return r;
}

int rfx_w_res(rfx_w *w, uint32_t rkind, const char *name, const void *payload, uint32_t len) {
    rfx_buf b = {0};
    b32(&b, rkind);
    bstr(&b, name, name ? (uint32_t)strlen(name) : 0);
    if (len) bx(&b, payload, len);
    int r = b.err ? -1 : rfx_w_raw(w, RFX_REC_RES, b.p, b.len);
    free(b.p);
    return r;
}

int rfx_w_call(rfx_w *w, uint32_t func, uint64_t ret, const void *payload, uint32_t len) {
    rfx_buf b = {0};
    b32(&b, func); b64(&b, ret);
    if (len) bx(&b, payload, len);
    int r = b.err ? -1 : rfx_w_raw(w, RFX_REC_CALL, b.p, b.len);
    free(b.p);
    return r;
}

int rfx_w_exp(rfx_w *w, uint32_t func, const void *payload, uint32_t len) {
    rfx_buf b = {0};
    b32(&b, func);
    if (len) bx(&b, payload, len);
    int r = b.err ? -1 : rfx_w_raw(w, RFX_REC_EXP, b.p, b.len);
    free(b.p);
    return r;
}

int rfx_w_chk(rfx_w *w, uint32_t ckind, const void *payload, uint32_t len) {
    rfx_buf b = {0};
    b32(&b, ckind);
    if (len) bx(&b, payload, len);
    int r = b.err ? -1 : rfx_w_raw(w, RFX_REC_CHK, b.p, b.len);
    free(b.p);
    return r;
}

int rfx_w_end(rfx_w *w) { return rfx_w_raw(w, RFX_REC_END, NULL, 0); }

int rfx_w_close(rfx_w *w) {
    if (!w) return -1;
    int r = w->err || fclose(w->f);
    free(w);
    return r;
}

// ---------- CALL 逐函数助手 ----------

int rfx_call_u32(rfx_w *w, uint32_t func, uint64_t ret, uint32_t a) {
    return rfx_w_call(w, func, ret, &a, 4);
}
int rfx_call_u64(rfx_w *w, uint32_t func, uint64_t ret, uint64_t a) {
    return rfx_w_call(w, func, ret, &a, 8);
}
int rfx_call_none(rfx_w *w, uint32_t func, uint64_t ret) {
    return rfx_w_call(w, func, ret, NULL, 0);
}
int rfx_call_sub_index(rfx_w *w, uint32_t func, const uint64_t *h, uint32_t n) {
    rfx_buf b = {0};
    b32(&b, n); if (n) bx(&b, h, n * 8);
    int r = b.err ? -1 : rfx_w_call(w, func, 0, b.p, b.len);
    free(b.p);
    return r;
}
int rfx_call_reg_tex(rfx_w *w, int32_t id, uint64_t tex, const uint8_t view16[16]) {
    rfx_buf b = {0};
    b32(&b, (uint32_t)id); b64(&b, tex); b8(&b, view16 != NULL); if (view16) bx(&b, view16, 16);
    int r = b.err ? -1 : rfx_w_call(w, RFX_BE_REG_TEX, 0, b.p, b.len);
    free(b.p);
    return r;
}
int rfx_call_reg_samp(rfx_w *w, int32_t id, const uint8_t samp_par[40]) {
    rfx_buf b = {0};
    b32(&b, (uint32_t)id); bx(&b, samp_par, 40);
    int r = b.err ? -1 : rfx_w_call(w, RFX_BE_REG_SAMP, 0, b.p, b.len);
    free(b.p);
    return r;
}
int rfx_call_present(rfx_w *w, uint64_t tex, double period_s, const int32_t crop[4], uint64_t ticket) {
    rfx_buf b = {0};
    union { double d; uint64_t u; } ps = {.d = period_s};
    b64(&b, tex); b64(&b, ps.u);
    b8(&b, crop != NULL); if (crop) bx(&b, crop, 16);
    int r = b.err ? -1 : rfx_w_call(w, RFX_BE_PRESENT, ticket, b.p, b.len);
    free(b.p);
    return r;
}
int rfx_call_read_texels(rfx_w *w, uint64_t tex, uint32_t level, uint32_t layer0,
                         const int32_t region[6], uint64_t dst, uint64_t row, uint64_t img) {
    rfx_buf b = {0};
    b64(&b, tex); b32(&b, level); b32(&b, layer0); bx(&b, region, 24); b64(&b, dst); b64(&b, row); b64(&b, img);
    int r = b.err ? -1 : rfx_w_call(w, RFX_BE_READ_TEXELS, 0, b.p, b.len);
    free(b.p);
    return r;
}

// ---------- 读 ----------

int rfx_r_open(rfx_r *r, const char *path) {
    memset(r, 0, sizeof *r);
    FILE *f = fopen(path, "rb");
    if (!f) { r->err = 1; return -1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n < 0 || (r->buf = malloc((size_t)n + 1)) == NULL) { fclose(f); r->err = 1; return -1; }
    r->size = (uint64_t)n;
    int ok = fread(r->buf, 1, (size_t)n, f) == (size_t)n;
    fclose(f);
    if (!ok || r->size < 16) { r->err = 1; return -1; }
    uint32_t mg, ver, kind;
    memcpy(&mg, r->buf, 4); memcpy(&ver, r->buf + 4, 4); memcpy(&kind, r->buf + 8, 4);
    if (mg != RFX_MAGIC || ver != RFX_VERSION) { r->err = 1; return -1; }
    r->version = ver; r->kind = kind; r->pos = 16;
    return 0;
}

int rfx_r_next(rfx_r *r, rfx_rec *out) {
    if (r->err || r->pos + 8 > r->size) return -1;
    uint32_t tag, len;
    memcpy(&tag, r->buf + r->pos, 4); memcpy(&len, r->buf + r->pos + 4, 4);
    if (r->pos + 8 + len > r->size) return -1;
    out->tag = tag; out->off = r->pos;
    out->payload = r->buf + r->pos + 8;
    out->len = len;
    r->pos += 8 + len;
    out->id = 0;
    if ((tag == RFX_REC_RES || tag == RFX_REC_CALL || tag == RFX_REC_EXP || tag == RFX_REC_CHK) && len >= 4)
        memcpy(&out->id, out->payload, 4);
    return tag == RFX_REC_END ? 0 : 1;
}

void rfx_r_close(rfx_r *r) { free(r->buf); memset(r, 0, sizeof *r); }

int rfx_r_validate_kind(const rfx_r *r) {
    rfx_r t = *r; rfx_rec rec;
    t.pos = 16;
    while (rfx_r_next(&t, &rec) == 1) {
        int ok;
        switch (r->kind) {
            case RFX_KIND_IN:
                ok = rec.tag == RFX_REC_REGION || rec.tag == RFX_REC_DATA ||
                     rec.tag == RFX_REC_RES || rec.tag == RFX_REC_CALL;
                break;
            case RFX_KIND_EXP:
                ok = rec.tag == RFX_REC_ASSUME || rec.tag == RFX_REC_EXP || rec.tag == RFX_REC_CHK;
                break;
            default: ok = 0;
        }
        if (!ok) return -1;
    }
    return t.err ? -1 : 0;
}

// ---------- 比对 ----------

// 把一条记录流读成数组（按需过滤 EXP/CHK 之外不挑 —— 期望文件本就只有 ASSUME/EXP/CHK）。
typedef struct { uint64_t off; uint32_t tag, id, len; const uint8_t *p; } seq_rec;
typedef struct { seq_rec *v; uint32_t n, cap; const uint8_t *base; } seq_t;

static int seq_push(seq_t *s, const rfx_rec *r) {
    if (s->n == s->cap) {
        uint32_t c = s->cap ? s->cap * 2 : 64;
        seq_rec *q = realloc(s->v, c * sizeof *q);
        if (!q) return -1;
        s->v = q; s->cap = c;
    }
    s->v[s->n++] = (seq_rec){r->off, r->tag, r->id, r->len, r->payload};
    return 0;
}

static int seq_load(const char *path, const uint32_t *funcs, uint32_t nfuncs, seq_t *s, char *err, size_t esz) {
    rfx_r r;
    memset(s, 0, sizeof *s);
    if (rfx_r_open(&r, path)) { snprintf(err, esz, "打不开或头不合法：%s", path); return -1; }
    rfx_rec rec;
    int st;
    while ((st = rfx_r_next(&r, &rec)) == 1) {
        // CHK 是给回放线束的断言（回调载荷 / 读回内容），打点记录器不产出它——比对只覆盖 ASSUME+EXP
        if (rec.tag == RFX_REC_CHK) continue;
        if (funcs && rec.tag == RFX_REC_EXP) {
            uint32_t i;
            for (i = 0; i < nfuncs && rec.id != funcs[i]; i++);
            if (i == nfuncs) continue;
        }
        if (seq_push(s, &rec)) { rfx_r_close(&r); snprintf(err, esz, "内存不足"); return -1; }
    }
    if (st < 0) { rfx_r_close(&r); snprintf(err, esz, "%s 在 %#llx 处截断 / 坏格式", path, (unsigned long long)r.pos); return -1; }
    s->base = r.buf;   // r 不 close：buf 的所有权随 seq 交出，调用方负责 free(s->base)
    return 0;
}

static const char *rec_name(uint32_t tag, uint32_t id) {
    switch (tag) {
        case RFX_REC_EXP: return rfx_gpu_name(id);
        case RFX_REC_CHK: return rfx_chk_name(id);
        case RFX_REC_CALL: return rfx_call_name(id);
        case RFX_REC_RES: return rfx_res_name(id);
        default: return rfx_tag_name(tag);
    }
}

int rfx_cmp_file(const char *exp_path, const char *act_path,
                 const uint32_t *funcs, uint32_t nfuncs, rfx_diff *d) {
    seq_t e = {0}, a = {0};
    char err[192];
    if (seq_load(exp_path, funcs, nfuncs, &e, err, sizeof err)) goto bad;
    if (seq_load(act_path, funcs, nfuncs, &a, err, sizeof err)) goto bad;
    uint32_t n = e.n < a.n ? e.n : a.n;
    for (uint32_t i = 0; i < n; i++) {
        const seq_rec *x = &e.v[i], *y = &a.v[i];
        uint32_t xl = 8 + x->len, yl = 8 + y->len;
        uint32_t m = xl < yl ? xl : yl;
        const uint8_t *xp = x->p - 8, *yp = y->p - 8;   // 含 tag+len 头一起比
        for (uint32_t k = 0; k < m; k++) {
            if (xp[k] != yp[k]) {
                d->index = i; d->tag = x->tag; d->id = x->id;
                d->file_off = x->off + k; d->act_off = y->off + k;
                d->exp_b = xp[k]; d->act_b = yp[k];
                snprintf(d->msg, sizeof d->msg, "第 %u 条记录（%s）偏移 %#llx：期望 %#02x 实际 %#02x",
                         i, rec_name(x->tag, x->id), (unsigned long long)d->file_off, d->exp_b, d->act_b);
                goto diff;
            }
        }
        if (xl != yl) {
            d->index = i; d->tag = x->tag; d->id = x->id;
            d->file_off = x->off + m; d->act_off = y->off + m;
            d->exp_b = xl > yl ? xp[m] : -1; d->act_b = yl > xl ? yp[m] : -1;
            snprintf(d->msg, sizeof d->msg, "第 %u 条记录（%s）长度不同：期望 %u 实际 %u",
                     i, rec_name(x->tag, x->id), xl, yl);
            goto diff;
        }
        if (x->tag != y->tag || x->id != y->id) {   // 等长不同 id 已在字节比里抓到，这里兜底
            d->index = i; d->tag = x->tag; d->id = x->id;
            d->file_off = x->off; d->act_off = y->off; d->exp_b = d->act_b = -1;
            snprintf(d->msg, sizeof d->msg, "第 %u 条记录种类不同：期望 %s 实际 %s",
                     i, rec_name(x->tag, x->id), rec_name(y->tag, y->id));
            goto diff;
        }
    }
    if (e.n != a.n) {
        const seq_rec *extra = e.n > a.n ? &e.v[n] : &a.v[n];
        d->index = n; d->tag = extra->tag; d->id = extra->id;
        d->file_off = e.n > a.n ? extra->off : UINT64_MAX;
        d->act_off = e.n > a.n ? UINT64_MAX : extra->off;
        d->exp_b = d->act_b = -1;
        snprintf(d->msg, sizeof d->msg, "记录数不同：期望 %u 实际 %u；第一条多出的是 %s",
                 e.n, a.n, rec_name(extra->tag, extra->id));
        goto diff;
    }
    free(e.v); free(a.v); free((void *)e.base); free((void *)a.base);
    return 0;
bad:
    snprintf(d->msg, sizeof d->msg, "%s", err);
    d->index = UINT32_MAX; d->file_off = d->act_off = UINT64_MAX; d->exp_b = d->act_b = -1;
diff:
    free(e.v); free(a.v); free((void *)e.base); free((void *)a.base);
    return 1;
}

// ---------- 名称与 CRC ----------

uint32_t rfx_crc32(const void *p, size_t n) {
    const uint8_t *q = p;
    uint32_t c = 0xFFFFFFFFu;
    while (n--) {
        c ^= *q++;
        for (int i = 0; i < 8; i++) c = (c >> 1) ^ (0xEDB88320u & -(int32_t)(c & 1));
    }
    return ~c;
}

const char *rfx_tag_name(uint32_t tag) {
    static const char *n[] = {"?", "REGION", "DATA", "END", "RES", "CALL", "EXP", "CHK", "ASSUME"};
    return tag < sizeof n / sizeof n[0] ? n[tag] : "?";
}

const char *rfx_call_name(uint32_t f) {
    static const char *n[] = {
        "?", "nvn_be_set_depth_zero", "nvn_be_set_origin_lower_left", "nvn_be_pool_add", "nvn_be_pool_del",
        "nvn_be_alias_drop_pool", "nvn_be_sub_index", "nvn_be_sub_begin", "nvn_be_exec", "nvn_be_exec_rest",
        "nvn_be_sub_commit", "nvn_be_last_fence", "nvn_be_wait", "nvn_be_finish", "nvn_be_drain",
        "nvn_be_tex_init", "nvn_be_tex_release", "nvn_be_tex_cpu_written", "nvn_be_tex_gpu_owned",
        "nvn_be_reg_tex", "nvn_be_unreg_tex_range", "nvn_be_reg_samp", "nvn_be_set_tex_pool_n",
        "nvn_be_xv_window_tex", "nvn_be_present", "nvn_be_present_wait", "nvn_be_set_frame",
        "nvn_be_read_texels", "nvn_be_prog_release", "nvn_be_shader_prefetch",
        "nvn_be_finish_publish", "nvn_be_finish_wait", "nvn_be_event_written",
    };
    return f < sizeof n / sizeof n[0] ? n[f] : "?";
}

const char *rfx_gpu_name(uint32_t f) {
    static const char *n[] = {
        "?", "nvn_gpu_open", "nvn_gpu_close", "nvn_gpu_buf_wrap", "nvn_gpu_buf_create", "nvn_gpu_buf_release",
        "nvn_gpu_buf_use", "nvn_gpu_buf_write", "nvn_gpu_arena_alloc", "nvn_gpu_tex_create", "nvn_gpu_tex_release",
        "nvn_gpu_view_create", "nvn_gpu_view_create_buf", "nvn_gpu_view_release", "nvn_gpu_samp_create",
        "nvn_gpu_samp_release", "nvn_gpu_tex_upload", "nvn_gpu_tex_upload_blocklinear", "nvn_gpu_shader_load",
        "nvn_gpu_shader_release", "nvn_gpu_pipe_get", "nvn_gpu_cpipe_get", "nvn_gpu_cmd_begin", "nvn_gpu_cmd_abort",
        "nvn_gpu_pass_begin", "nvn_gpu_pass_end", "nvn_gpu_set_pipe", "nvn_gpu_set_dyn", "nvn_gpu_set_vbuf",
        "nvn_gpu_bind", "nvn_gpu_push", "nvn_gpu_draw", "nvn_gpu_dispatch", "nvn_gpu_copy_buf", "nvn_gpu_fill_buf",
        "nvn_gpu_copy_buf_tex", "nvn_gpu_copy_tex_buf", "nvn_gpu_copy_tex", "nvn_gpu_blit", "nvn_gpu_clear_view",
        "nvn_gpu_barrier", "nvn_gpu_occlusion", "nvn_gpu_label", "nvn_gpu_cmd_commit", "nvn_gpu_fence_wait",
        "nvn_gpu_surface_attach", "nvn_gpu_surface_rebuild", "nvn_gpu_surface_detach", "nvn_gpu_drawable_acquire",
        "nvn_gpu_drawable_release", "nvn_gpu_present",
    };
    return f < sizeof n / sizeof n[0] ? n[f] : "?";
}

const char *rfx_chk_name(uint32_t c) {
    static const char *n[] = {
        "?", "chk_fence_done", "chk_fence_failed", "chk_done", "chk_buf", "chk_presented", "chk_retired", "chk_error",
    };
    return c < sizeof n / sizeof n[0] ? n[c] : "?";
}

const char *rfx_res_name(uint32_t k) {
    static const char *n[] = {"?", "prog_snap", "shader", "surface"};
    return k < sizeof n / sizeof n[0] ? n[k] : "?";
}
