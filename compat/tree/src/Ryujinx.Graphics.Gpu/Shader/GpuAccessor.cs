using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Runtime.InteropServices;
using TextureDescriptor = Ryujinx.Graphics.Gpu.Image.TextureDescriptor;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// Represents a GPU state and memory accessor.
    /// </summary>
    class GpuAccessor : GpuAccessorBase, IGpuAccessor
    {
        private readonly GpuChannel _channel;
        private readonly GpuAccessorState _state;
        private readonly int _stageIndex;
        private readonly bool _compute;
        private readonly bool _isVulkan;
        private readonly bool _hasGeometryShader;
        private readonly bool _supportsQuads;

        /// <summary>
        /// Creates a new instance of the GPU state accessor for graphics shader translation.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="channel">GPU channel</param>
        /// <param name="state">Current GPU state</param>
        /// <param name="stageIndex">Graphics shader stage index (0 = Vertex, 4 = Fragment)</param>
        /// <param name="hasGeometryShader">Indicates if a geometry shader is present</param>
        public GpuAccessor(
            GpuContext context,
            GpuChannel channel,
            GpuAccessorState state,
            int stageIndex,
            bool hasGeometryShader) : base(context, state.ResourceCounts, stageIndex)
        {
            _channel = channel;
            _state = state;
            _stageIndex = stageIndex;
            _isVulkan = TranslationCapabilities.Api == TargetApi.Vulkan;
            _hasGeometryShader = hasGeometryShader;
            _supportsQuads = TranslationCapabilities.SupportsQuads;

            if (stageIndex == (int)ShaderStage.Geometry - 1)
            {
                // Only geometry shaders require the primitive topology.
                _state.SpecializationState.RecordPrimitiveTopology();
            }
        }

        /// <summary>
        /// Creates a new instance of the GPU state accessor for compute shader translation.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="channel">GPU channel</param>
        /// <param name="state">Current GPU state</param>
        public GpuAccessor(GpuContext context, GpuChannel channel, GpuAccessorState state) : base(context, state.ResourceCounts, 0)
        {
            _channel = channel;
            _state = state;
            _compute = true;
        }

        /// <inheritdoc/>
        public uint ConstantBuffer1Read(int offset)
        {
            ulong baseAddress = _compute
                ? _channel.BufferManager.GetComputeUniformBufferAddress(1)
                : _channel.BufferManager.GetGraphicsUniformBufferAddress(_stageIndex, 1);

            return _channel.MemoryManager.Physical.Read<uint>(baseAddress + (ulong)offset);
        }

        /// <inheritdoc/>
        public void Log(string message)
        {
            Logger.Warning?.Print(LogClass.Gpu, $"Shader translator: {message}");
        }

        // S2A：着色器取码安全阀。着色器地址落在未映射处，或一直解不到 EXIT 时，原版会把读到的全零当指令一直解下去
        // （旧库实测 2 分钟吃到 67 GB）。未映射或一个阶段取码超过 S2AMaxShaderCodePages 页（1 MB）即抛异常报红。
        private const int S2AMaxShaderCodePages = 256;
        private System.Collections.Generic.HashSet<ulong> _s2aCodePages;

        /// <summary>S2A：取码失败负缓存（#723 P1）的页集探针，解码前由 ShaderCache 挂上；GetCode 每碰一页记一笔。</summary>
        internal S2AFaultProbe S2AProbe;

        /// <summary>S2A（着色器防线红行现场）：各阶段取码读到的最远地址（不含），ShaderCache 解码前挂上、按阶段切槽；为空不记。</summary>
        internal ulong[] S2AFetchEnd;
        internal int S2AFetchSlot;

        /// <inheritdoc/>
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize)
        {
            // S2A：本页先记进页集（未映射的也记：负缓存要按它判失效），再读。
            ulong page = address & ~Ryujinx.Graphics.Gpu.Memory.MemoryManager.PageMask;

            _s2aCodePages ??= new System.Collections.Generic.HashSet<ulong>();
            if (_s2aCodePages.Add(page) && _s2aCodePages.Count > S2AMaxShaderCodePages)
            {
                throw new InvalidOperationException($"S2A: shader code fetch exceeded {S2AMaxShaderCodePages} pages (at GPU VA 0x{address:X})");
            }

            int size = Math.Max(minimumSize, 0x1000 - (int)(address & 0xfff));

            S2AProbe?.Note(address, size);   // 这次读到的字节区间（负缓存只比这些字节的内容）
            if (S2AFetchEnd != null) S2AFetchEnd[S2AFetchSlot] = Math.Max(S2AFetchEnd[S2AFetchSlot], address + (ulong)size);

            if (!_channel.MemoryManager.IsMapped(address))
            {
                throw new InvalidOperationException($"S2A: shader code fetch from unmapped GPU VA 0x{address:X}");
            }

            return MemoryMarshal.Cast<byte, ulong>(_channel.MemoryManager.GetSpan(address, size));
        }

        public void S2AReportStateUse(uint readFlags, uint attrReadMask) => _state.SpecializationState?.S2ARecordUsage(readFlags, attrReadMask);   // S2A

        /// <inheritdoc/>
        public int QueryComputeLocalSizeX() => _state.ComputeState.LocalSizeX;

        /// <inheritdoc/>
        public int QueryComputeLocalSizeY() => _state.ComputeState.LocalSizeY;

        /// <inheritdoc/>
        public int QueryComputeLocalSizeZ() => _state.ComputeState.LocalSizeZ;

        /// <inheritdoc/>
        public int QueryComputeLocalMemorySize() => _state.ComputeState.LocalMemorySize;

        /// <inheritdoc/>
        public int QueryComputeSharedMemorySize() => _state.ComputeState.SharedMemorySize;

        /// <inheritdoc/>
        public uint QueryConstantBufferUse()
        {
            uint useMask = _compute
                ? _channel.BufferManager.GetComputeUniformBufferUseMask()
                : _channel.BufferManager.GetGraphicsUniformBufferUseMask(_stageIndex);

            _state.SpecializationState?.RecordConstantBufferUse(_stageIndex, useMask);
            return useMask;
        }

        /// <inheritdoc/>
        public GpuGraphicsState QueryGraphicsState()
        {
            return _state.GraphicsState.CreateShaderGraphicsState(
                !_isVulkan,
                _supportsQuads,
                _hasGeometryShader,
                _isVulkan || _state.GraphicsState.YNegateEnabled);
        }

        /// <inheritdoc/>
        public bool QueryHasConstantBufferDrawParameters()
        {
            _state.SpecializationState?.S2ARecordUsage(S2AStateRead.Cbdp, 0);   // S2A：读了才进匹配
            return _state.GraphicsState.HasConstantBufferDrawParameters;
        }

        /// <inheritdoc/>
        public bool QueryHasUnalignedStorageBuffer()
        {
            return _state.GraphicsState.HasUnalignedStorageBuffer || _state.ComputeState.HasUnalignedStorageBuffer;
        }

        /// <inheritdoc/>
        public int QuerySamplerArrayLengthFromPool()
        {
            int length = _state.SamplerPoolMaximumId + 1;
            _state.SpecializationState?.RegisterTextureArrayLengthFromPool(isSampler: true, length);

            return length;
        }

        /// <inheritdoc/>
        public SamplerType QuerySamplerType(int handle, int cbufSlot)
        {
            _state.SpecializationState?.RecordTextureSamplerType(_stageIndex, handle, cbufSlot);
            return GetTextureDescriptor(handle, cbufSlot).UnpackTextureTarget().ConvertSamplerType();
        }

        /// <inheritdoc/>
        public bool QueryTextureIsBuffer(int handle, int cbufSlot)
        {
            _state.SpecializationState?.S2ARecordTextureIsBuffer(_stageIndex, handle, cbufSlot);
            return GetTextureDescriptor(handle, cbufSlot).UnpackTextureTarget() == TextureTarget.TextureBuffer;
        }

        /// <inheritdoc/>
        public int QueryTextureArrayLengthFromBuffer(int slot)
        {
            int size = _compute
                ? _channel.BufferManager.GetComputeUniformBufferSize(slot)
                : _channel.BufferManager.GetGraphicsUniformBufferSize(_stageIndex, slot);

            int arrayLength = size / Constants.TextureHandleSizeInBytes;

            _state.SpecializationState?.RegisterTextureArrayLengthFromBuffer(_stageIndex, 0, slot, arrayLength);

            return arrayLength;
        }

        /// <inheritdoc/>
        public int QueryTextureArrayLengthFromPool()
        {
            int length = _state.PoolState.TexturePoolMaximumId + 1;
            _state.SpecializationState?.RegisterTextureArrayLengthFromPool(isSampler: false, length);

            return length;
        }

        //// <inheritdoc/>
        public TextureFormat QueryTextureFormat(int handle, int cbufSlot)
        {
            _state.SpecializationState?.RecordTextureFormat(_stageIndex, handle, cbufSlot);
            TextureDescriptor descriptor = GetTextureDescriptor(handle, cbufSlot);
            return ConvertToTextureFormat(descriptor.UnpackFormat(), descriptor.UnpackSrgb());
        }

        /// <inheritdoc/>
        public bool QueryTextureCoordNormalized(int handle, int cbufSlot)
        {
            _state.SpecializationState?.RecordTextureCoordNormalized(_stageIndex, handle, cbufSlot);
            return GetTextureDescriptor(handle, cbufSlot).UnpackTextureCoordNormalized();
        }

        /// <summary>
        /// Gets the texture descriptor for a given texture on the pool.
        /// </summary>
        /// <param name="handle">Index of the texture (this is the word offset of the handle in the constant buffer)</param>
        /// <param name="cbufSlot">Constant buffer slot for the texture handle</param>
        /// <returns>Texture descriptor</returns>
        private Image.TextureDescriptor GetTextureDescriptor(int handle, int cbufSlot)
        {
            if (_compute)
            {
                return _channel.TextureManager.GetComputeTextureDescriptor(
                    _state.PoolState.TexturePoolGpuVa,
                    _state.PoolState.TextureBufferIndex,
                    _state.PoolState.TexturePoolMaximumId,
                    handle,
                    cbufSlot);
            }
            else
            {
                return _channel.TextureManager.GetGraphicsTextureDescriptor(
                    _state.PoolState.TexturePoolGpuVa,
                    _state.PoolState.TextureBufferIndex,
                    _state.PoolState.TexturePoolMaximumId,
                    _stageIndex,
                    handle,
                    cbufSlot);
            }
        }

        /// <inheritdoc/>
        public bool QueryTransformFeedbackEnabled()
        {
            return _state.TransformFeedbackDescriptors != null;
        }

        /// <inheritdoc/>
        public ReadOnlySpan<byte> QueryTransformFeedbackVaryingLocations(int bufferIndex)
        {
            return _state.TransformFeedbackDescriptors[bufferIndex].AsSpan();
        }

        /// <inheritdoc/>
        public int QueryTransformFeedbackStride(int bufferIndex)
        {
            return _state.TransformFeedbackDescriptors[bufferIndex].Stride;
        }

        /// <inheritdoc/>
        public void RegisterTexture(int handle, int cbufSlot)
        {
            _state.SpecializationState?.RegisterTexture(_stageIndex, handle, cbufSlot, GetTextureDescriptor(handle, cbufSlot));
        }
    }
}
