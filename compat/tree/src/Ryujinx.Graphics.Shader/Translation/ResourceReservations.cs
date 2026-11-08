using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using System.Collections.Generic;
using System.Numerics;

namespace Ryujinx.Graphics.Shader.Translation
{
    public class ResourceReservations
    {
        public const int TfeBuffersCount = 4;

        public const int MaxVertexBufferTextures = 32;

        private const int TextureSetIndex = 2; // TODO: Get from GPU accessor.

        public int VertexInfoConstantBufferBinding { get; }
        public int VertexOutputStorageBufferBinding { get; }
        public int GeometryVertexOutputStorageBufferBinding { get; }
        public int GeometryIndexOutputStorageBufferBinding { get; }
        public int IndexBufferTextureBinding { get; }
        public int TopologyRemapBufferTextureBinding { get; }

        public int ReservedConstantBuffers { get; }
        public int ReservedStorageBuffers { get; }
        public int ReservedTextures { get; }
        public int ReservedImages { get; }
        public bool GeometryInputFixed { get; }
        public int InputSizePerInvocation { get; }
        public int OutputSizePerInvocation { get; }
        public int OutputSizeInBytesPerInvocation => OutputSizePerInvocation * sizeof(uint);

        private readonly int _tfeBufferSbBaseBinding;
        private readonly int _vertexBufferTextureBaseBinding;

        private readonly Dictionary<IoDefinition, int> _offsets;
        internal IReadOnlyDictionary<IoDefinition, int> Offsets => _offsets;

        internal ResourceReservations(bool isTransformFeedbackEmulated, bool vertexAsCompute)
        {
            // All stages reserves the first constant buffer binding for the support buffer.
            ReservedConstantBuffers = 1;
            ReservedStorageBuffers = 0;
            ReservedTextures = 0;
            ReservedImages = 0;

            if (isTransformFeedbackEmulated)
            {
                // Transform feedback emulation currently always uses 4 storage buffers.
                _tfeBufferSbBaseBinding = ReservedStorageBuffers;
                ReservedStorageBuffers = TfeBuffersCount;
            }

            if (vertexAsCompute)
            {
                // One constant buffer reserved for vertex related state.
                VertexInfoConstantBufferBinding = ReservedConstantBuffers++;

                // One storage buffer for the output vertex data.
                VertexOutputStorageBufferBinding = ReservedStorageBuffers++;

                // One storage buffer for the output geometry vertex data.
                GeometryVertexOutputStorageBufferBinding = ReservedStorageBuffers++;

                // One storage buffer for the output geometry index data.
                GeometryIndexOutputStorageBufferBinding = ReservedStorageBuffers++;

                // Enough textures reserved for all vertex attributes, plus the index buffer.
                IndexBufferTextureBinding = ReservedTextures;
                TopologyRemapBufferTextureBinding = ReservedTextures + 1;
                _vertexBufferTextureBaseBinding = ReservedTextures + 2;
                ReservedTextures += 2 + MaxVertexBufferTextures;
            }
        }

        internal ResourceReservations(
            IGpuAccessor gpuAccessor,
            bool isTransformFeedbackEmulated,
            bool vertexAsCompute,
            IoUsage? vacInput,
            IoUsage vacOutput) : this(
                isTransformFeedbackEmulated,
                vertexAsCompute,
                vacInput,
                vacOutput,
                gpuAccessor.QueryHostSupportsViewportIndexVertexTessellation(),
                gpuAccessor.QueryHostSupportsViewportMask(),
                vertexAsCompute && gpuAccessor.QueryGeometryInputFixed())
        {
        }

        // S2A：构造输入只有这几项（宿主能力两项取值、而非整个 IGpuAccessor），记下来供转计算程序进磁盘缓存后按同一输入重建（S2AWrite / S2ARead）
        private ResourceReservations(
            bool isTransformFeedbackEmulated,
            bool vertexAsCompute,
            IoUsage? vacInput,
            IoUsage vacOutput,
            bool hostViewportIndexVt,
            bool hostViewportMask,
            bool geometryInputFixed = false) : this(isTransformFeedbackEmulated, vertexAsCompute)
        {
            _s2aTfe = isTransformFeedbackEmulated;
            _s2aInput = vacInput;
            _s2aOutput = vacOutput;
            _s2aVpIndex = hostViewportIndexVt;
            _s2aVpMask = hostViewportMask;

            if (vertexAsCompute)
            {
                _offsets = new();
                GeometryInputFixed = geometryInputFixed;

                if (vacInput.HasValue)
                {
                    InputSizePerInvocation = geometryInputFixed ? FillGeometryInputMap() : FillIoOffsetMap(hostViewportIndexVt, hostViewportMask, StorageKind.Input, vacInput.Value);
                }

                OutputSizePerInvocation = FillIoOffsetMap(hostViewportIndexVt, hostViewportMask, StorageKind.Output, vacOutput);
            }
        }

        private readonly bool _s2aTfe;
        private readonly IoUsage? _s2aInput;
        private readonly IoUsage _s2aOutput;
        private readonly bool _s2aVpIndex;
        private readonly bool _s2aVpMask;

        /// <summary>S2A：S2AWrite 写出的字节数（版本 1）。</summary>
        public const int S2ASerializedSize = 20;

        /// <summary>
        /// S2A：转计算（顶点 / 几何当计算着色器跑）的保留布局序列化，进 Ryujinx 磁盘缓存，加载时 S2ARead 按同一构造输入重建（偏移表与运行时翻译时算的同一份）。
        /// 布局（小端）：u8 版本 1、u8 标志（位 0 变换反馈模拟、位 1 有输入用法、位 2 宿主顶点阶段写视口号、位 3 宿主视口掩码）、u8 输入裁剪距离位、u8 输出裁剪距离位、
        /// u32 输入特性位、i32 输入自定义位置位、u32 输出特性位、i32 输出自定义位置位。
        /// </summary>
        public void S2AWrite(System.Span<byte> o)
        {
            o[..S2ASerializedSize].Clear();
            o[0] = 1;
            o[1] = (byte)((_s2aTfe ? 1 : 0) | (_s2aInput.HasValue ? 2 : 0) | (_s2aVpIndex ? 4 : 0) | (_s2aVpMask ? 8 : 0));
            IoUsage i = _s2aInput ?? default;
            o[2] = i.ClipDistancesWritten;
            o[3] = _s2aOutput.ClipDistancesWritten;
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(o[4..], (uint)i.S2AUsedFeatures);
            System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(o[8..], i.UserDefinedMap);
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(o[12..], (uint)_s2aOutput.S2AUsedFeatures);
            System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(o[16..], _s2aOutput.UserDefinedMap);
        }

        /// <summary>S2A：按 S2AWrite 的字节重建转计算保留布局；版本 / 长度不符返回 null。</summary>
        public static ResourceReservations S2ARead(System.ReadOnlySpan<byte> b)
        {
            if (b.Length < S2ASerializedSize || b[0] != 1)
            {
                return null;
            }

            int f = b[1];
            IoUsage? input = (f & 2) != 0
                ? new IoUsage((FeatureFlags)System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(b[4..]), b[2], System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(b[8..]))
                : null;
            IoUsage output = new((FeatureFlags)System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(b[12..]), b[3], System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(b[16..]));

            return new ResourceReservations((f & 1) != 0, vertexAsCompute: true, input, output, (f & 4) != 0, (f & 8) != 0);
        }

        // S2A（直连离线几何，原 graphics/nvn/third_party/ryujinx 的改动）：几何输入按 Maxwell 属性表的固定布局排，与 dmsh_geometry.py 一致，独立出库的各阶段靠它对上。
        //   只有直连翻译器的 IGpuAccessor 答 QueryGeometryInputFixed 为真；通用模式恒为假，磁盘缓存重建（S2ARead）也走假，不进序列化
        private int FillGeometryInputMap()
        {
            for (int c = 0; c < 4; c++) _offsets.Add(new(StorageKind.Input, IoVariable.Position, 0, c), c);
            _offsets.Add(new(StorageKind.Input, IoVariable.PointSize), 4);
            for (int c = 0; c < 8; c++) _offsets.Add(new(StorageKind.Input, IoVariable.ClipDistance, 0, c), 5 + c);
            _offsets.Add(new(StorageKind.Input, IoVariable.Layer), 13);
            _offsets.Add(new(StorageKind.Input, IoVariable.ViewportIndex), 14);
            for (int a = 0; a < 32; a++) for (int c = 0; c < 4; c++)
                _offsets.Add(new(StorageKind.Input, IoVariable.UserDefined, a, c), 16 + 4 * a + c);
            return 144;
        }

        private int FillIoOffsetMap(bool hostViewportIndexVt, bool hostViewportMask, StorageKind storageKind, IoUsage vacUsage)
        {
            int offset = 0;

            for (int c = 0; c < 4; c++)
            {
                _offsets.Add(new IoDefinition(storageKind, IoVariable.Position, 0, c), offset++);
            }

            _offsets.Add(new IoDefinition(storageKind, IoVariable.PointSize), offset++);

            int clipDistancesWrittenMap = vacUsage.ClipDistancesWritten;

            while (clipDistancesWrittenMap != 0)
            {
                int index = BitOperations.TrailingZeroCount(clipDistancesWrittenMap);

                _offsets.Add(new IoDefinition(storageKind, IoVariable.ClipDistance, 0, index), offset++);

                clipDistancesWrittenMap &= ~(1 << index);
            }

            if (vacUsage.UsesRtLayer)
            {
                _offsets.Add(new IoDefinition(storageKind, IoVariable.Layer), offset++);
            }

            if (vacUsage.UsesViewportIndex && hostViewportIndexVt)
            {
                _offsets.Add(new IoDefinition(storageKind, IoVariable.VertexIndex), offset++);
            }

            if (vacUsage.UsesViewportMask && hostViewportMask)
            {
                _offsets.Add(new IoDefinition(storageKind, IoVariable.ViewportMask), offset++);
            }

            int usedDefinedMap = vacUsage.UserDefinedMap;

            while (usedDefinedMap != 0)
            {
                int location = BitOperations.TrailingZeroCount(usedDefinedMap);

                for (int c = 0; c < 4; c++)
                {
                    _offsets.Add(new IoDefinition(storageKind, IoVariable.UserDefined, location, c), offset++);
                }

                usedDefinedMap &= ~(1 << location);
            }

            return offset;
        }

        internal static bool IsVectorOrArrayVariable(IoVariable variable)
        {
            return variable switch
            {
                IoVariable.ClipDistance or
                IoVariable.Position => true,
                _ => false,
            };
        }

        public int GetTfeBufferStorageBufferBinding(int bufferIndex)
        {
            return _tfeBufferSbBaseBinding + bufferIndex;
        }

        public int GetVertexBufferTextureBinding(int vaLocation)
        {
            return _vertexBufferTextureBaseBinding + vaLocation;
        }

        public SetBindingPair GetVertexBufferTextureSetAndBinding(int vaLocation)
        {
            return new SetBindingPair(TextureSetIndex, GetVertexBufferTextureBinding(vaLocation));
        }

        public SetBindingPair GetIndexBufferTextureSetAndBinding()
        {
            return new SetBindingPair(TextureSetIndex, IndexBufferTextureBinding);
        }

        public SetBindingPair GetTopologyRemapBufferTextureSetAndBinding()
        {
            return new SetBindingPair(TextureSetIndex, TopologyRemapBufferTextureBinding);
        }

        internal bool TryGetOffset(StorageKind storageKind, int location, int component, out int offset)
        {
            return _offsets.TryGetValue(new IoDefinition(storageKind, IoVariable.UserDefined, location, component), out offset);
        }

        internal bool TryGetOffset(StorageKind storageKind, IoVariable ioVariable, int location, int component, out int offset)
        {
            return _offsets.TryGetValue(new IoDefinition(storageKind, ioVariable, location, component), out offset);
        }

        internal bool TryGetOffset(StorageKind storageKind, IoVariable ioVariable, int component, out int offset)
        {
            return _offsets.TryGetValue(new IoDefinition(storageKind, ioVariable, 0, component), out offset);
        }

        internal bool TryGetOffset(StorageKind storageKind, IoVariable ioVariable, out int offset)
        {
            return _offsets.TryGetValue(new IoDefinition(storageKind, ioVariable, 0, 0), out offset);
        }
    }
}
