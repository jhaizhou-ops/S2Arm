// 格式映射自测：已知样例 + 未知格式必须 UNDEFINED（不猜）。
#include <stdio.h>
#include <string.h>
#include "nvn_vk_format.h"
#include "include/nvn.h"

int main(void) {
    struct { uint32_t nvn; VkFormat vk; const char *name; } cases[] = {
        { NVN_FORMAT_RGBA8, VK_FORMAT_R8G8B8A8_UNORM, "RGBA8" },
        { NVN_FORMAT_RGBA8_SRGB, VK_FORMAT_R8G8B8A8_SRGB, "RGBA8_SRGB" },
        { NVN_FORMAT_RGB565, VK_FORMAT_R5G6B5_UNORM_PACK16, "RGB565" },
        { NVN_FORMAT_DEPTH24_STENCIL8, VK_FORMAT_D24_UNORM_S8_UINT, "D24S8" },
        { NVN_FORMAT_RGBA16F, VK_FORMAT_R16G16B16A16_SFLOAT, "RGBA16F" },
        { NVN_FORMAT_RGB_DXT1, VK_FORMAT_BC1_RGBA_UNORM_BLOCK, "DXT1" },
        { NVN_FORMAT_BPTC_UNORM, VK_FORMAT_BC7_UNORM_BLOCK, "BPTC" },
        // ASTC 全 14 种块尺寸 × UNORM / SRGB（0x79–0x94）。Wonder 首绘撞到 0x87（4x4 SRGB）。
        { NVN_FORMAT_RGBA_ASTC_4x4, VK_FORMAT_ASTC_4x4_UNORM_BLOCK, "ASTC4x4" },
        { NVN_FORMAT_RGBA_ASTC_5x4, VK_FORMAT_ASTC_5x4_UNORM_BLOCK, "ASTC5x4" },
        { NVN_FORMAT_RGBA_ASTC_5x5, VK_FORMAT_ASTC_5x5_UNORM_BLOCK, "ASTC5x5" },
        { NVN_FORMAT_RGBA_ASTC_6x5, VK_FORMAT_ASTC_6x5_UNORM_BLOCK, "ASTC6x5" },
        { NVN_FORMAT_RGBA_ASTC_6x6, VK_FORMAT_ASTC_6x6_UNORM_BLOCK, "ASTC6x6" },
        { NVN_FORMAT_RGBA_ASTC_8x5, VK_FORMAT_ASTC_8x5_UNORM_BLOCK, "ASTC8x5" },
        { NVN_FORMAT_RGBA_ASTC_8x6, VK_FORMAT_ASTC_8x6_UNORM_BLOCK, "ASTC8x6" },
        { NVN_FORMAT_RGBA_ASTC_8x8, VK_FORMAT_ASTC_8x8_UNORM_BLOCK, "ASTC8x8" },
        { NVN_FORMAT_RGBA_ASTC_10x5, VK_FORMAT_ASTC_10x5_UNORM_BLOCK, "ASTC10x5" },
        { NVN_FORMAT_RGBA_ASTC_10x6, VK_FORMAT_ASTC_10x6_UNORM_BLOCK, "ASTC10x6" },
        { NVN_FORMAT_RGBA_ASTC_10x8, VK_FORMAT_ASTC_10x8_UNORM_BLOCK, "ASTC10x8" },
        { NVN_FORMAT_RGBA_ASTC_10x10, VK_FORMAT_ASTC_10x10_UNORM_BLOCK, "ASTC10x10" },
        { NVN_FORMAT_RGBA_ASTC_12x10, VK_FORMAT_ASTC_12x10_UNORM_BLOCK, "ASTC12x10" },
        { NVN_FORMAT_RGBA_ASTC_12x12, VK_FORMAT_ASTC_12x12_UNORM_BLOCK, "ASTC12x12" },
        { NVN_FORMAT_RGBA_ASTC_4x4_SRGB, VK_FORMAT_ASTC_4x4_SRGB_BLOCK, "ASTC4x4_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_5x4_SRGB, VK_FORMAT_ASTC_5x4_SRGB_BLOCK, "ASTC5x4_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_5x5_SRGB, VK_FORMAT_ASTC_5x5_SRGB_BLOCK, "ASTC5x5_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_6x5_SRGB, VK_FORMAT_ASTC_6x5_SRGB_BLOCK, "ASTC6x5_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_6x6_SRGB, VK_FORMAT_ASTC_6x6_SRGB_BLOCK, "ASTC6x6_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_8x5_SRGB, VK_FORMAT_ASTC_8x5_SRGB_BLOCK, "ASTC8x5_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_8x6_SRGB, VK_FORMAT_ASTC_8x6_SRGB_BLOCK, "ASTC8x6_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_8x8_SRGB, VK_FORMAT_ASTC_8x8_SRGB_BLOCK, "ASTC8x8_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_10x5_SRGB, VK_FORMAT_ASTC_10x5_SRGB_BLOCK, "ASTC10x5_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_10x6_SRGB, VK_FORMAT_ASTC_10x6_SRGB_BLOCK, "ASTC10x6_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_10x8_SRGB, VK_FORMAT_ASTC_10x8_SRGB_BLOCK, "ASTC10x8_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_10x10_SRGB, VK_FORMAT_ASTC_10x10_SRGB_BLOCK, "ASTC10x10_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_12x10_SRGB, VK_FORMAT_ASTC_12x10_SRGB_BLOCK, "ASTC12x10_SRGB" },
        { NVN_FORMAT_RGBA_ASTC_12x12_SRGB, VK_FORMAT_ASTC_12x12_SRGB_BLOCK, "ASTC12x12_SRGB" },
        // 顶点属性常用的打包格式：10/10/10/2 的 SNORM/SINT（法线/切线），NVN 低位往上 r,g,b,a。
        { NVN_FORMAT_RGB10A2SN, VK_FORMAT_A2B10G10R10_SNORM_PACK32, "RGB10A2SN" },
        { NVN_FORMAT_RGB10A2I, VK_FORMAT_A2B10G10R10_SINT_PACK32, "RGB10A2I" },
        // X（未定义第四通道）族：Vulkan 没有 RGBX 位宽格式，落到同宽 RGBA（X 位不可依赖）。
        { NVN_FORMAT_RGBX8, VK_FORMAT_R8G8B8A8_UNORM, "RGBX8" },
        { NVN_FORMAT_RGBX8_SRGB, VK_FORMAT_R8G8B8A8_SRGB, "RGBX8_SRGB" },
        { NVN_FORMAT_RGBX16F, VK_FORMAT_R16G16B16A16_SFLOAT, "RGBX16F" },
        { NVN_FORMAT_RGBX32F, VK_FORMAT_R32G32B32A32_SFLOAT, "RGBX32F" },
        { NVN_FORMAT_RGBX8UI, VK_FORMAT_R8G8B8A8_UINT, "RGBX8UI" },
        // BGR 族：NVN 低位往上 r,g,b,a，与 Vulkan 的 BGR 打包一一对应。
        { NVN_FORMAT_BGR565, VK_FORMAT_B5G6R5_UNORM_PACK16, "BGR565" },
        { NVN_FORMAT_BGRX8, VK_FORMAT_B8G8R8A8_UNORM, "BGRX8" },
        { NVN_FORMAT_BGRA8_SRGB, VK_FORMAT_B8G8R8A8_SRGB, "BGRA8_SRGB" },
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        VkFormat got = nvn_vk_format(cases[i].nvn);
        printf("%-14s 0x%02x -> %d (want %d) %s\n", cases[i].name, cases[i].nvn, (int)got, (int)cases[i].vk, got == cases[i].vk ? "ok" : "FAIL");
        if (got != cases[i].vk) bad++;
    }
    // 压缩块表必须同步收 SRGB 项；真实上传走 nvn_fmt_bpb（带块宽高），不靠这张布尔表算尺寸。
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        if (cases[i].nvn < NVN_FORMAT_RGBA_ASTC_4x4 || cases[i].nvn > NVN_FORMAT_RGBA_ASTC_12x12_SRGB) continue;
        int got = nvn_vk_format_is_compressed(cases[i].vk);
        printf("compressed %-14s -> %d %s\n", cases[i].name, got, got == 1 ? "ok" : "FAIL");
        if (got != 1) bad++;
    }
    if (nvn_vk_format_is_compressed(VK_FORMAT_R8G8B8A8_UNORM) != 0) {
        printf("compressed RGBA8 -> 1 FAIL\n");
        bad++;
    }
    // 压缩块总字节必须按格式自己的块宽高算：非 4x4 ASTC 在修前一律按 4x4 会多算。
    struct { uint32_t nvn, w, h; unsigned long long want; const char *name; } blocks[] = {
        { NVN_FORMAT_RGBA_ASTC_4x4, 8, 8, 64, "ASTC4x4 8x8" },
        { NVN_FORMAT_RGBA_ASTC_5x5, 10, 10, 64, "ASTC5x5 10x10" },
        { NVN_FORMAT_RGBA_ASTC_5x5_SRGB, 10, 10, 64, "ASTC5x5_SRGB 10x10" },
        { NVN_FORMAT_RGBA_ASTC_8x8, 16, 16, 64, "ASTC8x8 16x16" },
        { NVN_FORMAT_RGBA_ASTC_8x8_SRGB, 16, 16, 64, "ASTC8x8_SRGB 16x16" },
        { NVN_FORMAT_RGBA_ASTC_12x12, 24, 24, 64, "ASTC12x12 24x24" },
        { NVN_FORMAT_RGBA_ASTC_12x12_SRGB, 24, 24, 64, "ASTC12x12_SRGB 24x24" },
        { NVN_FORMAT_RGBA_ASTC_5x5, 1, 1, 16, "ASTC5x5 1x1" },
        { NVN_FORMAT_RGBA_ASTC_8x8, 17, 9, 96, "ASTC8x8 17x9" },
        { NVN_FORMAT_BPTC_UNORM, 8, 8, 64, "BPTC 8x8" },
    };
    for (unsigned i = 0; i < sizeof blocks / sizeof blocks[0]; i++) {
        unsigned long long got = (unsigned long long)nvn_vk_format_compressed_image_bytes(
            blocks[i].nvn, blocks[i].w, blocks[i].h);
        printf("block-bytes %-18s %ux%u -> %llu (want %llu) %s\n", blocks[i].name,
               blocks[i].w, blocks[i].h, got, blocks[i].want, got == blocks[i].want ? "ok" : "FAIL");
        if (got != blocks[i].want) bad++;
    }
    if (nvn_vk_format_compressed_image_bytes(NVN_FORMAT_RGBA8, 8, 8) != 0) {
        printf("block-bytes RGBA8 (uncompressed) -> nonzero FAIL\n");
        bad++;
    }
    if (nvn_vk_format_compressed_image_bytes(0xDEADu, 8, 8) != 0) {
        printf("block-bytes unknown -> nonzero FAIL\n");
        bad++;
    }
    VkFormat unk = nvn_vk_format(0xDEADu);
    printf("unknown 0xDEAD -> %d (want %d) %s\n", (int)unk, (int)VK_FORMAT_UNDEFINED, unk == VK_FORMAT_UNDEFINED ? "ok" : "FAIL");
    if (unk != VK_FORMAT_UNDEFINED) bad++;
    // 同格式视图不是覆盖：Vulkan 只要求不同格式时同兼容类。Wonder 在 BC4 纹理上设同格式+swizzle 视图曾被误拒。
    char why[192] = "";
    VkFormat out = VK_FORMAT_UNDEFINED;
    int ok = nvn_vk_format_override_ok(VK_FORMAT_BC4_UNORM_BLOCK, NVN_FORMAT_RGTC1_UNORM, &out, why, sizeof why);
    printf("same-format BC4 view -> rc %d out %d %s\n", ok, (int)out, (ok == 0 && out == VK_FORMAT_BC4_UNORM_BLOCK) ? "ok" : "FAIL");
    if (ok != 0 || out != VK_FORMAT_BC4_UNORM_BLOCK) bad++;
    why[0] = 0; out = VK_FORMAT_UNDEFINED;
    ok = nvn_vk_format_override_ok(VK_FORMAT_BC4_UNORM_BLOCK, NVN_FORMAT_RGTC2_UNORM, &out, why, sizeof why);
    printf("cross-format BC4/BC5 view -> rc %d (%s) %s\n", ok, why, ok != 0 ? "ok" : "FAIL");
    if (ok == 0) bad++;
    // 解码后的 BC 纹理取「同 NVN 格式」视图：图像是解码后格式（BC4 → R8_UNORM），视图必须
    // 沿用图像格式；拿 BC4（139）去和 R8_UNORM（9）比兼容类会误拒。同一修法覆盖全部 compute
    // 解码族（BC1–BC7 的 UNORM/SNORM/SRGB）；ASTC 在本仓库没有 compute 软解路径（原生支持），
    // 但“同 NVN 格式视图恒合法”对压缩格式同样成立，一并钉住。
    struct { uint32_t nvn; VkFormat base; const char *name; } same_fmt[] = {
        { NVN_FORMAT_RGB_DXT1_SRGB, VK_FORMAT_R8G8B8A8_SRGB, "BC1 SRGB" },
        { NVN_FORMAT_RGBA_DXT5_SRGB, VK_FORMAT_R8G8B8A8_SRGB, "BC3 SRGB" },
        { NVN_FORMAT_RGTC1_UNORM, VK_FORMAT_R8_UNORM, "BC4 UNORM" },
        { NVN_FORMAT_RGTC1_SNORM, VK_FORMAT_R8_SNORM, "BC4 SNORM" },
        { NVN_FORMAT_RGTC2_UNORM, VK_FORMAT_R8G8_UNORM, "BC5 UNORM" },
        { NVN_FORMAT_RGTC2_SNORM, VK_FORMAT_R8G8_SNORM, "BC5 SNORM" },
        { NVN_FORMAT_BPTC_SFLOAT, VK_FORMAT_R16G16B16A16_SFLOAT, "BC6H SFLOAT" },
        { NVN_FORMAT_BPTC_UFLOAT, VK_FORMAT_R16G16B16A16_SFLOAT, "BC6H UFLOAT" },
        { NVN_FORMAT_BPTC_UNORM, VK_FORMAT_R8G8B8A8_UNORM, "BC7 UNORM" },
        { NVN_FORMAT_BPTC_UNORM_SRGB, VK_FORMAT_R8G8B8A8_SRGB, "BC7 SRGB" },
        { NVN_FORMAT_RGBA_ASTC_4x4, VK_FORMAT_ASTC_4x4_UNORM_BLOCK, "ASTC4x4" },
        { NVN_FORMAT_RGBA_ASTC_8x8_SRGB, VK_FORMAT_ASTC_8x8_SRGB_BLOCK, "ASTC8x8 SRGB" },
    };
    for (unsigned i = 0; i < sizeof same_fmt / sizeof same_fmt[0]; i++) {
        why[0] = 0; out = VK_FORMAT_UNDEFINED;
        int rc = nvn_vk_format_texview_ok(same_fmt[i].base, same_fmt[i].nvn, same_fmt[i].nvn,
                                          &out, why, sizeof why);
        printf("decoded same-NVN %-12s -> rc %d out %d %s\n", same_fmt[i].name, rc, (int)out,
               (rc == 0 && out == same_fmt[i].base) ? "ok" : "FAIL");
        if (rc != 0 || out != same_fmt[i].base) bad++;
    }
    // 异格式仍拒：同族不同存储格式（如 BC4 SNORM）、跨族压缩格式、不同块尺寸的 ASTC。
    struct { uint32_t nvn; VkFormat base; uint32_t view; const char *name; } cross_fmt[] = {
        { NVN_FORMAT_RGTC1_UNORM, VK_FORMAT_R8_UNORM, NVN_FORMAT_RGTC1_SNORM, "BC4 UNORM vs 0x4a" },
        { NVN_FORMAT_RGTC1_UNORM, VK_FORMAT_R8_UNORM, NVN_FORMAT_RGTC2_UNORM, "BC4 UNORM vs 0x4b" },
        { NVN_FORMAT_RGTC2_UNORM, VK_FORMAT_R8G8_UNORM, NVN_FORMAT_RGTC1_UNORM, "BC5 UNORM vs 0x49" },
        { NVN_FORMAT_BPTC_SFLOAT, VK_FORMAT_R16G16B16A16_SFLOAT, NVN_FORMAT_BPTC_UNORM, "BC6H vs 0x4d" },
        { NVN_FORMAT_BPTC_UNORM, VK_FORMAT_R8G8B8A8_UNORM, NVN_FORMAT_RGTC2_UNORM, "BC7 vs 0x4b" },
        { NVN_FORMAT_BPTC_UNORM_SRGB, VK_FORMAT_R8G8B8A8_SRGB, NVN_FORMAT_RGBA16F, "BC7 SRGB vs RGBA16F" },
        { NVN_FORMAT_RGBA_ASTC_4x4, VK_FORMAT_ASTC_4x4_UNORM_BLOCK, NVN_FORMAT_RGBA_ASTC_8x8, "ASTC4x4 vs 8x8" },
    };
    for (unsigned i = 0; i < sizeof cross_fmt / sizeof cross_fmt[0]; i++) {
        why[0] = 0; out = VK_FORMAT_UNDEFINED;
        int rc = nvn_vk_format_texview_ok(cross_fmt[i].base, cross_fmt[i].nvn, cross_fmt[i].view,
                                          &out, why, sizeof why);
        printf("decoded cross-NVN %-18s -> rc %d (%s) %s\n", cross_fmt[i].name, rc, why,
               rc != 0 ? "ok" : "FAIL");
        if (rc == 0) bad++;
    }
    // CPU 顶点解码（设备无顶点获取能力的格式 / 必须解码的格式 → float4）位级对拍。
    // sRGB 期望值 = 规范分段公式（(c+0.055)/1.055)^2.4 段；打包格式按 PACK16 位序（首名分量在最高位）。
    // src 是小端字节序；exp 是 NVN 顶点取数语义（缺失分量补 (0,0,0,1)，RGB5/BGR5 的 bit0 是填充位）。
    // 32 位 UI2F/I2F 期望 = C 整数→float 的 IEEE 就近舍入（2^24 以上向偶数取整），逐位核对。
    struct { uint32_t fmt; uint8_t src[16]; float exp[4]; int eb; const char *name; } dec[] = {
        { NVN_FORMAT_RGBA8_SRGB,  {0x00,0x80,0xFF,0x80}, {0.0f, 2.15860500e-01f, 1.0f, 128.0f*(1.0f/255.0f)}, 4, "RGBA8_SRGB" },
        { NVN_FORMAT_BGRA8_SRGB,  {0x80,0x00,0xFF,0x40}, {1.0f, 0.0f, 2.15860500e-01f, 64.0f*(1.0f/255.0f)}, 4, "BGRA8_SRGB" },
        { NVN_FORMAT_RGBX8_SRGB,  {0xFF,0x00,0x00,0x00}, {1.0f, 0.0f, 0.0f, 1.0f}, 4, "RGBX8_SRGB" },
        { NVN_FORMAT_BGRX8_SRGB,  {0x80,0x40,0xFF,0x00}, {1.0f, 5.12694584e-02f, 2.15860500e-01f, 1.0f}, 4, "BGRX8_SRGB" },
        { NVN_FORMAT_RGBA4,       {0xF0,0xF0,0,0},       {1.0f, 0.0f, 1.0f, 0.0f}, 2, "RGBA4" },
        { NVN_FORMAT_RGB5,        {0x00,0xF8,0,0},       {1.0f, 0.0f, 0.0f, 1.0f}, 2, "RGB5 padA" },
        { NVN_FORMAT_RGB5A1,      {0x01,0xF8,0,0},       {1.0f, 0.0f, 0.0f, 1.0f}, 2, "RGB5A1 A=1" },
        { NVN_FORMAT_RGB5A1,      {0x00,0xF8,0,0},       {1.0f, 0.0f, 0.0f, 0.0f}, 2, "RGB5A1 A=0" },
        { NVN_FORMAT_RGB565,      {0x00,0xF8,0,0},       {1.0f, 0.0f, 0.0f, 1.0f}, 2, "RGB565 R" },
        { NVN_FORMAT_RGB565,      {0xE0,0x07,0,0},       {0.0f, 1.0f, 0.0f, 1.0f}, 2, "RGB565 G" },
        { NVN_FORMAT_BGR565,      {0x1F,0x00,0,0},       {1.0f, 0.0f, 0.0f, 1.0f}, 2, "BGR565 R" },
        { NVN_FORMAT_BGR565,      {0x00,0xF8,0,0},       {0.0f, 0.0f, 1.0f, 1.0f}, 2, "BGR565 B" },
        { NVN_FORMAT_BGR5,        {0x00,0xF8,0,0},       {0.0f, 0.0f, 1.0f, 1.0f}, 2, "BGR5 padA" },
        { NVN_FORMAT_BGR5A1,      {0x01,0xF8,0,0},       {0.0f, 0.0f, 1.0f, 1.0f}, 2, "BGR5A1" },
        { NVN_FORMAT_A1BGR5,      {0xE0,0x83,0,0},       {0.0f, 1.0f, 0.0f, 1.0f}, 2, "A1BGR5" },
        { NVN_FORMAT_RGB9E5F,     {0x00,0x01,0x01,0x79}, {0.5f, 0.25f, 0.125f, 1.0f}, 4, "RGB9E5F" },
        // 32 位 UI2F/I2F：0 / 最大值 / 负数 / 2^24 以上精度边界，逐位对拍。
        { NVN_FORMAT_R32_UI2F,    {0,0,0,0},           {0.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_UI2F 0" },
        { NVN_FORMAT_R32_UI2F,    {0xC8,0,0,0},        {200.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_UI2F 200" },
        { NVN_FORMAT_R32_UI2F,    {0xFF,0xFF,0xFF,0xFF},{4294967296.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_UI2F max" },
        { NVN_FORMAT_R32_UI2F,    {0x01,0x00,0x00,0x01},{16777216.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_UI2F 2^24+1" },
        { NVN_FORMAT_R32_UI2F,    {0x03,0x00,0x00,0x01},{16777220.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_UI2F 2^24+3" },
        { NVN_FORMAT_R32_I2F,     {0xFF,0xFF,0xFF,0xFF},{-1.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_I2F -1" },
        { NVN_FORMAT_R32_I2F,     {0x00,0x00,0x00,0x80},{-2147483648.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_I2F min" },
        { NVN_FORMAT_R32_I2F,     {0x01,0x00,0x00,0x01},{16777216.0f, 0.0f, 0.0f, 1.0f}, 4, "R32_I2F 2^24+1" },
        { NVN_FORMAT_RG32_UI2F,   {0x01,0,0,0, 0xFF,0xFF,0xFF,0xFF},
                                  {1.0f, 4294967296.0f, 0.0f, 1.0f}, 8, "RG32_UI2F" },
        { NVN_FORMAT_RG32_I2F,    {0xFE,0xFF,0xFF,0xFF, 0xE8,0x03,0,0},
                                  {-2.0f, 1000.0f, 0.0f, 1.0f}, 8, "RG32_I2F" },
        { NVN_FORMAT_RGB32_UI2F,  {0x01,0x00,0x00,0x01, 0x07,0,0,0, 0x08,0,0,0},
                                  {16777216.0f, 7.0f, 8.0f, 1.0f}, 12, "RGB32_UI2F" },
        { NVN_FORMAT_RGB32_I2F,   {0xFF,0xFF,0xFF,0xFE, 0x00,0x00,0x00,0x80, 0x05,0,0,0},
                                  {-16777216.0f, -2147483648.0f, 5.0f, 1.0f}, 12, "RGB32_I2F" },
        { NVN_FORMAT_RGBA32_UI2F, {0,0,0,0, 0x01,0,0,0, 0xFF,0xFF,0xFF,0xFF, 0x03,0x00,0x00,0x01},
                                  {0.0f, 1.0f, 4294967296.0f, 16777220.0f}, 16, "RGBA32_UI2F" },
        { NVN_FORMAT_RGBA32_I2F,  {0xFF,0xFF,0xFF,0xFF, 0xFE,0xFF,0xFF,0xFF, 0xFD,0xFF,0xFF,0xFF, 0xFC,0xFF,0xFF,0xFF},
                                  {-1.0f, -2.0f, -3.0f, -4.0f}, 16, "RGBA32_I2F" },
    };
    for (unsigned i = 0; i < sizeof dec / sizeof dec[0]; i++) {
        float got[4] = {-1, -1, -1, -1};
        int eb = nvn_vattr_cpu_decode(dec[i].fmt, dec[i].src, got);
        int ok = eb == dec[i].eb;
        for (int c = 0; ok && c < 4; c++) {
            uint32_t gb, xb;
            memcpy(&gb, &got[c], 4); memcpy(&xb, &dec[i].exp[c], 4);
            if (gb != xb) ok = 0;   // 位级对拍：不允许任何舍入偏差
        }
        printf("vattr-decode %-18s -> eb %d {%g,%g,%g,%g} %s\n", dec[i].name, eb,
               got[0], got[1], got[2], got[3], ok ? "ok" : "FAIL");
        if (!ok) bad++;
    }
    // must_cpu_decode：32 位 UI2F/I2F 8 项必须解码（无原生等价物），且每项都有解码实现；
    // 其余格式（含 8/16 位 UI2F/I2F——原生 USCALED/SSCALED 已换算）不得标成必须解码。
    {
        uint32_t must[] = { NVN_FORMAT_R32_UI2F, NVN_FORMAT_R32_I2F,
                            NVN_FORMAT_RG32_UI2F, NVN_FORMAT_RG32_I2F,
                            NVN_FORMAT_RGB32_UI2F, NVN_FORMAT_RGB32_I2F,
                            NVN_FORMAT_RGBA32_UI2F, NVN_FORMAT_RGBA32_I2F };
        uint32_t native[] = { NVN_FORMAT_R8_UI2F, NVN_FORMAT_R8_I2F,
                              NVN_FORMAT_RGBA16_UI2F, NVN_FORMAT_RGBA16_I2F,
                              NVN_FORMAT_RGB10A2_UI2F, NVN_FORMAT_RGB10A2_I2F,
                              NVN_FORMAT_RGBA8, NVN_FORMAT_RGBA8_SRGB,
                              NVN_FORMAT_RGB565, NVN_FORMAT_BGRA8, NVN_FORMAT_RGB9E5F, 0xDEAD };
        for (unsigned i = 0; i < sizeof must / sizeof must[0]; i++) {
            float got[4];
            int eb = nvn_vattr_cpu_decode(must[i], (const uint8_t *)"\x01\x02\x03\x04\x05\x06\x07\x08"
                                          "\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10", got);
            int ok = nvn_vattr_must_cpu_decode(must[i]) == 1 && eb > 0;
            printf("must-decode 0x%02x -> flag %d eb %d %s\n", must[i],
                   nvn_vattr_must_cpu_decode(must[i]), eb, ok ? "ok" : "FAIL");
            if (!ok) bad++;
        }
        for (unsigned i = 0; i < sizeof native / sizeof native[0]; i++) {
            if (nvn_vattr_must_cpu_decode(native[i]) != 0) {
                printf("must-decode 0x%02x -> 1 FAIL\n", native[i]);
                bad++;
            }
        }
    }
    // 不解码的格式返回 0：调用方按“不支持”明确报红（不猜、不兜底）。
    {
        float got[4] = {9, 9, 9, 9};
        uint32_t no_dec[] = { NVN_FORMAT_RGBA8, NVN_FORMAT_BGRA8, NVN_FORMAT_RGB_DXT1, NVN_FORMAT_DEPTH16, 0xFF };
        for (unsigned i = 0; i < sizeof no_dec / sizeof no_dec[0]; i++) {
            int eb = nvn_vattr_cpu_decode(no_dec[i], (const uint8_t *)"\x01\x02\x03\x04", got);
            if (eb != 0) { printf("vattr-decode 0x%x -> eb %d FAIL\n", no_dec[i], eb); bad++; }
        }
    }
    printf("nvn-vk-format: %s (%d failures)\n", bad ? "FAIL" : "ok", bad);
    return bad ? 1 : 0;
}
