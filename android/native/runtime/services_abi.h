// Android 私有组合 ABI；原生与 NativeAOT 位于同一 DSO。
#pragma once
#include "../direct/s2a_direct.h"
#include "s2a_hostapi.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// v1 request（64 字节）只启动 generic；v2 在其布局前缀上追加 direct 图形表。
// version 字段是唯一判别：v1 入口收到 version=2 必须拒绝，v2 入口收到 version=1 也拒绝。
#define S2A_ANDROID_SERVICES_ABI 1u
#define S2A_ANDROID_SERVICES_ABI_V2 2u
#define S2A_ANDROID_SERVICES_REQUEST_V2_SIZE 80u
enum s2a_android_services_state {
    S2A_SERVICES_CREATED, S2A_SERVICES_STARTING, S2A_SERVICES_READY,
    S2A_SERVICES_FAILED, S2A_SERVICES_STOP_REQUESTED,
    S2A_SERVICES_STOPPED, // 仅真实managed Cleanup全成功后；RequestStop不授予此状态。
};
enum s2a_android_services_error {
    S2A_SERVICES_OK = 0, S2A_SERVICES_ARGUMENT = -1, S2A_SERVICES_VERSION = -2,
    S2A_SERVICES_ALREADY_USED = -3, S2A_SERVICES_PROVIDER = -4,
    S2A_SERVICES_HOST = -5, S2A_SERVICES_INITIALIZE = -6, S2A_SERVICES_GPU = -7,
    S2A_SERVICES_STOP = -8, S2A_SERVICES_CLEANUP = -9,
};
struct s2a_android_services_request {
    uint32_t size, version;
    uint64_t session_id;
    void *native_owner;
    const s2a_host_api_v1 *host_api;
    const char *game_data_dir, *state_dir;
    const void *lease_api; // 既有 s2a_wsi_api，保活到进程退出。
    uint32_t console_mode, reserved;
};
struct s2a_android_services_status {
    uint32_t size, version;
    uint64_t session_id;
    uint32_t state;
    int32_t error;
};

// direct 图形模式：0 generic，1 direct。首版 flags 必须为 0。
enum s2a_android_graphics_mode { S2A_GRAPHICS_GENERIC = 0, S2A_GRAPHICS_DIRECT = 1 };

// v2 请求：前 64 字节与 v1 同布局，version=2；graphics 在偏移 64，mode 72，flags 76。
// generic 要求 graphics=NULL；direct 要求 table/context/session 与已冻结 selection 完全匹配。
struct s2a_android_services_request_v2 {
    struct s2a_android_services_request base;
    const s2a_direct_api_v1 *graphics;
    uint32_t graphics_mode, flags;
};

// start 同步执行；返回0且Ready只证服务/GPU准备完成，仍须每线程attach和最终原生准入。
// 请求中的全部指针由宿主持有，保活到进程退出。
int s2a_android_services_start(const struct s2a_android_services_request *, struct s2a_android_services_status *);
// v2 是唯一的 direct 启动入口；generic 仍可走 v1 或 v2(graphics=NULL, mode=0)。
int s2a_android_services_start_v2(const struct s2a_android_services_request_v2 *, struct s2a_android_services_status *);
int s2a_android_services_status(uint64_t session_id, struct s2a_android_services_status *);
// 仅请求停止；返回结果或 StopRequested 状态都不证明已清场。
int s2a_android_services_request_stop(uint64_t session_id, struct s2a_android_services_status *);
// Direct-only cooperative request; does not cancel services or claim cleanup.
int s2a_android_services_request_applet_exit(uint64_t session_id);

// 在每条真实guest pthread上调用；仅证明本线程managed附着和同session服务仍Ready。
// 返回0不能替代原生同线程fault self-probe/final tracking门，也不证明任何guest已执行。
int32_t s2a_android_services_attach_thread(uint64_t session_id, struct s2a_android_services_status *);

#if UINTPTR_MAX == UINT64_MAX
#ifdef __cplusplus
#define S2A_ABI_ASSERT static_assert
#else
#define S2A_ABI_ASSERT _Static_assert
#endif
S2A_ABI_ASSERT(sizeof(struct s2a_android_services_request) == 64, "services request ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, session_id) == 8, "session ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, native_owner) == 16, "owner ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, host_api) == 24, "host ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, game_data_dir) == 32, "game path ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, state_dir) == 40, "state path ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, lease_api) == 48, "lease ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request, console_mode) == 56, "mode ABI");
S2A_ABI_ASSERT(sizeof(struct s2a_android_services_request_v2) == S2A_ANDROID_SERVICES_REQUEST_V2_SIZE, "services v2 request ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request_v2, graphics) == 64, "services v2 graphics offset");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request_v2, graphics_mode) == 72, "services v2 mode offset");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_request_v2, flags) == 76, "services v2 flags offset");
S2A_ABI_ASSERT(sizeof(struct s2a_android_services_status) == 24, "services status ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_status, state) == 16, "state ABI");
S2A_ABI_ASSERT(offsetof(struct s2a_android_services_status, error) == 20, "error ABI");
#undef S2A_ABI_ASSERT
#endif
#ifdef __cplusplus
}
#endif
