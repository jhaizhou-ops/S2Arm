// Host-only synthetic path: real descriptor parser, compile-result validator,
// and checked Vulkan call against a stub driver; no GPU or game assets.
#include <stdio.h>
#include <stdlib.h>
#include "nvn_vk_first_draw.h"
#include "direct/graphics.h"
#include "direct/spirv_storage_vk.h"

static int calls;
VKAPI_ATTR VkResult VKAPI_CALL vkCreateShaderModule(VkDevice device, const VkShaderModuleCreateInfo *info,
                                                    const VkAllocationCallbacks *alloc, VkShaderModule *module) {
    (void)device; (void)info; (void)alloc; (void)module;
    calls++;
    return VK_SUCCESS;
}
static unsigned char *read_file(const char *path, size_t *length) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END)) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    rewind(f);
    unsigned char *bytes = malloc((size_t)size + 1);
    if (!bytes) { fclose(f); return NULL; }
    *length = fread(bytes, 1, (size_t)size, f);
    fclose(f);
    if (*length != (size_t)size) { free(bytes); return NULL; }
    bytes[*length] = 0;
    return bytes;
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    size_t desc_len, result_len, shader_len;
    unsigned char *desc = read_file(argv[1], &desc_len), *result = read_file(argv[2], &result_len);
    unsigned char *shader = read_file(argv[3], &shader_len);
    if (!desc || !result || !shader) return 3;
    char why[192] = {0};
    struct s2a_graphics_descriptor_v1 parsed;
    if (s2a_graphics_descriptor_parse(desc, desc_len, &parsed, why, sizeof why)) return 4;
    int admit = s2a_graphics_storage_admit(0, parsed.storage_write_stages);
    if (!admit) {
        printf("admit=0 calls=%d\n", calls);
    } else {
        int rc = nvn_vk_program_vertex_storage_safe(result, result_len, why, sizeof why);
        if (!rc) {
            VkShaderModuleCreateInfo ci = {0};
            ci.codeSize = shader_len;
            ci.pCode = (const uint32_t *)shader;
            VkShaderModule module = VK_NULL_HANDLE;
            rc = s2a_vk_create_checked_vertex(VK_NULL_HANDLE, 0, &ci, &module, NULL);
        }
        printf("admit=1 result=%d calls=%d why=%s\n", rc, calls, why);
    }
    free(desc); free(result); free(shader);
    return 0;
}
