// C1：graphics.v1.json 的 native 严格消费端。
// 外壳（Java/C#/Python）已验证包与 extension；native 在重定位前再按同一 schema 解析一份，
// 只接受本实现支持的前端/后端/ABI/编译入口，缺项和未知值都返回准确错误，不猜默认路径。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_GRAPHICS_SCHEMA "s2a-graphics-v1"
#define S2A_GRAPHICS_FRONTEND "nvn"
#define S2A_GRAPHICS_BACKEND "vulkan-direct"
#define S2A_GRAPHICS_RUNTIME_COMPILER_ABI "s2a-direct-compile-v1"

struct s2a_graphics_descriptor_v1 {
    uint32_t direct_abi;
    uint32_t source_parser_version;
    uint32_t storage_write_stages;  // package lower bound, 1 << nvn_gpu_stage
    uint32_t storage_coverage_complete;  // reporting only; missing means unknown
    uint32_t profile_count;
    char profile_hashes[8][72];      // 每个 profile 的 profileHash（"sha256-"+64 hex）
    char title_id[17];               // 16 位大写 hex
    char game_content_root[72];      // "sha256-" + 64 位小写 hex
    char module_set_digest[72];      // "sha256-" + 64 位小写 hex
    char translator_closure[128];
    char runtime_compiler_abi[64];
};

enum s2a_graphics_error {
    S2A_GRAPHICS_OK = 0,
    S2A_GRAPHICS_MISSING = -1,
    S2A_GRAPHICS_SCHEMA_ERROR = -2,
    S2A_GRAPHICS_VALUE = -3,
    S2A_GRAPHICS_VERSION = -4,
    S2A_GRAPHICS_FRONTEND_ERROR = -5,
    S2A_GRAPHICS_IDENTITY = -6,
    S2A_GRAPHICS_LIMIT = -7,
};

// 解析并复制；why 写入 ASCII 原因（可为 NULL）。不读文件、不执行 guest。
int s2a_graphics_descriptor_parse(const uint8_t *json, size_t bytes,
                                  struct s2a_graphics_descriptor_v1 *out,
                                  char *why, size_t why_size);

// 仅命中描述符中实际列出的离线设备档；空库与未列出的 live 档都未命中。
int s2a_graphics_has_profile(const struct s2a_graphics_descriptor_v1 *descriptor, const char *profile);

// Unknown coverage does not gate admission; these bits are the known lower bound.
int s2a_graphics_storage_admit(int vertex_feature_enabled, uint32_t write_stages);

// implementationKey = SHA-256(gameContentRoot, moduleSetDigest, directABI,
// translatorClosure, effectiveProfileHash)，字段按 NUL 分隔。失败返回非 0。
int s2a_direct_implementation_key(const struct s2a_graphics_descriptor_v1 *descriptor,
                                  const char *effective_profile_hash, char out[65],
                                  char *why, size_t why_size);

#ifdef __cplusplus
}
#endif
