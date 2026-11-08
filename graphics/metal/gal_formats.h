// GAL Format 枚举（Ryujinx.Graphics.GAL.Format 的声明顺序，C 端共用；改动以 Format.cs 为准，条数不符编译即报错）
#pragma once
enum {
    F_R8Unorm, F_R8Snorm, F_R8Uint, F_R8Sint, F_R16Float, F_R16Unorm, F_R16Snorm, F_R16Uint, F_R16Sint, F_R32Float, F_R32Uint, F_R32Sint,
    F_R8G8Unorm, F_R8G8Snorm, F_R8G8Uint, F_R8G8Sint, F_R16G16Float, F_R16G16Unorm, F_R16G16Snorm, F_R16G16Uint, F_R16G16Sint,
    F_R32G32Float, F_R32G32Uint, F_R32G32Sint, F_R8G8B8Unorm, F_R8G8B8Snorm, F_R8G8B8Uint, F_R8G8B8Sint,
    F_R16G16B16Float, F_R16G16B16Unorm, F_R16G16B16Snorm, F_R16G16B16Uint, F_R16G16B16Sint, F_R32G32B32Float, F_R32G32B32Uint, F_R32G32B32Sint,
    F_R8G8B8A8Unorm, F_R8G8B8A8Snorm, F_R8G8B8A8Uint, F_R8G8B8A8Sint, F_R16G16B16A16Float, F_R16G16B16A16Unorm, F_R16G16B16A16Snorm,
    F_R16G16B16A16Uint, F_R16G16B16A16Sint, F_R32G32B32A32Float, F_R32G32B32A32Uint, F_R32G32B32A32Sint,
    F_S8Uint, F_D16Unorm, F_S8UintD24Unorm, F_D32Float, F_D24UnormS8Uint, F_D32FloatS8Uint, F_R8G8B8A8Srgb,
    F_R4G4Unorm, F_R4G4B4A4Unorm, F_R5G5B5X1Unorm, F_R5G5B5A1Unorm, F_R5G6B5Unorm, F_R10G10B10A2Unorm, F_R10G10B10A2Uint, F_R11G11B10Float, F_R9G9B9E5Float,
    F_Bc1RgbaUnorm, F_Bc2Unorm, F_Bc3Unorm, F_Bc1RgbaSrgb, F_Bc2Srgb, F_Bc3Srgb, F_Bc4Unorm, F_Bc4Snorm, F_Bc5Unorm, F_Bc5Snorm,
    F_Bc7Unorm, F_Bc7Srgb, F_Bc6HSfloat, F_Bc6HUfloat,
    F_Etc2RgbUnorm, F_Etc2RgbaUnorm, F_Etc2RgbPtaUnorm, F_Etc2RgbSrgb, F_Etc2RgbaSrgb, F_Etc2RgbPtaSrgb,
    F_R8Uscaled, F_R8Sscaled, F_R16Uscaled, F_R16Sscaled, F_R32Uscaled, F_R32Sscaled, F_R8G8Uscaled, F_R8G8Sscaled, F_R16G16Uscaled, F_R16G16Sscaled,
    F_R32G32Uscaled, F_R32G32Sscaled, F_R8G8B8Uscaled, F_R8G8B8Sscaled, F_R16G16B16Uscaled, F_R16G16B16Sscaled, F_R32G32B32Uscaled, F_R32G32B32Sscaled,
    F_R8G8B8A8Uscaled, F_R8G8B8A8Sscaled, F_R16G16B16A16Uscaled, F_R16G16B16A16Sscaled, F_R32G32B32A32Uscaled, F_R32G32B32A32Sscaled,
    F_R10G10B10A2Snorm, F_R10G10B10A2Sint, F_R10G10B10A2Uscaled, F_R10G10B10A2Sscaled,
    F_Astc4x4Unorm, F_Astc5x4Unorm, F_Astc5x5Unorm, F_Astc6x5Unorm, F_Astc6x6Unorm, F_Astc8x5Unorm, F_Astc8x6Unorm, F_Astc8x8Unorm,
    F_Astc10x5Unorm, F_Astc10x6Unorm, F_Astc10x8Unorm, F_Astc10x10Unorm, F_Astc12x10Unorm, F_Astc12x12Unorm,
    F_Astc4x4Srgb, F_Astc5x4Srgb, F_Astc5x5Srgb, F_Astc6x5Srgb, F_Astc6x6Srgb, F_Astc8x5Srgb, F_Astc8x6Srgb, F_Astc8x8Srgb,
    F_Astc10x5Srgb, F_Astc10x6Srgb, F_Astc10x8Srgb, F_Astc10x10Srgb, F_Astc12x10Srgb, F_Astc12x12Srgb,
    F_B5G6R5Unorm, F_B5G5R5A1Unorm, F_A1B5G5R5Unorm, F_B8G8R8A8Unorm, F_B8G8R8A8Srgb, F_B10G10R10A2Unorm, F_X8UintD24Unorm, F_A8B8G8R8Uint,
    F_COUNT
};
_Static_assert(F_COUNT == 148, "GAL Format 枚举条数变了：按 Ryujinx.Graphics.GAL/Format.cs 重排本表");
