// Generic shader translation / driver pipeline evidence; off unless explicitly debug-enabled.
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <limits.h>
#include "../direct/sha256.h"
#if defined(__ANDROID__)
#include "../debug_gate.h"
#endif

#define CE_CAP_DEFAULT 16384u
#define CE_CAP_MAX 65536u
struct ce_record { uint64_t id, start, end; uint32_t kind, result; };
static struct ce_record *g_events;
static unsigned g_capacity;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_session, g_next, g_lost, g_hits, g_begin_us;
static unsigned g_count;
static _Atomic int g_enabled;
static int g_flushed;
static char g_path[PATH_MAX];

static int ce_gate(void) {
#if defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {0};
    return s2a_debug_entries_open() && __system_property_get("debug.s2a.frame_log", value) == 1 && value[0] == '1';
#elif defined(S2A_CE_TESTING)
    const char *value = getenv("S2A_CE_TEST_ENABLE");
    return value && !strcmp(value, "1");
#else
    return 0;
#endif
}

static int ce_capacity(unsigned *capacity) {
    const char *value = NULL;
#if defined(__ANDROID__)
    char prop[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.s2a.compile_cap", prop) > 0) value = prop;
#elif defined(S2A_CE_TESTING)
    value = getenv("S2A_CE_TEST_CAP");
#endif
    if (!value || !*value) { *capacity = CE_CAP_DEFAULT; return 0; }
    uint64_t n = 0;
    for (const char *p = value; *p; p++) {
        if (*p < '0' || *p > '9') return -1;
        n = n * 10 + (unsigned)(*p - '0');
        if (n > CE_CAP_MAX) return -1;
    }
    if (!n) return -1;
    *capacity = (unsigned)n;
    return 0;
}

uint64_t s2a_ce_now(void);
int s2a_ce_enabled(void) { return g_enabled; }

int s2a_ce_init(const char *directory, uint64_t session) {
    pthread_mutex_lock(&g_lock);
    g_enabled = 0; g_flushed = 0; g_count = 0; g_lost = 0; g_hits = 0; g_next = 0; g_session = session; g_path[0] = 0;
    free(g_events); g_events = NULL; g_capacity = 0;
    if (!ce_gate()) { pthread_mutex_unlock(&g_lock); return 0; }
    if (!directory || directory[0] != '/' || !session) { pthread_mutex_unlock(&g_lock); return -1; }
    int n = snprintf(g_path, sizeof g_path, "%s/compile-events-%ld.jsonl", directory, (long)getpid());
    if (n <= 0 || (size_t)n >= sizeof g_path) { pthread_mutex_unlock(&g_lock); return -1; }
    if (ce_capacity(&g_capacity)) { pthread_mutex_unlock(&g_lock); return -1; }
    g_events = calloc(g_capacity, sizeof *g_events);
    if (!g_events) { pthread_mutex_unlock(&g_lock); return -1; }
    g_enabled = 1;
    g_begin_us = s2a_ce_now();
    if (!g_begin_us) { g_enabled = 0; pthread_mutex_unlock(&g_lock); return -1; }
    pthread_mutex_unlock(&g_lock);
    return 0;
}

uint64_t s2a_ce_now(void) {
    if (!g_enabled) return 0;
    struct timespec ts;
#if defined(CLOCK_BOOTTIME)
    if (clock_gettime(CLOCK_BOOTTIME, &ts)) return 0;
#else
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
#endif
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

int s2a_ce_record(uint32_t kind, uint32_t result, uint64_t start, uint64_t end) {
    pthread_mutex_lock(&g_lock);
    if (!g_enabled) { pthread_mutex_unlock(&g_lock); return 0; }
    if (g_flushed || kind < 1 || kind > 3 || result < 1 || result > 3 || !start || end < start) {
        g_lost++; pthread_mutex_unlock(&g_lock); return -1;
    }
    if (result == 1 && kind != 1) { g_lost++; pthread_mutex_unlock(&g_lock); return -1; }
    if (kind == 1 && result == 1) {
        if (g_hits == UINT64_MAX) { g_lost++; pthread_mutex_unlock(&g_lock); return -1; }
        g_hits++; pthread_mutex_unlock(&g_lock); return 0;
    }
    uint64_t id = ++g_next;
    if (g_count == g_capacity) { g_lost++; pthread_mutex_unlock(&g_lock); return 0; }
    g_events[g_count++] = (struct ce_record){id, start, end, kind, result};
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int s2a_ce_flush(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_enabled) { pthread_mutex_unlock(&g_lock); return 0; }
    if (g_flushed) { pthread_mutex_unlock(&g_lock); return -1; }
    g_flushed = 1;
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    if (n <= 0 || (size_t)n >= sizeof tmp) { pthread_mutex_unlock(&g_lock); return -1; }
    uint64_t end_us = s2a_ce_now();
    if (!end_us || end_us < g_begin_us) { pthread_mutex_unlock(&g_lock); return -1; }
    FILE *f = fopen(tmp, "w");
    if (!f) { pthread_mutex_unlock(&g_lock); return -1; }
    char header[256];
    int hlen = snprintf(header, sizeof header, "{\"schema\":\"s2a-compile-events-v2\",\"clock\":\"CLOCK_BOOTTIME\",\"pid\":%ld,\"session\":%llu,\"begin_us\":%llu,\"capacity\":%u}\n", (long)getpid(), (unsigned long long)g_session, (unsigned long long)g_begin_us, g_capacity);
    int error = hlen <= 0 || (size_t)hlen >= sizeof header || fwrite(header, 1, (size_t)hlen, f) != (size_t)hlen;
    s2a_sha256 hash; s2a_sha256_init(&hash);
    if (!error) s2a_sha256_update(&hash, (const uint8_t *)header, (size_t)hlen);
    static const char *const kinds[] = {"", "translation", "graphics_pipeline", "compute_pipeline"};
    static const char *const results[] = {"", "hit", "miss", "failure"};
    for (unsigned i = 0; i < g_count; i++) {
        struct ce_record *e = &g_events[i];
        char line[256];
        int len = snprintf(line, sizeof line, "{\"id\":%llu,\"kind\":\"%s\",\"result\":\"%s\",\"start_us\":%llu,\"end_us\":%llu}\n",
            (unsigned long long)e->id, kinds[e->kind], results[e->result], (unsigned long long)e->start, (unsigned long long)e->end);
        if (len <= 0 || (size_t)len >= sizeof line || fwrite(line, 1, (size_t)len, f) != (size_t)len) { error = 1; break; }
        s2a_sha256_update(&hash, (const uint8_t *)line, (size_t)len);
    }
    char footer_core[192];
    int flen = snprintf(footer_core, sizeof footer_core, "{\"status\":\"complete\",\"count\":%u,\"dropped\":%llu,\"hits\":%llu,\"end_us\":%llu}", g_count, (unsigned long long)g_lost, (unsigned long long)g_hits, (unsigned long long)end_us);
    if (flen <= 0 || (size_t)flen >= sizeof footer_core) error = 1;
    if (!error) s2a_sha256_update(&hash, (const uint8_t *)footer_core, (size_t)flen);
    uint8_t digest[32]; char hex[65]; s2a_sha256_final(&hash, digest); s2a_sha256_hex(digest, hex);
    if (!error && fprintf(f, "%.*s,\"sha256\":\"%s\"}\n", flen - 1, footer_core, hex) < 0) error = 1;
    if (fclose(f)) error = 1;
    if (!error && rename(tmp, g_path)) error = 1;
    if (error) unlink(tmp);
    pthread_mutex_unlock(&g_lock);
    return error ? -1 : 0;
}
