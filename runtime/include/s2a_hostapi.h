// Host API v1 (shared contract for iOS / macOS / Android / OHOS; draft, not
// wired to a concrete host yet).
//
// The runtime core and the C# service layer must not read platform system state
// directly (locale/time zone, display, input, decoding, UI, memory pressure).
// Each shell registers this table once before the guest starts; native and
// managed code call through it. The table is intentionally platform-neutral:
// Android fills it from Context/LocaleList/Display/AAssetManager, iOS/macOS
// from NSLocale/UIScreen/GameController/AudioToolbox, and a future OHOS shell
// from its own APIs.
//
// Every table starts with `size` and `abi_version`. `size` is a prefix length,
// not an identity: readers use min(host_size, own_size) and ignore appended
// fields. Append new fields at the end and grow `size`; bump `abi_version` only
// for a breaking change (field meaning, order, or removal). Optional
// capabilities are selected with `capabilities`, so an old core can still use a
// newer host's prefix.
//
// Rules:
//  - All strings are NUL-terminated UTF-8. The caller owns the output buffer;
//    no allocation is returned across this ABI.
//  - Every function returns 0 on success and a negative S2A_HOST_E_* value on
//    failure unless its comment says otherwise. No C++ exception may cross it.
//  - The host keeps the table and its `host` pointer alive for the process
//    lifetime. Register once, before guest start.
//  - A capability bit means the matching table is non-null and its prefix is
//    supported. Unknown capability bits are rejected.
//  - Direction: every table here is provided by the shell (the registrant) and
//    called by the core. A request in the other direction (shell -> core) is a
//    core-exported function, never a field of this table.
//  - Output structs (s2a_host_meminfo, s2a_host_input_state,
//    s2a_host_display_info, ...) follow the same prefix rule. The caller sets
//    out->size = sizeof(its own struct) before the call. The host writes only
//    the prefix both sides know (min(out->size, host's struct size)), then sets
//    out->size to the bytes it actually wrote and out->abi_version to
//    S2A_HOST_API_ABI_VERSION, so a newer core can tell which trailing fields
//    an older host left untouched. out->size smaller than the v1 struct returns
//    S2A_HOST_E_RANGE; out == NULL returns S2A_HOST_E_ARGUMENT.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_HOST_API_ABI_VERSION 1u

enum {
    S2A_HOST_E_OK = 0,
    S2A_HOST_E_ARGUMENT = -1,
    S2A_HOST_E_VERSION = -2,
    S2A_HOST_E_RANGE = -3,
    S2A_HOST_E_UNSUPPORTED = -4,
    S2A_HOST_E_INTERNAL = -5,
    S2A_HOST_E_TIMEOUT = -6,
};

typedef struct s2a_host_table {
    uint32_t size;         // >= sizeof(struct); appended fields grow it
    uint32_t abi_version;  // = S2A_HOST_API_ABI_VERSION; break-only bump
} s2a_host_table;

enum {
    S2A_HOST_CAP_USER = 1u << 0,
    S2A_HOST_CAP_MEMINFO = 1u << 1,
    S2A_HOST_CAP_INPUT = 1u << 2,
    S2A_HOST_CAP_DISPLAY = 1u << 3,
    S2A_HOST_CAP_UI = 1u << 4,
    S2A_HOST_CAP_DECODE = 1u << 5,
    S2A_HOST_CAP_STOP = 1u << 6,
    S2A_HOST_CAP_ALL = (1u << 7) - 1,
};

typedef struct s2a_host_user_v1 {
    s2a_host_table hdr;
    // These values are frozen for the session from BootSpec (the values the
    // shell resolved before guest start). A mid-session system language/zone
    // change does not change what the service layer sees.
    // BCP-47 language tag: Android LocaleList.getDefault().get(0).toLanguageTag()
    // (e.g. zh-Hans-CN), iOS/macOS NSLocale.languageCode + script + region.
    int (*language)(void *host, char *out, size_t cap);
    // ISO 3166-1 alpha-2, or "" when the platform has no country (language-only).
    int (*region)(void *host, char *out, size_t cap);
    // Canonical IANA name (e.g. Asia/Shanghai): Android ICU canonical ID,
    // iOS/macOS NSTimeZone.name. Time arithmetic uses the system-data lock's
    // tzdata, not the host's current offset.
    int (*timezone)(void *host, char *out, size_t cap);
} s2a_host_user_v1;

// Process/device memory accounting. This is deliberately distinct from
// s2a_mem_query(): that one answers Horizon QueryMemory for a guest address
// range; this one reports host/process/GPU pressure to the core and UI.
typedef struct s2a_host_meminfo {
    uint32_t size;
    uint32_t abi_version;
    uint64_t total_bytes;        // physical memory available to the process/device
    uint64_t available_bytes;    // current estimate; 0 = unknown
    uint64_t process_rss_bytes;
    uint64_t guest_mapped_bytes; // memory owned by the guest address space
    uint64_t gpu_bytes;          // driver-reported GPU allocation; 0 = unknown
    uint32_t flags;              // bit 0: available_bytes is a hard limit; bit 1: gpu is estimate
    uint32_t _pad;
} s2a_host_meminfo;

typedef struct s2a_host_meminfo_v1 {
    s2a_host_table hdr;
    // iOS/macOS fills this from task_vm_info / host_statistics plus the low-region
    // probe; Android from ActivityManager/Debug.MemoryInfo and the driver.
    int (*query)(void *host, s2a_host_meminfo *out);
} s2a_host_meminfo_v1;

// Same button bit layout as the platform input layer (Npad bits, sticks in
// -32768..32767). This table is the one core-facing input read. Platform push
// paths (Android s2a_android_input_set, iOS vpad) are implementation details
// behind it. s2a_vpad_read stays as the legacy InputPump symbol until A2 moves
// that consumer to this table; it is not a second core-facing API.
typedef struct s2a_host_input_state {
    uint32_t size;
    uint32_t abi_version;
    uint32_t buttons;
    uint32_t _pad;
    int32_t sticks[4];
    uint64_t timestamp_ns;
} s2a_host_input_state;

typedef struct s2a_host_input_v1 {
    s2a_host_table hdr;
    int (*read)(void *host, s2a_host_input_state *out);
} s2a_host_input_v1;

typedef struct s2a_host_display_info {
    uint32_t size;
    uint32_t abi_version;
    // Width/height/rotation come from the current window-lease revision
    // (s2a_wsi_* / #28), not a second Display snapshot.
    uint32_t width;       // game Surface pixels (iOS drawable / Android Surface), not Display pixels
    uint32_t height;
    uint32_t refresh_mhz; // platform refresh rate * 1000
    uint32_t rotation;    // Android Surface.ROTATION_* / iOS interface orientation (0..3)
    uint32_t dpi_x;
    uint32_t dpi_y;
} s2a_host_display_info;

typedef struct s2a_host_display_v1 {
    s2a_host_table hdr;
    int (*info)(void *host, s2a_host_display_info *out);
    // 0 = handheld, 1 = docked. This callback is the single runtime writer for
    // the mode; BootSpec / S2A_DOCKED only supplies the initial value and must
    // not remain a second live switch.
    int (*set_console_mode)(void *host, uint32_t mode);
} s2a_host_display_v1;

typedef struct s2a_host_ui_v1 {
    s2a_host_table hdr;
    // Asynchronous UI request: submit, wait separately, cancel on session stop.
    // The UI thread never blocks on the guest. The host keeps the answer until
    // it is consumed, so a too-small buffer can be retried without asking the
    // user again. request_json / reply_json are UTF-8 JSON.
    // begin: 0 on success, *request_id identifies the pending request.
    int (*begin)(void *host, const char *request_json, uint64_t *request_id);
    // wait: 0 = answer consumed; S2A_HOST_E_TIMEOUT = still pending;
    // S2A_HOST_E_RANGE = reply_cap too small, *reply_len gets the needed size.
    // On success *reply_len is the bytes written (excluding NUL).
    int (*wait)(void *host, uint64_t request_id, int timeout_ms,
                char *reply_json, size_t reply_cap, size_t *reply_len);
    // cancel: idempotent; a late answer for this id is discarded and must not
    // affect a newer session.
    int (*cancel)(void *host, uint64_t request_id);
} s2a_host_ui_v1;

// Starting set only. Add a codec value when real content needs it; append the
// enum value without an ABI bump. S2A_HOST_CAP_DECODE is optional: a platform
// without a decoder omits the table and reports Unsupported, rather than
// silently succeeding.
enum {
    S2A_HOST_CODEC_UNKNOWN = 0,
    S2A_HOST_CODEC_OPUS = 1,
    S2A_HOST_CODEC_VP8 = 2,
    S2A_HOST_CODEC_VP9 = 3,
};

typedef struct s2a_host_decode_v1 {
    s2a_host_table hdr;
    // Decode one packet into `out`; *out_len is in/out. S2A_HOST_E_RANGE means
    // the output buffer is too small, and the host writes the required size to
    // *out_len. The host never returns a pointer into its own memory.
    int (*decode)(void *host, uint32_t codec, const uint8_t *in, size_t in_len,
                  uint8_t *out, size_t *out_len, uint64_t pts_ns);
} s2a_host_decode_v1;

enum {
    S2A_HOST_STOP_USER = 0,
    S2A_HOST_STOP_LOW_MEMORY = 1,
    S2A_HOST_STOP_DEVICE_LOST = 2,
    S2A_HOST_STOP_ERROR = 3,
};

typedef struct s2a_host_stop_v1 {
    s2a_host_table hdr;
    // Core -> shell request to end the session (provided by the shell, called by
    // the core, like every table here): the guest exited on its own, the GPU
    // device was lost, an unrecoverable error, or the core decided memory is too
    // low to continue. The shell decides the UI (message, return to launcher)
    // and starts its teardown. This is a request, distinct from the s2a_native.h
    // shutdown(why) callback, which is the final notice just before the process
    // exits. The opposite direction (user / OS asks the core to stop) does not
    // go through this table; it uses the core's existing exit entry.
    // Must be asynchronous and must not block the caller. `detail` may be NULL.
    void (*request_stop)(void *host, uint32_t reason, const char *detail);
} s2a_host_stop_v1;

typedef struct s2a_host_api_v1 {
    s2a_host_table hdr;
    uint64_t capabilities; // S2A_HOST_CAP_* bits; must match non-null tables
    void *host;            // opaque host state passed to every callback
    const s2a_host_user_v1 *user;
    const s2a_host_meminfo_v1 *meminfo;
    const s2a_host_input_v1 *input;
    const s2a_host_display_v1 *display;
    const s2a_host_ui_v1 *ui;
    const s2a_host_decode_v1 *decode;
    const s2a_host_stop_v1 *stop;
} s2a_host_api_v1;

// Validates prefix sizes, abi_version and capability bits, then publishes the
// table. Returns 0 or S2A_HOST_E_*. Each table's size may be larger than this
// header's struct (new appended fields are ignored by old readers); a smaller
// table or a version mismatch is rejected. Registration is once, before guest
// start; a later call replaces the previous table (tests only).
int s2a_host_register(const s2a_host_api_v1 *api);

// Returns the registered table or NULL. The pointer is borrowed; the caller
// must not free it. Safe to call from any thread after registration.
const s2a_host_api_v1 *s2a_host_get(void);

#ifdef __cplusplus
}
#endif
