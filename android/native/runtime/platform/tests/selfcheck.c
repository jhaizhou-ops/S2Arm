#include "native.h"
#include "s2a_hostapi.h"
#include <errno.h>

int s2a_selfcheck(void);
const char *s2a_selfcheck_hint(void);
static unsigned checks;
static int mode;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)

static int memory_query(void *ctx, s2a_host_meminfo *out) {
    (void)ctx;
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return errno;
    s2a_host_meminfo real = {.size = sizeof real, .abi_version = S2A_HOST_API_ABI_VERSION};
    char line[128]; unsigned long long kb;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "MemTotal: %llu kB", &kb) == 1) real.total_bytes = kb * 1024;
        if (sscanf(line, "MemAvailable: %llu kB", &kb) == 1) real.available_bytes = kb * 1024;
    }
    fclose(f);
    if (mode == 1) return EIO;
    if (mode == 2) real.total_bytes = 0;
    if (mode == 3) real.available_bytes = 0;
    if (mode == 4) real.available_bytes = real.total_bytes + 1;
    if (mode == 5) real.size = sizeof real - 1;
    if (mode == 6) real.abi_version++;
    *out = real;
    return 0;
}

int main(void) {
    CHECK(s2a_window_ok());
    CHECK(!s2a_selfcheck());
    s2a_host_meminfo_v1 mem = {{sizeof mem, S2A_HOST_API_ABI_VERSION}, memory_query};
    s2a_host_api_v1 api = {.hdr = {sizeof api, S2A_HOST_API_ABI_VERSION},
        .capabilities = S2A_HOST_CAP_MEMINFO, .meminfo = &mem};
    CHECK(!s2a_host_register(&api));
#if S2A_MEM_NEED_MB > 0
    CHECK(!s2a_selfcheck());
    CHECK(strstr(s2a_selfcheck_hint(), "预算") != NULL);
#else
    CHECK(s2a_selfcheck());
    CHECK(strstr(s2a_selfcheck_hint(), "不保证") != NULL);
#endif
    CHECK(strstr(s2a_selfcheck_hint(), "AltStore") == NULL);
    for (mode = 1; mode <= 6; mode++) CHECK(!s2a_selfcheck());
    mode = 0; mem.query = NULL;
    CHECK(!s2a_selfcheck());
    mem.query = memory_query;
    s2a_window_trim(63ull << 30);
    CHECK(!s2a_selfcheck());
    CHECK(strstr(s2a_selfcheck_hint(), "39 位") != NULL);
    printf("selfcheck %u checks\n", checks);
    return 0;
}
