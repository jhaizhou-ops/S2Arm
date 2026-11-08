// READY 的 GPU 身份行：格式、真实设备值拼接、容量/缺失负控。
// 只用合成 VkPhysicalDeviceProperties 值，不建 Vulkan、不跑游戏。
#include <stdio.h>
#include <string.h>

#include "direct/vk_identity.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

int main(void) {
    char line[512];
    // Vulkan 版本编码：1.3.284 / 1.1.177（与 VK_MAKE_VERSION 同义）。
    unsigned api_8e = (1u << 22) | (3u << 12) | 284u;
    unsigned api_9000 = (1u << 22) | (1u << 12) | 177u;
    CHECK(!strcmp(s2a_vk_vendor_name(0x13B5), "ARM"), "vendor 0x13B5 -> ARM");
    CHECK(!strcmp(s2a_vk_vendor_name(0x5143), "Qualcomm"), "vendor 0x5143 -> Qualcomm");
    CHECK(!strcmp(s2a_vk_vendor_name(0x1234), "Unknown"), "unknown vendor stays explicit");

    CHECK(s2a_vk_identity_line("Adreno (TM) 830", api_8e,
                               "Adreno (TM) 830", "Vulkan 1.3.284",
                               line, sizeof line) == 0,
          "8E identity line formats");
    CHECK(strstr(line, "PrintGpuInformation: ") == line, "starts with the admission key");
    CHECK(strstr(line, "Adreno (TM) 830") != NULL, "carries the queried device name");
    CHECK(strstr(line, "(Vulkan v1.3.284") != NULL, "carries the queried API version");
    CHECK(strstr(line, "Driver: Adreno (TM) 830 Vulkan 1.3.284") != NULL,
          "carries driver name and info");
    CHECK(strstr(line, "830") != NULL && strstr(line, "v1.3.284") != NULL,
          "matches the 8E gpu_contains substrings");

    CHECK(s2a_vk_identity_line("Mali-G710 MC10", api_9000,
                               "ARM", "v1.r32p1",
                               line, sizeof line) == 0,
          "9000 identity line formats");
    CHECK(strstr(line, "Mali-G710 MC10") != NULL, "carries Mali device name");
    CHECK(strstr(line, "(Vulkan v1.1.177") != NULL, "carries Mali API version");
    CHECK(strstr(line, "Driver: ARM v1.r32p1") != NULL,
          "matches the 9000 gpu_contains substring");
    CHECK(strstr(line, "v1.1.177") != NULL && strstr(line, "ARM v1.r32p1") != NULL,
          "matches the 9000 gpu_contains substrings");

    // 负控：容量不足必须失败且不留半行，不能静默截断成可被误读的行。
    char tiny[8] = "dirty";
    CHECK(s2a_vk_identity_line("Adreno (TM) 830", api_8e, "Adreno", "Vulkan", tiny, sizeof tiny) != 0,
          "short buffer is rejected");
    CHECK(tiny[0] == 0, "short buffer is cleared");
    CHECK(s2a_vk_identity_line(NULL, api_8e, "Adreno", "Vulkan", line, sizeof line) != 0,
          "missing device name is rejected");
    CHECK(s2a_vk_identity_line("", api_8e, "Adreno", "Vulkan", line, sizeof line) != 0,
          "empty device name is rejected");
    CHECK(s2a_vk_identity_line("Adreno", api_8e, "Adreno", NULL, line, sizeof line) != 0,
          "missing driver info is rejected");

    if (fails) { printf("direct vk identity test: %d FAILED\n", fails); return 1; }
    printf("direct vk identity test: ok\n");
    return 0;
}
