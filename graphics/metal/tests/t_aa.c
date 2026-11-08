// Real Metal AA tests: analytic edges, exact planes, crop/flip, resize,
// pre-scale output, frozen snapshots and concurrent screenshot readers.
#include "../gal_abi.h"
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <objc/runtime.h>
#include <objc/message.h>

static int checks, failures;
#define CHECK(condition, ...) do { checks++; if (!(condition)) { failures++; printf("FAIL: " __VA_ARGS__); puts(""); } } while (0)
NXGAL_API uint64_t nxgal_helper_compiles(void);

static nxgal_tex_info info(int w, int h, int format) {
    return (nxgal_tex_info){w, h, 1, 1, 1, 1, 1, 4, format, 0, 1, {2, 3, 4, 5}};
}
static uint32_t texture(int w, int h, int format, const uint8_t *data) {
    nxgal_tex_info i = info(w, h, format);
    uint32_t t = nxgal_tex_create(&i);
    if (data) nxgal_tex_set_data(t, 0, 0, NULL, data, (uint64_t)w * h * 4);
    return t;
}
static void capture(int processed, uint8_t *data, int w, int h) {
    int width = 0, height = 0;
    int n = processed ? nxgal_screenshot_processed(data, w * h * 4, &width, &height) : nxgal_screenshot(data, w * h * 4, &width, &height);
    CHECK(n == w * h * 4 && width == w && height == h, "capture size: %d %dx%d, expected %dx%d", n, width, height, w, h);
}
static void bgra(const uint8_t *rgba, uint8_t *out, int n) {
    for (int p = 0; p < n; p++) { out[4*p] = rgba[4*p+2]; out[4*p+1] = rgba[4*p+1]; out[4*p+2] = rgba[4*p]; out[4*p+3] = 255; }
}
static void plane(uint8_t *data, int w, int h, int value) {
    for (int p = 0; p < w*h; p++) { data[4*p] = value; data[4*p+1] = 79; data[4*p+2] = 153; data[4*p+3] = 37; }
}
static void diagonal(uint8_t *data, int w, int h) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int v = x + 0.5 > 0.27 * (y + 0.5) + 8.31 ? 255 : 0;
        uint8_t *p = data + 4*(y*w+x); p[0] = p[1] = p[2] = v; p[3] = 37;
    }
}
// Exact unit-box coverage of x > slope*y+offset, independent of the AA shader.
static double integral(double x) { return x <= 0 ? 0 : x < 1 ? x*x/2 : x-0.5; }
static double decode_srgb(double x) { return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4); }
static double error(const uint8_t *data, int w, int h, int linear) {
    double sum = 0;
    for (int y = 3; y < h-3; y++) for (int x = 3; x < w-3; x++) {
        double a = x + 1 - 0.27*y - 8.31;
        double coverage = (integral(a) - integral(a-0.27)) / 0.27;
        double value = data[4*(y*w+x)] / 255.0;
        if (linear) value = decode_srgb(value);
        double d = value - coverage;
        sum += d*d;
    }
    return sum;
}

static void edges(void) {
    enum { W = 67, H = 53, N = W*H*4 };
    uint8_t source[N], raw[N], expected[N], output[6][N]; diagonal(source, W, H); bgra(source, expected, W*H);
    uint32_t t = texture(W, H, 36, source);
    nxgal_crop crop = {0,0,0,0,0,0,1,16,9};
    for (int mode = 0; mode <= 5; mode++) {
        uint64_t before[64], after[64];
        nxgal_window_set_antialiasing(mode); nxgal_perf_read(before,64,0); nxgal_present(t, &crop); nxgal_perf_read(after,64,0);
        if (!mode) CHECK(after[27] == before[27] && after[25] == before[25]+1, "AA off added a compute pass or extra render pass");
        capture(0, raw, W, H); capture(1, output[mode], W, H);
        CHECK(memcmp(raw, expected, N) == 0, "mode %d changed raw screenshot", mode);
        int fractional = 0, distant = 0, alpha = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int p = 4*(y*W+x); int value = output[mode][p];
            fractional += value > 0 && value < 255;
            if (fabs(x+0.5 - 0.27*(y+0.5) - 8.31) > 4 && output[mode][p] != expected[p]) distant++;
            alpha += output[mode][p+3] != 255;
        }
        printf("mode %d: fractional=%d, distant changes=%d, coverage error=%.6f\n", mode, fractional, distant, error(output[mode], W, H, mode>=2));
        CHECK(distant == 0 && alpha == 0, "mode %d altered a flat region or alpha", mode);
        if (mode) {
            CHECK(fractional > 0, "mode %d did not smooth the analytic edge", mode);
            CHECK(error(output[mode], W, H, mode>=2) < error(output[0], W, H, mode>=2), "mode %d did not improve analytic edge coverage", mode);
        }
    }
    CHECK(memcmp(output[0], expected, N) == 0, "AA off is not byte-identical");
    CHECK(memcmp(output[1], output[3], N) == 0, "mode 1 (the old Fxaa value) is not drawn as SMAA Medium");   // FXAA removed 10-30 (no license grant)
    CHECK(memcmp(output[3], output[4], N) != 0, "SMAA Medium and High outputs are identical");
    // Same binary geometry has identical SMAA edge weights at these contrasts.
    // Check its neighborhood mixing against independent sRGB transfer math.
    uint8_t toned[N], toned_out[N];
    for (int p=0;p<W*H;p++) { toned[4*p]=toned[4*p+1]=toned[4*p+2]=source[4*p]?192:64; toned[4*p+3]=37; }
    uint32_t tone_texture=texture(W,H,36,toned);
    nxgal_window_set_antialiasing(4); nxgal_present(tone_texture,&crop); capture(1,toned_out,W,H);
    double max_error=0,lo=decode_srgb(64.0/255),hi=decode_srgb(192.0/255);
    for(int p=0;p<W*H;p++) {
        double expected_linear=lo+(hi-lo)*decode_srgb(output[4][4*p]/255.0);
        double e=fabs(decode_srgb(toned_out[4*p]/255.0)-expected_linear); if(e>max_error) max_error=e;
    }
    CHECK(max_error<0.006,"SMAA mixed encoded values instead of linear light: error %.6f",max_error);
    nxgal_tex_release(tone_texture);
    nxgal_window_set_antialiasing(4); nxgal_present(t, &crop);
    plane(source, W, H, 21); nxgal_tex_set_data(t, 0, 0, NULL, source, N);
    nxgal_window_set_antialiasing(0); capture(1, raw, W, H);
    CHECK(memcmp(raw, output[4], N) == 0, "source mutation / setting change modified the frozen AA frame");
    // Presentation must scale the processed frame, not run AA on the resized image.
    nxgal_window_set_scaling(1, 0);
    uint32_t dst = texture(2*W, 2*H, 36, NULL); CHECK(nxgal_window_render_to(dst) == 0, "render_to failed");
    uint8_t scaled[4*N]; nxgal_tex_get_data(dst, 0, 0, scaled, sizeof scaled);
    int bad = 0;
    for (int y = 0; y < 2*H; y++) for (int x = 0; x < 2*W; x++) {
        const uint8_t *a = scaled+4*(y*2*W+x), *b = output[4]+4*((y/2)*W+x/2);
        if (a[0] != b[2] || a[1] != b[1] || a[2] != b[0] || a[3] != 255) bad++;
    }
    CHECK(bad == 0, "presentation differs from nearest-scaled AA output at %d pixels", bad);
    nxgal_tex_release(dst); nxgal_tex_release(t);
}

static void crop_resize_color(void) {
    const int sizes[][2] = {{1,1},{2,3},{31,17},{96,64},{37,25}};
    for (int k = 0; k < 5; k++) {
        int w = sizes[k][0], h = sizes[k][1], n = w*h*4;
        uint8_t *source = malloc(n), *expected = malloc(n), *out = malloc(n);
        plane(source, w, h, 37+k*21); bgra(source, expected, w*h);
        uint32_t t = texture(w, h, 54, source); // sRGB source must retain encoded bytes.
        for (int mode = 0; mode <= 5; mode++) {
            nxgal_window_set_antialiasing(mode); nxgal_present(t, NULL); capture(1, out, w, h);
            CHECK(memcmp(out, expected, n) == 0, "mode %d, %dx%d sRGB plane changed: first pixel %u,%u,%u,%u expected %u,%u,%u,%u", mode, w, h,
                  out[0],out[1],out[2],out[3],expected[0],expected[1],expected[2],expected[3]);
        }
        nxgal_tex_release(t); free(source); free(expected); free(out);
    }
    enum { W=79,H=61,CW=67,CH=49,N=CW*CH*4 };
    uint8_t source[W*H*4], transformed[N], out[N], ref[N]; diagonal(source, W, H);
    for (int y=0;y<CH;y++) for (int x=0;x<CW;x++) memcpy(transformed+4*(y*CW+x), source+4*((4+CH-1-y)*W+5+CW-1-x), 4);
    uint32_t t = texture(W,H,36,source), reference = texture(CW,CH,36,transformed);
    nxgal_crop crop = {5,5+CW,4,4+CH,1,1,1,16,9};
    for (int mode = 1; mode <= 5; mode++) {
        nxgal_window_set_antialiasing(mode); nxgal_present(t,&crop); capture(1,out,CW,CH);
        nxgal_present(reference,NULL); capture(1,ref,CW,CH);
        CHECK(memcmp(out,ref,N)==0,"mode %d ran before crop/flip",mode);
    }
    nxgal_tex_release(t); nxgal_tex_release(reference);
}

static atomic_int stop_reader, reader_errors, reader_frames;
static void *reader(void *unused) {
    (void)unused; uint8_t data[96*64*4];
    while (!atomic_load(&stop_reader)) {
        int w,h;
        int n = nxgal_screenshot_processed(data,sizeof data,&w,&h);
        if (n <= 0 || n > (int)sizeof data) { atomic_fetch_add(&reader_errors,1); continue; }
        int bad = 0;
        for (int p=0;p<w*h;p++) if (data[4*p] != 153 || data[4*p+1] != 79 || (data[4*p+2] != 29 && data[4*p+2] != 211) || data[4*p+3] != 255 || data[4*p+2] != data[2]) { bad=1; break; }
        if (bad) atomic_fetch_add(&reader_errors,1);
        atomic_fetch_add(&reader_frames,1);
    }
    return NULL;
}
static void concurrent_snapshots(void) {
    uint8_t data[96*64*4]; plane(data,96,64,29);
    uint32_t t = texture(96,64,36,data); nxgal_window_set_antialiasing(4); nxgal_present(t,NULL);
    pthread_t thread; CHECK(pthread_create(&thread,NULL,reader,NULL)==0,"screenshot reader did not start");
    for(int i=0;i<36;i++) {
        plane(data,96,64,i&1?29:211); nxgal_tex_set_data(t,0,0,NULL,data,sizeof data);
        nxgal_window_set_antialiasing(i%6); nxgal_present(t,NULL);
    }
    atomic_store(&stop_reader,1); pthread_join(thread,NULL);
    CHECK(atomic_load(&reader_frames)>0,"concurrent screenshot reader captured no frames");
    CHECK(atomic_load(&reader_errors)==0,"concurrent snapshots mixed frames: %d",atomic_load(&reader_errors));
    printf("concurrent processed screenshots: %d\n",atomic_load(&reader_frames));
    nxgal_tex_release(t);
}

// AA encode failure (audit 11-01 P1-25): the frame must still be counted and become the latest snapshot, shown without AA
// (processed screenshot == raw frame); previously present returned before commit, leaving the previous frame (and an open compute encoder).
// Fault injection gal_aa_test_fail (gal_aa.m): 1 = fail at entry, 2 = fail after edge/blend passes were encoded.
extern int gal_aa_test_fail;
static void aa_failure(void) {
    enum { W = 40, H = 24, N = W*H*4 };
    uint8_t data[N], expected[N], out[N], raw[N];
    plane(data, W, H, 29);
    uint32_t t = texture(W, H, 36, data);
    nxgal_window_set_antialiasing(4); nxgal_present(t, NULL);
    const int values[3] = {0, 211, 97};
    for (int k = 1; k <= 2; k++) {
        plane(data, W, H, values[k]); nxgal_tex_set_data(t, 0, 0, NULL, data, N); bgra(data, expected, W*H);
        uint64_t s0[4], s1[4]; nxgal_window_stats(s0);
        gal_aa_test_fail = k; nxgal_present(t, NULL); gal_aa_test_fail = 0;
        nxgal_window_stats(s1);
        CHECK(s1[0] == s0[0] + 1, "AA failure %d: present not counted (%llu -> %llu)", k, (unsigned long long)s0[0], (unsigned long long)s1[0]);
        capture(0, raw, W, H); capture(1, out, W, H);
        CHECK(memcmp(raw, expected, N) == 0, "AA failure %d: raw snapshot is not the new frame (first byte %u, expected %u)", k, raw[0], expected[0]);
        CHECK(memcmp(out, expected, N) == 0, "AA failure %d: processed snapshot is not the new frame without AA (first byte %u, expected %u)", k, out[0], expected[0]);
    }
    // AA recovers on the next frame: the analytic diagonal gets fractional edge values only through SMAA.
    uint8_t diag[N]; diagonal(diag, W, H); nxgal_tex_set_data(t, 0, 0, NULL, diag, N);
    nxgal_present(t, NULL); capture(1, out, W, H);
    int fractional = 0; for (int p = 0; p < W*H; p++) fractional += out[4*p] > 0 && out[4*p] < 255;
    CHECK(fractional > 0, "AA did not recover after encode failures");
    printf("AA failure fallback: fractional after recovery=%d\n", fractional);
    nxgal_tex_release(t);
}

int gal_present_drain(int timeout_ms);
static double seconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void mailbox(void) {
    id cls = (id)objc_getClass("CAMetalLayer");
    id layer = ((id (*)(id,SEL))objc_msgSend)(cls,sel_registerName("layer"));
    ((id (*)(id,SEL))objc_msgSend)(layer,sel_registerName("retain"));
    CHECK(layer != NULL,"CAMetalLayer creation failed"); if (!layer) return;
    uint8_t source[96*64*4]; plane(source,96,64,211);
    uint32_t t=texture(96,64,36,source);
    nxgal_window_set_size(192,128); nxgal_window_set_vsync(1); nxgal_window_set_layer((void *)layer);
    uint64_t start[4],end[4]; nxgal_window_stats(start);
    for(int i=0;i<18;i++) { nxgal_window_set_antialiasing(i%6); nxgal_present(t,NULL); }
    double deadline=seconds()+5;
    for (;;) {
        nxgal_window_stats(end);
        if (end[1]-start[1]+end[2]-start[2]+end[3]-start[3]>=18 || seconds()>=deadline) break;
        struct timespec pause={0,5000000}; nanosleep(&pause,NULL);
    }
    CHECK(end[0]-start[0]==18,"mailbox lost a producer frame");
    CHECK(end[1]-start[1]+end[2]-start[2]+end[3]-start[3]==18,"AA mailbox counters did not close");
    CHECK(end[1]>start[1] && end[3]==start[3],"AA mailbox did not present successfully");
    CHECK(gal_present_drain(3000),"AA presentation queue did not drain");
    uint8_t out[sizeof source],expected[sizeof source]; bgra(source,expected,96*64); capture(1,out,96,64);
    CHECK(memcmp(out,expected,sizeof out)==0,"mailbox changed the latest processed snapshot");
    printf("AA mailbox: shown=%llu dropped=%llu missing=%llu\n",(unsigned long long)(end[1]-start[1]),(unsigned long long)(end[2]-start[2]),(unsigned long long)(end[3]-start[3]));
    nxgal_window_set_layer(NULL); nxgal_tex_release(t);
    ((id (*)(id,SEL))objc_msgSend)(layer,sel_registerName("release"));
}

int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    nxgal_window_set_antialiasing(3); // Settings are valid before renderer initialization.
    if (nxgal_init(0)) return 2;
    edges(); crop_resize_color(); concurrent_snapshots(); aa_failure(); mailbox();
    CHECK(nxgal_helper_compiles()==0,"AA helper libraries compiled at runtime: %llu",(unsigned long long)nxgal_helper_compiles());
    nxgal_shutdown();
    printf("%d / %d checks passed\n",checks-failures,checks);
    return failures?1:0;
}
