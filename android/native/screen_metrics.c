#include "screen_metrics.h"
#include "s2a_hostapi.h"
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
// 调试覆盖（debug.s2a.render_*）只在真机读系统属性：宿主单测用 -D__ANDROID__ 测安卓分支、却没有 bionic 的这个头，
//   按「有头文件」判（11-01：f7b55aeb8 只按 __ANDROID__ 判，android/test.sh 宿主两步在 Mac / Linux 都编不过）
#if defined(__ANDROID__) && __has_include(<sys/system_properties.h>)
#define S2A_SCREEN_PROP_OVERRIDE 1
#include <sys/system_properties.h>
#endif

// Widen initializes once per game. Freeze both normalized axes together so a
// surface revision between two queries cannot pair two different aspects.
static _Atomic uint64_t screen_snapshot;
int s2a_android_screen_metrics(int *width, int *height) {
    if (!width || !height) return 0;
    uint64_t packed = atomic_load_explicit(&screen_snapshot, memory_order_acquire);
    if (!packed) {
#if defined(S2A_SCREEN_PROP_OVERRIDE)
        char rw[PROP_VALUE_MAX] = {0}, rh[PROP_VALUE_MAX] = {0};
        if (__system_property_get("debug.s2a.render_width", rw) > 0 &&
            __system_property_get("debug.s2a.render_height", rh) > 0) {
            int ow = atoi(rw), oh = atoi(rh);
            if (ow > 0 && oh > 0 && ow <= 8192 && oh <= 8192) {
                packed = (uint64_t)(uint32_t)ow << 32 | (uint32_t)oh;
                atomic_store_explicit(&screen_snapshot, packed, memory_order_release);
            }
        }
#endif
        if (packed) { *width = (int)(packed >> 32); *height = (int)(uint32_t)packed; return 1; }
        const s2a_host_api_v1 *api = s2a_host_get();
        if (!api || !(api->capabilities & S2A_HOST_CAP_DISPLAY) || !api->display || !api->display->info) return 0;
        s2a_host_display_info d = {.size = sizeof d};
        if (api->display->info(api->host, &d) != S2A_HOST_E_OK || !d.width || !d.height) return 0;
        uint64_t w = 1920, h = 1080;
        if ((uint64_t)d.width * 9 > (uint64_t)d.height * 16)
            w = ((uint64_t)1080 * d.width / d.height) & ~(uint64_t)1;
        else if ((uint64_t)d.width * 9 < (uint64_t)d.height * 16)
            h = ((uint64_t)1920 * d.height / d.width) & ~(uint64_t)1;
        if (w > 8192 || h > 8192) return 0;
        packed = w << 32 | h;
        uint64_t empty = 0;
        if (!atomic_compare_exchange_strong_explicit(&screen_snapshot, &empty, packed,
                                                     memory_order_release, memory_order_acquire))
            packed = empty;
    }
    *width = (int)(packed >> 32);
    *height = (int)(uint32_t)packed;
    return 1;
}
