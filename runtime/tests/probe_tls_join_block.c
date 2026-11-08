// Real native TLS destructor blocks while the production reaper joins it.
// Shares the real SDK/NPDM/entry observations; no provider is replaced.
// This covers one CPU/native failure boundary, not the complete session owner.
#define S2A_SDK_STOP_HELPERS_ONLY
#include "probe_sdk_stop.c"
#undef S2A_SDK_STOP_HELPERS_ONLY

static pthread_mutex_t destructor_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t destructor_condition = PTHREAD_COND_INITIALIZER;
static int destructor_entered, release_destructor;
static uintptr_t destructor_local, system_stack_low, system_stack_high;
static uintptr_t initial_stack_low, initial_stack_high;
static size_t requested_stack_bytes;
static uint64_t initial_mach_id, destructor_mach_id;
static const uint64_t retained_word = 0x746c736a6f696e31ull;

static uint64_t current_mach_id(void) {
    thread_identifier_info_data_t identity;
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(pthread_mach_thread_np(pthread_self()), THREAD_IDENTIFIER_INFO,
                    (thread_info_t)&identity, &count) != KERN_SUCCESS) return 0;
    return identity.thread_id;
}
static void *recorded_bootstrap(void *unused) {
    initial_stack_high = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t reported = pthread_get_stacksize_np(pthread_self());
    initial_mach_id = current_mach_id();
    uintptr_t here = (uintptr_t)__builtin_frame_address(0);
    if (!initial_mach_id || reported < requested_stack_bytes || reported > initial_stack_high) {
        fail("cannot record actual initial pthread stack/identity"); _Exit(1);
    }
    initial_stack_low = initial_stack_high - reported;
    if (here < initial_stack_low || here >= initial_stack_high) {
        fail("initial bootstrap frame is outside actual pthread bounds"); _Exit(1);
    }
    fprintf(stderr, "[join-block] initial pthread tid=%llu requested_bytes=%zu reported_bytes=%zu system_host_stack=%#lx..%#lx frame=%#lx\n",
            (unsigned long long)initial_mach_id, requested_stack_bytes, reported,
            (unsigned long)initial_stack_low, (unsigned long)initial_stack_high, (unsigned long)here);
    return bootstrap(unused);
}

static void blocking_destructor(void *value) {
    if (value != &sentinel_tag) { fail("unexpected real TLS destructor value"); _Exit(1); }
    volatile uint64_t host_word = retained_word;
    if (pthread_mutex_lock(&destructor_mutex)) { fail("destructor lock failed"); _Exit(1); }
    system_stack_high = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    system_stack_low = system_stack_high - pthread_get_stacksize_np(pthread_self());
    destructor_mach_id = current_mach_id();
    destructor_local = (uintptr_t)&host_word;
    destructor_entered = 1;
    fprintf(stderr, "[join-block] real TLS destructor entered host_local=%#lx system_host_stack=%#lx..%#lx tid=%llu\n",
            (unsigned long)destructor_local, (unsigned long)system_stack_low, (unsigned long)system_stack_high,
            (unsigned long long)destructor_mach_id);
    while (!release_destructor) {
        int error = pthread_cond_wait(&destructor_condition, &destructor_mutex);
        if (error) { fail("real destructor pthread_cond_wait failed"); _Exit(1); }
    }
    int intact = host_word == retained_word;
    pthread_mutex_unlock(&destructor_mutex);
    if (!intact) { fail("system host stack word changed while TLS blocked"); _Exit(1); }
    sentinel_destroy(value);
    fprintf(stderr, "[join-block] real TLS destructor released and sentinel completed\n");
}

struct identity_snapshot {
    int complete, joiners, target_present, joiner_waiting;
    uint64_t joiner_id;
};
static struct identity_snapshot mach_snapshot(uint64_t target, int emit) {
    struct identity_snapshot result = {.complete = 1};
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        result.complete = 0;
        return result;
    }
    for (mach_msg_type_number_t i = 0; i < count; ++i) {
        thread_identifier_info_data_t identity;
        thread_extended_info_data_t extended;
        thread_basic_info_data_t basic;
        mach_msg_type_number_t n_identity = THREAD_IDENTIFIER_INFO_COUNT;
        mach_msg_type_number_t n_extended = THREAD_EXTENDED_INFO_COUNT;
        mach_msg_type_number_t n_basic = THREAD_BASIC_INFO_COUNT;
        kern_return_t a = thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &n_identity);
        kern_return_t b = thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&extended, &n_extended);
        kern_return_t c = thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &n_basic);
        if (a != KERN_SUCCESS || b != KERN_SUCCESS || c != KERN_SUCCESS) {
            result.complete = 0;
            if (emit) fprintf(stderr, "[join-block] incomplete Mach snapshot port=%u errors=%d/%d/%d\n", threads[i], a, b, c);
        } else {
            extended.pth_name[sizeof extended.pth_name - 1] = 0;
            if (identity.thread_id == target) result.target_present = 1;
            if (!strcmp(extended.pth_name, "s2a-线程回收")) {
                result.joiners++;
                result.joiner_id = identity.thread_id;
                result.joiner_waiting = basic.run_state == TH_STATE_WAITING;
            }
            if (emit) fprintf(stderr, "[join-block] Mach tid=%llu state=%d name=%s\n",
                              (unsigned long long)identity.thread_id, basic.run_state, extended.pth_name);
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, (vm_size_t)count * sizeof *threads);
    return result;
}

static int await_original_joiner_gone(uint64_t original) {
    uint64_t deadline = now_ns() + 5000000000ull;
    int absent_snapshots = 0;
    while (now_ns() < deadline) {
        struct identity_snapshot snapshot = mach_snapshot(original, 0);
        if (snapshot.complete && !snapshot.target_present && snapshot.joiners == 0) {
            if (++absent_snapshots == 2) {
                snapshot = mach_snapshot(original, 1);
                if (snapshot.complete && !snapshot.target_present && snapshot.joiners == 0) {
                    fprintf(stderr, "[join-block] original production joiner tid=%llu absent in complete Mach snapshots\n",
                            (unsigned long long)original);
                    return 1;
                }
                absent_snapshots = 0;
            }
        } else absent_snapshots = 0;
        usleep(1000);
    }
    return 0;
}

static int read_word(uintptr_t address, void *output, size_t size) {
    vm_size_t count = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, size, (vm_address_t)output, &count) == KERN_SUCCESS && count == size;
}
static int host_page_retained(uintptr_t address) {
    vm_address_t region = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t rc = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return rc == KERN_SUCCESS && region <= address && address - region < size &&
           (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE);
}
static int retained_owners(uint64_t event, uint64_t original_thread_id) {
    int locked = pthread_mutex_lock(&destructor_mutex);
    if (locked) return 0;
    uintptr_t host_address = destructor_local;
    int active = destructor_entered && !release_destructor;
    int same_identity = initial_mach_id && destructor_mach_id == initial_mach_id;
    int same_bounds = system_stack_low == initial_stack_low && system_stack_high == initial_stack_high &&
                      host_address >= system_stack_low && host_address < system_stack_high;
    pthread_mutex_unlock(&destructor_mutex);
    uint64_t host_value = 0, thread_id = 0, event_cookie = 0;
    uint32_t guest_value = 0, thread_kind = 0, event_kind = 0;
    // Observe each actual resource even if another check fails; keep all facts.
    int host_page = host_page_retained(host_address);
    int host_read = read_word(host_address, &host_value, sizeof host_value);
    int guest_read = read_word(local_handles, &guest_value, sizeof guest_value);
    int guest_stack = query_local(local_handles, sizeof guest_value);
    int thread_exists = s2a_handle_get(thread_handle, &thread_kind, &thread_id);
    int event_exists = s2a_handle_get(wait_handle, &event_kind, &event_cookie);
    int thread_identity = thread_exists && thread_kind == S2A_OBJ_THREAD && thread_id == original_thread_id;
    int event_identity = event_exists && event_kind == S2A_OBJ_EVENT_R && event_cookie == event;
    int host_intact = host_read && host_value == retained_word;
    int guest_intact = guest_read && guest_value == wait_handle;
    int destroyed = atomic_load(&tls_destroyed), joined = s2a_thread_session_joined();
    int intact = active && same_identity && same_bounds && requested_stack_bytes == (8u << 20) &&
                 !destroyed && !joined && host_page && host_intact && guest_intact && guest_stack && thread_identity && event_identity;
    fprintf(stderr, "[join-block] ownership_checks active=%d same_mach_identity=%d same_host_bounds=%d requested_bytes=%zu host_page_RW=%d host_read=%d host_word_intact=%d guest_read=%d guest_word_intact=%d guest_stack_RW=%d thread_identity=%d event_identity=%d\n",
            active, same_identity, same_bounds, requested_stack_bytes, host_page, host_read, host_intact,
            guest_read, guest_intact, guest_stack, thread_identity, event_identity);
    fprintf(stderr, "[join-block] blocked ownership retained=%d TLS=%d joined=%d host_page=%#lx thread=%#x event=%#x\n",
            intact, destroyed, joined, (unsigned long)host_address, thread_handle, wait_handle);
    return intact;
}

int main(int argc, char **argv) {
    _Static_assert(sizeof(void *) == 8 && sizeof(int) == 4 && sizeof(int64_t) == 8, "SDK AAPCS64 scalar ABI");
    case_name = "tls-join-block";
    scenario = WAIT_INFINITE;
    timeout_ns = -1;
    if (argc != 3) return fail("usage: probe_tls_join_block <real module directory> <raw-log-path>");
    if (!s2a_window_ok()) return fail("production constructor did not reserve guest window");
    const char *diagnostics = getenv("S2A_WAIT_DIAG");
    if (!diagnostics || strcmp(diagnostics, "1")) return fail("production S2A_WAIT_DIAG=1 required");
    fprintf(stderr, "[join-block] pid=%d native TLS deadline probe; system 8MiB host stack, no tail-owned-stack claim\n", getpid());
    s2a_crash_install();
    const char *names[] = {"main", "subsdk0", "sdk"};
    load_modules(argv[1], names, 3);
    char npdm[PATH_MAX];
    if (snprintf(npdm, sizeof npdm, "%s/main.npdm", argv[1]) >= (int)sizeof npdm) return fail("NPDM path too long");
    stack_top = s2a_mem_init(npdm);
    if (load_wrapper(argv[1], 0x18)) return 1;
    uint64_t event = s2a_event_create(&wait_handle, NULL);
    if (!event || !wait_handle) return fail("real event creation failed");
    if (pthread_key_create(&sentinel_key, blocking_destructor)) return fail("blocking TLS key creation failed");
    pthread_attr_t attr;
    if (pthread_attr_init(&attr)) return fail("pthread_attr_init failed");
    int error = pthread_attr_setstacksize(&attr, 8u << 20);
    if (!error) error = pthread_attr_getstacksize(&attr, &requested_stack_bytes);
    if (!error && requested_stack_bytes != (8u << 20)) error = EINVAL;
    pthread_t guest;
    if (!error) error = pthread_create(&guest, &attr, recorded_bootstrap, NULL);
    pthread_attr_destroy(&attr);
    if (error) return fail("real guest pthread creation failed");
    for (int attempt = 0; attempt < 5000 && !atomic_load_explicit(&ready, memory_order_acquire); ++attempt) usleep(1000);
    if (!atomic_load_explicit(&ready, memory_order_acquire)) return fail("guest did not enter real guest body");
    if (!query_local(local_handles, sizeof(uint32_t)) || !query_local(local_index, sizeof(int32_t)) ||
        !s2a_thread_restart_supported() || !await_wait(guest, argv[2])) return fail("real guest waiting precondition missing");
    uint32_t kind = 0; uint64_t original_thread_id = 0;
    if (!s2a_handle_get(thread_handle, &kind, &original_thread_id) || kind != S2A_OBJ_THREAD) return fail("real thread identity missing");

    uint64_t started = now_ns();
    int first_result = s2a_thread_stop_all(5000);
    uint64_t elapsed = now_ns() - started;
    fprintf(stderr, "[join-block] first stop result=%d elapsed_ns=%llu joined=%d TLS=%d\n", first_result,
            (unsigned long long)elapsed, s2a_thread_session_joined(), atomic_load(&tls_destroyed));
    // 6s is a stated scheduling tolerance for this one 5s native deadline,
    // not a changed clock or a larger timeout supplied to production.
    if (first_result != -1 || elapsed < 5000000000ull || elapsed > 6000000000ull)
        return fail("first native stop did not return timeout within the declared 5-6s observation bound");
    struct identity_snapshot original = mach_snapshot(0, 1);
    if (!original.complete || original.joiners != 1 || !original.joiner_waiting)
        return fail("cannot identify exactly one blocked production joiner");
    fprintf(stderr, "[join-block] original production joiner tid=%llu is Mach WAITING\n", (unsigned long long)original.joiner_id);
    if (!retained_owners(event, original_thread_id)) return fail("blocked TLS lost native ownership");
    usleep(250000);
    if (!retained_owners(event, original_thread_id)) return fail("blocked TLS ownership did not remain intact");

    if (pthread_mutex_lock(&destructor_mutex)) return fail("controller destructor lock failed");
    release_destructor = 1;
    int signal_error = pthread_cond_broadcast(&destructor_condition);
    pthread_mutex_unlock(&destructor_mutex);
    if (signal_error) return fail("controller could not release real destructor wait");
    if (!await_original_joiner_gone(original.joiner_id))
        return fail("original joiner termination is not proven; no second stop and no owner release");
    fprintf(stderr, "[join-block] after original joiner termination joined=%d TLS=%d\n",
            s2a_thread_session_joined(), atomic_load(&tls_destroyed));
    if (s2a_thread_session_joined() || atomic_load(&tls_destroyed) != 1)
        return fail("unexpected pre-drain joined/TLS state");

    // Only now is the original worker proven absent. This serial native drain
    // is probe cleanup; no full-session coordinator was started or retried.
    int second_result = s2a_thread_stop_all(5000);
    fprintf(stderr, "[join-block] serial native drain result=%d joined=%d TLS=%d\n", second_result,
            s2a_thread_session_joined(), atomic_load(&tls_destroyed));
    if (second_result || !s2a_thread_session_joined() || atomic_load(&tls_destroyed) != 1)
        return fail("serial production drain did not verify retirement");
    s2a_event_release(event);
    if (!s2a_handle_close(wait_handle) || !s2a_handle_close(thread_handle)) return fail("real native handles did not close");
    if (pthread_key_delete(sentinel_key) || pthread_cond_destroy(&destructor_condition) || pthread_mutex_destroy(&destructor_mutex))
        return fail("probe synchronization cleanup failed");
    fprintf(stderr, "[join-block] PASS native TLS blocked deadline and serial cleanup; owners released only after join\n");
    return 0;
}
