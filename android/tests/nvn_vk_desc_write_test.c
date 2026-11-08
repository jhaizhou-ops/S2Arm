// 描述符写入初始化的反例（宿主，无 Vulkan 运行时）：三路描述符都必须整结构清零，
// 尤其是 dstArrayElement（描述符数组起始下标）——曾经漏填它在真机上把 Adreno 驱动写崩。
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include "nvn_vk_desc_write.h"

static int fails;
static void check(int cond, const char *what) {
    if (!cond) { printf("  FAIL %s\n", what); fails++; }
}
// 预填非零垃圾：未清零的字段会原样留下，测试据此判定
static void poison(VkWriteDescriptorSet *w) { memset(w, 0xA5, sizeof *w); }

static void one(VkDescriptorType t, uint32_t binding, const char *name) {
    VkWriteDescriptorSet w;
    poison(&w);
    s2a_desc_write_init(&w, (VkDescriptorSet)(uintptr_t)0x1234, binding, t, 1);
    printf("  %-22s sType=%d dstSet=%p dstBinding=%u dstArrayElement=%u count=%u type=%d pNext=%p texel=%p\n",
           name, (int)w.sType, (void *)w.dstSet, w.dstBinding, w.dstArrayElement, w.descriptorCount,
           (int)w.descriptorType, (void *)w.pNext, (void *)w.pTexelBufferView);
    check(w.sType == VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, "sType");
    check((uintptr_t)w.dstSet == 0x1234, "dstSet");
    check(w.dstBinding == binding, "dstBinding");
    check(w.dstArrayElement == 0, "dstArrayElement 必须是 0");
    check(w.descriptorCount == 1, "descriptorCount");
    check(w.descriptorType == t, "descriptorType");
    check(w.pNext == NULL, "pNext");
    check(w.pTexelBufferView == NULL, "pTexelBufferView");
    check(w.pBufferInfo == NULL && w.pImageInfo == NULL, "info 指针清零");
}

// 反例：复刻「逐字段赋值但漏 dstArrayElement」的写法，必须能把污染值带出来。
static void negative_control(void) {
    VkWriteDescriptorSet w;
    poison(&w);
    w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    w.dstSet = (VkDescriptorSet)(uintptr_t)0x1234;
    w.dstBinding = 7;
    w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    printf("  反例(漏 dstArrayElement)      dstArrayElement=%u（应 != 0，证明本例能抓到遗漏）\n", w.dstArrayElement);
    check(w.dstArrayElement != 0, "反例必须留下污染值");
}

int main(void) {
    printf("== 描述符写入初始化 ==\n");
    one(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 3, "UBO");
    one(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 5, "Storage");
    one(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 9, "Texture");
    negative_control();
    printf("%s\n", fails ? "nvn-vk-desc-write: 失败" : "nvn-vk-desc-write: 通过");
    return fails ? 1 : 0;
}
