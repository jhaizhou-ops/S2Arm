// Real rewritten modules and a real directory read error after map/parse.
// No guest, service, renderer, allocator or file API is replaced or started.
#include "../src/native.h"
#include <dirent.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int s2a_session_try_boot(void (*)(void *), void *);
int s2a_gate_count(void);
uint64_t s2a_mem_mod_base(const char *);
uint64_t s2a_mem_init(const char *);
void s2a_widen_start(void), s2a_fps_start(const char *);
static int threads(void);
static int started_threads;
struct boot_input { const char *directory; const char **names; int count, after_load; };
static void load_input(void *arg) {
    struct boot_input *input = arg;
    load_modules(input->directory, input->names, input->count);
    if (input->after_load) {
        s2a_widen_start(); s2a_fps_start(input->directory);
        started_threads = threads();
        // A real directory cannot be read as an NPDM. Fail only after the
        // production loader has completed and its real scanner has started.
        s2a_mem_init(input->directory);
    }
}

static int guest_bytes(uint64_t base, uint64_t size, uint64_t *accessible) {
    *accessible = 0;
    for (uint64_t cursor = base, end = base + size; cursor < end;) {
        mach_vm_address_t at = cursor; mach_vm_size_t length = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t error = mach_vm_region(mach_task_self(), &at, &length, VM_REGION_BASIC_INFO_64,
                                             (vm_region_info_t)&info, &count, &object);
        if (object) mach_port_deallocate(mach_task_self(), object);
        // A hole is also a failure: the guest reservation must remain owned.
        if (error || at > cursor || !length || length > UINT64_MAX - at || at + length <= cursor) return -1;
        uint64_t next = at + length < end ? at + length : end;
        if (info.protection != VM_PROT_NONE) *accessible += next - cursor;
        cursor = next;
    }
    return 0;
}

static int threads(void) {
    thread_act_array_t list; mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &list, &count)) return -1;
    for (unsigned i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof *list);
    return (int)count;
}

static int link_input(const char *source, const char *temporary, const char *failure) {
    DIR *directory = opendir(source); if (!directory) return -1;
    struct dirent *entry; int result = 0;
    while ((entry = readdir(directory))) {
        char from[4096], to[4096]; struct stat info;
        if (snprintf(from, sizeof from, "%s/%s", source, entry->d_name) >= (int)sizeof from ||
            snprintf(to, sizeof to, "%s/%s", temporary, entry->d_name) >= (int)sizeof to) { result = -1; break; }
        if (stat(from, &info)) { result = -1; break; }
        if (!S_ISREG(info.st_mode)) continue;
        // Only this link differs. The target is the existing input directory,
        // so stdio fails with its actual directory-read error, not a made-up table.
        if (symlink(!strcmp(entry->d_name, failure) ? source : from, to)) { result = -1; break; }
    }
    closedir(directory);
    return result;
}

static void remove_links(const char *temporary) {
    DIR *directory = opendir(temporary);
    if (directory) {
        struct dirent *entry;
        while ((entry = readdir(directory))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            char path[4096]; snprintf(path, sizeof path, "%s/%s", temporary, entry->d_name);
            unlink(path);
        }
        closedir(directory);
    }
    rmdir(temporary);
}

int main(int argc, char **argv) {
    // The constructor reads the real NPDM at argv[1] before main.
    if (argc < 4 ||
        (strcmp(argv[2], "first") && strcmp(argv[2], "last") && strcmp(argv[2], "after-load")) || !s2a_window_ok()) return 2;
    char *source = realpath(argv[1], NULL); if (!source) return 2;
    char npdm[4096]; snprintf(npdm, sizeof npdm, "%s/main.npdm", source);
    (void)s2a_mem_mod_base(npdm); // Use the actual layout and establish its host tail.
    uint64_t wb, ws, before_bytes, after_bytes = UINT64_MAX;
    s2a_window_get(&wb, &ws);
    if (guest_bytes(wb, ws, &before_bytes) || before_bytes || s2a_gate_count()) { free(source); return 2; }
    volatile uint64_t *tail = s2a_tail_map(16384, S2A_TAIL_MO | S2A_TAIL_ONLY, PROT_READ | PROT_WRITE);
    if (!tail || !s2a_tail_has((const void *)tail)) { free(source); return 2; }
    const uint64_t sentinel = UINT64_C(0x738291abcdef0456);
    tail[0] = sentinel; tail[2047] = ~sentinel;
    char temporary[] = "/tmp/s2a-boot-abort-XXXXXX", failure[64];
    const char *failed_module = !strcmp(argv[2], "first") ? argv[3] : argv[argc - 1];
    int after_load = !strcmp(argv[2], "after-load");
    if (after_load) { failure[0] = 0; failed_module = "npdm-directory"; }
    else snprintf(failure, sizeof failure, "%s.gates.tsv", failed_module);
    if (!mkdtemp(temporary)) {
        s2a_tail_unmap((void *)tail, 16384, S2A_TAIL_MO); free(source); return 2;
    }
    if (link_input(source, temporary, failure)) {
        remove_links(temporary); s2a_tail_unmap((void *)tail, 16384, S2A_TAIL_MO); free(source); return 2;
    }
    struct boot_input input = {temporary, (const char **)&argv[3], argc - 3, after_load};
    int before_fds, after_fds; uint64_t soft, hard;
    s2a_fd_usage(&before_fds, &soft, &hard); int before_threads = threads();
    int result = s2a_session_try_boot(load_input, &input);
    s2a_fd_usage(&after_fds, &soft, &hard); int after_threads = threads();
    int vm_error = guest_bytes(wb, ws, &after_bytes);
    int tail_ok = s2a_tail_has((const void *)tail) && tail[0] == sentinel && tail[2047] == ~sentinel;
    int partial = g_mod != NULL || g_mod_cap;   // 失败装载后模块表整张释放（不再是定长表里残留的槽）
    for (int i = 0; g_mod && i < g_mod_cap; i++) partial += g_mod[i].base != NULL || g_mod[i].symh != NULL;
    int gates = s2a_gate_count();
    printf("boot abort %s/%s: result=%d guest_accessible_bytes=%llu->%llu vm_error=%d fds=%d->%d threads=%d->%d started_threads=%d modules=%d partial=%d gates=%d host_tail=%s\n",
           argv[2], failed_module, result, (unsigned long long)before_bytes, (unsigned long long)after_bytes,
           vm_error, before_fds, after_fds, before_threads, after_threads, started_threads, g_nmod, partial, gates, tail_ok ? "kept" : "CHANGED");
    int bad = result != -1 || vm_error || after_bytes != before_bytes || before_fds != after_fds ||
              before_threads < 0 || before_threads != after_threads || (after_load && started_threads <= before_threads) ||
              g_nmod || partial || gates || !tail_ok;
    remove_links(temporary); s2a_tail_unmap((void *)tail, 16384, S2A_TAIL_MO); free(source);
    return bad ? 1 : 0;
}
