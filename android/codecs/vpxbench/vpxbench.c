// VP9 原生解码测速与对拍（设计 docs/设计_原生VP9/design_draft.md Phase 1 · 1a；design_phase2_B.md PR 1）。只是测量工具，不进产品。
//   vpxbench <file.ivf> <threads> [max_packets]
//     读 IVF，逐包用 services/vpx/s2a_vp9.c 解码（多线程时开行级并行，与生产设置一致），按包计时，打印 mean / p50 / p95 / max（毫秒）。
//   vpxbench --jobs <capture_dir> <threads> [max_jobs]
//     读手机上抓的 NVDEC 作业（S2A_NVDEC_VP9_CAPTURE 的 frame_%06d.bin），按 hdr.c（设计 §2-§3）写帧头、经 libvpx 补丁的
//     s2a_vp9_nvdec 逐作业解码，上一作业解出的 MV 作下一作业的 MV 输入（Phase 1：读缓冲 = 上一作业写缓冲）。按作业计时，
//     并把画面 / MV / 计数的 FNV-1a-64 与抓取里记下的 C# 解码器结果比对。
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "hdr.h"
#include "vpx/s2a_vp9_nvdec.h"

void *s2a_vp9_open(int threads);
int s2a_vp9_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info);
void s2a_vp9_close(void *h);
int s2a_vp9_nvdec(void *h, const uint8_t *frame, uint32_t size, const s2a_vp9_nvdec_io *io, s2a_vp9_nvdec_picture *pic,
                  const char **error);

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void stats(const char *what, double *ms, size_t n)
{
    double sum = 0;
    for (size_t i = 0; i < n; i++) sum += ms[i];
    qsort(ms, n, sizeof *ms, cmp);
    printf("%s n=%zu mean=%.2f p50=%.2f p95=%.2f max=%.2f\n", what, n, n ? sum / n : 0, n ? ms[n / 2] : 0,
           n ? ms[(size_t)(n * 0.95)] : 0, n ? ms[n - 1] : 0);
}

static uint64_t fnv(uint64_t h, const uint8_t *p, size_t n)
{
    while (n--) h = (h ^ *p++) * 0x100000001b3ULL;
    return h;
}

static uint64_t fnv_plane(const uint8_t *p, int stride, int w, int h)
{
    uint64_t x = 0xcbf29ce484222325ULL;
    for (int y = 0; y < h; y++) x = fnv(x, p + (long)y * stride, (size_t)w);
    return x;
}

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)n);
    if (b == NULL || fread(b, 1, (size_t)n, f) != (size_t)n)
    {
        fclose(f);
        free(b);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return b;
}

static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t u64(const uint8_t *p) { return u32(p) | (uint64_t)u32(p + 4) << 32; }

#define MAX_REASONS 16

static int jobs_mode(const char *dir, int threads, long max)
{
    void *dec = s2a_vp9_open(threads);
    if (dec == NULL) return fprintf(stderr, "s2a_vp9_open failed\n"), 1;
    size_t frame_cap = 16u << 20, mv_cap = 0;
    uint8_t *frame = malloc(frame_cap), *mv_a = NULL, *mv_b = NULL, probs[S2A_VP9_PROBS_SIZE], counts[S2A_VP9_COUNTS_SIZE];
    uint8_t guest_counts[S2A_NVDEC_COUNTS_SIZE];
    double *ms = NULL;
    size_t n_ms = 0;
    s2a_slots slots;
    s2a_slots_reset(&slots);
    int active = 0, mv_valid = 0;
    long jobs = 0, native = 0, waiting = 0, pic_ok = 0, mv_ok = 0, counts_ok = 0;
    long first_pic_bad = -1, first_mv_bad = -1, first_counts_bad = -1;
    const char *reasons[MAX_REASONS];
    long reason_n[MAX_REASONS];
    int n_reasons = 0;
    const int verbose = getenv("S2A_VPXBENCH_VERBOSE") != NULL;
    const char *dump_dir = getenv("S2A_VPXBENCH_DUMP_PROBS");   // debugging: converted Vp9EntropyProbs per job

    for (long j = 0; max <= 0 || j < max; j++)
    {
        char path[4096];
        size_t len;
        snprintf(path, sizeof path, "%s/frame_%06ld.bin", dir, j);
        uint8_t *rec = read_file(path, &len);
        if (rec == NULL) break;
        jobs++;
        if (len < 32 || memcmp(rec, "S2V9", 4) != 0 || u32(rec + 4) != 1) return fprintf(stderr, "%s: not S2V9 v1\n", path), 1;
        uint32_t n_pic = u32(rec + 12), n_ent = u32(rec + 16), n_reg = u32(rec + 20), n_tile = u32(rec + 24), n_pre = u32(rec + 28);
        const uint8_t *pic_b = rec + 32, *ent_b = pic_b + n_pic, *reg_b = ent_b + n_ent, *tiles = reg_b + n_reg;
        const uint8_t *trailer = tiles + n_tile + n_pre;
        if (n_pic != S2A_NVDEC_PICINFO_SIZE || n_ent != S2A_NVDEC_ENTROPY_SIZE || n_reg < 32 || trailer + 41 > rec + len)
            return fprintf(stderr, "%s: unexpected section sizes\n", path), 1;

        s2a_pic p;
        s2a_surfaces sf;
        s2a_pic_parse(pic_b, &p);
        for (int i = 0; i < 4; i++)
        {
            sf.luma[i] = u32(reg_b + 8 * i);
            sf.chroma[i] = u32(reg_b + 8 * i + 4);
        }
        const int key = (p.flags & S2A_KEY) != 0, intra_only = !key && (p.flags & S2A_INTRA_ONLY);
        const char *why = NULL;
        if (key && !active)
        {
            active = 1;
            s2a_slots_reset(&slots);
        }
        int target = 0;
        size_t flen = 0;
        if (!active)
            waiting++;
        else
            why = s2a_build_frame(&p, &sf, &slots, tiles, n_tile, frame, frame_cap, &flen, &target);

        const int mi_count = ((p.size_w[3] + 7) >> 3) * ((p.size_h[3] + 7) >> 3);
        if ((size_t)mi_count * S2A_VP9_MVREF_SIZE > mv_cap)
        {
            mv_cap = (size_t)mi_count * S2A_VP9_MVREF_SIZE;
            mv_a = realloc(mv_a, mv_cap);
            mv_b = realloc(mv_b, mv_cap);
            mv_valid = 0;
        }
        if (active && why == NULL)
        {
            s2a_entropy_convert(ent_b, probs);
            if (dump_dir != NULL)
            {
                char dp[4096];
                snprintf(dp, sizeof dp, "%s/probs_%06ld.bin", dump_dir, j);
                FILE *df = fopen(dp, "wb");
                if (df != NULL)
                {
                    fwrite(probs, 1, sizeof probs, df);
                    fclose(df);
                }
            }
            s2a_vp9_nvdec_io io = {
                .probs = probs,
                .intra_frame = key || intra_only,
                .tx_mode = p.tx_mode,
                .reference_mode = p.ref_mode,
                .comp_fixed_ref = p.comp_fixed_ref,
                .comp_var_ref0 = p.comp_var_ref[0],
                .comp_var_ref1 = p.comp_var_ref[1],
                .use_prev_frame_mvs = s2a_use_prev_mvs(&p),
                .mi_count = mi_count,
                .prev_mvs = mv_a,
                .mvs = mv_b,
                .counts = counts,
            };
            if (io.use_prev_frame_mvs && !mv_valid)
                why = "previous MVs unknown";
            else
            {
                s2a_vp9_nvdec_picture pic;
                const char *err = NULL;
                double t0 = now_ms();
                int r = s2a_vp9_nvdec(dec, frame, (uint32_t)flen, &io, &pic, &err);
                double dt = now_ms() - t0;
                if (r == S2A_VP9_OK)
                {
                    native++;
                    ms = realloc(ms, (n_ms + 1) * sizeof *ms);
                    ms[n_ms++] = dt;
                    s2a_slots_commit(&slots, &p, &sf, key ? -1 : target);
                    const int uvw = (pic.width + 1) >> 1, uvh = (pic.height + 1) >> 1;
                    const int same_pic = trailer[0] && fnv_plane(pic.planes[0], pic.strides[0], pic.width, pic.height) == u64(trailer + 1) &&
                                         fnv_plane(pic.planes[1], pic.strides[1], uvw, uvh) == u64(trailer + 9) &&
                                         fnv_plane(pic.planes[2], pic.strides[2], uvw, uvh) == u64(trailer + 17);
                    const int same_mv = fnv(0xcbf29ce484222325ULL, mv_b, (size_t)mi_count * S2A_VP9_MVREF_SIZE) == u64(trailer + 25);
                    size_t gn = s2a_counts_to_guest(counts, guest_counts);
                    const int same_counts = fnv(0xcbf29ce484222325ULL, guest_counts, gn) == u64(trailer + 33);
                    pic_ok += same_pic;
                    mv_ok += same_mv;
                    counts_ok += same_counts;
                    if (!same_pic && first_pic_bad < 0) first_pic_bad = j;
                    if (verbose)
                        fprintf(stderr, "job %ld key=%d intra=%d interp=%u ref_mode=%u tx=%u lf=%u/%u q=%u target=%d refs=%x/%x/%x out=%x pic=%d\n", j, key,
                                intra_only, p.interp, p.ref_mode, p.tx_mode, p.filter_level, p.sharpness, p.base_q, target,
                                sf.luma[0], sf.luma[1], sf.luma[2], sf.luma[3], same_pic);
                    if (verbose)
                        fprintf(stderr, "yhash %ld native=%016llx csharp=%016llx\n", j,
                                (unsigned long long)fnv_plane(pic.planes[0], pic.strides[0], pic.width, pic.height),
                                (unsigned long long)u64(trailer + 1));
                    if (!same_mv && first_mv_bad < 0) first_mv_bad = j;
                    if (!same_counts && first_counts_bad < 0) first_counts_bad = j;
                    uint8_t *t = mv_a;
                    mv_a = mv_b;
                    mv_b = t;
                    mv_valid = 1;
                }
                else
                    why = r == S2A_VP9_UNREPR    ? "libvpx: not representable"
                          : r == S2A_VP9_NEED_KEY ? "libvpx: not representable after header"
                                                  : "libvpx: decode error";
                if (err != NULL) fprintf(stderr, "job %ld: libvpx: %s\n", j, err);
            }
        }
        if (why != NULL)
        {
            active = 0;
            mv_valid = 0;
            s2a_slots_reset(&slots);
            int k = 0;
            while (k < n_reasons && strcmp(reasons[k], why) != 0) k++;
            if (k == n_reasons && n_reasons < MAX_REASONS)
            {
                reasons[n_reasons] = why;
                reason_n[n_reasons++] = 0;
            }
            if (k < n_reasons) reason_n[k]++;
            fprintf(stderr, "job %ld -> C#: %s\n", j, why);
        }
        free(rec);
    }
    s2a_vp9_close(dec);
    printf("threads=%d jobs=%ld native=%ld (%.1f%%) waiting_for_key=%ld\n", threads, jobs, native,
           jobs ? 100.0 * native / jobs : 0, waiting);
    for (int k = 0; k < n_reasons; k++) printf("fallback %ld: %s\n", reason_n[k], reasons[k]);
    printf("parity vs C#: picture %ld/%ld (first bad %ld), mvs %ld/%ld (first bad %ld), counts %ld/%ld (first bad %ld)\n",
           pic_ok, native, first_pic_bad, mv_ok, native, first_mv_bad, counts_ok, native, first_counts_bad);
    stats("per-job decode ms", ms, n_ms);
    free(ms);
    free(frame);
    free(mv_a);
    free(mv_b);
    return 0;
}

static int ivf_mode(const char *path, int threads, long max)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL)
    {
        perror(path);
        return 2;
    }
    uint8_t hdr[32];
    if (fread(hdr, 1, 32, f) != 32 || memcmp(hdr, "DKIF", 4) != 0 || memcmp(hdr + 8, "VP90", 4) != 0)
    {
        fprintf(stderr, "not an IVF/VP9 file\n");
        return 2;
    }
    fseek(f, hdr[6] | hdr[7] << 8, SEEK_SET);

    void *dec = s2a_vp9_open(threads);
    if (dec == NULL)
    {
        fprintf(stderr, "s2a_vp9_open failed\n");
        return 1;
    }
    size_t cap = 4096, n = 0, bufcap = 0;
    double *ms = malloc(cap * sizeof *ms);
    uint8_t *buf = NULL;
    long shown = 0, failed = 0;
    double total0 = now_ms();
    for (;;)
    {
        uint8_t fh[12];
        if (fread(fh, 1, 12, f) != 12 || (max > 0 && (long)n >= max)) break;
        uint32_t len = fh[0] | fh[1] << 8 | fh[2] << 16 | (uint32_t)fh[3] << 24;
        if (len > bufcap)
        {
            bufcap = len;
            buf = realloc(buf, bufcap);
        }
        if (fread(buf, 1, len, f) != len) break;
        uint8_t *planes[3];
        int32_t strides[3], info[4];
        double t0 = now_ms();
        int r = s2a_vp9_decode(dec, buf, len, planes, strides, info);
        double dt = now_ms() - t0;
        if (r == 0) shown++;
        else if (r < 0) failed++;
        if (n == cap)
        {
            cap *= 2;
            ms = realloc(ms, cap * sizeof *ms);
        }
        ms[n++] = dt;
    }
    double wall = now_ms() - total0;
    s2a_vp9_close(dec);
    if (n == 0)
    {
        fprintf(stderr, "no packets\n");
        return 1;
    }
    printf("threads=%d packets=%zu shown=%ld failed=%ld wall_s=%.2f\n", threads, n, shown, failed, wall / 1e3);
    stats("per-packet decode ms", ms, n);
    free(ms);
    free(buf);
    return failed ? 1 : 0;
}

int main(int argc, char **argv)
{
    if (argc >= 4 && strcmp(argv[1], "--jobs") == 0) return jobs_mode(argv[2], atoi(argv[3]), argc > 4 ? atol(argv[4]) : 0);
    if (argc >= 3 && argv[1][0] != '-') return ivf_mode(argv[1], atoi(argv[2]), argc > 3 ? atol(argv[3]) : 0);
    fprintf(stderr, "usage: vpxbench <file.ivf> <threads> [max_packets]\n       vpxbench --jobs <capture_dir> <threads> [max_jobs]\n");
    return 2;
}
