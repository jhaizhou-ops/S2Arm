// 新后端消费统一编译结果：读 <control 键>.program.json（s2a-direct-program-v1）。
//
// 这里**不再**有任何 XGS 解析、扩展名探测或失败回退：文件不是 program 结果就直接拒。
// 阶段身份：prog_t.sd[]/keys[] 是“第 i 个置位”，NVN 枚举 VS=0/FS=1/GS=2/TCS=3/TES=4/CS=5；
// 文件里的 "stage" 是字符串（vs/fs/gs/tcs/tes/cs），必须与调用方期望的 NVN 阶段一致。
//
// 每个阶段保存：SPIR-V、真实反射（cbuffers/sbuffers/textures/images 的 set/binding）、
// 顶点输入位掩码、文件级身份（整份 JSON 的 SHA-256）——身份不靠短 key，短 key 只用于定位文件。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif
#define NVK_PROGRAM_MAX_BINDINGS 256
#define NVK_PROGRAM_MAX_INPUTS 16
#define NVK_STAGE_COUNT 6

struct nvn_vk_shader_binding {
    uint32_t set, binding, type, count, slot;   // type 用 VkDescriptorType 数值
};

struct nvn_vk_stage {
    uint32_t present;
    uint32_t nvn_enum;        // NVN_SHADER_STAGE_*（0=VS,1=FS,2=GS,3=TCS,4=TES,5=CS）
    uint32_t array_index;     // 在 prog_t.sd[]/keys[] 里的序号
    char key[17];
    VkShaderModule module;
    uint32_t binding_count;
    struct nvn_vk_shader_binding bindings[NVK_PROGRAM_MAX_BINDINGS];
    uint32_t input_count;
    uint32_t inputs[NVK_PROGRAM_MAX_INPUTS];
    uint32_t attribute_read_mask;
    uint32_t spirv_words;
};

struct nvn_vk_program {
    struct nvn_vk_stage stage[NVK_STAGE_COUNT];   // 按 NVN 枚举索引
    uint32_t stage_mask;
    char identity[65];                            // 整份 program 结果的 SHA-256
    char schema[32];
};

// keys: 按数组顺序（第 i 项 = stages 掩码第 i 个置位）；stages: NVN 位掩码。
// 每个阶段读 <key>.program.json，并要求文件里的 stage 与位对应的 NVN 枚举一致。
int nvn_vk_program_load(struct s2a_vk_device *d, const char *directory,
                        const uint8_t keys[6][8], uint32_t stages,
                        struct nvn_vk_program *out, char *why, size_t why_size);
void nvn_vk_program_destroy(struct s2a_vk_device *d, struct nvn_vk_program *p);
void nvn_vk_program_summary(const struct nvn_vk_program *p, char *out, size_t n);
#ifdef __cplusplus
}
#endif
