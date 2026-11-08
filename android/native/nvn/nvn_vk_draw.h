// 新后端的绘制入口：回放器把已绑定的 prog_t 交给这里。
#pragma once
#include <stdint.h>
#include "vk_device.h"
#include "vk_record.h"

#ifdef __cplusplus
extern "C" {
#endif
// opaque = 着色器目录（S2A_SHADER_DIR，<revision>/shaders/vulkan/direct）。
int nvk_draw_builder(struct s2a_vk_device *device, const struct s2a_record_draw_state *state,
                     struct s2a_record_result *result, void *opaque);
// 初次加载 / 缓存命中 / 失败次数（日志用）。
void nvk_draw_stats(uint32_t *loaded, uint32_t *hits, uint32_t *failed);
#ifdef __cplusplus
}
#endif
