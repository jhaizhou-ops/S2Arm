// Android Vulkan direct frontend, stage 1. The caller owns one immutable session.
#pragma once
#include "wsi_lease.h"
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_android.h>
#include <vulkan/vulkan_vi.h>

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_direct_vk_host {
    PFN_vkGetInstanceProcAddr instance_proc;
    PFN_vkGetDeviceProcAddr device_proc;
    // Loader exports used before an instance exists (static guest imports).
    PFN_vkVoidFunction (*symbol)(const char *name);
    // Every function returned to the guest, including dynamic lookups, is wrapped.
    void *(*wrap)(const char *name, void *function);
    void (*error)(const char *operation, VkResult result);
    // Called only for void API failures. Must stop the session, never return.
    void (*fatal)(const char *operation);
    // Blocking driver calls release/reacquire the guest virtual core.
    void (*block_begin)(void);
    void (*block_end)(void);
    // Resolve a vi NativeWindow token through HLE; never treat it as ANativeWindow.
    // Must stay alive until all VkSurfaceKHR owners are destroyed.
    const struct s2a_wsi_api *(*window)(void *guest_token);
    // Optional until a reverse guest-stack bridge is supplied. Vulkan allocators
    // run synchronously on the calling guest thread (Vulkan host-memory rules).
    uint64_t (*guest_call)(void *function, const uint64_t args[6]);
};

// Once per process; EALREADY on reconfiguration. No guest calls before success.
int s2a_android_vk_configure(const struct s2a_direct_vk_host *host);
// Same interface as the Apple loader hook. Returns NULL for unavailable names.
void *s2a_vk_entry(const char *name);
// 就绪判定（#274）：本包有有效的 direct-vulkan.txt 即 1。定义在 direct_choice.c，与冷启动准备共用同一个解析；
// AUTO 另看上局状态（s2a_vk_auto_resolve）。Vulkan 款缺省不开 AUTO（VulkanDirectChoice.DEFAULT）。
int s2a_vk_lib_ready(const char *game_data);
// Quiescence check at process cleanup. EBUSY if the guest still owns live WSI.
int s2a_android_vk_stop(void);
uint64_t s2a_android_vk_presents(void);
// 收局阶段合同（Android 直连；只由收局线程按序调用）：
// 1 关准入 s2a_android_vk_quiesce：call_gate 短锁内置粘性 vk_quiescing（未配置时也置，
//   之后 configure 返回 ECANCELED）。返回此刻外层 token 数；从未配置直连则返回 -1，
//   调用方跳过第 2 阶段。此后无外层 token 的新调用放锁后永久 park；已受理调用的嵌套
//   调用仍归属其外层 token。
// 2 有界排空 s2a_android_vk_drain_admitted：收局线程不持任何直连锁，等外层 token
//   归零。此时 SVC 门与 writer epoch 仍未进入终局，已受理 driver 帧里的反向 allocator
//   回调可正常进 SVC、block_end 取回虚拟核，直到外层 finish_call 出账后 park。
//   成功=0；准入未关或终局 SVC 门已发布 EINVAL；收局线程自身在 token 或反向回调帧里
//   EDEADLK；800ms 绝对 deadline 内未归零 EBUSY（列出在途调用名）。非 0 时调用方不得
//   进入第 3 阶段，保留全部 Vulkan 资源并失败退出。
// 3 之后才允许发布不可逆的 SVC park 与 writer epoch，最后 terminal_drain 销毁。
// 限制：passthrough 命令（vkCmd*、vkAllocateCommandBuffers、vkMapMemory 等）不取
//   token，驱动可在其中隐式调用父 pool/device/instance 的客体 allocator。这类驱动帧
//   不能被第 2 阶段排空；若终局门把它冻结在回调里，terminal_drain 按反向回调计数
//   返回 EBUSY 并保留资源（失败封闭），不能当作已清场。
int s2a_android_vk_quiesce(void);
int s2a_android_vk_drain_admitted(void);
// Terminal process shutdown only, after native guest/fault writer quiescence.
// The process must exit; guest allocator storage remains quarantined until then.
// EBUSY without touching the device if any token or reverse callback is live.
int s2a_android_vk_terminal_drain(void);

#ifdef __cplusplus
}
#endif
