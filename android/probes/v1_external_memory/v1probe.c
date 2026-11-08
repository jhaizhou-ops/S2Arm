// WP17 V1 probe (issue #401). Reuses the V0 probe (JSON lines, Vulkan context, import / coherency
// helpers) by including its source and adds:
//   swap_ahb / swap_heap  V1-a: re-back a filled range of a PROT_NONE guest window in place
//                          (AHB or dma-buf heap -> copy -> MAP_FIXED -> VkBuffer -> GPU r/w -> swap back)
//   ahb / heapcpu          V1-b: the V0 AHB section without its 1 GiB size, and dma-buf heap open /
//                          alloc / MAP_FIXED / CPU r/w without Vulkan; with the V0 dmabuf section these
//                          run both from adb shell and inside the probe APK (in-process, no fork)
//   bench                  V1-c: CPU sequential write / read and shuffled 4-byte reads on 64 MiB of
//                          memfd, AHB (MAP_FIXED) and dma-buf heap memory
//   sparse                 V1-e: one sparse VkBuffer bound to several AHB imports, CPU view stitched
//                          with MAP_FIXED, whole-range and block-boundary GPU r/w
// Built as an executable (adb shell, every section in a forked child with a watchdog) and, with
// -DV1_JNI, as libv1probe.so for the probe APK.
#define V0PROBE_NO_MAIN 1
// v0's JSON helper jint() clashes with the JNI type of the same name; jni.h is included after
// this macro is dropped, right before the JNI entry point.
#define jint v0_jint
#include "../v0_external_memory/v0probe.c"

#include <sched.h>
#include <sys/system_properties.h>

#define V1_SECTION_ALARM_S 240
#define WIN_GUARD (2 * MB)
#define SPAN_CHUNK (64 * MB)

static int g_isolated = 1; // 1: sections run in forked children (adb); 0: in-process (APK)

static const char *mode_name(void) { return g_isolated ? "fork" : "inproc"; }

// ---------------------------------------------------------------- patterns over a word range

static void fill_at(uint32_t *p, size_t n, size_t base, uint32_t seed) {
    for (size_t i = 0; i < n; i++) p[i] = pat((uint32_t)(base + i), seed);
}

// Bytes of p[0..n) that differ from pat(base + i, seed) ^ key; *first gets the first bad global word.
static uint64_t mismatch_at(const volatile uint32_t *p, size_t n, size_t base, uint32_t seed, uint32_t key, long long *first) {
    uint64_t bad = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t d = p[i] ^ pat((uint32_t)(base + i), seed) ^ key;
        if (!d) continue;
        if (*first < 0) *first = (long long)(base + i);
        bad += ((d & 0xFFu) != 0) + ((d & 0xFF00u) != 0) + ((d & 0xFF0000u) != 0) + ((d & 0xFF000000u) != 0);
    }
    return bad;
}

typedef struct {
    uint64_t bad;
    long long first;
    VkResult vr;
    const char *step;
} Span;

static void span_init(Span *s) {
    s->bad = 0;
    s->first = -1;
    s->vr = VK_SUCCESS;
    s->step = "match";
}

static VkDeviceSize span_chunk(const Ctx *c) {
    VkDeviceSize ch = SPAN_CHUNK;
    if (ch > c->props.limits.maxStorageBufferRange) ch = c->props.limits.maxStorageBufferRange & ~(VkDeviceSize)(MB - 1);
    return ch;
}

// GPU reads target[off, off + len) and writes aux = target ^ key; CPU compares aux with
// pat(word index in target, seed) ^ key. The caller has written the target through its CPU view.
static void span_gpu_read(const Ctx *c, const Target *t, VkDeviceSize off, VkDeviceSize len, uint32_t seed, Span *s) {
    span_init(s);
    VkDeviceSize ch = span_chunk(c);
    Plain aux;
    if ((s->vr = plain_alloc(c, ch < len ? ch : len, &aux))) { s->step = "aux_alloc"; plain_free(c, &aux); return; }
    for (VkDeviceSize o = off; o < off + len; o += ch) {
        VkDeviceSize n = off + len - o < ch ? off + len - o : ch;
        memset(aux.ptr, 0xCD, n);
        Target tw = *t;
        tw.win_off = o;
        tw.win_len = n;
        if ((s->vr = gpu_xor(c, t->buf, aux.buf, (uint32_t)(n / 4), &tw))) { s->step = "gpu"; break; }
        s->bad += mismatch_at(aux.ptr, n / 4, o / 4, seed, XOR_KEY, &s->first);
    }
    if (!s->vr && s->bad) s->step = "mismatch";
    plain_free(c, &aux);
}

// GPU writes target[off, off + len) = pat(word index, seed) ^ key (from aux); the caller then checks
// the target through its CPU view with mismatch_at(..., seed, XOR_KEY).
static void span_gpu_write(const Ctx *c, const Target *t, VkDeviceSize off, VkDeviceSize len, uint32_t seed, Span *s) {
    span_init(s);
    VkDeviceSize ch = span_chunk(c);
    Plain aux;
    if ((s->vr = plain_alloc(c, ch < len ? ch : len, &aux))) { s->step = "aux_alloc"; plain_free(c, &aux); return; }
    for (VkDeviceSize o = off; o < off + len; o += ch) {
        VkDeviceSize n = off + len - o < ch ? off + len - o : ch;
        fill_at(aux.ptr, n / 4, o / 4, seed);
        Target tw = *t;
        tw.win_off = o;
        tw.win_len = n;
        if ((s->vr = gpu_xor(c, aux.buf, t->buf, (uint32_t)(n / 4), &tw))) { s->step = "gpu"; break; }
    }
    plain_free(c, &aux);
}

static void jspan(Js *j, const char *prefix, const Span *s) {
    char k[96];
    prefixed(k, sizeof k, prefix, "bad_bytes"); juint(j, k, s->bad);
    prefixed(k, sizeof k, prefix, "first_bad_word"); jint(j, k, s->first);
    prefixed(k, sizeof k, prefix, "step"); jstr(j, k, s->step);
    if (s->vr) { prefixed(k, sizeof k, prefix, "vk"); jstr(j, k, vkr(s->vr)); }
}

// ---------------------------------------------------------------- /proc/self/maps

// What backs [a, b), relative to `base`: "start-end perms inode name[+fileoff]" pieces separated by
// ';', adjacent pieces merged when perms / inode / name match (and the file offset continues).
static void range_desc(uintptr_t base, uintptr_t a, uintptr_t b, char *out, size_t cap) {
    out[0] = 0;
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) { snprintf(out, cap, "maps_errno_%d", errno); return; }
    struct { unsigned long long s, e, off; unsigned long ino; char perms[8]; char name[160]; } pv = {0};
    int have = 0;
    size_t n = 0;
    char line[512];
    for (;;) {
        int eof = !fgets(line, sizeof line, f);
        unsigned long long s = 0, e = 0, off = 0;
        unsigned long ino = 0;
        char perms[8] = "", dev[16] = "";
        int pos = 0;
        const char *name = "";
        if (!eof) {
            if (sscanf(line, "%llx-%llx %7s %llx %15s %lu %n", &s, &e, perms, &off, dev, &ino, &pos) < 6) continue;
            if (e <= a || s >= b) continue;
            name = line + pos;
            line[strcspn(line, "\n")] = 0;
            unsigned long long cs = s < a ? a : s, ce = e > b ? b : e;
            off += cs - s;
            s = cs;
            e = ce;
            if (have && pv.e == s && pv.ino == ino && !strcmp(pv.perms, perms) && !strcmp(pv.name, name)
                && (ino == 0 || pv.off + (pv.e - pv.s) == off)) {
                pv.e = e;
                continue;
            }
        }
        if (have) {
            int w = snprintf(out + n, cap - n, "%s%llx-%llx %s %lu %s", n ? ";" : "", pv.s - base, pv.e - base, pv.perms, pv.ino, pv.name);
            if (w > 0 && (size_t)w < cap - n) n += (size_t)w;
            if (pv.ino) {
                w = snprintf(out + n, cap - n, "+%llx", pv.off);
                if (w > 0 && (size_t)w < cap - n) n += (size_t)w;
            }
        }
        if (eof) break;
        pv.s = s;
        pv.e = e;
        pv.off = off;
        pv.ino = ino;
        snprintf(pv.perms, sizeof pv.perms, "%s", perms);
        snprintf(pv.name, sizeof pv.name, "%s", name);
        have = 1;
    }
    fclose(f);
}

// ---------------------------------------------------------------- start line

typedef struct {
    Js *j;
    const char *k;
} PropOut;

static void prop_cb(void *cookie, const char *name, const char *value, uint32_t serial) {
    (void)name;
    (void)serial;
    PropOut *o = cookie;
    jstr(o->j, o->k, value);
}

// __system_property_read_callback also returns values longer than PROP_VALUE_MAX (fingerprints).
static void jprop(Js *j, const char *k, const char *prop) {
    const prop_info *pi = __system_property_find(prop);
    PropOut o = {j, k};
    if (pi) __system_property_read_callback(pi, prop_cb, &o);
    else jstr(j, k, "");
}

static void start_line(const char *list) {
    Js j;
    jbegin(&j, "start");
    jstr(&j, "rev", PROBE_REV);
    jstr(&j, "mode", mode_name());
    jstr(&j, "sections", list);
    jint(&j, "pid", getpid());
    jint(&j, "uid", getuid());
    char ctx[256] = "";
    int fd = open("/proc/self/attr/current", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t r = read(fd, ctx, sizeof ctx - 1);
        ctx[r > 0 ? r : 0] = 0;
        ctx[strcspn(ctx, "\n")] = 0;
        close(fd);
    }
    jstr(&j, "selinux", ctx);
    jprop(&j, "model", "ro.product.model");
    jprop(&j, "soc", "ro.soc.model");
    jprop(&j, "fingerprint", "ro.build.fingerprint");
    jint(&j, "page", sysconf(_SC_PAGESIZE));
    jend(&j);
}

// ---------------------------------------------------------------- V1-b: AHB / heap without Vulkan

// The V0 AHB section (its alloc-only sizes are capped by AHB_LIMIT_BYTES in v0probe.c).
static void sec_ahb_v1(Ctx *c, int arg) {
    (void)arg;
    if (!c->ext_ahb || !c->get_ahb_props) {
        Js j;
        jbegin(&j, "ahb");
        jstatus(&j, "unsupported");
        jstr(&j, "reason", "VK_ANDROID_external_memory_android_hardware_buffer absent");
        jend(&j);
        return;
    }
    for (size_t s = 0; s < NELEM(k_test_sizes); s++) ahb_one(c, k_test_sizes[s], AHB_FULL);
    for (size_t s = 0; s < NELEM(k_ahb_max_sizes); s++) ahb_one(c, k_ahb_max_sizes[s], AHB_ALLOC_ONLY);
}

static const char *k_cpu_heaps[] = {"system", "system-uncached", "qcom,system", "mtk_mm", "mtk_mm-uncached"};

// dma-buf heap from the CPU side only: open, allocate 2 MiB, MAP_FIXED into a reserved window,
// write / read back with DMA_BUF_IOCTL_SYNC around each access. Every refused call is reported.
static void sec_heapcpu(Ctx *c, int arg) {
    (void)c;
    (void)arg;
    Js j;
    jbegin(&j, "dma_heaps");
    DIR *dir = opendir("/dev/dma_heap");
    if (!dir) {
        jstatus(&j, "fail");
        jerrno(&j, "opendir", errno);
    } else {
        int count = 0;
        while (readdir(dir)) count++;
        closedir(dir);
        jstatus(&j, "ok");
        jint(&j, "entries", count);
    }
    jend(&j);
    const size_t size = 2 * MB;
    for (size_t h = 0; h < NELEM(k_cpu_heaps); h++) {
        char path[96];
        snprintf(path, sizeof path, "/dev/dma_heap/%s", k_cpu_heaps[h]);
        jbegin(&j, "heapcpu");
        jstr(&j, "heap", k_cpu_heaps[h]);
        juint(&j, "size", size);
        int hfd = open(path, O_RDONLY | O_CLOEXEC);
        if (hfd < 0) {
            int e = errno;
            jstatus(&j, e == ENOENT ? "absent" : "fail");
            jerrno(&j, "open", e);
            jend(&j);
            continue;
        }
        struct dma_heap_allocation_data ad = {.len = size, .fd_flags = O_RDWR | O_CLOEXEC};
        if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &ad)) {
            jstatus(&j, "fail");
            jerrno(&j, "DMA_HEAP_IOCTL_ALLOC", errno);
            jend(&j);
            close(hfd);
            continue;
        }
        int fd = (int)ad.fd;
        void *raw = NULL;
        size_t raw_len = 0;
        uint8_t *w = reserve_window(size, 2 * MB, &raw, &raw_len);
        void *m = w ? mmap(w, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0) : MAP_FAILED;
        if (m == MAP_FAILED || m != w) {
            jstatus(&j, "fail");
            jerrno(&j, "mmap_fixed", w ? errno : ENOMEM);
        } else {
            Target t = {.cpu = w, .mode = CPU_DMABUF_SYNC, .fd = fd};
            int err = 0;
            long long first = -1;
            uint64_t bad = 0;
            const char *step = "match";
            if (!cpu_begin(&t, 1, &err)) step = "sync_start_write";
            else {
                fill_at((uint32_t *)w, size / 4, 0, 0x7777u);
                if (!cpu_end(&t, 1, &err)) step = "sync_end_write";
                else if (!cpu_begin(&t, 0, &err)) step = "sync_start_read";
                else {
                    bad = mismatch_at((const uint32_t *)w, size / 4, 0, 0x7777u, 0, &first);
                    if (!cpu_end(&t, 0, &err)) step = "sync_end_read";
                    else if (bad) step = "mismatch";
                }
            }
            jbool(&j, "mmap_fixed_ok", 1);
            jstr(&j, "cpu_step", step);
            if (err) jint(&j, "cpu_errno", err);
            juint(&j, "cpu_bad_bytes", bad);
            jstatus(&j, !err && !bad ? "ok" : "fail");
        }
        jend(&j);
        if (raw) munmap(raw, raw_len);
        close(fd);
        close(hfd);
    }
}

// ---------------------------------------------------------------- V1-a: in-place re-backing

enum { SHAPE_MEMFD, SHAPE_ANON, SHAPE_COUNT };
static const char *k_shape_names[] = {"memfd_shared", "anon_private"};

// [gap_lo | lo | pool | hi | gap_hi] inside one PROT_NONE reservation. lo / pool / hi are one
// mapping of the guest backing (memfd shared from offset 0, or anonymous private), filled with
// distinct patterns; the gaps stay PROT_NONE. This is the shape of android/native:
// reserve PROT_NONE, place shared backing with MAP_FIXED, alias with mremap(old_size = 0).
typedef struct {
    int shape;
    size_t n;
    void *raw;
    size_t raw_len;
    uint8_t *win, *lo, *pool, *hi;
    size_t win_len;
    int memfd;
    uint8_t *alias; // memfd shape: a second mapping of the pool's memfd pages
    int err;
    const char *step;
} Guest;

#define SEED_LO 0x10001u
#define SEED_POOL 0x20002u
#define SEED_HI 0x30003u

static int guest_map(int shape, size_t n, Guest *g) {
    memset(g, 0, sizeof *g);
    g->shape = shape;
    g->n = n;
    g->memfd = -1;
    g->win_len = 2 * WIN_GUARD + 2 * WIN_GUARD + n;
    g->win = reserve_window(g->win_len, 2 * MB, &g->raw, &g->raw_len);
    if (!g->win) { g->err = errno; g->step = "reserve"; return 0; }
    g->lo = g->win + WIN_GUARD;
    g->pool = g->lo + WIN_GUARD;
    g->hi = g->pool + n;
    size_t mapped = 2 * WIN_GUARD + n;
    void *m;
    if (shape == SHAPE_MEMFD) {
        g->memfd = memfd_create("v1probe-guest", MFD_CLOEXEC);
        if (g->memfd < 0) { g->err = errno; g->step = "memfd_create"; return 0; }
        if (ftruncate(g->memfd, (off_t)mapped)) { g->err = errno; g->step = "ftruncate"; return 0; }
        m = mmap(g->lo, mapped, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, g->memfd, 0);
    } else {
        m = mmap(g->lo, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    }
    if (m == MAP_FAILED || m != g->lo) { g->err = errno; g->step = "mmap_fixed_backing"; return 0; }
    fill_at((uint32_t *)g->lo, WIN_GUARD / 4, 0, SEED_LO);
    fill_at((uint32_t *)g->pool, n / 4, 0, SEED_POOL);
    fill_at((uint32_t *)g->hi, WIN_GUARD / 4, 0, SEED_HI);
    if (shape == SHAPE_MEMFD) {
        void *a = mremap(g->pool, 0, n, MREMAP_MAYMOVE);
        if (a == MAP_FAILED) { g->err = errno; g->step = "mremap_alias"; return 0; }
        g->alias = a;
    }
    return 1;
}

static void guest_free(Guest *g) {
    if (g->alias) munmap(g->alias, g->n);
    if (g->raw) munmap(g->raw, g->raw_len);
    if (g->memfd >= 0) close(g->memfd);
}

typedef struct {
    char gap_lo[512], lo[512], hi[512], gap_hi[512], win[2048];
} Layout;

static void layout_take(const Guest *g, Layout *l) {
    uintptr_t b = (uintptr_t)g->win;
    range_desc(b, b, (uintptr_t)g->lo, l->gap_lo, sizeof l->gap_lo);
    range_desc(b, (uintptr_t)g->lo, (uintptr_t)g->pool, l->lo, sizeof l->lo);
    range_desc(b, (uintptr_t)g->hi, (uintptr_t)g->hi + WIN_GUARD, l->hi, sizeof l->hi);
    range_desc(b, (uintptr_t)g->hi + WIN_GUARD, b + g->win_len, l->gap_hi, sizeof l->gap_hi);
    range_desc(b, b, b + g->win_len, l->win, sizeof l->win);
}

// Neighbours (both PROT_NONE gaps and both filled neighbours) mapped as before and still holding
// their patterns.
static int neighbours(Js *j, const Guest *g, const Layout *before, const char *phase) {
    Layout now;
    layout_take(g, &now);
    long long f1 = -1, f2 = -1;
    uint64_t lo_bad = mismatch_at((const uint32_t *)g->lo, WIN_GUARD / 4, 0, SEED_LO, 0, &f1);
    uint64_t hi_bad = mismatch_at((const uint32_t *)g->hi, WIN_GUARD / 4, 0, SEED_HI, 0, &f2);
    int maps_same = !strcmp(now.gap_lo, before->gap_lo) && !strcmp(now.lo, before->lo) && !strcmp(now.hi, before->hi)
                    && !strcmp(now.gap_hi, before->gap_hi);
    char k[96];
    snprintf(k, sizeof k, "%s_neighbour_maps_same", phase); jbool(j, k, maps_same);
    snprintf(k, sizeof k, "%s_lo_bad_bytes", phase); juint(j, k, lo_bad);
    snprintf(k, sizeof k, "%s_hi_bad_bytes", phase); juint(j, k, hi_bad);
    snprintf(k, sizeof k, "%s_maps", phase); jstr(j, k, now.win);
    if (!maps_same) {
        snprintf(k, sizeof k, "%s_maps_lo", phase); jstr(j, k, now.lo);
        snprintf(k, sizeof k, "%s_maps_hi", phase); jstr(j, k, now.hi);
    }
    return maps_same && !lo_bad && !hi_bad;
}

enum { NEW_AHB, NEW_HEAP };

typedef struct {
    int kind;
    AHardwareBuffer *ahb;
    int fd; // dma-buf fd that is mmapped over the pool
} NewBack;

// Allocates the GPU-importable replacement for the pool. Returns 0 and fills step / errno on failure.
static int newback_alloc(const Ctx *c, int kind, const char *heap, size_t n, NewBack *nb, Js *j) {
    memset(nb, 0, sizeof *nb);
    nb->kind = kind;
    nb->fd = -1;
    if (kind == NEW_AHB && n > AHB_LIMIT_BYTES) { jstr(j, "step", "ahb_size_over_probe_limit"); return 0; }
    double t0 = now_us();
    if (kind == NEW_AHB) {
        AHardwareBuffer_Desc d = {
            .width = (uint32_t)n, .height = 1, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_BLOB,
            .usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER};
        int e = AHardwareBuffer_allocate(&d, &nb->ahb);
        jdbl(j, "alloc_us", now_us() - t0);
        if (e) { jstr(j, "step", "AHardwareBuffer_allocate"); jint(j, "ahb_err", e); nb->ahb = NULL; return 0; }
        int fds[32], ferr = 0;
        int nf = ahb_fds(nb->ahb, fds, 32, &ferr);
        jint(j, "native_handle_fds", nf);
        if (nf < 1) { jstr(j, "step", "ahb_native_handle_fd"); jint(j, "errno", ferr); return 0; }
        nb->fd = fds[0];
        for (int i = 1; i < nf; i++) close(fds[i]);
        (void)c;
        return 1;
    }
    char path[96];
    snprintf(path, sizeof path, "/dev/dma_heap/%s", heap);
    int hfd = open(path, O_RDONLY | O_CLOEXEC);
    if (hfd < 0) { jerrno(j, "heap_open", errno); return 0; }
    struct dma_heap_allocation_data ad = {.len = n, .fd_flags = O_RDWR | O_CLOEXEC};
    int r = ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &ad);
    int e = errno;
    close(hfd);
    jdbl(j, "alloc_us", now_us() - t0);
    if (r) { jerrno(j, "DMA_HEAP_IOCTL_ALLOC", e); return 0; }
    nb->fd = (int)ad.fd;
    return 1;
}

static void newback_free(NewBack *nb) {
    if (nb->fd >= 0) close(nb->fd);
    if (nb->ahb) AHardwareBuffer_release(nb->ahb);
    nb->fd = -1;
    nb->ahb = NULL;
}

// Copies the pool into the new backing through a temporary mapping, then MAP_FIXED the new
// backing over the pool. The old pages are no longer reachable through the pool address.
static int swap_in(Guest *g, NewBack *nb, Js *j) {
    double t0 = now_us();
    void *tmp = mmap(NULL, g->n, PROT_READ | PROT_WRITE, MAP_SHARED, nb->fd, 0);
    if (tmp == MAP_FAILED) { jerrno(j, "swap_in_mmap_tmp", errno); return 0; }
    memcpy(tmp, g->pool, g->n);
    munmap(tmp, g->n);
    double t1 = now_us();
    void *m = mmap(g->pool, g->n, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, nb->fd, 0);
    if (m == MAP_FAILED || m != g->pool) { jerrno(j, "swap_in_mmap_fixed", errno); return 0; }
    jdbl(j, "swap_in_copy_us", t1 - t0);
    jdbl(j, "swap_in_us", now_us() - t0);
    return 1;
}

// Pool destruction: copy the pool back into guest memory of the original kind and put that memory
// back at the pool address (memfd: the original file pages at their original offset; anonymous:
// fresh private pages moved in with mremap).
static int swap_back(Guest *g, Js *j) {
    double t0 = now_us();
    if (g->shape == SHAPE_MEMFD) {
        void *tmp = mmap(NULL, g->n, PROT_READ | PROT_WRITE, MAP_SHARED, g->memfd, (off_t)WIN_GUARD);
        if (tmp == MAP_FAILED) { jerrno(j, "swap_back_mmap_tmp", errno); return 0; }
        memcpy(tmp, g->pool, g->n);
        munmap(tmp, g->n);
        void *m = mmap(g->pool, g->n, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, g->memfd, (off_t)WIN_GUARD);
        if (m == MAP_FAILED || m != g->pool) { jerrno(j, "swap_back_mmap_fixed", errno); return 0; }
    } else {
        void *tmp = mmap(NULL, g->n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (tmp == MAP_FAILED) { jerrno(j, "swap_back_mmap_tmp", errno); return 0; }
        memcpy(tmp, g->pool, g->n);
        void *m = mremap(tmp, g->n, g->n, MREMAP_MAYMOVE | MREMAP_FIXED, g->pool);
        if (m == MAP_FAILED || m != g->pool) { jerrno(j, "swap_back_mremap_fixed", errno); munmap(tmp, g->n); return 0; }
    }
    jdbl(j, "swap_back_us", now_us() - t0);
    return 1;
}

#define SEED_C2G 0x40004u
#define SEED_G2C 0x50005u

static void swap_one(Ctx *c, int kind, const char *heap, int shape, size_t n) {
    Js j;
    jbegin(&j, kind == NEW_AHB ? "swap_ahb" : "swap_heap");
    jstr(&j, "backing", kind == NEW_AHB ? "ahb" : heap);
    jstr(&j, "shape", k_shape_names[shape]);
    juint(&j, "size", n);
    Guest g;
    NewBack nb = {.fd = -1};
    Imp o = {0};
    int ok = 0;
    if (!guest_map(shape, n, &g)) { jerrno(&j, g.step, g.err); goto out; }
    Layout before;
    layout_take(&g, &before);
    jstr(&j, "before_maps", before.win);
    if (!newback_alloc(c, kind, heap, n, &nb, &j)) goto out;
    if (!swap_in(&g, &nb, &j)) goto out;

    // 1. Content survived the swap (CPU, whole pool) and the neighbours are untouched.
    long long first = -1;
    uint64_t bad = mismatch_at((const uint32_t *)g.pool, n / 4, 0, SEED_POOL, 0, &first);
    juint(&j, "after_swap_in_cpu_bad_bytes", bad);
    int nok = neighbours(&j, &g, &before, "after_swap_in");
    if (g.alias) {
        // The alias still maps the old memfd pages: a write through the pool must not show there.
        ((volatile uint32_t *)g.pool)[0] ^= 0xFFFFFFFFu;
        jbool(&j, "alias_sees_pool_write_while_swapped", ((volatile uint32_t *)g.alias)[0] == ((volatile uint32_t *)g.pool)[0]);
        ((volatile uint32_t *)g.pool)[0] ^= 0xFFFFFFFFu;
    }

    // 2. Import the new backing as a VkBuffer.
    if (kind == NEW_AHB) {
        VkAndroidHardwareBufferPropertiesANDROID ap = {.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID};
        VkResult r = c->get_ahb_props(c->dev, nb.ahb, &ap);
        if (r) { jvk(&j, "vkGetAndroidHardwareBufferPropertiesANDROID", r); goto out; }
        VkImportAndroidHardwareBufferInfoANDROID imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID, .buffer = nb.ahb};
        import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID, n, ap.allocationSize, ap.memoryTypeBits, &imp, &o);
    } else {
        VkMemoryFdPropertiesKHR fp = {.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR};
        VkResult r = c->get_fd_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, nb.fd, &fp);
        if (r) { jvk(&j, "vkGetMemoryFdPropertiesKHR", r); goto out; }
        int dfd = dup(nb.fd);
        VkImportMemoryFdInfoKHR imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = dfd};
        import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, n, n, fp.memoryTypeBits, &imp, &o);
        if (!o.mem) close(dfd);
    }
    jimp(&j, c, &o);
    if (o.vr) goto out;
    Target t = {.buf = o.buf, .size = n, .cpu = g.pool, .mode = CPU_PLAIN, .qfot = 1, .fd = nb.fd};

    // 3. GPU sees the original guest bytes; CPU->GPU and GPU->CPU through the pool address.
    Span s0, s1, s2;
    span_gpu_read(c, &t, 0, n, SEED_POOL, &s0);
    jspan(&j, "gpu_reads_original_", &s0);
    fill_at((uint32_t *)g.pool, n / 4, 0, SEED_C2G);
    span_gpu_read(c, &t, 0, n, SEED_C2G, &s1);
    jspan(&j, "c2g_", &s1);
    memset(g.pool, 0x5A, n);
    span_gpu_write(c, &t, 0, n, SEED_G2C, &s2);
    if (!s2.vr) s2.bad = mismatch_at((const uint32_t *)g.pool, n / 4, 0, SEED_G2C, XOR_KEY, &s2.first);
    if (!s2.vr && s2.bad) s2.step = "mismatch";
    jspan(&j, "g2c_", &s2);

    // 4. Pool destruction: swap back while the import is still alive, then free the import and
    //    the new backing; the GPU-written bytes must stay at the pool address.
    if (!swap_back(&g, &j)) goto out;
    first = -1;
    uint64_t back_bad = mismatch_at((const uint32_t *)g.pool, n / 4, 0, SEED_G2C, XOR_KEY, &first);
    juint(&j, "after_swap_back_cpu_bad_bytes", back_bad);
    imp_free(c, &o);
    newback_free(&nb);
    first = -1;
    uint64_t rel_bad = mismatch_at((const uint32_t *)g.pool, n / 4, 0, SEED_G2C, XOR_KEY, &first);
    juint(&j, "after_release_cpu_bad_bytes", rel_bad);
    nok &= neighbours(&j, &g, &before, "after_swap_back");
    Layout after;
    layout_take(&g, &after);
    jbool(&j, "window_maps_same_as_before", !strcmp(after.win, before.win));
    int alias_ok = 1;
    if (g.alias) {
        first = -1;
        uint64_t abad = mismatch_at((const uint32_t *)g.alias, n / 4, 0, SEED_G2C, XOR_KEY, &first);
        juint(&j, "alias_after_swap_back_bad_bytes", abad);
        alias_ok = abad == 0;
    }
    ok = !bad && nok && !s0.bad && !s0.vr && !s1.bad && !s1.vr && !s2.bad && !s2.vr && !back_bad && !rel_bad && alias_ok;
out:
    jstatus(&j, ok ? "ok" : "fail");
    jend(&j);
    imp_free(c, &o);
    newback_free(&nb);
    guest_free(&g);
}

static const size_t k_swap_sizes[] = {2 * MB, 64 * MB, 400 * MB};

static void sec_swap_ahb(Ctx *c, int arg) {
    (void)arg;
    if (!c->ext_ahb || !c->get_ahb_props) {
        Js j;
        jbegin(&j, "swap_ahb");
        jstatus(&j, "unsupported");
        jstr(&j, "reason", "VK_ANDROID_external_memory_android_hardware_buffer absent");
        jend(&j);
        return;
    }
    for (int sh = 0; sh < SHAPE_COUNT; sh++)
        for (size_t s = 0; s < NELEM(k_swap_sizes); s++) swap_one(c, NEW_AHB, NULL, sh, k_swap_sizes[s]);
}

static void sec_swap_heap(Ctx *c, int arg) {
    (void)arg;
    if (!c->ext_dmabuf || !c->ext_fd || !c->get_fd_props) {
        Js j;
        jbegin(&j, "swap_heap");
        jstatus(&j, "unsupported");
        jstr(&j, "reason", "VK_EXT_external_memory_dma_buf or VK_KHR_external_memory_fd absent");
        jend(&j);
        return;
    }
    for (int sh = 0; sh < SHAPE_COUNT; sh++)
        for (size_t s = 0; s < NELEM(k_swap_sizes); s++) swap_one(c, NEW_HEAP, "system-uncached", sh, k_swap_sizes[s]);
}

// ---------------------------------------------------------------- V1-c: CPU throughput

#define BENCH_BYTES (64 * MB)
#define BENCH_REPS 3

static volatile uint64_t g_sink;

static void op_memset(uint8_t *p, size_t n, int v) {
    memset(p, v, n);
    __asm__ volatile("" ::: "memory");
}

// One 64-byte line per iteration (8 x 64-bit stores of distinct values).
static void op_write64(uint8_t *p, size_t n, uint64_t v) {
    uint64_t *q = (uint64_t *)p;
    for (size_t i = 0; i < n / 8; i += 8) {
        q[i] = v + i; q[i + 1] = v + i + 1; q[i + 2] = v + i + 2; q[i + 3] = v + i + 3;
        q[i + 4] = v + i + 4; q[i + 5] = v + i + 5; q[i + 6] = v + i + 6; q[i + 7] = v + i + 7;
    }
    __asm__ volatile("" ::: "memory");
}

static void op_seqread(const uint8_t *p, size_t n) {
    const uint64_t *q = (const uint64_t *)p;
    uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    for (size_t i = 0; i < n / 8; i += 4) { s0 += q[i]; s1 += q[i + 1]; s2 += q[i + 2]; s3 += q[i + 3]; }
    g_sink = s0 + s1 + s2 + s3;
}

// 4-byte loads at a shuffled permutation of every word of the buffer.
static void op_randread(const uint8_t *p, const uint32_t *idx, size_t words) {
    const uint32_t *q = (const uint32_t *)p;
    uint64_t s = 0;
    for (size_t i = 0; i < words; i++) s += q[idx[i]];
    g_sink = s;
}

enum { OP_MEMSET, OP_WRITE64, OP_SEQREAD, OP_RANDREAD, OP_COUNT };
static const char *k_op_names[] = {"seq_write_memset", "seq_write_64b", "seq_read", "rand_read_4b"};

typedef struct {
    const char *name;   // backing label
    const char *detail; // how it is mapped
    uint8_t *p;
    void *raw;
    size_t raw_len;
    int fd;             // dma-buf fd (heap / AHB) or memfd
    int sync_ends;      // DMA_BUF_IOCTL_SYNC once before and once after each measured op
    AHardwareBuffer *ahb;
    int ok;
    const char *step;   // first refused call when !ok
    int err;
    Imp imp;            // GPU import of the same memory (dma-buf attached to the GPU, as in real use)
    const char *gpu;    // import / first GPU read result
} BenchBack;

static int bench_sync(const BenchBack *b, int start, int write) {
    struct dma_buf_sync s = {.flags = (start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END) | (write ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ)};
    return ioctl(b->fd, DMA_BUF_IOCTL_SYNC, &s) ? errno : 0;
}

static void bench_map(BenchBack *b, int fd) {
    uint8_t *w = reserve_window(BENCH_BYTES, 2 * MB, &b->raw, &b->raw_len);
    void *m = w ? mmap(w, BENCH_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0) : MAP_FAILED;
    if (m == MAP_FAILED || m != w) { b->step = "mmap_fixed"; b->err = w ? errno : ENOMEM; return; }
    b->p = w;
    b->ok = 1;
}

static int cpu_khz(int cpu, const char *what) {
    char path[128];
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/%s", cpu, what);
    FILE *f = fopen(path, "re");
    if (!f) return -1;
    int khz = -1;
    if (fscanf(f, "%d", &khz) != 1) khz = -1;
    fclose(f);
    return khz;
}

// Pins to the online CPU with the highest cpuinfo_max_freq (highest index on ties); -1 if none took.
static int pin_fastest_cpu(int *max_khz, int *err) {
    long ncpu = sysconf(_SC_NPROCESSORS_CONF);
    int tried[64] = {0};
    *err = 0;
    for (;;) {
        int best = -1, bk = -1;
        for (int i = 0; i < ncpu && i < 64; i++) {
            int k = cpu_khz(i, "cpuinfo_max_freq");
            if (!tried[i] && k >= bk) { bk = k; best = i; }
        }
        if (best < 0 || bk < 0) return -1;
        tried[best] = 1;
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(best, &set);
        if (!sched_setaffinity(0, sizeof set, &set)) { *max_khz = bk; return best; }
        *err = errno;
    }
}

static int cmp_dbl(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void sec_bench(Ctx *c, int arg) {
    (void)arg;
    Js j;
    int max_khz = 0, pin_err = 0;
    int cpu = pin_fastest_cpu(&max_khz, &pin_err);
    // ~300 ms of busy work so the governor has ramped the pinned core before anything is timed.
    for (double t = now_us(); now_us() - t < 300000;) g_sink += (uint64_t)t;
    jbegin(&j, "bench_setup");
    jint(&j, "pinned_cpu", cpu);
    jint(&j, "cpu_max_khz", max_khz);
    if (pin_err) jint(&j, "pin_errno_last", pin_err);
    if (cpu >= 0) jint(&j, "cur_khz_start", cpu_khz(cpu, "scaling_cur_freq"));
    juint(&j, "bytes", BENCH_BYTES);
    jint(&j, "reps", BENCH_REPS);

    enum { NB = 6 };
    BenchBack bb[NB];
    memset(bb, 0, sizeof bb);
    for (int i = 0; i < NB; i++) bb[i].fd = -1;
    int nb = 0;

    // Guest memory as it is today: memfd shared, MAP_FIXED into a PROT_NONE window.
    BenchBack *b = &bb[nb++];
    b->name = "memfd";
    b->detail = "memfd MAP_SHARED|MAP_FIXED";
    b->fd = memfd_create("v1bench", MFD_CLOEXEC);
    if (b->fd < 0 || ftruncate(b->fd, BENCH_BYTES)) { b->step = "memfd"; b->err = errno; }
    else bench_map(b, b->fd);

    // AHB, CPU view = its dma-buf fd with MAP_FIXED (the V1-a shape).
    b = &bb[nb++];
    b->name = "ahb_fixed";
    b->detail = "AHB BLOB CPU_*_OFTEN|GPU_DATA_BUFFER, dma-buf fd MAP_SHARED|MAP_FIXED, no lock";
    AHardwareBuffer_Desc d = {
        .width = (uint32_t)BENCH_BYTES, .height = 1, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_BLOB,
        .usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER};
    int ae = AHardwareBuffer_allocate(&d, &b->ahb);
    if (!ae) {
        int fds[32], ferr = 0;
        int nf = ahb_fds(b->ahb, fds, 32, &ferr);
        if (nf >= 1) {
            b->fd = fds[0];
            for (int i = 1; i < nf; i++) close(fds[i]);
            bench_map(b, b->fd);
        } else {
            b->step = "ahb_native_handle_fd";
            b->err = ferr;
        }
    } else {
        b->ahb = NULL;
        b->step = "AHardwareBuffer_allocate";
        b->err = ae;
    }

    static const char *heaps[] = {"system-uncached", "system"};
    for (size_t h = 0; h < NELEM(heaps); h++) {
        char path[96];
        snprintf(path, sizeof path, "/dev/dma_heap/%s", heaps[h]);
        int hfd = open(path, O_RDONLY | O_CLOEXEC);
        if (hfd < 0) continue;
        struct dma_heap_allocation_data ad = {.len = BENCH_BYTES, .fd_flags = O_RDWR | O_CLOEXEC};
        int r = ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &ad);
        close(hfd);
        if (r) continue;
        b = &bb[nb++];
        b->name = h == 0 ? "heap_system_uncached" : "heap_system_nosync";
        b->detail = h == 0 ? "dma-buf heap system-uncached MAP_FIXED, no sync" : "dma-buf heap system MAP_FIXED, no sync";
        b->fd = (int)ad.fd;
        bench_map(b, b->fd);
        if (h == 1 && b->ok) {
            // Same buffer, SYNC_START before and SYNC_END after each measured op (timed with it).
            BenchBack *s = &bb[nb++];
            *s = *b;
            s->name = "heap_system_sync_ends";
            s->detail = "dma-buf heap system MAP_FIXED, SYNC_START/SYNC_END around each op (included)";
            s->sync_ends = 1;
            s->raw = NULL; // owned by the nosync entry
            s->ahb = NULL;
            s->fd = dup(b->fd);
        }
    }
    jkey(&j, "backings");
    jraw(&j, "[");
    for (int i = 0; i < nb; i++) { jraw(&j, "%s", i ? "," : ""); jesc(&j, bb[i].name); }
    jraw(&j, "]");
    jend(&j);

    size_t words = BENCH_BYTES / 4;
    uint32_t *idx = malloc(words * sizeof *idx);
    if (!idx) return;
    for (size_t i = 0; i < words; i++) idx[i] = (uint32_t)i;
    uint64_t x = 0x9E3779B97F4A7C15ull;
    for (size_t i = words - 1; i > 0; i--) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        size_t k = (size_t)(x % (i + 1));
        uint32_t tmp = idx[i]; idx[i] = idx[k]; idx[k] = tmp;
    }
    for (int i = 0; i < nb; i++)
        if (bb[i].ok && !bb[i].sync_ends) op_memset(bb[i].p, BENCH_BYTES, 0x11); // fault every page in

    // Import AHB / heap memory into Vulkan and let the GPU read it once, so the dma-buf has its GPU
    // attachment while the CPU is measured (heap SYNC ioctls only do cache maintenance for attached
    // devices). The memfd baseline stays CPU-only.
    for (int i = 0; i < nb; i++) {
        BenchBack *e = &bb[i];
        e->gpu = "none";
        if (!e->ok || e->sync_ends || !strcmp(e->name, "memfd")) continue;
        if (e->ahb && c->get_ahb_props) {
            VkAndroidHardwareBufferPropertiesANDROID ap = {.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID};
            if (c->get_ahb_props(c->dev, e->ahb, &ap)) { e->gpu = "ahb_props_fail"; continue; }
            VkImportAndroidHardwareBufferInfoANDROID ii = {.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID, .buffer = e->ahb};
            import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID, BENCH_BYTES, ap.allocationSize, ap.memoryTypeBits, &ii, &e->imp);
        } else if (!e->ahb && c->ext_dmabuf && c->get_fd_props) {
            VkMemoryFdPropertiesKHR fp = {.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR};
            if (c->get_fd_props(c->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, e->fd, &fp)) { e->gpu = "fd_props_fail"; continue; }
            int dfd = dup(e->fd);
            VkImportMemoryFdInfoKHR ii = {.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = dfd};
            import_buffer(c, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, BENCH_BYTES, BENCH_BYTES, fp.memoryTypeBits, &ii, &e->imp);
            if (!e->imp.mem) close(dfd);
        } else {
            continue;
        }
        if (e->imp.vr) { e->gpu = "import_fail"; continue; }
        Target t = {.buf = e->imp.buf, .size = BENCH_BYTES, .cpu = e->p, .mode = CPU_PLAIN, .qfot = 1, .fd = e->fd};
        Span sp;
        span_gpu_read(c, &t, 0, MB, 0, &sp);
        e->gpu = sp.vr ? "gpu_read_fail" : "imported_gpu_read";
    }
    for (int i = 0; i < nb; i++)
        if (bb[i].sync_ends) bb[i].gpu = bb[i - 1].gpu; // shares the nosync entry's buffer and import

    double us[NB][OP_COUNT][BENCH_REPS];
    double sync_us[NB][OP_COUNT][BENCH_REPS];
    int sync_err[NB];
    memset(us, 0, sizeof us);
    memset(sync_us, 0, sizeof sync_us);
    memset(sync_err, 0, sizeof sync_err);
    // Pass -1 is an untimed warm-up of every op on every backing (CPU and memory-bus DVFS settle);
    // measured passes rotate the backing order so no backing always runs first.
    for (int rep = -1; rep < BENCH_REPS; rep++)
        for (int ii = 0; ii < nb; ii++) {
            int i = rep < 0 ? ii : (ii + rep) % nb;
            if (!bb[i].ok) continue;
            for (int op = 0; op < OP_COUNT; op++) {
                int write = op == OP_MEMSET || op == OP_WRITE64;
                double t0 = now_us(), ts = 0;
                if (bb[i].sync_ends) {
                    int e = bench_sync(&bb[i], 1, write);
                    if (e) sync_err[i] = e;
                    ts = now_us() - t0;
                }
                switch (op) {
                case OP_MEMSET: op_memset(bb[i].p, BENCH_BYTES, 0x21 + rep); break;
                case OP_WRITE64: op_write64(bb[i].p, BENCH_BYTES, (uint64_t)(rep + 1) << 40); break;
                case OP_SEQREAD: op_seqread(bb[i].p, BENCH_BYTES); break;
                default: op_randread(bb[i].p, idx, words); break;
                }
                if (bb[i].sync_ends) {
                    double t1 = now_us();
                    int e = bench_sync(&bb[i], 0, write);
                    if (e) sync_err[i] = e;
                    ts += now_us() - t1;
                }
                if (rep < 0) continue;
                us[i][op][rep] = now_us() - t0;
                sync_us[i][op][rep] = ts;
            }
        }
    free(idx);
    if (cpu >= 0) {
        jbegin(&j, "bench_end");
        jint(&j, "cur_khz_end", cpu_khz(cpu, "scaling_cur_freq"));
        jstr(&j, "order", "untimed warm-up pass, then 3 passes with the backing order rotated by one each pass");
        jint(&j, "running_on", sched_getcpu());
        jend(&j);
    }

    for (int i = 0; i < nb; i++) {
        jbegin(&j, "bench");
        jstr(&j, "backing", bb[i].name);
        jstr(&j, "detail", bb[i].detail);
        jstr(&j, "gpu", bb[i].gpu ? bb[i].gpu : "none");
        if (!bb[i].ok) {
            jstatus(&j, "fail");
            jstr(&j, "step", bb[i].step);
            jint(&j, "err", bb[i].err);
            jend(&j);
            continue;
        }
        jstatus(&j, sync_err[i] ? "fail" : "ok");
        if (sync_err[i]) jint(&j, "sync_errno", sync_err[i]);
        for (int op = 0; op < OP_COUNT; op++) {
            double s[BENCH_REPS];
            jkey(&j, k_op_names[op]);
            jraw(&j, "{\"us\":[");
            for (int r = 0; r < BENCH_REPS; r++) { jraw(&j, "%s%.1f", r ? "," : "", us[i][op][r]); s[r] = us[i][op][r]; }
            qsort(s, BENCH_REPS, sizeof s[0], cmp_dbl);
            double med = s[BENCH_REPS / 2];
            jraw(&j, "],\"median_us\":%.1f,\"median_mib_s\":%.1f", med, (double)BENCH_BYTES / MB / (med / 1e6));
            if (bb[i].sync_ends) {
                jraw(&j, ",\"sync_us\":[");
                for (int r = 0; r < BENCH_REPS; r++) jraw(&j, "%s%.1f", r ? "," : "", sync_us[i][op][r]);
                jraw(&j, "]");
            }
            jraw(&j, "}");
        }
        jend(&j);
    }
    for (int i = 0; i < nb; i++) {
        imp_free(c, &bb[i].imp);
        if (bb[i].raw) munmap(bb[i].raw, bb[i].raw_len);
        if (bb[i].fd >= 0) close(bb[i].fd);
        if (bb[i].ahb) AHardwareBuffer_release(bb[i].ahb);
    }
}

// ---------------------------------------------------------------- V1-e: sparse buffer over AHBs

#define SPARSE_TOTAL (400 * MB)
#define SPARSE_CHUNKS 4

static void sec_sparse(Ctx *c, int arg) {
    (void)arg;
    Js j;
    VkPhysicalDeviceFeatures f;
    vkGetPhysicalDeviceFeatures(c->pd, &f);
    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &qn, NULL);
    VkQueueFamilyProperties qfp[16];
    if (qn > 16) qn = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &qn, qfp);
    int sparse_compute_qf = -1;
    jbegin(&j, "sparse_caps");
    jbool(&j, "sparseBinding", f.sparseBinding);
    jbool(&j, "sparseResidencyBuffer", f.sparseResidencyBuffer);
    jbool(&j, "sparseResidencyAliased", f.sparseResidencyAliased);
    juint(&j, "sparseAddressSpaceSize", c->props.limits.sparseAddressSpaceSize);
    jkey(&j, "queue_families");
    jraw(&j, "[");
    for (uint32_t i = 0; i < qn; i++) {
        jraw(&j, "%s{\"i\":%u,\"flags\":\"0x%x\",\"count\":%u,\"sparse\":%s}", i ? "," : "", i, qfp[i].queueFlags, qfp[i].queueCount,
             (qfp[i].queueFlags & VK_QUEUE_SPARSE_BINDING_BIT) ? "true" : "false");
        if (sparse_compute_qf < 0 && (qfp[i].queueFlags & (VK_QUEUE_SPARSE_BINDING_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_SPARSE_BINDING_BIT | VK_QUEUE_COMPUTE_BIT))
            sparse_compute_qf = (int)i;
    }
    jraw(&j, "]");
    jint(&j, "sparse_compute_queue_family", sparse_compute_qf);
    if (c->ext_ahb) {
        static const struct { VkBufferCreateFlags fl; const char *k; } q[] = {
            {VK_BUFFER_CREATE_SPARSE_BINDING_BIT, "ahb_ext_props_sparse_binding"},
            {VK_BUFFER_CREATE_SPARSE_BINDING_BIT | VK_BUFFER_CREATE_SPARSE_RESIDENCY_BIT, "ahb_ext_props_sparse_residency"},
        };
        for (size_t i = 0; i < NELEM(q); i++) {
            VkPhysicalDeviceExternalBufferInfo info = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO, .flags = q[i].fl,
                .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID};
            VkExternalBufferProperties out = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
            vkGetPhysicalDeviceExternalBufferProperties(c->pd, &info, &out);
            jhex(&j, q[i].k, out.externalMemoryProperties.externalMemoryFeatures);
        }
    }
    jend(&j);

    jbegin(&j, "sparse");
    juint(&j, "size", SPARSE_TOTAL);
    jint(&j, "chunks", SPARSE_CHUNKS);
    if (!f.sparseBinding || sparse_compute_qf < 0 || !c->ext_ahb) {
        jstatus(&j, "unsupported");
        jstr(&j, "reason", !f.sparseBinding ? "sparseBinding feature absent"
                           : sparse_compute_qf < 0 ? "no queue family with SPARSE_BINDING and COMPUTE"
                                                   : "VK_ANDROID_external_memory_android_hardware_buffer absent");
        jend(&j);
        return;
    }
    // Recreate the device with sparseBinding enabled on a SPARSE_BINDING|COMPUTE queue.
    ctx_destroy(c);
    static VkPhysicalDeviceFeatures want;
    memset(&want, 0, sizeof want);
    want.sparseBinding = VK_TRUE;
    g_ctx_features = &want;
    g_ctx_queue_flags = VK_QUEUE_COMPUTE_BIT | VK_QUEUE_SPARSE_BINDING_BIT;
    if (!ctx_init(c)) { jstatus(&j, "fail"); jstr(&j, "step", "ctx_init_sparse"); jend(&j); return; }
    jint(&j, "queue_family", c->qf);

    const VkDeviceSize chunk = SPARSE_TOTAL / SPARSE_CHUNKS;
    VkBuffer buf = VK_NULL_HANDLE;
    VkDeviceMemory mem[SPARSE_CHUNKS] = {0};
    AHardwareBuffer *ahb[SPARSE_CHUNKS] = {0};
    int fds[SPARSE_CHUNKS];
    for (int i = 0; i < SPARSE_CHUNKS; i++) fds[i] = -1;
    void *raw = NULL;
    size_t raw_len = 0;
    int ok = 0;
    VkResult r;

    VkExternalMemoryBufferCreateInfo ext = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
                                            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID};
    VkBufferCreateInfo bi = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = &ext, .flags = VK_BUFFER_CREATE_SPARSE_BINDING_BIT, .size = SPARSE_TOTAL,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    r = vkCreateBuffer(c->dev, &bi, NULL, &buf);
    jstr(&j, "create_ext_ahb_vk", vkr(r));
    int with_ext = 1;
    if (r) {
        buf = VK_NULL_HANDLE;
        bi.pNext = NULL;
        with_ext = 0;
        r = vkCreateBuffer(c->dev, &bi, NULL, &buf);
        jstr(&j, "create_plain_vk", vkr(r));
        if (r) { buf = VK_NULL_HANDLE; jvk(&j, "vkCreateBuffer", r); goto out; }
    }
    jbool(&j, "buffer_has_ahb_handle_type", with_ext);
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(c->dev, buf, &mr);
    juint(&j, "req_size", mr.size);
    juint(&j, "req_alignment", mr.alignment);
    jhex(&j, "req_bits", mr.memoryTypeBits);
    if (chunk % mr.alignment) { jstr(&j, "step", "chunk_not_multiple_of_sparse_alignment"); goto out; }

    VkSparseMemoryBind binds[SPARSE_CHUNKS];
    memset(binds, 0, sizeof binds);
    jkey(&j, "chunk_imports");
    jraw(&j, "[");
    int imported = 0;
    for (int i = 0; i < SPARSE_CHUNKS; i++) {
        jraw(&j, "%s{", i ? "," : "");
        AHardwareBuffer_Desc d = {
            .width = (uint32_t)chunk, .height = 1, .layers = 1, .format = AHARDWAREBUFFER_FORMAT_BLOB,
            .usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER};
        int e = AHardwareBuffer_allocate(&d, &ahb[i]);
        if (e) { ahb[i] = NULL; jraw(&j, "\"ahb_err\":%d}", e); break; }
        VkAndroidHardwareBufferPropertiesANDROID ap = {.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID};
        r = c->get_ahb_props(c->dev, ahb[i], &ap);
        jraw(&j, "\"props_vk\":\"%s\",\"allocation_size\":%llu,\"memory_type_bits\":\"0x%x\"", vkr(r), (unsigned long long)ap.allocationSize, ap.memoryTypeBits);
        if (r) { jraw(&j, "}"); break; }
        int type = pick_type(c, ap.memoryTypeBits & mr.memoryTypeBits);
        jraw(&j, ",\"type\":%d", type);
        if (type < 0) { jraw(&j, ",\"step\":\"no_common_memory_type\"}"); break; }
        VkImportAndroidHardwareBufferInfoANDROID imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID, .buffer = ahb[i]};
        VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &imp, .allocationSize = ap.allocationSize, .memoryTypeIndex = (uint32_t)type};
        r = vkAllocateMemory(c->dev, &ai, NULL, &mem[i]);
        jraw(&j, ",\"import_vk\":\"%s\"", vkr(r));
        if (r) { mem[i] = VK_NULL_HANDLE; jraw(&j, "}"); break; }
        int afd[32], ferr = 0;
        int nf = ahb_fds(ahb[i], afd, 32, &ferr);
        if (nf >= 1) {
            fds[i] = afd[0];
            for (int k = 1; k < nf; k++) close(afd[k]);
        }
        jraw(&j, ",\"fd_ok\":%s}", nf >= 1 ? "true" : "false");
        binds[i] = (VkSparseMemoryBind){.resourceOffset = (VkDeviceSize)i * chunk, .size = chunk, .memory = mem[i], .memoryOffset = 0};
        imported++;
    }
    jraw(&j, "]");
    if (imported != SPARSE_CHUNKS) {
        jstr(&j, "step", "chunk_import");
        if (with_ext) {
            // Same sparse buffer without the AHB handle type: which memory types would it take?
            VkBuffer pb = VK_NULL_HANDLE;
            VkBufferCreateInfo pbi = bi;
            pbi.pNext = NULL;
            VkResult pr = vkCreateBuffer(c->dev, &pbi, NULL, &pb);
            jstr(&j, "plain_sparse_create_vk", vkr(pr));
            if (!pr) {
                VkMemoryRequirements pmr;
                vkGetBufferMemoryRequirements(c->dev, pb, &pmr);
                jhex(&j, "plain_sparse_req_bits", pmr.memoryTypeBits);
                vkDestroyBuffer(c->dev, pb, NULL);
            }
            // And a non-sparse buffer with the AHB handle type (what V0 / V1-a bind AHB memory to).
            VkBufferCreateInfo nbi = bi;
            nbi.flags = 0;
            pr = vkCreateBuffer(c->dev, &nbi, NULL, &pb);
            if (!pr) {
                VkMemoryRequirements pmr;
                vkGetBufferMemoryRequirements(c->dev, pb, &pmr);
                jhex(&j, "nonsparse_ahb_req_bits", pmr.memoryTypeBits);
                vkDestroyBuffer(c->dev, pb, NULL);
            }
        }
        for (uint32_t t = 0; t < c->memp.memoryTypeCount; t++) {
            char key[32], name[160];
            snprintf(key, sizeof key, "memtype_%u", t);
            mem_flag_names(c->memp.memoryTypes[t].propertyFlags, name, sizeof name);
            jstr(&j, key, name);
        }
        goto out;
    }

    VkSparseBufferMemoryBindInfo bbi = {.buffer = buf, .bindCount = SPARSE_CHUNKS, .pBinds = binds};
    VkBindSparseInfo bsi = {.sType = VK_STRUCTURE_TYPE_BIND_SPARSE_INFO, .bufferBindCount = 1, .pBufferBinds = &bbi};
    double t0 = now_us();
    r = vkQueueBindSparse(c->q, 1, &bsi, c->fence);
    jstr(&j, "bind_sparse_vk", vkr(r));
    if (r) { jvk(&j, "vkQueueBindSparse", r); goto out; }
    r = vkWaitForFences(c->dev, 1, &c->fence, VK_TRUE, 5000000000ull);
    vkResetFences(c->dev, 1, &c->fence);
    jdbl(&j, "bind_sparse_us", now_us() - t0);
    if (r) { jvk(&j, "bind_sparse_fence", r); goto out; }

    // CPU view: the chunks' dma-buf fds MAP_FIXED back to back in one reserved window.
    uint8_t *w = reserve_window(SPARSE_TOTAL, 2 * MB, &raw, &raw_len);
    if (!w) { jerrno(&j, "reserve", errno); goto out; }
    for (int i = 0; i < SPARSE_CHUNKS; i++) {
        void *m = fds[i] >= 0 ? mmap(w + i * chunk, chunk, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fds[i], 0) : MAP_FAILED;
        if (m == MAP_FAILED || m != w + i * chunk) { jerrno(&j, "chunk_mmap_fixed", fds[i] >= 0 ? errno : EBADF); goto out; }
    }
    jbool(&j, "cpu_view_contiguous", 1);
    Target t = {.buf = buf, .size = SPARSE_TOTAL, .cpu = w, .mode = CPU_PLAIN, .qfot = with_ext, .fd = -1};

    Span s1, s2;
    fill_at((uint32_t *)w, SPARSE_TOTAL / 4, 0, SEED_C2G);
    span_gpu_read(c, &t, 0, SPARSE_TOTAL, SEED_C2G, &s1);
    jspan(&j, "whole_c2g_", &s1);
    memset(w, 0x5A, SPARSE_TOTAL);
    span_gpu_write(c, &t, 0, SPARSE_TOTAL, SEED_G2C, &s2);
    if (!s2.vr) s2.bad = mismatch_at((const uint32_t *)w, SPARSE_TOTAL / 4, 0, SEED_G2C, XOR_KEY, &s2.first);
    if (!s2.vr && s2.bad) s2.step = "mismatch";
    jspan(&j, "whole_g2c_", &s2);
    ok = !s1.vr && !s1.bad && !s2.vr && !s2.bad;

    // A 2 MiB window centred on every chunk boundary, one dispatch each.
    jkey(&j, "boundaries");
    jraw(&j, "[");
    for (int i = 1; i < SPARSE_CHUNKS; i++) {
        VkDeviceSize off = (VkDeviceSize)i * chunk - MB, len = 2 * MB;
        Span b1, b2;
        fill_at((uint32_t *)(w + off), len / 4, off / 4, SEED_C2G + (uint32_t)i);
        span_gpu_read(c, &t, off, len, SEED_C2G + (uint32_t)i, &b1);
        memset(w + off, 0x5A, len);
        span_gpu_write(c, &t, off, len, SEED_G2C + (uint32_t)i, &b2);
        if (!b2.vr) b2.bad = mismatch_at((const uint32_t *)(w + off), len / 4, off / 4, SEED_G2C + (uint32_t)i, XOR_KEY, &b2.first);
        jraw(&j, "%s{\"at\":%llu,\"c2g_bad_bytes\":%llu,\"c2g_vk\":\"%s\",\"g2c_bad_bytes\":%llu,\"g2c_vk\":\"%s\"}", i > 1 ? "," : "",
             (unsigned long long)(off + MB), (unsigned long long)b1.bad, vkr(b1.vr), (unsigned long long)b2.bad, vkr(b2.vr));
        ok &= !b1.vr && !b1.bad && !b2.vr && !b2.bad;
    }
    jraw(&j, "]");
out:
    jstatus(&j, ok ? "ok" : "fail");
    jend(&j);
    if (c->dev) vkDeviceWaitIdle(c->dev);
    if (raw) munmap(raw, raw_len);
    if (buf) vkDestroyBuffer(c->dev, buf, NULL);
    for (int i = 0; i < SPARSE_CHUNKS; i++) {
        if (mem[i]) vkFreeMemory(c->dev, mem[i], NULL);
        if (fds[i] >= 0) close(fds[i]);
        if (ahb[i]) AHardwareBuffer_release(ahb[i]);
    }
}

// ---------------------------------------------------------------- driver

static const Section k_v1_sections[] = {
    {"device", sec_device, 0},
    {"ahb", sec_ahb_v1, 0},
    {"dmabuf", sec_dmabuf, 0},
    {"heapcpu", sec_heapcpu, 0},
    {"swap_ahb", sec_swap_ahb, 0},
    {"swap_heap", sec_swap_heap, 0},
    {"bench", sec_bench, 0},
    {"sparse", sec_sparse, 0},
};

static int run_one(const Section *s) {
    g_ctx_features = NULL;
    g_ctx_queue_flags = VK_QUEUE_COMPUTE_BIT;
    Ctx c;
    int ok = ctx_init(&c);
    if (ok) s->fn(&c, s->arg);
    ctx_destroy(&c);
    fflush(stdout);
    return ok;
}

// `list`: comma-separated section names, or "all". Returns 0 when every listed section finished.
static int run_sections(const char *list) {
    g_probe_tag = "v1";
    start_line(list);
    double t0 = now_us();
    int done = 0, ran = 0;
    Js j;
    for (size_t i = 0; i < NELEM(k_v1_sections); i++) {
        const char *name = k_v1_sections[i].name;
        if (strcmp(list, "all")) {
            size_t l = strlen(name);
            const char *p = list;
            int hit = 0;
            while ((p = strstr(p, name))) {
                if ((p == list || p[-1] == ',') && (p[l] == ',' || p[l] == 0)) { hit = 1; break; }
                p += l;
            }
            if (!hit) continue;
        }
        ran++;
        double s0 = now_us();
        jbegin(&j, "section");
        jstr(&j, "name", name);
        if (!g_isolated) {
            int ok = run_one(&k_v1_sections[i]);
            jstatus(&j, ok ? "done" : "init_fail");
            done += ok;
        } else {
            pid_t pid = fork();
            if (pid == 0) {
                alarm(V1_SECTION_ALARM_S);
                _exit(run_one(&k_v1_sections[i]) ? 0 : 2);
            }
            int st = 0;
            if (pid < 0 || waitpid(pid, &st, 0) < 0) st = -1;
            if (st == -1) {
                jstatus(&j, "fail");
                jerrno(&j, "fork_or_wait", errno);
            } else if (WIFSIGNALED(st)) {
                jstatus(&j, WTERMSIG(st) == SIGALRM ? "timeout" : "crash");
                jint(&j, "signal", WTERMSIG(st));
            } else {
                jstatus(&j, WEXITSTATUS(st) == 0 ? "done" : "init_fail");
                jint(&j, "exit", WEXITSTATUS(st));
                done += WEXITSTATUS(st) == 0;
            }
        }
        jdbl(&j, "ms", (now_us() - s0) / 1000.0);
        jend(&j);
    }
    jbegin(&j, "end");
    jint(&j, "sections_run", ran);
    jint(&j, "sections_done", done);
    jdbl(&j, "total_ms", (now_us() - t0) / 1000.0);
    jend(&j);
    return done == ran ? 0 : 1;
}

#ifdef V1_JNI
#undef jint
#include <jni.h>
// Called by org.s2arm.probe.v1.ProbeActivity on a background thread. JSON lines go to `out_path`
// (the app's private files dir); sections run in this app process, one after another.
JNIEXPORT jint JNICALL Java_org_s2arm_probe_v1_ProbeActivity_nativeRun(JNIEnv *env, jclass cls, jstring out_path, jstring sections) {
    (void)cls;
    const char *out = (*env)->GetStringUTFChars(env, out_path, NULL);
    const char *list = (*env)->GetStringUTFChars(env, sections, NULL);
    int rc = 3;
    int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd >= 0) {
        fflush(stdout);
        if (dup2(fd, STDOUT_FILENO) >= 0) {
            setvbuf(stdout, NULL, _IOLBF, 0);
            g_isolated = 0;
            rc = run_sections(list);
            fflush(stdout);
        }
        close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, sections, list);
    (*env)->ReleaseStringUTFChars(env, out_path, out);
    return rc;
}
#else
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    return run_sections(argc > 1 ? argv[1] : "all");
}
#endif
