namespace Ryujinx.Graphics.Shader
{
    public readonly struct BufferDescriptor
    {
        // New fields should be added to the end of the struct to keep disk shader cache compatibility.

        public readonly int Set;
        public readonly int Binding;
        public readonly byte Slot;
        public readonly byte SbCbSlot;
        public readonly ushort SbCbOffset;
        public readonly BufferUsageFlags Flags;
        // S2A：结尾 3 字节对齐填充写成显式字段（恒 0），理由同 TextureDescriptor._pad0。布局、大小（16）与读取不变
#pragma warning disable CS0169 // 只占位、不读
        private readonly byte _pad0, _pad1, _pad2;
#pragma warning restore CS0169

        public BufferDescriptor(int set, int binding, int slot)
        {
            Set = set;
            Binding = binding;
            Slot = (byte)slot;
            SbCbSlot = 0;
            SbCbOffset = 0;
            Flags = BufferUsageFlags.None;
        }

        public BufferDescriptor(int set, int binding, int slot, int sbCbSlot, int sbCbOffset, BufferUsageFlags flags)
        {
            Set = set;
            Binding = binding;
            Slot = (byte)slot;
            SbCbSlot = (byte)sbCbSlot;
            SbCbOffset = (ushort)sbCbOffset;
            Flags = flags;
        }
    }
}
