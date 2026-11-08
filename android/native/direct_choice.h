#pragma once
// Vulkan 款直连的冷启动选择（#274 零配置就绪判定）：包内描述 direct-vulkan.txt 的唯一解析、
// AUTO 判定与 attempt 标记。纯 C、不依赖运行时与 Vulkan，宿主单测直接编；
// direct_session.c 的 s2a_android_vk_session_prepare 与 s2a_vk_lib_ready 共用同一个解析。
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// s2a_android_vk_select 的三态：通用 / 直连（手动）/ AUTO（冷启动准备时按包与上局状态判）
enum { S2A_VK_CHOICE_GENERIC = 0, S2A_VK_CHOICE_DIRECT = 1, S2A_VK_CHOICE_AUTO = 2 };

// 读 <game_dir>/direct-vulkan.txt。返回 0 = 有效，*skipped 置要跳过的 subsdkN 位图（可传 NULL）；
// ENOENT = 没有；EINVAL = 格式不对（首行不是 S2ARM_VULKAN_DIRECT_V1、模块行不是 subsdk0–9 或重复）；
// ENAMETOOLONG = 路径太长；EIO = 读错。game_dir 为空 → EINVAL。
int s2a_vk_descriptor_read(const char *game_dir, unsigned *skipped);

// 安卓侧就绪判定：本包有有效描述即 1（同 s2a_vk_descriptor_read == 0）。也声明在 direct_vk.h，定义在 direct_choice.c
int s2a_vk_lib_ready(const char *game_data);

// AUTO 判定：返回 1 = 走直连；0 = 回通用。why 写一行原因，点名读到的文件（why 可为 NULL）。
// 回通用的情况：游戏或状态目录没给；本包没有有效描述；状态目录里有上局的 vulkan-direct.fail；
// 状态目录里有上局没正常结束留下的 vulkan-direct.attempt。fail 只在手动直连正常结束时清（s2a_vk_session_end）。
int s2a_vk_auto_resolve(const char *game_dir, const char *state_dir, char *why, size_t why_size);

// attempt 标记 <state_dir>/vulkan-direct.attempt：直连准备开始前原子写入；直连会话正常停止时删。
// 崩溃或被杀时留下，下次 AUTO 据此回通用。begin 返回 0 或 errno；end 删不存在的也返回 0。
int s2a_vk_attempt_begin(const char *state_dir);
int s2a_vk_attempt_end(const char *state_dir);

// 直连会话结束时的标记清理，规则同 NVN 直连 s2a_direct_finish（#274 维护方定）：
// normal=0（没正常结束）什么都不删；正常结束删 attempt；再若是手动直连（S2A_VK_CHOICE_DIRECT）
// 且本局没写过 fail（failed_this_session=0），删上局留下的 vulkan-direct.fail——手动重试成功后 AUTO 恢复。
// AUTO 与通用都不清 fail；通用也不碰 attempt。启动时不清。返回 0 或第一个 errno。
int s2a_vk_session_end(const char *state_dir, int choice, int normal, int failed_this_session);

#ifdef __cplusplus
}
#endif
