// 装载器私有输入合同；不属于对游戏公开的 ABI。
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_loader_blob {
    const void *bytes;
    size_t length;
    void *lease;
};

struct s2a_loader_source {
    void *context;
    // filename 为模块映像、随行表或宽屏策略表；可选表不存在返回 ENOENT。
    // 调用方先验证签名、artifact 和预期哈希，再返回 0；可用完整 APK 哈希绑定其资产。
    // 必须读取该已验证 APK 中 artifact 列出的精确路径；失败返回 errno，不能遗留 lease。
    // 成功的 bytes 到 release 前必须保持不可变；空 gates 可用 NULL + length 0。
    int (*read)(void *context, const char *filename, struct s2a_loader_blob *out);
    // 每个成功 read 恰好 release 一次；失败致命退出的进程由系统回收。
    void (*release)(void *context, struct s2a_loader_blob *blob);
};

// Android APK 输入：只借用 source 到函数返回，不保存 AAsset 或缓冲指针。
// 模块映射属于进程生命周期；与 load_modules 一样只允许冷启动调用一次。
// 宽屏表经同一认证源读取并在 release 前复制或消费；NPDM 仍由启动组合层提供。
void load_modules_from_source(const struct s2a_loader_source *source, const char **names, int n);

#ifdef __cplusplus
}
#endif
