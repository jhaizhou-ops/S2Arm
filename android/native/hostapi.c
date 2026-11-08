#include "s2a_hostapi.h"

#include <stdatomic.h>

static _Atomic(const s2a_host_api_v1 *) g_api;

// `size` is a prefix length: a newer host may append fields. Older readers use
// the prefix they know; only a smaller table or a version bump is rejected.
static int table_ok(const s2a_host_table *table, size_t size) {
    return table && table->size >= size && table->abi_version == S2A_HOST_API_ABI_VERSION;
}

#define CHECK_TABLE(cap, field, type)                                             \
    do {                                                                          \
        if (api->capabilities & (cap)) {                                          \
            if (!api->field) return S2A_HOST_E_ARGUMENT;                           \
            if (!table_ok((const s2a_host_table *)api->field, sizeof(type)))      \
                return S2A_HOST_E_VERSION;                                        \
        } else if (api->field != NULL) {                                          \
            return S2A_HOST_E_ARGUMENT;                                           \
        }                                                                         \
    } while (0)

int s2a_host_register(const s2a_host_api_v1 *api) {
    if (!api) return S2A_HOST_E_ARGUMENT;
    if (!table_ok(&api->hdr, sizeof *api)) return S2A_HOST_E_VERSION;
    if (api->capabilities & ~((uint64_t)S2A_HOST_CAP_ALL)) return S2A_HOST_E_ARGUMENT;

    CHECK_TABLE(S2A_HOST_CAP_USER, user, s2a_host_user_v1);
    CHECK_TABLE(S2A_HOST_CAP_MEMINFO, meminfo, s2a_host_meminfo_v1);
    CHECK_TABLE(S2A_HOST_CAP_INPUT, input, s2a_host_input_v1);
    CHECK_TABLE(S2A_HOST_CAP_DISPLAY, display, s2a_host_display_v1);
    CHECK_TABLE(S2A_HOST_CAP_UI, ui, s2a_host_ui_v1);
    CHECK_TABLE(S2A_HOST_CAP_DECODE, decode, s2a_host_decode_v1);
    CHECK_TABLE(S2A_HOST_CAP_STOP, stop, s2a_host_stop_v1);

    atomic_store_explicit(&g_api, api, memory_order_release);
    return S2A_HOST_E_OK;
}

const s2a_host_api_v1 *s2a_host_get(void) {
    return atomic_load_explicit(&g_api, memory_order_acquire);
}
