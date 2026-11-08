// Real boot continuation, VA reservation and Foundation settings. No UIKit,
// renderer, services or game starts here; scene timing remains a device gate.
#import <Foundation/Foundation.h>
#include "../src/native.h"
#include "../../ios/settings.h"
#include "s2a_boot.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static NSUserDefaults *settings;
static void apply_settings(void) { s2a_ios_apply_graphics_settings(settings); }

static void check_reserved(uint64_t base, uint64_t size) {
    uint64_t cursor = base;
    unsigned regions = 0;
    // Darwin can split one mmap into multiple regions (128 MiB on this Mac).
    // Check every segment; a gap, writable segment or unmapped tail fails.
    while (cursor < base + size) {
        mach_vm_address_t address = cursor;
        mach_vm_size_t length = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        CHECK(mach_vm_region(mach_task_self(), &address, &length, VM_REGION_BASIC_INFO_64,
                             (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        CHECK(address <= cursor && address + length > cursor && info.protection == VM_PROT_NONE);
        cursor = address + length; regions++;
    }
    fprintf(stderr, "VA %#llx +%#llx: %u actual contiguous PROT_NONE regions\n", base, size, regions);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        // 解包专用局（S2A_PACK_APPLY_ONLY=1）构造期不占客体窗口（vawin.c：解包局用不到客体内存）；其余模式照旧占整窗
        if (!strcmp(argv[1], "prewarm-apply")) { uint64_t b0, s0; s2a_window_get(&b0, &s0); CHECK(!s2a_window_ok() && !s0); }
        else CHECK(s2a_window_ok());
        int prewarm = !strncmp(argv[1], "prewarm", 7);
        CHECK(s2a_process_prewarmed() == prewarm);
        uint64_t base, size; s2a_window_get(&base, &size);
        if (strcmp(argv[1], "prewarm-apply")) {
            CHECK(base && size >= (32ull << 30));
            check_reserved(base, size);   // actual constructor-time mapping
        }
        // The shim compiles iOS branches on macOS; release the actual Mac
        // malloc guard after verifying the reservation, as the Mac host does.
        void (*release)(void) = dlsym(RTLD_DEFAULT, "s2a_vaguard_open");
        CHECK(release != NULL); release();
        settings = [[NSUserDefaults alloc] initWithSuiteName:
            [@"local.s2arm.prewarm." stringByAppendingString:NSUUID.UUID.UUIDString]];
        [settings setVolatileDomain:@{@"S2AResolutionScale": @"1.5"} forName:NSArgumentDomain];
        CHECK(getenv("S2A_RES_SCALE") == NULL);
        // host_main now always defers iOS for the initial loading screen.
        int deferred = s2a_host_boot_defer(apply_settings, 1);
        CHECK(deferred == 1);
        CHECK(s2a_host_boot_deferred() == deferred && s2a_host_boot_pending() == deferred);
        CHECK(getenv("S2A_RES_SCALE") == NULL);   // no settings before activation
        if (!strcmp(argv[1], "prewarm-apply")) {
            CHECK(deferred && getenv("S2A_PACK_APPLY_ONLY") != NULL);
            puts("✓ t_ios_prewarm：预热解包仍在等待激活"); return 0;
        }
        if (deferred) {
            CHECK(s2a_host_boot_defer(apply_settings, 1) == 1);
            s2a_boot_entry entry = s2a_host_boot_take();
            CHECK(entry == apply_settings && !s2a_host_boot_pending());
            entry();
            CHECK(s2a_host_boot_take() == NULL);
            CHECK(s2a_host_boot_defer(apply_settings, 1) == 1);
            CHECK(s2a_host_boot_take() == NULL);   // no second launch after a repeated request
        } else {
            CHECK(s2a_host_boot_take() == NULL);
            apply_settings();
        }
        CHECK(getenv("S2A_RES_SCALE") && !strcmp(getenv("S2A_RES_SCALE"), "1.5"));
        // Repeated reserve must preserve an actual committed page, including
        // after the guest window is trimmed for the host tail allocator.
        CHECK(mprotect((void *)base, (size_t)getpagesize(), PROT_READ | PROT_WRITE) == 0);
        *(volatile uint64_t *)base = 0x123456789abcdef0ull;
        s2a_window_reserve();
        CHECK(*(volatile uint64_t *)base == 0x123456789abcdef0ull);
        s2a_window_trim(size / 2); s2a_window_reserve();
        uint64_t again_base, again_size; s2a_window_get(&again_base, &again_size);
        CHECK(again_base == base && again_size == size / 2);
        CHECK(*(volatile uint64_t *)base == 0x123456789abcdef0ull);
        puts("✓ t_ios_prewarm：真实窗口、延后续体、仅一次领取和Foundation偏好");
        return 0;
    }
}
