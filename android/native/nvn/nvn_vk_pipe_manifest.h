// 安卓侧管线预热清单（设备侧增长）：记录“这台设备玩这款游戏实际建过哪些 PSO”，
// 下次会话开局由预热路径按同一份完整配方提前创建。
//
// 与 iOS 的 pso_manifest.tsv/pso_user.tsv 思路一致，但载体不同：
//   * iOS 每条管线一个 Metal binary archive（驱动产物要自己存）；
//   * Vulkan 的驱动产物已经由 VkPipelineCache（nvn_vk_driver_cache）落盘，
//     这里只需要存“该建哪些 PSO”的规范配方（nvk_pipe_recipe，纯标量、可逐字节比较）。
//
// 文件：<游戏缓存目录>/nvn-vk/pipes-v<layout_policy>-<pipelineCacheUUID 32hex>.bin
//   magic "S2APM1" + 版本 + layout_policy + entry_size + count + FNV-1a 校验和 + 条目。
//   换布局策略/换驱动 UUID 自然不命中；损坏/超限/短读一律整份拒绝，绝不喂给运行时。
// 只读/只写本进程自己的缓存目录；不碰安装 revision、不碰游戏文件。
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "nvn_vk_pipe_recipe.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NVM_MAX_ENTRIES 2048   // 2048 × sizeof(nvm_entry) ≈ 1.6 MiB

// 一条清单项：完整管线配方 + 程序缓存键（input_sha：按它从程序缓存/离线库取结果字节）。
// input_sha 不参与管线配方的命中判据；只给预热取程序用。
struct nvm_entry {
    struct nvk_pipe_recipe recipe;
    uint8_t input_sha[32];
};

// 绑定缓存目录与驱动 UUID（在管线缓存初始化时调用一次）；随后尝试加载上次的清单。
void nvm_manifest_configure(const char *cache_dir, const uint8_t uuid[16]);
int  nvm_manifest_enabled(void);

// 记录一条实际创建过的 PSO 配方（去重；容量满后拒绝并计数）。
void nvm_manifest_note(const struct nvk_pipe_recipe *r, const uint8_t input_sha[32]);

// 会话收尾落盘（原子写：临时文件 + fsync + rename）；失败只记录，不影响收尾。
void nvm_manifest_save(void);
void nvm_manifest_save_sync(void);   // 收尾用：同步写，进程退出前保证落盘

int  nvm_manifest_count(void);
const struct nvm_entry *nvm_manifest_at(int i);
// 预热带走的游标（从 0 开始）：返回 0 = 没有更多；1 = 取到一条。
int nvm_manifest_take_next(struct nvm_entry *out);

void nvm_manifest_stats(uint32_t *loaded, uint32_t *recorded, uint32_t *dups, uint32_t *refused);

#ifdef __cplusplus
}
#endif
