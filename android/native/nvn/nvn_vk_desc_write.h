// VkWriteDescriptorSet 的初始化（生产与宿主测试共用）。
//
// 为什么单独抽出来：这个结构一直是**没有初始化的栈数组元素**，必须靠整结构清零保证所有字段
// 有定义。曾经为省几字节把它改成逐字段赋值，漏了 dstArrayElement（描述符数组起始下标），
// 结果真机上 Adreno 驱动在 vkUpdateDescriptorSets 里按垃圾下标写越界，第一笔 draw 就 SIGSEGV。
// 这里把「整结构清零 + 明确写 dstArrayElement = 0」固定成唯一入口，测试用预填垃圾字节的
// 反例核对三路描述符（UBO / Storage / Texture）都真的被清零。
#pragma once
#include <vulkan/vulkan.h>
#include <string.h>

static inline void s2a_desc_write_init(VkWriteDescriptorSet *w, VkDescriptorSet set, uint32_t binding,
                                       VkDescriptorType type, uint32_t count) {
    memset(w, 0, sizeof *w);   // 整结构清零：pNext / pTexelBufferView / dstArrayElement 都要有定义
    w->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    w->dstSet = set;
    w->dstBinding = binding;
    w->dstArrayElement = 0;    // 这些绑定都是单元素，起始下标必须是 0（不能留给栈上的垃圾）
    w->descriptorCount = count;
    w->descriptorType = type;
}
