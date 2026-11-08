// Vulkan 款直连着色器库的口径（出包 translator/vk_shaders.py ↔ 运行时 hle_vk.m / 就绪判定 s2a_vk_lib_ready）：
//   库 = <资源包>/shaders/direct/vk/vk_shaders.metallib + vk_shaders.tsv，表第一行是「# s2arm-vk-lib <口径号>」。
//   表格式、槽位分配、翻译选项任何一项改了就把口径号加 1（vk_shaders.py 的 VK_LIB_ABI 同步改）：旧包不再算就绪、运行时拒载报红
#pragma once
#define S2A_VK_LIB_ABI 3   // 2：一维贴图翻成二维（--msl-texture-1d-as-2d）；3：MSL 3.1（--msl-version 30100，审计 #1534 P1-66）
#define S2A_VK_LIB_TAG "# s2arm-vk-lib "

// Host lifecycle (0 success, negative errno). Check before stopping guest code;
// request_stop before guest joins; shutdown only after guests/services have joined.
int dm_vk_restart_check(void);
int dm_vk_request_stop(void);
int dm_vk_shutdown_session(void);
