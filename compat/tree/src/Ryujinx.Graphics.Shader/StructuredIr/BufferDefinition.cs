namespace Ryujinx.Graphics.Shader.StructuredIr
{
    readonly struct BufferDefinition
    {
        public BufferLayout Layout { get; }
        public int Set { get; }
        public int Binding { get; }
        public string Name { get; }
        public StructureType Type { get; }
        public BufferUsageFlags Flags { get; }

        public BufferDefinition(BufferLayout layout, int set, int binding, string name, StructureType type,
            BufferUsageFlags flags = BufferUsageFlags.Write)
        {
            Layout = layout;
            Set = set;
            Binding = binding;
            Name = name;
            Type = type;
            Flags = flags;
        }

        public BufferDefinition WithFlags(BufferUsageFlags flags) => new(Layout, Set, Binding, Name, Type, flags);
    }
}
