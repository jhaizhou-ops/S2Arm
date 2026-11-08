// Real Metal resources through the production GAL entry points, with no host or backend stubs.
// This verifies resource-table reset and a second session; it does not execute a game or validate iOS.
#import "../gal_internal.h"
#include "../gal_formats.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void nxgal_request_stop(void);
int nxgal_shutdown_session(void);
void gal_upload_stats(int out[3]);

GAL_MTL4_ZONE_BEGIN
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL round %d: %s\n", round + 1, #c); return 1; } } while (0)
int main(int argc, char **argv) {
    (void)argc;
    if (setenv("NXGAL_ASYNC_XC", "1", 1)) return 2;
    int incomplete_samples = 0, complete_samples = 0;
    for (int round = 0; round < 10; round++) @autoreleasepool {
        REQUIRE(nxgal_init(0) == 0);
        NSString *inputs = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"t_prog_in"];
        NSData *vs = [NSData dataWithContentsOfFile:[inputs stringByAppendingPathComponent:@"vs.spv"]];
        NSData *fs = [NSData dataWithContentsOfFile:[inputs stringByAppendingPathComponent:@"fs.spv"]];
        REQUIRE(vs.length && fs.length && vs.length <= UINT32_MAX && fs.length <= UINT32_MAX);
        REQUIRE(!(vs.length & 3) && !(fs.length & 3));
        nxgal_shader shaders[2] = {{vs.bytes, (uint32_t)vs.length, 1}, {fs.bytes, (uint32_t)fs.length, 5}};
        uint64_t xc_before[8], xc_after[8];
        nxgal_prog_xc_stats(xc_before);
        if (round == 0) REQUIRE(xc_before[0] == 0);
        uint32_t unused = nxgal_prog_create(shaders, 2, NULL, 0, 0xff);
        uint32_t kept = nxgal_prog_create(shaders, 2, NULL, 0, 0xff);
        uint32_t unqueried = nxgal_prog_create(shaders, 2, NULL, 0, 0xff);
        REQUIRE(unused && kept && unqueried && unused != kept && kept != unqueried && unused != unqueried);
        nxgal_prog_xc_stats(xc_after);
        uint64_t new_jobs = xc_after[0] - xc_before[0];
        // These fixtures have not entered this process's shader table. A disk
        // MSL cache hit is read inside the already registered job, so it does
        // not change the expected two jobs shared by these three programs.
        // Later rounds may reuse completed process entries instead.
        REQUIRE(new_jobs <= 2);
        if (round == 0) REQUIRE(new_jobs == 2);
        nxgal_prog_release(unused);
        REQUIRE(gal_prog_get(unused) == NULL);
        uint8_t bytes[256], readback[256];
        for (int i = 0; i < 256; i++) bytes[i] = (uint8_t)(round * 17 + i);
        uint32_t buffer = nxgal_buf_create(sizeof bytes, 0);
        REQUIRE(buffer == 1);
        nxgal_buf_set_data(buffer, 0, bytes, sizeof bytes);
        REQUIRE(nxgal_buf_get_data(buffer, 0, sizeof readback, readback) == 0);
        REQUIRE(memcmp(bytes, readback, sizeof bytes) == 0);
        size_t hostSize = (size_t)getpagesize();
        void *host = mmap(NULL, hostSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        REQUIRE(host != MAP_FAILED);
        memcpy(host, bytes, sizeof bytes);
        uint32_t imported = nxgal_buf_create_host(host, (int32_t)hostSize);
        REQUIRE(imported != 0);
        REQUIRE(nxgal_buf_get_data(imported, 0, sizeof readback, readback) == 0);
        REQUIRE(memcmp(bytes, readback, sizeof bytes) == 0);

        nxgal_tex_info info = {.width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1,
            .block_w = 1, .block_h = 1, .bpp = 4, .format = F_R8G8B8A8Unorm, .target = 1, .swz = {2, 3, 4, 5}};
        uint32_t texture = nxgal_tex_create(&info);
        REQUIRE(texture == 1);
        uint32_t view = nxgal_tex_view(texture, &info, 0, 0);
        REQUIRE(view != 0);
        nxgal_sampler_info samplerInfo = {.min_filter = 1, .mag_filter = 1, .seamless_cube = 1, .max_lod = 1, .max_aniso = 1};
        uint32_t sampler = nxgal_sampler_create(&samplerInfo);
        REQUIRE(sampler == 1);
        uint32_t array = nxgal_tarr_create(1, 0, 0);
        REQUIRE(array == 1);
        void *upload = NULL;
        uint32_t lease = nxgal_upload_rent(64, &upload);
        REQUIRE(lease && upload);
        memcpy(upload, bytes, 64);
        nxgal_tex_set_data_lease(texture, 0, 0, NULL, lease, 64);
        REQUIRE(nxgal_tex_get_data(texture, 0, 0, readback, 64) == 64);
        REQUIRE(memcmp(bytes, readback, 64) == 0);
        nxgal_tarr_set_textures(array, 0, &texture, 1);
        nxgal_tarr_set_samplers(array, 0, &sampler, 1);

        // Leave owned resources, an unsubmitted lease and a timestamp event for shutdown to
        // release. A second session must not reuse their storage or read their old queues.
        REQUIRE(nxgal_upload_rent(128, &upload) != 0 && upload);
        nxgal_buf_clear(buffer, 0, sizeof bytes, 0x11223344);
        REQUIRE(nxgal_counter_report(3, 1, 0) != 0);
        // A nonblocking observation can finalize this program if compilation
        // already finished. Never query the other owner before shutdown: its
        // pending descriptor (when created) must be retired by the real path.
        int status = nxgal_prog_status(kept, 0);
        REQUIRE(status == 0 || status == 2);
        incomplete_samples += status == 2;
        complete_samples += status == 0;
        printf("PROGRAM round %d: new_jobs=%llu sampled_status=%d; second owner unqueried\n",
               round + 1, (unsigned long long)new_jobs, status);
        nxgal_request_stop();
        REQUIRE(nxgal_shutdown_session() == 0);
        REQUIRE(gal_prog_get(kept) == NULL && gal_prog_get(unqueried) == NULL);
        REQUIRE(gal_buf_size(buffer) == 0);
        REQUIRE(gal_buf_size(imported) == 0);
        REQUIRE(memcmp(host, bytes, sizeof bytes) == 0);
        REQUIRE(munmap(host, hostSize) == 0);
        REQUIRE(gal_tex_get(texture) == NULL && gal_tex_get(view) == NULL);
        REQUIRE(gal_sampler_get(sampler) == nil && gal_tarr_get(array) == NULL);
        int uploads[3]; gal_upload_stats(uploads);
        REQUIRE(uploads[0] == 0 && uploads[1] == 0 && uploads[2] == 0);
        uint32_t events[4]; uint64_t values[4];
        REQUIRE(nxgal_counter_poll(events, values, 4) == 0);
        printf("PASS real Metal resource session %d/10\n", round + 1);
    }
    printf("PROGRAM observations: incomplete=%d complete=%d; timeout/boost interleavings not forced\n",
           incomplete_samples, complete_samples);
    puts("PASS 10 GAL resource restarts; game/iOS acceptance remains untested");
    return 0;
}
GAL_MTL4_ZONE_END
