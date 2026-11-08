#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#include "nvn_obj.h"
// 测试/诊断用：把前端纹理读回主机、为合成程序注册 Vulkan 管线。
int s2a_nvn_adapter_read_texture(const tex_t *texture, uint8_t *out, size_t bytes);
int s2a_nvn_adapter_register_program(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                     const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                     uint32_t width, uint32_t height);
int s2a_nvn_adapter_register_program_textured(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                              const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                              uint32_t width, uint32_t height, const tex_t *sampled);
int s2a_nvn_adapter_register_program_vertex(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                            const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                            uint32_t width, uint32_t height, const void *vertices,
                                            size_t vertex_bytes);
int s2a_nvn_adapter_register_program_topology(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                              const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                              uint32_t width, uint32_t height, VkPrimitiveTopology topology);
