using System;

namespace Ryujinx.Graphics.Shader
{
    /// <summary>
    /// Flags that indicate how a texture will be used in a shader.
    /// </summary>
    [Flags]
    public enum TextureUsageFlags
    {
        None = 0,

        // Integer sampled textures must be noted for resolution scaling.
        ResScaleUnsupported = 1 << 0,
        NeedsScaleValue = 1 << 1,
        ImageStore = 1 << 2,
        ImageCoherent = 1 << 3,

        // S2A：被原子指令使用的图像。原子经 OpImageTexelPointer 访问，Vulkan 要求
        // Image Format 为 R64i/R64ui/R32f/R32i/R32ui（VUID-04658），不得声明成 Unknown。
        ImageAtomic = 1 << 4,
    }
}
