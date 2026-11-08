// Explicit CPU probe: loaded SDK wrappers run on the real NPDM guest stack.
// Supports main/subsdk0/sdk and the checked wrapper ABI only. No SDK startup,
// service host, GPU, game or complete-session retirement is exercised here.
#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <sys/stat.h>

#if !defined(__APPLE__) || !defined(__aarch64__)
#error This probe requires the real Apple arm64 production entry/SVC implementation.
#endif
#ifdef S2A_UNIT_TEST
#error This probe must not use unit-test implementations.
#endif

void sw_call_on_stack(void (*fn)(void), uint64_t sp);
uint32_t s2a_thread_main_init(void);
uint64_t s2a_mem_init(const char *npdm);
int s2a_thread_stop_all(int wait_ms), s2a_thread_session_joined(void);
int s2a_thread_restart_supported(void);
void s2a_thread_dump(void), s2a_crash_install(void);

typedef void (*sleep_fn)(int64_t);
typedef uint32_t (*wait_fn)(int32_t *, const uint32_t *, int, int64_t);
enum scenario { SLEEP, WAIT_INFINITE, WAIT_TIMED };
static enum scenario scenario;
static sleep_fn sdk_sleep;
static wait_fn sdk_wait;
static uint64_t stack_top, gate_return;
static int64_t timeout_ns;
static uint32_t wait_handle, thread_handle;
static pthread_key_t sentinel_key;
static int sentinel_tag;
static _Atomic int ready, tls_destroyed;
static uintptr_t local_handles, local_index;
static uint32_t unexpected_result;
static const char *case_name;

static int fail(const char *why) {
    fprintf(stderr, "[probe] FAIL %s: %s\n", case_name ? case_name : "setup", why);
    return 1;
}
static uint32_t word(const module_t *m, int64_t off) {
    uint32_t value;
    memcpy(&value, m->base + off, sizeof value);
    return value;
}
static int text_range(const module_t *m, uint64_t off, uint64_t size) {
    uint64_t image = m->patch_off < 0 ? m->file_image_len : m->size;
    return m->text_end <= image && off <= m->text_end && size <= m->text_end - off;
}
static int patch_range(const module_t *m, int64_t off, uint64_t size) {
    if (m->size > INT64_MAX || m->patch_len > INT64_MAX) return 0;
    int64_t end = m->patch_off < 0 ? m->patch_off + (int64_t)m->patch_len : (int64_t)m->size;
    return off >= m->patch_off && off <= end && size <= (uint64_t)(end - off);
}
static int branch_destination(uint32_t instruction, int64_t pc, int64_t *dest) {
    if ((instruction & 0xfc000000u) != 0x14000000u) return 0;
    int64_t delta = (int64_t)(int32_t)(instruction << 6) >> 4;
    *dest = pc + delta;
    return 1;
}
static int check_gate(module_t *m, uint64_t orig, int64_t ret) {
    int64_t target, resume;
    if ((orig & 3) || (ret & 3) || !text_range(m, orig, 4) ||
        !branch_destination(word(m, (int64_t)orig), (int64_t)orig, &target) ||
        !patch_range(m, target, 4) || !patch_range(m, ret - 4, 12) || target >= ret) return 0;
    // Validate the actual rewriter gate's entry, real indirect call, and return.
    return word(m, target) == 0xa9bf7bfdu && word(m, ret - 4) == 0xd63f03c0u &&
           word(m, ret) == 0xa8c17bfdu &&
           branch_destination(word(m, ret + 4), ret + 4, &resume) && resume == (int64_t)orig + 4;
}
static int load_wrapper(const char *directory, int svc) {
    module_t *sdk = NULL;
    for (int i = 0; i < g_nmod; ++i) if (!strcmp(g_mod[i].name, "sdk")) {
        if (sdk) return fail("multiple SDK modules");
        sdk = &g_mod[i];
    }
    if (!sdk) return fail("SDK module absent");
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/%s.gates.tsv", directory, sdk->name) >= (int)sizeof path)
        return fail("gate path too long");
    FILE *file = fopen(path, "r");
    if (!file) return fail("cannot read original gate metadata");
    char line[512]; int found = 0, error = 0;
    while (fgets(line, sizeof line, file)) {
        unsigned long ret, orig; int arg; char kind[16];
        if (sscanf(line, "%lx %15s %d %lx", &ret, kind, &arg, &orig) != 4 ||
            strcmp(kind, "svc") || arg != svc) continue;
        if (++found != 1 || !check_gate(sdk, orig, (int64_t)ret)) { error = 1; break; }
        if (svc == 0x0b) {
            if (!text_range(sdk, orig, 8) || word(sdk, (int64_t)orig + 4) != 0xd65f03c0u) { error = 1; break; }
            sdk_sleep = (sleep_fn)(sdk->base + orig);
        } else {
            // Original AAPCS64 ABI: save x0 output pointer; svc result w0/index w1;
            // restore pointer into x2, store index, restore SP, and return.
            if (orig < 4 || !text_range(sdk, orig - 4, 24) ||
                word(sdk, (int64_t)orig - 4) != 0xf81f0fe0u ||
                word(sdk, (int64_t)orig + 4) != 0xf94003e2u ||
                word(sdk, (int64_t)orig + 8) != 0xb9000041u ||
                word(sdk, (int64_t)orig + 12) != 0x910043ffu ||
                word(sdk, (int64_t)orig + 16) != 0xd65f03c0u) { error = 1; break; }
            sdk_wait = (wait_fn)(sdk->base + orig - 4);
        }
        gate_return = ret;
        fprintf(stderr, "[probe] real wrapper module=%s svc=%#x entry=%#lx orig=%#lx gate_return=%#lx\n",
                sdk->name, svc, svc == 0x0b ? orig : orig - 4, orig, ret);
    }
    if (ferror(file)) error = 1;
    if (fclose(file)) error = 1;
    if (error || found != 1) return fail("SDK wrapper or gate instruction template/bounds mismatch");
    return 0;
}
static void sentinel_destroy(void *value) {
    if (value == &sentinel_tag) atomic_fetch_add(&tls_destroyed, 1);
}
static void guest_body(void) {
    uint32_t handles[1] = {wait_handle};
    int32_t index = -1;
    local_handles = (uintptr_t)handles;
    local_index = (uintptr_t)&index;
    atomic_store_explicit(&ready, 1, memory_order_release);
    if (scenario == SLEEP) {
        sdk_sleep(timeout_ns);
        unexpected_result = 0;
    } else {
        unexpected_result = sdk_wait(&index, handles, 1, timeout_ns);
    }
    // Only an unexpected SDK return reaches this. sw_call_on_stack restores
    // the real host stack before the bootstrap reports a whole-process failure.
}
static void *bootstrap(void *unused) {
    (void)unused;
    thread_handle = s2a_thread_main_init();
    if (!thread_handle || pthread_setspecific(sentinel_key, &sentinel_tag)) {
        fail("main registration or TLS sentinel failed"); exit(1);
    }
    sw_xstack_thread_init(((uint64_t)__builtin_frame_address(0) - 0x400) & ~15ull, stack_top);
    sw_call_on_stack(guest_body, stack_top);
    fprintf(stderr, "[probe] FAIL %s: SDK unexpectedly returned %#x; restored host stack\n", case_name, unexpected_result);
    exit(1);
}
static int query_local(uintptr_t address, size_t size) {
    s2a_meminfo info;
    if (s2a_mem_query(address, &info) || info.state != 0x0b || (info.perm & 3) != 3 ||
        address < info.base || address - info.base >= info.size || size > info.size - (address - info.base) ||
        stack_top < info.base || stack_top - info.base > info.size) return 0;
    fprintf(stderr, "[probe] actual guest local=%#lx Stack=%#llx+%#llx perm=%u NPDM_top=%#llx\n",
            (unsigned long)address, (unsigned long long)info.base, (unsigned long long)info.size,
            info.perm, (unsigned long long)stack_top);
    return 1;
}
static int native_waiting(pthread_t thread) {
    thread_basic_info_data_t info; mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    kern_return_t rc = thread_info(pthread_mach_thread_np(thread), THREAD_BASIC_INFO, (thread_info_t)&info, &count);
    return rc == KERN_SUCCESS && info.run_state == TH_STATE_WAITING;
}
static int dump_confirms_wait(const char *trace_path) {
    int fd = open(trace_path, O_RDONLY);
    if (fd < 0) return -1;
    off_t start = lseek(fd, 0, SEEK_END);
    if (start < 0) { close(fd); return -1; }
    s2a_thread_dump();
    char data[16384]; ssize_t count = pread(fd, data, sizeof data - 1, start);
    close(fd);
    if (count < 0) return -1;
    data[count] = 0;
    char identity[64], svc[40], lr[64], event[64];
    snprintf(identity, sizeof identity, "线程 %#x id ", thread_handle);
    snprintf(svc, sizeof svc, "最近 svc %#x ", scenario == SLEEP ? 0x0b : 0x18);
    snprintf(lr, sizeof lr, " lr sdk+%#llx ", (unsigned long long)gate_return);
    snprintf(event, sizeof event, " %#x=事件读", wait_handle);
    char *line = strstr(data, identity);
    if (!line) return 0;
    char *end = strchr(line, '\n');
    if (!end) return 0;
    *end = 0;
    int good = strstr(line, svc) && strstr(line, lr) && !strstr(line, "已退出");
    if (scenario != SLEEP) {
        good = good && strstr(line, "等同步") && strstr(end + 1, event) && !strstr(end + 1, "(已触发)");
    }
    return good;
}
static int await_wait(pthread_t thread, const char *trace_path) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (native_waiting(thread)) {
            int evidence = dump_confirms_wait(trace_path);
            if (evidence < 0) return 0;
            if (evidence && native_waiting(thread)) {
                fprintf(stderr, "[probe] confirmed production svc=%#x SDK gate lr, native Mach WAITING%s\n",
                        scenario == SLEEP ? 0x0b : 0x18, scenario == SLEEP ? "" : ", unsignaled event / kind4");
                return 1;
            }
        }
        usleep(1000);
    }
    return 0;
}
// The TLS-blocking probe includes these helpers in the same translation unit.
// It supplies its own main without replacing a production implementation.
#ifndef S2A_SDK_STOP_HELPERS_ONLY
int main(int argc, char **argv) {
    _Static_assert(sizeof(void *) == 8 && sizeof(int) == 4 && sizeof(int64_t) == 8, "SDK AAPCS64 scalar ABI");
    if (argc != 4) return fail("usage: probe_sdk_stop <real module directory> <sleep|wait-infinite|wait-timed> <raw-log-path>");
    case_name = argv[2];
    if (!strcmp(case_name, "sleep")) scenario = SLEEP;
    else if (!strcmp(case_name, "wait-infinite")) scenario = WAIT_INFINITE;
    else if (!strcmp(case_name, "wait-timed")) scenario = WAIT_TIMED;
    else return fail("unknown scenario");
    if (!s2a_window_ok()) return fail("production constructor did not reserve the guest window");
    const char *diagnostics = getenv("S2A_WAIT_DIAG");
    if (!diagnostics || strcmp(diagnostics, "1")) return fail("production S2A_WAIT_DIAG=1 is required");
    fprintf(stderr, "[probe] pid=%d case=%s\n", getpid(), case_name);
    s2a_crash_install();
    const char *names[] = {"main", "subsdk0", "sdk"};
    load_modules(argv[1], names, 3);
    char npdm[PATH_MAX];
    if (snprintf(npdm, sizeof npdm, "%s/main.npdm", argv[1]) >= (int)sizeof npdm) return fail("NPDM path too long");
    stack_top = s2a_mem_init(npdm);
    if (load_wrapper(argv[1], scenario == SLEEP ? 0x0b : 0x18)) return 1;
    timeout_ns = scenario == WAIT_INFINITE ? -1 : 60000000000ll;
    uint64_t event = 0;
    if (scenario != SLEEP) {
        event = s2a_event_create(&wait_handle, NULL);
        if (!event || !wait_handle) return fail("real unsignaled event creation failed");
    }
    if (pthread_key_create(&sentinel_key, sentinel_destroy)) return fail("sentinel pthread_key_create failed");
    pthread_attr_t attr;
    if (pthread_attr_init(&attr)) return fail("pthread_attr_init failed");
    int error = pthread_attr_setstacksize(&attr, 8u << 20);
    pthread_t thread;
    if (!error) error = pthread_create(&thread, &attr, bootstrap, NULL);
    pthread_attr_destroy(&attr);
    if (error) return fail("8 MiB production-style guest pthread failed");
    for (int attempt = 0; attempt < 5000 && !atomic_load_explicit(&ready, memory_order_acquire); ++attempt) usleep(1000);
    if (!atomic_load_explicit(&ready, memory_order_acquire)) return fail("guest body did not publish ready");
    if (!query_local(local_handles, sizeof(uint32_t)) || !query_local(local_index, sizeof(int32_t)))
        return fail("actual guest locals are not in the real NPDM Stack/RW mapping");
    if (!s2a_thread_restart_supported()) return fail("real roster rejected restart");
    if (!await_wait(thread, argv[3])) return fail("no matching production wait evidence before stop");
    // No service was started. The controller does not perform pthread_join:
    // the production roster/reaper alone owns the thread and its TLS lifetime.
    int stopped = s2a_thread_stop_all(5000);
    int joined = s2a_thread_session_joined();
    int destroyed = atomic_load(&tls_destroyed);
    fprintf(stderr, "[probe] stop_result=%d session_joined=%d TLS_destructors=%d\n", stopped, joined, destroyed);
    if (stopped || !joined || destroyed != 1) return fail("production stop/join/TLS retirement incomplete");
    if (event) {
        s2a_event_release(event);
        if (!s2a_handle_close(wait_handle)) return fail("event read handle close failed");
        fprintf(stderr, "[probe] original event owner released; real read handle closed\n");
    }
    if (!s2a_handle_close(thread_handle)) return fail("retired main handle close failed");
    if (pthread_key_delete(sentinel_key)) return fail("sentinel key deletion failed");
    fprintf(stderr, "[probe] PASS %s (CPU/native-only; no SDK initialization/game/services/GPU)\n", case_name);
    return 0;
}
#endif
