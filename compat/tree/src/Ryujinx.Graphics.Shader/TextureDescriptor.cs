namespace Ryujinx.Graphics.Shader
{
    public readonly struct TextureDescriptor
    {
        // New fields should be added to the end of the struct to keep disk shader cache compatibility.

        public readonly int Set;
        public readonly int Binding;

        public readonly SamplerType Type;
        public readonly TextureFormat Format;

        public readonly int CbufSlot;
        public readonly int HandleIndex;
        public readonly int ArrayLength;

        public readonly bool Separate;
        // S2A：Separate 后的 3 字节对齐填充写成显式字段（恒 0）。盘缓存按原始内存写本结构（DiskCacheHostStorage.WriteShaderProgramInfo → WriteWithMagicAndSize），
        //   隐式填充是复制时留下的栈上残留：同一份翻译两次写出的缓存字节不同（10-24 马车8 翻译缓存相邻两份，宿主程序二进制只差这 3 字节），
        //   着色器包产出指纹（graphics/tools/shbake/out_fp.py）因此对不上。布局、大小（36）与读取不变
#pragma warning disable CS0169 // 只占位、不读
        private readonly byte _pad0, _pad1, _pad2;
#pragma warning restore CS0169

        public readonly TextureUsageFlags Flags;

        public TextureDescriptor(
            int set,
            int binding,
            SamplerType type,
            TextureFormat format,
            int cbufSlot,
            int handleIndex,
            int arrayLength,
            bool separate,
            TextureUsageFlags flags)
        {
            Set = set;
            Binding = binding;
            Type = type;
            Format = format;
            CbufSlot = cbufSlot;
            HandleIndex = handleIndex;
            ArrayLength = arrayLength;
            Separate = separate;
            Flags = flags;
        }
    }
}
