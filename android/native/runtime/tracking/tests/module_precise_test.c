// Linux host: production Android module mapper, tracker and shared-page aliases.
// Logical VM readability and fault-dispatch readiness are explicit stubs.
#include "module.h"
#include "s2a_track.h"
#include "runtime.h"
#include "readonly_copy.h"
#include "track_platform.h"
#include "mirror.h"
int plat_vm_reserve(size_t, size_t, uint64_t, void **);
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static uintptr_t logical_base;
static size_t logical_size;
static uint64_t prepared_address, prepared_size;
static unsigned prepare_calls;
static void write_prep(uint64_t address, uint64_t size) {
    prepared_address = address; prepared_size = size; ++prepare_calls;
}
struct s2a_meminfo;
int s2a_mem_readable(uint64_t a, uint64_t n) {
    return a >= logical_base && n <= logical_size && a - logical_base <= logical_size - n;
}
int s2a_mem_query(uint64_t a, struct s2a_meminfo *out) { (void)a; (void)out; return -1; }
int s2a_android_fault_dispatch_installed(void) { return 1; }
int s2a_android_tracking_vm_ready(void) { return 1; }
int s2a_android_fault_dispatch_ready(void) { return 1; }
int s2a_track_test_pagesize(void) { return (int)sysconf(_SC_PAGESIZE); }

// Exercise the actual module mapper and Android alias provider. The mapper's
// text, key and patch pages must not acquire a writable alias.
static int sealed_alias(uint8_t *source, size_t page, const char *name) {
    void *alias = NULL;
    uint8_t before = source[0];
    int error = s2a_track_platform_alias((uintptr_t)source, page, PROT_READ | PROT_WRITE, &alias);
    if (!error && alias) {
        ((uint8_t *)alias)[0] ^= 0x5a;
        int corrupted = source[0] != before;
        ((uint8_t *)alias)[0] = before;
        s2a_track_platform_unalias(alias, page);
        fprintf(stderr, "FAIL %s alias accepted, source modified=%d\n", name, corrupted);
        return 1;
    }
    if (!error || alias || source[0] != before) {
        fprintf(stderr, "FAIL %s alias refusal contract\n", name); return 1;
    }
    return 0;
}

int main(void) {
    void *window = NULL;
    if (plat_vm_reserve(0x100000, 0x4000, 1ull<<39, &window)) return 2;
    s2a_android_mirror_configure(1);   // 本夹具验证「开」路径（#1184 开关缺省关）
    s2a_android_mirror_init((uintptr_t)window, 0x100000);
    const char fix[] = "# BUILD_ID\t000102\n# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n# PATCH_OFF\t0x10000\n"
        "# KEY_PAGE_OFF\t0x4000\n# KEY_PAGE_SIZE\t0x4000\n# TEXT_END\t0x1000\n"
        "# RO_OFF\t0x1000\n# DATA_OFF\t0x2000\n# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n"
        "# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n";
    const uint64_t slots[S2A_KEY_N] = {0x188, 0x198, 0x1a8, 0x1b8};
    uint8_t *raw = calloc(1, 0x10010);
    struct s2a_module module;
    char err[256] = {0};
    if (!raw || s2a_module_map_mem("module", fix, sizeof(fix) - 1, raw, 0x10010,
                                   slots, &module, err, sizeof err)) {
        fprintf(stderr, "module mapping failed: %s\n", err); return 2;
    }
    uint8_t *data = module.base + 0x8000;
    if ((uintptr_t)data >= (uintptr_t)window && (uintptr_t)data - (uintptr_t)window < 0x100000) return 2;
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    int sealed_failures = 0;
    sealed_failures += sealed_alias(module.base, page, "text");
    sealed_failures += sealed_alias(module.base + 0x4000, page, "key");
    sealed_failures += sealed_alias(module.base + 0x10000, page, "patch");
    if (s2a_track_runtime_prepare() || s2a_track_gpu_reserve((uintptr_t)data, page)) {
        fprintf(stderr, "tracker preparation/reserve failed\n"); return 3;
    }
    logical_base = (uintptr_t)data; logical_size = page;
    s2a_track_set_readflush(1); s2a_track_set_emul(0); s2a_track_set_touch(NULL);
    s2a_track_prot_changed((uintptr_t)data, page);
    s2a_track_batch batch;
    s2a_track_drain(&batch); s2a_track_drain_done();
    s2a_track_reprotect((uintptr_t)data, 0x1000, S2A_TRACK_NONE);
    s2a_track_write_quiet((uintptr_t)data + 16, 1); data[16] = 0x5a;
    s2a_track_drain(&batch);
    if (!batch.nprecise) { fprintf(stderr, "no precise snapshot\n"); return 4; }
    uint8_t copy[4096];
    int error = s2a_android_copy_guest_readonly((uintptr_t)data, copy, sizeof copy);
    if (error || copy[16] != 0x5a || s2a_track_platform_protection((uintptr_t)data) != PROT_NONE) {
        fprintf(stderr, "module readonly copy/protection failed: %d\n", error); return 6;
    }
    s2a_track_copy_precise(batch.precise[0].addr, copy, sizeof copy);
    if (copy[16] != 0x5a) { fprintf(stderr, "snapshot byte missing\n"); return 5; }

    // Simulate a GPU callback changing the CPU byte and its unrelated neighbor
    // without changing guest permissions, then restore the merged snapshot.
    void *alias = NULL;
    if (s2a_track_platform_alias((uintptr_t)data, page, PROT_READ | PROT_WRITE, &alias)) return 7;
    ((uint8_t *)alias)[16] = 0x11; ((uint8_t *)alias)[17] = 0x77;
    if (s2a_track_platform_unalias(alias, page)) return 7;
    // A no-op write preparation creates a pending precise snapshot before restore.
    s2a_track_write_quiet((uintptr_t)data + 32, 1);
    s2a_track_reprotect((uintptr_t)data, 0x1000, S2A_TRACK_NONE);
    error = s2a_android_copy_guest_readonly((uintptr_t)data, copy, sizeof copy);
    if (error) return 7;
    copy[16] = 0x5a;
    s2a_track_set_write_prep(write_prep);
    s2a_track_restore_precise((uintptr_t)data, copy, sizeof copy);
    s2a_track_set_write_prep(NULL);
    error = s2a_android_copy_guest_readonly((uintptr_t)data, copy, sizeof copy);
    if (error || copy[16] != 0x5a || copy[17] != 0x77 ||
        s2a_track_platform_protection((uintptr_t)data) != PROT_NONE || prepare_calls != 1 ||
        prepared_address != (uintptr_t)data || prepared_size != sizeof copy) {
        fprintf(stderr, "precise restore changed protection or neighbor: %d\n", error); return 8;
    }
    s2a_track_drain_done();
    s2a_track_drain(&batch);
    int old_reported = 0;
    for (unsigned i = 0; i < batch.nprecise; ++i) if (batch.precise[i].addr == (uintptr_t)data) {
        old_reported |= (batch.precise[i].bits[0] >> 16) & 1;
    }
    s2a_track_drain_done();
    if (old_reported) {
        fprintf(stderr, "second drain falsely reports a restored byte\n"); return 9;
    }
    s2a_module_unmap(&module); free(raw);
    if (sealed_failures) return 10;
    puts("PASS real module GPU precise copy, protected restore, sealed aliases");
    return 0;
}
