// Real-module lifecycle probe. Requires a user's existing rewritten module
// directory; never starts C# or opens game save data. This is not a gameplay test.
#include "../src/native.h"
#include <mach/mach.h>
#include <stdatomic.h>
#include <sys/mman.h>

int s2a_gate_session_reset(void), s2a_thread_session_reset(void), s2a_window_session_reset(void);
void s2a_loader_session_reset(void), s2a_mem_session_reset(void), s2a_cpatch_session_reset(void);
int s2a_fps_session_reset(void), s2a_widen_session_reset(void), s2a_far_session_reset(void);
int s2a_thread_session_joined(void);
int s2a_cpatch_fps_count(void);
int s2a_thread_stop_all(int), svc_thread(int, uint64_t *);
int s2a_svc_park_all(int);
int svc_mem(int, uint64_t *, uint64_t);
uint32_t s2a_thread_main_init(void);
uint64_t s2a_mem_init(const char *);
int s2a_gate_count(void), s2a_test_handle_used(void);
static _Atomic int ready;
static _Atomic int destroyed;
static pthread_key_t destructor_key;
static uint64_t stack_top;
static void *(*guest_memset)(void *, int, size_t);
static void *cpu_buffer;
enum { WAIT_SLEEP, CPU_LOOP, WAIT_SYNC, WAIT_SYNC_TIMED, WAIT_GATE };
static int stop_case;
static uint32_t wait_handle;
static uint64_t sleep_gate;
static const char *const stop_names[] = {
    "native timed wait", "real SDK CPU loop", "infinite WaitSynchronization", "timed WaitSynchronization", "closed SVC gate"
};
void sw_call_on_stack(void (*)(void), uint64_t);
uint64_t s2a_event_create(uint32_t *, uint32_t *);
void s2a_event_release(uint64_t);

static void cpu_body(void) {
    // Execute the user's actual SDK code without any syscall/checkpoint in
    // the loop. Only the production guest-PC signal path can stop this case.
    for (;;) { guest_memset(cpu_buffer, 0x5a, 2u << 20); atomic_store(&ready, 1); }
}

static void destructor(void *p) { if (p) atomic_fetch_add(&destroyed, 1); }
static uint64_t find_sleep_gate(const char *dir) {
    for (int i = 0; i < g_nmod; i++) {
        char path[1100], line[256];
        snprintf(path, sizeof path, "%s/%s.gates.tsv", dir, g_mod[i].name);
        FILE *file = fopen(path, "r");
        if (!file) return 0;
        while (fgets(line, sizeof line, file)) {
            unsigned long ret, orig; char kind[16]; int arg;
            if (sscanf(line, "%lx %15s %d %lx", &ret, kind, &arg, &orig) == 4 && !strcmp(kind, "svc") && arg == 0x0b) {
                fclose(file); return (uint64_t)g_mod[i].base + ret;
            }
        }
        fclose(file);
    }
    return 0;
}
static void *sleeper(void *unused) {
    (void)unused;
    sw_xstack_thread_init(((uint64_t)__builtin_frame_address(0) - 0x400) & ~15ull, 0);
    s2a_thread_main_init();
    pthread_setspecific(destructor_key, &ready);
    if (stop_case == CPU_LOOP) sw_call_on_stack(cpu_body, stack_top);
    atomic_store(&ready, 1);
    for (;;) {
        if (stop_case == WAIT_GATE) {
            uint64_t regs[31] = {60000000000ull};
            gate_dispatch(sleep_gate, regs);
            fprintf(stderr, "closed gate returned to guest\n"); abort();
        } else if (stop_case == WAIT_SLEEP) {
            uint64_t regs[128] = {60000000000ull};
            svc_thread(0x0b, regs);
        } else {
            uint64_t regs[128] = {0, (uint64_t)&wait_handle, 1,
                stop_case == WAIT_SYNC ? UINT64_MAX : 60000000000ull};
            svc_thread(0x18, regs);
            fprintf(stderr, "unexpected WaitSynchronization return: %#llx\n", (unsigned long long)regs[0]);
            abort();
        }
    }
}
// Observe the actual native wait before stopping, rather than racing stop
// against svc_enter and accidentally testing only its entry checkpoint.
static int await_native_wait(pthread_t pt) {
    for (int i = 0; i < 5000; i++) {
        thread_basic_info_data_t info; mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        if (thread_info(pthread_mach_thread_np(pt), THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return 0;
        if (info.run_state == TH_STATE_WAITING) return 1;
        usleep(1000);
    }
    return 0;
}
static uint64_t hash(const uint8_t *p, uint64_t n) {
    uint64_t h = 1469598103934665603ull;
    for (uint64_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}
int main(int argc, char **argv) {
    if (argc < 3 || !s2a_window_ok()) {
        fprintf(stderr, "usage: probe_session_reload <existing module directory> <module names...>\n"); return 2;
    }
    char npdm[1100]; snprintf(npdm, sizeof npdm, "%s/main.npdm", argv[1]);
    const char *widen_option = getenv("S2A_PROBE_WIDEN_RELOAD");
    int verify_widen = widen_option && !strcmp(widen_option, "1");
    if (verify_widen) {
        char verified[1100]; snprintf(verified, sizeof verified, "%s/widen_verified.tsv", argv[1]);
        if (getenv("S2A_WIDEN_VERIFIED") || access(verified, R_OK)) {
            fprintf(stderr, "widen reload probe requires a verified real module root and no verification override\n"); return 2;
        }
        if (setenv("S2A_SCREEN_W", "2560", 1)) return 1;
    }
    const char *narrow = getenv("S2A_WIDEN_NARROW");
    char *original_narrow = narrow ? strdup(narrow) : NULL;
    if (narrow && !original_narrow) return 1;
    void s2a_crash_install(void); s2a_crash_install();
    uint64_t first_base[argc], first_hash[2][argc], first_size[argc];   // 模块数 = argc - 2
    int first_gates = 0, first_cpatch = -1, hashes_seen[2] = {0};
    volatile uint64_t *host_tail = NULL;
    if (pthread_key_create(&destructor_key, destructor)) return 1;
    for (int pass = 0; pass < 10; pass++) {
        int variant = verify_widen && (pass & 1);
        if (verify_widen && (setenv("S2A_WIDESCREEN", variant ? "1" : "0", 1) ||
                             setenv("S2A_WIDEN_FULL", variant ? "1" : "0", 1))) return 1;
        load_modules(argv[1], (const char **)&argv[2], argc - 2);
        if (verify_widen && (s2a_screen_w() != (variant ? 2560 : 1920) || s2a_widen_full() != variant)) {
            fprintf(stderr, "widen state did not follow this session's settings on pass %d\n", pass + 1); return 1;
        }
        narrow = getenv("S2A_WIDEN_NARROW");
        if (original_narrow && (!narrow || strcmp(narrow, original_narrow))) {
            fprintf(stderr, "widen load changed the explicit launch narrow setting\n"); return 1;
        }
        if (verify_widen && !original_narrow && (variant ? narrow != NULL : (!narrow || strcmp(narrow, "1")))) {
            fprintf(stderr, "automatic narrow setting did not follow this session's width\n"); return 1;
        }
        int cpatch = s2a_cpatch_fps_count();
        if (first_cpatch < 0) first_cpatch = cpatch;
        if (cpatch != first_cpatch) { fprintf(stderr, "community FPS patch registrations accumulated across sessions\n"); return 1; }
        stack_top = s2a_mem_init(npdm);
        if (!host_tail) {
            host_tail = s2a_tail_map(16384, S2A_TAIL_MO | S2A_TAIL_ONLY, PROT_READ | PROT_WRITE);
            if (!host_tail || !s2a_tail_has((const void *)host_tail)) {
                fprintf(stderr, "real host-tail allocation required for window-retention probe\n"); return 1;
            }
            *host_tail = 0x6a6f696e7461696cull;
        }
        stop_case = pass % 5;
        uint64_t wait_event = 0;
        if (stop_case == WAIT_SYNC || stop_case == WAIT_SYNC_TIMED) {
            wait_event = s2a_event_create(&wait_handle, NULL);
            if (!wait_event || !wait_handle) return 1;
        }
        if (stop_case == CPU_LOOP) {
            guest_memset = guest_sym("memset");
            if (!guest_memset || !module_of((void *)guest_memset)) { fprintf(stderr, "real SDK memset export required for guest-PC stop probe\n"); return 1; }
            uint64_t regs[31] = {0}; regs[1] = 2u << 20;
            if (!svc_mem(0x01, regs, 0) || regs[0]) return 1;
            cpu_buffer = (void *)regs[1];
        }
        if (stop_case == WAIT_GATE) {
            sleep_gate = find_sleep_gate(argv[1]);
            if (!sleep_gate || s2a_svc_park_all(0)) return 1;
        }
        int gates = s2a_gate_count();
        if (pass && gates != first_gates) return 1;
        first_gates = gates;
        for (int i = 0; i < g_nmod; i++) {
            module_t *m = &g_mod[i];
            uint64_t end = m->patch_off < 0 ? m->file_image_len : (uint64_t)m->patch_off;
            if (end < m->data_off) return 1;
            uint64_t size = end - m->data_off, h = hash(m->base + m->data_off, size);
            if ((pass && ((uint64_t)m->base != first_base[i] || size != first_size[i])) ||
                (hashes_seen[variant] && h != first_hash[variant][i])) {
                fprintf(stderr, "module data/address differs after reload: %s pass %d\n", m->name, pass + 1); return 1;
            }
            first_base[i] = (uint64_t)m->base; first_size[i] = size; first_hash[variant][i] = h;
            // Change only this process's mapped data. The next pass must load
            // the exact original data again from the read-only input files.
            if (size) m->base[m->data_off] ^= 0xff;
        }
        hashes_seen[variant] = 1;
        atomic_store(&ready, 0);
        pthread_t pt; if (pthread_create(&pt, NULL, sleeper, NULL)) return 1;
        for (int n = 0; n < 5000 && !atomic_load(&ready); n++) usleep(1000);
        if (!atomic_load(&ready)) return 1;
        if (stop_case != CPU_LOOP && !await_native_wait(pt)) {
            fprintf(stderr, "thread did not enter %s\n", stop_names[stop_case]); return 1;
        }
        if (s2a_thread_stop_all(5000)) {
            fprintf(stderr, "failed to stop %s on pass %d\n", stop_names[stop_case], pass + 1); return 1;
        }
        if (!s2a_thread_session_joined() || atomic_load(&destroyed) != pass + 1) { fprintf(stderr, "pthread join/TLS destructor did not complete\n"); return 1; }
        if (wait_event) s2a_event_release(wait_event);
        if (s2a_fps_session_reset() || s2a_widen_session_reset()) return 1;
        s2a_cpatch_session_reset();
        if (s2a_cpatch_fps_count()) { fprintf(stderr, "community FPS patch registrations survived reset\n"); return 1; }
        narrow = getenv("S2A_WIDEN_NARROW");
        if (original_narrow ? (!narrow || strcmp(narrow, original_narrow)) : narrow != NULL) {
            fprintf(stderr, "widen reset did not restore the launch narrow setting\n"); return 1;
        }
        if (s2a_gate_session_reset() || s2a_thread_session_reset() || s2a_test_handle_used()) return 1;
        if (s2a_far_session_reset() || s2a_window_session_reset()) return 1;
        if (*host_tail != 0x6a6f696e7461696cull) { fprintf(stderr, "guest reset replaced host-owned tail memory\n"); return 1; }
        s2a_mem_session_reset(); s2a_loader_session_reset();
        printf("pass %d: stable module data/address, %d gates, stopped %s, joined thread/TLS, empty handles, retained host tail\n", pass + 1, gates, stop_names[stop_case]);
        if (verify_widen) printf("  widen setting %d: width %d, full %d; narrow launch value preserved\n", variant, variant ? 2560 : 1920, variant);
    }
    pthread_key_delete(destructor_key);
    s2a_tail_unmap((void *)host_tail, 16384, S2A_TAIL_MO);
    free(original_narrow);
    printf("community FPS patch rows loaded per session: %d%s\n", first_cpatch, first_cpatch ? "" : " (no real community FPS patch coverage)");
    return 0;
}
