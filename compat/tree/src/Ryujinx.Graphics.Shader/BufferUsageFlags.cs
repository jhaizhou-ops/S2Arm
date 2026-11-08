using System;

namespace Ryujinx.Graphics.Shader
{
    /// <summary>
    /// Flags that indicate how a buffer will be used in a shader.
    /// </summary>
    [Flags]
    public enum BufferUsageFlags : byte
    {
        None = 0,

        /// <summary>
        /// Buffer is written to.
        /// </summary>
        Write = 1 << 0,

        /// <summary>
        /// S2A（F1）：不是客体存储缓冲，而是越界记录缓冲（<see cref="S2AStorageOobRecord"/>）。
        /// 不读 SbDescriptor、不按客体槽位绑定；由渲染器按程序绑定，资源用法不计入着色器写（不产生缓冲写屏障）。
        /// </summary>
        S2AOobRecord = 1 << 1,
    }
}
