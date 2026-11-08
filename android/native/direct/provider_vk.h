// C1：生产 direct provider 的配置入口（只有把共享 NVN 前端 + nvn_vk 后端编进来的构建才有实现）。
// runtime 在调用 s2a_direct_select 之前把本局上下文交过来；generic 构建里这些符号是弱的，直接跳过。
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_direct_vk_context {
    const char *game_data_dir;   // 已激活 revision 根（从这里读 shaders/vulkan/direct 下的离线库）
    const char *state_dir;       // 会话状态目录
    double display_hz;           // 0=未知
    const void *lease_api;       // 既有 s2a_wsi_api；窗口还没接进 direct 会话，当前只登记
};

// 弱符号：没有 provider 的构建里为 NULL。
void s2a_direct_provider_vk_configure(const struct s2a_direct_vk_context *context) __attribute__((weak));

#ifdef __cplusplus
}
#endif
