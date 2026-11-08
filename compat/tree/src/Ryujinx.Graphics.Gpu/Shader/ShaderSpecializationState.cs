using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using TextureDescriptor = Ryujinx.Graphics.Shader.TextureDescriptor;

namespace Ryujinx.Graphics.Gpu.Shader
{
    class ShaderSpecializationState
    {
        private const uint ComsMagic = (byte)'C' | ((byte)'O' << 8) | ((byte)'M' << 16) | ((byte)'S' << 24);
        private const uint GfxsMagic = (byte)'G' | ((byte)'F' << 8) | ((byte)'X' << 16) | ((byte)'S' << 24);
        private const uint TfbdMagic = (byte)'T' | ((byte)'F' << 8) | ((byte)'B' << 16) | ((byte)'D' << 24);
        private const uint TexkMagic = (byte)'T' | ((byte)'E' << 8) | ((byte)'X' << 16) | ((byte)'K' << 24);
        private const uint TexsMagic = (byte)'T' | ((byte)'E' << 8) | ((byte)'X' << 16) | ((byte)'S' << 24);
        private const uint PgpsMagic = (byte)'P' | ((byte)'G' << 8) | ((byte)'P' << 16) | ((byte)'S' << 24);

        /// <summary>
        /// Flags indicating GPU state that is used by the shader.
        /// </summary>
        [Flags]
        private enum QueriedStateFlags
        {
            PrimitiveTopology = 1 << 1,
            TransformFeedback = 1 << 3,
            TextureArrayFromBuffer = 1 << 4,
            TextureArrayFromPool = 1 << 5,
            S2AUsageTracked = 1 << 8,   // S2A：翻译时记了读过哪些状态（S2ARecordUsage）；没有这位的旧条目照原版全比
            S2AA2cRead = 1 << 9,    // S2AStateRead 位 i ↔ 1 << (9 + i)
            S2ADepthRead = 1 << 10,
            S2ACbdpRead = 1 << 11,
            S2AAlphaRead = 1 << 12,
            S2ATessRead = 1 << 13,   // S2A：翻译读了曲面模式（TCS / TES）：匹配要比 TessellationMode
            S2AEarlyZRead = 1 << 14,
            S2ATopologyRead = 1 << 15,
            S2AHalvePrimRead = 1 << 16,
            S2APointSizeRead = 1 << 17,
            S2ALocalMemRead = 1 << 18,
            S2ASharedMemRead = 1 << 19,
            S2AReadMask = S2AA2cRead | S2ADepthRead | S2ACbdpRead | S2AAlphaRead | S2ATessRead | S2AEarlyZRead | S2ATopologyRead | S2AHalvePrimRead | S2APointSizeRead | S2ALocalMemRead | S2ASharedMemRead,
            // S2A（10-21）：第二代使用记录——14–19 位有记（之前的条目只记 9–12 位、0099 起另记 13 位曲面；没这一位时 13–19 位按「阶段在就算读过」保守核对，见 S2AVerify）
            S2AUsageV2 = 1 << 20,
        }

        private QueriedStateFlags _queriedState;
        private uint _s2aAttrRead;   // S2A：翻译时读过类型的顶点属性位置

        /// <summary>S2A：记下翻译实际读过的状态（访问器在 TranslatorContext.Translate 结尾调）；多阶段累加</summary>
        public void S2ARecordUsage(uint readFlags, uint attrReadMask)
        {
            _queriedState |= QueriedStateFlags.S2AUsageTracked | QueriedStateFlags.S2AUsageV2 | ((QueriedStateFlags)(readFlags << 9) & QueriedStateFlags.S2AReadMask);
            _s2aAttrRead |= attrReadMask;
        }

        /// <summary>S2A：使用记录只读（离线批量翻译补变体用）：有无记录 / a2c 抖动是否读过 / 读过类型的属性位置</summary>
        public bool S2AUsageTracked => (_queriedState & QueriedStateFlags.S2AUsageTracked) != 0;
        public bool S2AA2cRead => (_queriedState & QueriedStateFlags.S2AA2cRead) != 0;
        /// <summary>S2A：翻译读过常量缓冲绘制参数（cbdp）。按需实化时用来在不知道宿主程序的情况下按运行时状态核对缺宿主二进制的条目。</summary>
        public bool S2ACbdpRead => (_queriedState & QueriedStateFlags.S2ACbdpRead) != 0;
        public uint S2AAttrRead => _s2aAttrRead;

        /// <summary>S2A：翻译读过的状态位（S2AStateRead 位号，离线烘焙器统计「读过缺省值字段的程序数」用）；S2AUsageV2 = 有第二代记录（早期深度 … 共享内存这几位可信）</summary>
        public uint S2AReadBits => (uint)(_queriedState & QueriedStateFlags.S2AReadMask) >> 9;
        public bool S2AUsageV2 => (_queriedState & QueriedStateFlags.S2AUsageV2) != 0;

        /// <summary>S2A：序列化时去掉使用记录（缓存合并按「客体代码 + 特化状态」去重用：同一程序有无记录算同一条）</summary>
        public void S2AWriteWithoutUsage(ref BinarySerializer dataWriter)
        {
            QueriedStateFlags q = _queriedState; uint m = _s2aAttrRead;
            _queriedState &= ~(QueriedStateFlags.S2AUsageTracked | QueriedStateFlags.S2AUsageV2 | QueriedStateFlags.S2AReadMask); _s2aAttrRead = 0;
            try { Write(ref dataWriter); } finally { _queriedState = q; _s2aAttrRead = m; }
        }

        /// <summary>S2A：把另一份（同一程序再翻时记录的）使用记录并进来（离线批量翻译写盘用继承条目的状态时）</summary>
        public void S2AMergeUsage(ShaderSpecializationState other)
        {
            if ((other._queriedState & QueriedStateFlags.S2AUsageTracked) == 0) return;
            // 原样并入（含第二代标记）：对方没有第二代记录时这边也不能凭空标上
            _queriedState |= other._queriedState & (QueriedStateFlags.S2AUsageTracked | QueriedStateFlags.S2AUsageV2 | QueriedStateFlags.S2AReadMask);
            _s2aAttrRead |= other._s2aAttrRead;
        }
        /// <summary>
        /// S2A（10-23 画面·着色器线）：继承条目的贴图查询记录按这次再翻实际查过的收窄——每个贴图的查询位与 <paramref name="other"/>（同客体代码用当前翻译器再翻的状态）同键的查询位取交，对方没登记的贴图查询位清零。
        /// 参照缓存（上游社区缓存 / 旧版本局）的翻译器总查「坐标是否归一化」，当前翻译器把它运行时化（Ryujinx 0044）、不再查：原样继承会把旧查询连值带进包，
        /// 运行时描述符不同就判不符重翻（暗黑2 包 10559 个程序 4052 个带它，jhz 实机 5 次首遇现编 0.6–1.4 s）。代码不随没查的字段变，匹配也不该比它。返回清掉的查询位数。
        /// </summary>
        public int S2ATrimTextureQueries(ShaderSpecializationState other)
        {
            int n = 0;
            foreach (KeyValuePair<TextureKey, Box<TextureSpecializationState>> kv in _textureSpecialization)
            {
                QueriedTextureStateFlags keep = other._textureSpecialization.TryGetValue(kv.Key, out Box<TextureSpecializationState> o) ? o.Value.QueriedFlags : 0;
                QueriedTextureStateFlags drop = kv.Value.Value.QueriedFlags & ~keep;
                if (drop == 0) continue;
                kv.Value.Value.QueriedFlags &= keep;
                n += System.Numerics.BitOperations.PopCount((uint)drop);
            }
            return n;
        }
        private bool _compute;
        private byte _constantBufferUsePerStage;

        /// <summary>
        /// Compute engine state.
        /// </summary>
        public GpuChannelComputeState ComputeState;

        /// <summary>
        /// 3D engine state.
        /// </summary>
        public GpuChannelGraphicsState GraphicsState;

        /// <summary>
        /// Contant buffers bound at the time the shader was compiled, per stage.
        /// </summary>
        public Array5<uint> ConstantBufferUse;

        /// <summary>
        /// Pipeline state captured at the time of shader use.
        /// </summary>
        public ProgramPipelineState? PipelineState;

        /// <summary>
        /// Transform feedback buffers active at the time the shader was compiled.
        /// </summary>
        public TransformFeedbackDescriptor[] TransformFeedbackDescriptors;

        /// <summary>
        /// Flags indicating texture state that is used by the shader.
        /// </summary>
        [Flags]
        private enum QueriedTextureStateFlags
        {
            TextureFormat = 1 << 0,
            SamplerType = 1 << 1,
            CoordNormalized = 1 << 2,
            // S2A：只查询了「是不是贴图缓冲」（IGpuAccessor.QueryTextureIsBuffer），匹配只比这一位
            S2ASamplerIsBuffer = 1 << 3,
        }

        /// <summary>
        /// Reference type wrapping a value.
        /// </summary>
        private class Box<T>
        {
            /// <summary>
            /// Wrapped value.
            /// </summary>
            public T Value;
        }

        /// <summary>
        /// State of a texture or image that is accessed by the shader.
        /// </summary>
        private struct TextureSpecializationState
        {
            // New fields should be added to the end of the struct to keep disk shader cache compatibility.

            /// <summary>
            /// Flags indicating which state of the texture the shader depends on.
            /// </summary>
            public QueriedTextureStateFlags QueriedFlags;

            /// <summary>
            /// Encoded texture format value.
            /// </summary>
            public uint Format;

            /// <summary>
            /// True if the texture format is sRGB, false otherwise.
            /// </summary>
            public bool FormatSrgb;

            /// <summary>
            /// Texture target.
            /// </summary>
            public TextureTarget TextureTarget;

            /// <summary>
            /// Indicates if the coordinates used to sample the texture are normalized or not (0.0..1.0 or 0..Width/Height).
            /// </summary>
            public bool CoordNormalized;
        }

        /// <summary>
        /// Texture binding information, used to identify each texture accessed by the shader.
        /// </summary>
        private readonly record struct TextureKey
        {
            // New fields should be added to the end of the struct to keep disk shader cache compatibility.

            /// <summary>
            /// Shader stage where the texture is used.
            /// </summary>
            public readonly int StageIndex;

            /// <summary>
            /// Texture handle offset in words on the texture buffer.
            /// </summary>
            public readonly int Handle;

            /// <summary>
            /// Constant buffer slot of the texture buffer (-1 to use the texture buffer index GPU register).
            /// </summary>
            public readonly int CbufSlot;

            /// <summary>
            /// Creates a new texture key.
            /// </summary>
            /// <param name="stageIndex">Shader stage where the texture is used</param>
            /// <param name="handle">Texture handle offset in words on the texture buffer</param>
            /// <param name="cbufSlot">Constant buffer slot of the texture buffer (-1 to use the texture buffer index GPU register)</param>
            public TextureKey(int stageIndex, int handle, int cbufSlot)
            {
                StageIndex = stageIndex;
                Handle = handle;
                CbufSlot = cbufSlot;
            }
        }

        private readonly Dictionary<TextureKey, Box<TextureSpecializationState>> _textureSpecialization;
        private readonly Dictionary<TextureKey, int> _textureArrayFromBufferSpecialization;
        private readonly Dictionary<bool, int> _textureArrayFromPoolSpecialization;
        private KeyValuePair<TextureKey, Box<TextureSpecializationState>>[] _allTextures;
        private Box<TextureSpecializationState>[][] _textureByBinding;
        private Box<TextureSpecializationState>[][] _imageByBinding;

        /// <summary>
        /// Creates a new instance of the shader specialization state.
        /// </summary>
        private ShaderSpecializationState()
        {
            _textureSpecialization = new Dictionary<TextureKey, Box<TextureSpecializationState>>();
            _textureArrayFromBufferSpecialization = new Dictionary<TextureKey, int>();
            _textureArrayFromPoolSpecialization = new Dictionary<bool, int>();
        }

        /// <summary>
        /// Creates a new instance of the shader specialization state.
        /// </summary>
        /// <param name="state">Current compute engine state</param>
        public ShaderSpecializationState(ref GpuChannelComputeState state) : this()
        {
            ComputeState = state;
            _compute = true;
        }

        /// <summary>
        /// Creates a new instance of the shader specialization state.
        /// </summary>
        /// <param name="state">Current 3D engine state</param>
        /// <param name="descriptors">Optional transform feedback buffers in use, if any</param>
        private ShaderSpecializationState(ref GpuChannelGraphicsState state, TransformFeedbackDescriptor[] descriptors) : this()
        {
            GraphicsState = state;
            _compute = false;

            if (descriptors != null)
            {
                TransformFeedbackDescriptors = descriptors;
                _queriedState |= QueriedStateFlags.TransformFeedback;
            }
        }

        /// <summary>
        /// S2A（10-27）：只做查找用的准备（贴图特化快照）。按需实化核对「缺宿主二进制的条目是否真的匹配」时，条目没有
        /// CachedShaderProgram（Prepare 不会跑），但比贴图描述符要这份快照；绑定快照与阶段信息不在匹配路径上，不建。
        /// </summary>
        internal void S2APrepareMatchOnly() => _allTextures ??= _textureSpecialization.ToArray();

        /// <summary>
        /// Prepare the shader specialization state for quick binding lookups.
        /// </summary>
        /// <param name="stages">The shader stages</param>
        public void Prepare(CachedShaderStage[] stages)
        {
            _allTextures = _textureSpecialization.ToArray();
            _s2aFoutTargets = S2AWrittenTargets(stages);

            _textureByBinding = new Box<TextureSpecializationState>[stages.Length][];
            _imageByBinding = new Box<TextureSpecializationState>[stages.Length][];

            for (int i = 0; i < stages.Length; i++)
            {
                CachedShaderStage stage = stages[i];
                if (stage?.Info != null)
                {
                    ReadOnlyCollection<TextureDescriptor> textures = stage.Info.Textures;
                    ReadOnlyCollection<TextureDescriptor> images = stage.Info.Images;

                    Box<TextureSpecializationState>[] texBindings = new Box<TextureSpecializationState>[textures.Count];
                    Box<TextureSpecializationState>[] imageBindings = new Box<TextureSpecializationState>[images.Count];

                    int stageIndex = Math.Max(i - 1, 0); // Don't count VertexA for looking up spec state. No-Op for compute.

                    for (int j = 0; j < textures.Count; j++)
                    {
                        TextureDescriptor texture = textures[j];
                        texBindings[j] = GetTextureSpecState(stageIndex, texture.HandleIndex, texture.CbufSlot);
                    }

                    for (int j = 0; j < images.Count; j++)
                    {
                        TextureDescriptor image = images[j];
                        imageBindings[j] = GetTextureSpecState(stageIndex, image.HandleIndex, image.CbufSlot);
                    }

                    _textureByBinding[i] = texBindings;
                    _imageByBinding[i] = imageBindings;
                }
            }
        }

        /// <summary>
        /// Creates a new instance of the shader specialization state.
        /// </summary>
        /// <param name="state">Current 3D engine state</param>
        /// <param name="pipelineState">Current program pipeline state</param>
        /// <param name="descriptors">Optional transform feedback buffers in use, if any</param>
        public ShaderSpecializationState(
            ref GpuChannelGraphicsState state,
            ref ProgramPipelineState pipelineState,
            TransformFeedbackDescriptor[] descriptors) : this(ref state, descriptors)
        {
            PipelineState = pipelineState;
        }

        /// <summary>
        /// Creates a new instance of the shader specialization state.
        /// </summary>
        /// <param name="state">Current 3D engine state</param>
        /// <param name="pipelineState">Current program pipeline state</param>
        /// <param name="descriptors">Optional transform feedback buffers in use, if any</param>
        public ShaderSpecializationState(
            ref GpuChannelGraphicsState state,
            ProgramPipelineState? pipelineState,
            TransformFeedbackDescriptor[] descriptors) : this(ref state, descriptors)
        {
            PipelineState = pipelineState;
        }

        /// <summary>
        /// Indicates that the shader accesses the primitive topology state.
        /// </summary>
        public void RecordPrimitiveTopology()
        {
            _queriedState |= QueriedStateFlags.PrimitiveTopology;
        }

        /// <summary>
        /// Indicates that the shader accesses the constant buffer use state.
        /// </summary>
        /// <param name="stageIndex">Shader stage index</param>
        /// <param name="useMask">Mask indicating the constant buffers bound at the time of the shader compilation</param>
        public void RecordConstantBufferUse(int stageIndex, uint useMask)
        {
            ConstantBufferUse[stageIndex] = useMask;
            _constantBufferUsePerStage |= (byte)(1 << stageIndex);
        }

        /// <summary>
        /// Indicates that a given texture is accessed by the shader.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <param name="descriptor">Descriptor of the texture</param>
        public void RegisterTexture(int stageIndex, int handle, int cbufSlot, Image.TextureDescriptor descriptor)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.Format = descriptor.UnpackFormat();
            state.Value.FormatSrgb = descriptor.UnpackSrgb();
            state.Value.TextureTarget = descriptor.UnpackTextureTarget();
            state.Value.CoordNormalized = descriptor.UnpackTextureCoordNormalized();
        }

        /// <summary>
        /// Indicates that a given texture is accessed by the shader.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <param name="format">Maxwell texture format value</param>
        /// <param name="formatSrgb">Whenever the texture format is a sRGB format</param>
        /// <param name="target">Texture target type</param>
        /// <param name="coordNormalized">Whenever the texture coordinates used on the shader are considered normalized</param>
        public void RegisterTexture(
            int stageIndex,
            int handle,
            int cbufSlot,
            uint format,
            bool formatSrgb,
            TextureTarget target,
            bool coordNormalized)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.Format = format;
            state.Value.FormatSrgb = formatSrgb;
            state.Value.TextureTarget = target;
            state.Value.CoordNormalized = coordNormalized;
        }

        /// <summary>
        /// Registers the length of a texture array calculated from a constant buffer size.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <param name="length">Number of elements in the texture array</param>
        public void RegisterTextureArrayLengthFromBuffer(int stageIndex, int handle, int cbufSlot, int length)
        {
            _textureArrayFromBufferSpecialization[new TextureKey(stageIndex, handle, cbufSlot)] = length;
            _queriedState |= QueriedStateFlags.TextureArrayFromBuffer;
        }

        /// <summary>
        /// Registers the length of a texture array calculated from a texture or sampler pool capacity.
        /// </summary>
        /// <param name="isSampler">True for sampler pool, false for texture pool</param>
        /// <param name="length">Number of elements in the texture array</param>
        public void RegisterTextureArrayLengthFromPool(bool isSampler, int length)
        {
            _textureArrayFromPoolSpecialization[isSampler] = length;
            _queriedState |= QueriedStateFlags.TextureArrayFromPool;
        }

        /// <summary>
        /// Indicates that the format of a given texture was used during the shader translation process.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        public void RecordTextureFormat(int stageIndex, int handle, int cbufSlot)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.QueriedFlags |= QueriedTextureStateFlags.TextureFormat;
        }

        /// <summary>
        /// Indicates that the target of a given texture was used during the shader translation process.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        public void RecordTextureSamplerType(int stageIndex, int handle, int cbufSlot)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.QueriedFlags |= QueriedTextureStateFlags.SamplerType;
        }

        /// <summary>
        /// S2A：翻译时只用了「是不是贴图缓冲」这一位（见 IGpuAccessor.QueryTextureIsBuffer）。
        /// </summary>
        public void S2ARecordTextureIsBuffer(int stageIndex, int handle, int cbufSlot)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.QueriedFlags |= QueriedTextureStateFlags.S2ASamplerIsBuffer;
        }

        /// <summary>
        /// Indicates that the coordinate normalization state of a given texture was used during the shader translation process.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        public void RecordTextureCoordNormalized(int stageIndex, int handle, int cbufSlot)
        {
            Box<TextureSpecializationState> state = GetOrCreateTextureSpecState(stageIndex, handle, cbufSlot);
            state.Value.QueriedFlags |= QueriedTextureStateFlags.CoordNormalized;
        }

        /// <summary>
        /// Checks if primitive topology was queried by the shader.
        /// </summary>
        /// <returns>True if queried, false otherwise</returns>
        public bool IsPrimitiveTopologyQueried()
        {
            return (_queriedState & QueriedStateFlags.PrimitiveTopology) == QueriedStateFlags.PrimitiveTopology;
        }

        /// <summary>
        /// Checks if a given texture was registered on this specialization state.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        public bool TextureRegistered(int stageIndex, int handle, int cbufSlot)
        {
            return GetTextureSpecState(stageIndex, handle, cbufSlot) != null;
        }

        /// <summary>
        /// Checks if a given texture array (from constant buffer) was registered on this specialization state.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>True if the length for the given buffer and stage exists, false otherwise</returns>
        public bool TextureArrayFromBufferRegistered(int stageIndex, int handle, int cbufSlot)
        {
            return _textureArrayFromBufferSpecialization.ContainsKey(new TextureKey(stageIndex, handle, cbufSlot));
        }

        /// <summary>
        /// Checks if a given texture array (from a sampler pool or texture pool) was registered on this specialization state.
        /// </summary>
        /// <param name="isSampler">True for sampler pool, false for texture pool</param>
        /// <returns>True if the length for the given pool, false otherwise</returns>
        public bool TextureArrayFromPoolRegistered(bool isSampler)
        {
            return _textureArrayFromPoolSpecialization.ContainsKey(isSampler);
        }

        /// <summary>
        /// Gets the recorded format of a given texture.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>Format and sRGB tuple</returns>
        public (uint, bool) GetFormat(int stageIndex, int handle, int cbufSlot)
        {
            TextureSpecializationState state = GetTextureSpecState(stageIndex, handle, cbufSlot).Value;
            return (state.Format, state.FormatSrgb);
        }

        /// <summary>
        /// Gets the recorded target of a given texture.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>Texture target</returns>
        public TextureTarget GetTextureTarget(int stageIndex, int handle, int cbufSlot)
        {
            return GetTextureSpecState(stageIndex, handle, cbufSlot).Value.TextureTarget;
        }

        /// <summary>
        /// Gets the recorded coordinate normalization state of a given texture.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>True if coordinates are normalized, false otherwise</returns>
        public bool GetCoordNormalized(int stageIndex, int handle, int cbufSlot)
        {
            return GetTextureSpecState(stageIndex, handle, cbufSlot).Value.CoordNormalized;
        }

        /// <summary>
        /// Gets the recorded length of a given texture array (from constant buffer).
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>Texture array length</returns>
        public int GetTextureArrayFromBufferLength(int stageIndex, int handle, int cbufSlot)
        {
            return _textureArrayFromBufferSpecialization[new TextureKey(stageIndex, handle, cbufSlot)];
        }

        /// <summary>
        /// Gets the recorded length of a given texture array (from a sampler or texture pool).
        /// </summary>
        /// <param name="isSampler">True to get the sampler pool length, false to get the texture pool length</param>
        /// <returns>Texture array length</returns>
        public int GetTextureArrayFromPoolLength(bool isSampler)
        {
            return _textureArrayFromPoolSpecialization[isSampler];
        }

        /// <summary>
        /// Gets texture specialization state for a given texture, or create a new one if not present.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>Texture specialization state</returns>
        private Box<TextureSpecializationState> GetOrCreateTextureSpecState(int stageIndex, int handle, int cbufSlot)
        {
            TextureKey key = new(stageIndex, handle, cbufSlot);

            if (!_textureSpecialization.TryGetValue(key, out Box<TextureSpecializationState> state))
            {
                _textureSpecialization.Add(key, state = new Box<TextureSpecializationState>());
            }

            return state;
        }

        /// <summary>
        /// Gets texture specialization state for a given texture.
        /// </summary>
        /// <param name="stageIndex">Shader stage where the texture is used</param>
        /// <param name="handle">Offset in words of the texture handle on the texture buffer</param>
        /// <param name="cbufSlot">Slot of the texture buffer constant buffer</param>
        /// <returns>Texture specialization state</returns>
        private Box<TextureSpecializationState> GetTextureSpecState(int stageIndex, int handle, int cbufSlot)
        {
            TextureKey key = new(stageIndex, handle, cbufSlot);

            if (_textureSpecialization.TryGetValue(key, out Box<TextureSpecializationState> state))
            {
                return state;
            }

            return null;
        }

        /// <summary>
        /// Checks if the recorded state matches the current GPU 3D engine state.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="graphicsState">Graphics state</param>
        /// <param name="vertexAsCompute">Indicates that the vertex shader has been converted into a compute shader</param>
        /// <param name="usesDrawParameters">Indicates whether the vertex shader accesses draw parameters</param>
        /// <param name="checkTextures">Indicates whether texture descriptors should be checked</param>
        /// <returns>True if the state matches, false otherwise</returns>
        // S2A（10-21）：最近一次 Matches* 判不符的字段（首遇重翻诊断：ShaderCacheHashTable.TryFind 不中时取它记拒因，见 ShaderCache.S2ALogMiss）；只写不读时零开销
        [ThreadStatic] internal static string S2AMissWhy;
        // S2A（10-21）：最近一次缓存查找不中的分类（ShaderCacheHashTable / ComputeShaderCacheHashTable.TryFind 写，ShaderCache 翻译前读）
        [ThreadStatic] internal static string S2AMiss;

        public bool MatchesGraphics(
            GpuChannel channel,
            ref GpuChannelPoolState poolState,
            ref GpuChannelGraphicsState graphicsState,
            bool vertexAsCompute,
            bool usesDrawParameters,
            bool checkTextures)
        {
            if (graphicsState.ViewportTransformDisable != GraphicsState.ViewportTransformDisable)
            {
                S2AMissWhy = "ViewportTransformDisable"; return false;
            }

            // S2A：翻译读了图元拓扑（几何着色器按输入拓扑定输入图元；转计算时几何计算核按它取顶点）→ 输入拓扑类不同就不是同一个程序。
            // 上游这里不比（拓扑变化只触发重新查找、查到的还是旧程序）：首遇按三角形翻的几何程序画点 / 线时照用，出包按缺省拓扑烘的更会错配
            if (IsPrimitiveTopologyQueried() && graphicsState.S2AInputTopology != GraphicsState.S2AInputTopology)
            {
                S2AMissWhy = "图元拓扑"; return false;
            }

            bool thisA2cDitherEnable = GraphicsState.AlphaToCoverageEnable && GraphicsState.AlphaToCoverageDitherEnable;
            bool otherA2cDitherEnable = graphicsState.AlphaToCoverageEnable && graphicsState.AlphaToCoverageDitherEnable;

            bool s2aTracked = (_queriedState & QueriedStateFlags.S2AUsageTracked) != 0;   // S2A：有使用记录就只比翻译读过的

            if ((!s2aTracked || (_queriedState & QueriedStateFlags.S2AA2cRead) != 0) && otherA2cDitherEnable != thisA2cDitherEnable)
            {
                S2AMissWhy = "A2C 抖动"; return false;
            }

            if ((!s2aTracked || (_queriedState & QueriedStateFlags.S2ADepthRead) != 0) && graphicsState.DepthMode != GraphicsState.DepthMode)   // S2A：运行时化后翻译不读 DepthMode，不比
            {
                S2AMissWhy = "DepthMode"; return false;
            }

            // S2A：比「翻出来有没有透明测试代码」，不比原始开关位（开着但比较方式 Always = 关，同一份着色器）。主机能力同 GpuAccessor：Vulkan 口径不支持透明测试
            bool s2aHostAlpha = channel.Capabilities.Api != Ryujinx.Graphics.Shader.Translation.TargetApi.Vulkan;
            if (graphicsState.S2AAlphaTestEmitted(s2aHostAlpha) != GraphicsState.S2AAlphaTestEmitted(s2aHostAlpha))
            {
                S2AMissWhy = "透明测试开关"; return false;
            }

            if (graphicsState.S2AAlphaTestEmitted(s2aHostAlpha) && (!s2aTracked || (_queriedState & QueriedStateFlags.S2AAlphaRead) != 0) &&   // S2A：运行时化后不读比较方式 / 参考值，不比
                (graphicsState.AlphaTestCompare != GraphicsState.AlphaTestCompare ||
                graphicsState.AlphaTestReference != GraphicsState.AlphaTestReference))
            {
                S2AMissWhy = "透明测试比较 / 参考值"; return false;
            }

            if (ShaderCache.MayConvertVtgToCompute(ref channel.Capabilities) && !vertexAsCompute)
            {
                Span<AttributeType> attributeTypesSpan = graphicsState.AttributeTypes.AsSpan();
                Span<AttributeType> gAttributeTypesSpan = GraphicsState.AttributeTypes.AsSpan();
                
                for (int index = 0; index < attributeTypesSpan.Length; index++)
                {
                    if (s2aTracked && (_s2aAttrRead & (1u << index)) == 0) continue;   // S2A：翻译没读过这个位置的类型
                    AttributeType lType = FilterAttributeType(channel, attributeTypesSpan[index]);
                    AttributeType rType = FilterAttributeType(channel, gAttributeTypesSpan[index]);

                    if (lType != rType)
                    {
                        S2AMissWhy = "顶点属性类型"; return false;
                    }
                }
            }
            else
            {
                Span<AttributeType> s2aL = graphicsState.AttributeTypes.AsSpan(), s2aR = GraphicsState.AttributeTypes.AsSpan();
                for (int index = 0; index < s2aL.Length; index++)
                {
                    if (s2aTracked && (_s2aAttrRead & (1u << index)) == 0) continue;   // S2A：翻译没读过这个位置的类型
                    if (s2aL[index] != s2aR[index]) { S2AMissWhy = "顶点属性类型（S2A 记录）"; return false; }
                }
            }

            if (usesDrawParameters && (!s2aTracked || (_queriedState & QueriedStateFlags.S2ACbdpRead) != 0) && graphicsState.HasConstantBufferDrawParameters != GraphicsState.HasConstantBufferDrawParameters)   // S2A：运行时化后不读 cbdp，不比
            {
                S2AMissWhy = "常量缓冲绘制参数"; return false;
            }

            if (graphicsState.HasUnalignedStorageBuffer != GraphicsState.HasUnalignedStorageBuffer)
            {
                S2AMissWhy = "存储缓冲未对齐"; return false;
            }

            if (s2aTracked && (_queriedState & QueriedStateFlags.S2ATessRead) != 0 && graphicsState.TessellationMode.Packed != GraphicsState.TessellationMode.Packed)   // S2A：曲面程序按翻译时的域 / 分区 / 绕序匹配
            {
                S2AMissWhy = "曲面模式"; return false;
            }

            if (channel.Capabilities.NeedsFragmentOutputSpecialization && !S2AFoutMatches(ref graphicsState))
            {
                // S2A（10-24）：拒因带两边取值（条目 / 运行时，0 浮点 1 有符号整数 2 无符号整数…，AttributeType 数值），只在不中时拼串
                S2AMissWhy = $"片元输出类型（条目 {string.Join(",", GraphicsState.FragmentOutputTypes.AsSpan().ToArray().Select(t => (int)t))} 运行时 {string.Join(",", graphicsState.FragmentOutputTypes.AsSpan().ToArray().Select(t => (int)t))}）"; return false;
            }

            if (graphicsState.DualSourceBlendEnable != GraphicsState.DualSourceBlendEnable)
            {
                S2AMissWhy = "双源混合"; return false;
            }

            if (graphicsState.YNegateEnabled != GraphicsState.YNegateEnabled)
            {
                S2AMissWhy = "YNegate"; return false;
            }

            return Matches(channel, ref poolState, checkTextures, isCompute: false);
        }

        /// <summary>
        /// Converts special vertex attribute groups to their generic equivalents, for comparison purposes.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="type">Vertex attribute type</param>
        /// <returns>Filtered attribute</returns>
        private static AttributeType FilterAttributeType(GpuChannel channel, AttributeType type)
        {
            type &= ~(AttributeType.Packed | AttributeType.PackedRgb10A2Signed | AttributeType.TexelDecode | AttributeType.TexelInvalidFormat);

            if (channel.Capabilities.SupportsScaledVertexFormats &&
                (type == AttributeType.Sscaled || type == AttributeType.Uscaled))
            {
                type = AttributeType.Float;
            }

            return type;
        }

        /// <summary>
        /// Checks if the recorded state matches the current GPU compute engine state.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="computeState">Compute state</param>
        /// <param name="checkTextures">Indicates whether texture descriptors should be checked</param>
        /// <returns>True if the state matches, false otherwise</returns>
        public bool MatchesCompute(GpuChannel channel, ref GpuChannelPoolState poolState, GpuChannelComputeState computeState, bool checkTextures)
        {
            if (computeState.HasUnalignedStorageBuffer != ComputeState.HasUnalignedStorageBuffer)
            {
                S2AMissWhy = "存储缓冲未对齐（计算）"; return false;
            }

            return Matches(channel, ref poolState, checkTextures, isCompute: true);
        }

        /// <summary>
        /// Fetch the constant buffers used for a texture to cache.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="isCompute">Indicates whenever the check is requested by the 3D or compute engine</param>
        /// <param name="cachedTextureBufferIndex">The currently cached texture buffer index</param>
        /// <param name="cachedSamplerBufferIndex">The currently cached sampler buffer index</param>
        /// <param name="cachedTextureBuffer">The currently cached texture buffer data</param>
        /// <param name="cachedSamplerBuffer">The currently cached sampler buffer data</param>
        /// <param name="cachedStageIndex">The currently cached stage</param>
        /// <param name="textureBufferIndex">The new texture buffer index</param>
        /// <param name="samplerBufferIndex">The new sampler buffer index</param>
        /// <param name="stageIndex">Stage index of the constant buffer</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static void UpdateCachedBuffer(
            GpuChannel channel,
            bool isCompute,
            scoped ref int cachedTextureBufferIndex,
            scoped ref int cachedSamplerBufferIndex,
            scoped ref ReadOnlySpan<int> cachedTextureBuffer,
            scoped ref ReadOnlySpan<int> cachedSamplerBuffer,
            scoped ref int cachedStageIndex,
            int textureBufferIndex,
            int samplerBufferIndex,
            int stageIndex)
        {
            bool stageChange = stageIndex != cachedStageIndex;

            if (stageChange || textureBufferIndex != cachedTextureBufferIndex)
            {
                ref BufferBounds bounds = ref channel.BufferManager.GetUniformBufferBounds(isCompute, stageIndex, textureBufferIndex);

                cachedTextureBuffer = MemoryMarshal.Cast<byte, int>(channel.MemoryManager.Physical.GetSpan(bounds.Range));
                cachedTextureBufferIndex = textureBufferIndex;

                if (samplerBufferIndex == textureBufferIndex)
                {
                    cachedSamplerBuffer = cachedTextureBuffer;
                    cachedSamplerBufferIndex = samplerBufferIndex;
                }
            }

            if (stageChange || samplerBufferIndex != cachedSamplerBufferIndex)
            {
                ref BufferBounds bounds = ref channel.BufferManager.GetUniformBufferBounds(isCompute, stageIndex, samplerBufferIndex);

                cachedSamplerBuffer = MemoryMarshal.Cast<byte, int>(channel.MemoryManager.Physical.GetSpan(bounds.Range));
                cachedSamplerBufferIndex = samplerBufferIndex;
            }

            cachedStageIndex = stageIndex;
        }

        /// <summary>
        /// Checks if the recorded state matches the current GPU state.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="checkTextures">Indicates whether texture descriptors should be checked</param>
        /// <param name="isCompute">Indicates whenever the check is requested by the 3D or compute engine</param>
        /// <returns>True if the state matches, false otherwise</returns>
        private bool Matches(GpuChannel channel, ref GpuChannelPoolState poolState, bool checkTextures, bool isCompute)
        {
            int constantBufferUsePerStageMask = _constantBufferUsePerStage;

            Span<uint> constantBufferUseSpan = ConstantBufferUse.AsSpan();
            
            while (constantBufferUsePerStageMask != 0)
            {
                int index = BitOperations.TrailingZeroCount(constantBufferUsePerStageMask);

                uint useMask = isCompute
                    ? channel.BufferManager.GetComputeUniformBufferUseMask()
                    : channel.BufferManager.GetGraphicsUniformBufferUseMask(index);

                if (constantBufferUseSpan[index] != useMask)
                {
                    S2AMissWhy = "常量缓冲使用"; return false;
                }

                constantBufferUsePerStageMask &= ~(1 << index);
            }

            if (checkTextures && _allTextures.Length > 0)
            {
                TexturePool pool = channel.TextureManager.GetTexturePool(poolState.TexturePoolGpuVa, poolState.TexturePoolMaximumId);

                int cachedTextureBufferIndex = -1;
                int cachedSamplerBufferIndex = -1;
                int cachedStageIndex = -1;
                ReadOnlySpan<int> cachedTextureBuffer = Span<int>.Empty;
                ReadOnlySpan<int> cachedSamplerBuffer = Span<int>.Empty;

                foreach (KeyValuePair<TextureKey, Box<TextureSpecializationState>> kv in _allTextures)
                {
                    TextureKey textureKey = kv.Key;

                    (int textureBufferIndex, int samplerBufferIndex) = TextureHandle.UnpackSlots(textureKey.CbufSlot, poolState.TextureBufferIndex);

                    UpdateCachedBuffer(channel,
                        isCompute,
                        ref cachedTextureBufferIndex,
                        ref cachedSamplerBufferIndex,
                        ref cachedTextureBuffer,
                        ref cachedSamplerBuffer,
                        ref cachedStageIndex,
                        textureBufferIndex,
                        samplerBufferIndex,
                        textureKey.StageIndex);

                    int packedId = TextureHandle.ReadPackedId(textureKey.Handle, cachedTextureBuffer, cachedSamplerBuffer);
                    int textureId = TextureHandle.UnpackTextureId(packedId);

                    if (pool.IsValidId(textureId))
                    {
                        ref readonly Image.TextureDescriptor descriptor = ref pool.GetDescriptorRef(textureId);

                        if (!MatchesTexture(kv.Value, descriptor))
                        {
                            return false;
                        }
                    }
                }
            }

            return true;
        }

        /// <summary>
        /// Checks if the recorded texture state matches the given texture descriptor.
        /// </summary>
        /// <param name="specializationState">Texture specialization state</param>
        /// <param name="descriptor">Texture descriptor</param>
        /// <returns>True if the state matches, false otherwise</returns>
        /// <summary>S2A 单测入口（graphics/tools/shbake/tests/spec）：按句柄取登记的贴图状态，与给定描述符比（同 MatchesTexture）；不匹配时 S2AMissWhy 给拒因。</summary>
        internal bool S2ATestMatchesTexture(int stageIndex, int handle, int cbufSlot, in Image.TextureDescriptor descriptor)
        {
            S2AMissWhy = null;
            return MatchesTexture(GetTextureSpecState(stageIndex, handle, cbufSlot), descriptor);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static bool MatchesTexture(Box<TextureSpecializationState> specializationState, in Image.TextureDescriptor descriptor)
        {
            if (specializationState != null)
            {
                if ((specializationState.Value.QueriedFlags & QueriedTextureStateFlags.CoordNormalized) == QueriedTextureStateFlags.CoordNormalized &&
                    specializationState.Value.CoordNormalized != descriptor.UnpackTextureCoordNormalized())
                {
                    S2AMissWhy = "贴图坐标归一化"; return false;
                }

                // S2A：翻译时查询过采样器类型（QuerySamplerType）的，类型不同就不能复用。上游不比：上游缓存条目都由同一游戏运行时翻译，类型天然一致；
                // 出包离线烘焙拿不到运行时描述符，按缺省 Texture1D 翻（10-20 动森全屏后处理顶点着色器把二维参数贴图当一维采样，远景景深失效）
                if ((specializationState.Value.QueriedFlags & QueriedTextureStateFlags.SamplerType) == QueriedTextureStateFlags.SamplerType &&
                    specializationState.Value.TextureTarget.ConvertSamplerType() != descriptor.UnpackTextureTarget().ConvertSamplerType())
                {
                    S2AMissWhy = "贴图类型"; return false;
                }

                // S2A：只查询过「是不是贴图缓冲」的，只比这一位（TEX / TLDS 一维；翻出的代码只取决于它）
                if ((specializationState.Value.QueriedFlags & QueriedTextureStateFlags.S2ASamplerIsBuffer) == QueriedTextureStateFlags.S2ASamplerIsBuffer &&
                    (specializationState.Value.TextureTarget == TextureTarget.TextureBuffer) != (descriptor.UnpackTextureTarget() == TextureTarget.TextureBuffer))
                {
                    S2AMissWhy = "贴图是否缓冲"; return false;
                }
            }

            return true;
        }

        /// <summary>
        /// Checks if the recorded texture state for a given texture binding matches a texture descriptor.
        /// </summary>
        /// <param name="stage">The shader stage</param>
        /// <param name="index">The texture index</param>
        /// <param name="descriptor">Texture descriptor</param>
        /// <returns>True if the state matches, false otherwise</returns>
        public bool MatchesTexture(ShaderStage stage, int index, in Image.TextureDescriptor descriptor)
        {
            Box<TextureSpecializationState> specializationState = _textureByBinding[(int)stage][index];

            return MatchesTexture(specializationState, descriptor);
        }

        /// <summary>
        /// Checks if the recorded texture state for a given image binding matches a texture descriptor.
        /// </summary>
        /// <param name="stage">The shader stage</param>
        /// <param name="index">The texture index</param>
        /// <param name="descriptor">Texture descriptor</param>
        /// <returns>True if the state matches, false otherwise</returns>
        public bool MatchesImage(ShaderStage stage, int index, in Image.TextureDescriptor descriptor)
        {
            Box<TextureSpecializationState> specializationState = _imageByBinding[(int)stage][index];

            return MatchesTexture(specializationState, descriptor);
        }

        /// <summary>
        /// Populates pipeline state that doesn't exist in older caches with default values
        /// based on specialization state.
        /// </summary>
        /// <param name="pipelineState">Pipeline state to prepare</param>
        private void PreparePipelineState(ref ProgramPipelineState pipelineState)
        {
            if (!_compute)
            {
                pipelineState.DepthMode = GraphicsState.DepthMode ? DepthMode.MinusOneToOne : DepthMode.ZeroToOne;
            }
        }

        /// <summary>
        /// Reads shader specialization state that has been serialized.
        /// </summary>
        /// <param name="dataReader">Data reader</param>
        /// <returns>Shader specialization state</returns>
        public static ShaderSpecializationState Read(ref BinarySerializer dataReader)
        {
            ShaderSpecializationState specState = new();

            dataReader.Read(ref specState._queriedState);
            dataReader.Read(ref specState._compute);

            if (specState._compute)
            {
                dataReader.ReadWithMagicAndSize(ref specState.ComputeState, ComsMagic);
            }
            else
            {
                dataReader.ReadWithMagicAndSize(ref specState.GraphicsState, GfxsMagic);
            }

            dataReader.Read(ref specState._constantBufferUsePerStage);

            int constantBufferUsePerStageMask = specState._constantBufferUsePerStage;

            Span<uint> constantBufferUseSpan = specState.ConstantBufferUse.AsSpan();
            
            while (constantBufferUsePerStageMask != 0)
            {
                int index = BitOperations.TrailingZeroCount(constantBufferUsePerStageMask);
                dataReader.Read(ref constantBufferUseSpan[index]);
                constantBufferUsePerStageMask &= ~(1 << index);
            }

            bool hasPipelineState = false;

            dataReader.Read(ref hasPipelineState);

            if (hasPipelineState)
            {
                ProgramPipelineState pipelineState = default;
                dataReader.ReadWithMagicAndSize(ref pipelineState, PgpsMagic);

                specState.PreparePipelineState(ref pipelineState);
                specState.PipelineState = pipelineState;
            }

            if ((specState._queriedState & QueriedStateFlags.TransformFeedback) == QueriedStateFlags.TransformFeedback)
            {
                ushort tfCount = 0;
                dataReader.Read(ref tfCount);
                specState.TransformFeedbackDescriptors = new TransformFeedbackDescriptor[tfCount];

                for (int index = 0; index < tfCount; index++)
                {
                    dataReader.ReadWithMagicAndSize(ref specState.TransformFeedbackDescriptors[index], TfbdMagic);
                }
            }

            ushort count = 0;
            dataReader.Read(ref count);

            for (int index = 0; index < count; index++)
            {
                TextureKey textureKey = default;
                Box<TextureSpecializationState> textureState = new();

                dataReader.ReadWithMagicAndSize(ref textureKey, TexkMagic);
                dataReader.ReadWithMagicAndSize(ref textureState.Value, TexsMagic);

                specState._textureSpecialization[textureKey] = textureState;
            }

            if ((specState._queriedState & QueriedStateFlags.TextureArrayFromBuffer) == QueriedStateFlags.TextureArrayFromBuffer)
            {
                dataReader.Read(ref count);

                for (int index = 0; index < count; index++)
                {
                    TextureKey textureKey = default;
                    int length = 0;

                    dataReader.ReadWithMagicAndSize(ref textureKey, TexkMagic);
                    dataReader.Read(ref length);

                    specState._textureArrayFromBufferSpecialization[textureKey] = length;
                }
            }

            if ((specState._queriedState & QueriedStateFlags.TextureArrayFromPool) == QueriedStateFlags.TextureArrayFromPool)
            {
                dataReader.Read(ref count);

                for (int index = 0; index < count; index++)
                {
                    bool textureKey = default;
                    int length = 0;

                    dataReader.ReadWithMagicAndSize(ref textureKey, TexkMagic);
                    dataReader.Read(ref length);

                    specState._textureArrayFromPoolSpecialization[textureKey] = length;
                }
            }

            if ((specState._queriedState & QueriedStateFlags.S2AUsageTracked) != 0) dataReader.Read(ref specState._s2aAttrRead);   // S2A：有使用记录才多一个 uint（旧条目照旧可读）

            return specState;
        }

        /// <summary>
        /// Serializes the shader specialization state.
        /// </summary>
        /// <param name="dataWriter">Data writer</param>
        public void Write(ref BinarySerializer dataWriter)
        {
            dataWriter.Write(ref _queriedState);
            dataWriter.Write(ref _compute);

            if (_compute)
            {
                dataWriter.WriteWithMagicAndSize(ref ComputeState, ComsMagic);
            }
            else
            {
                dataWriter.WriteWithMagicAndSize(ref GraphicsState, GfxsMagic);
            }

            dataWriter.Write(ref _constantBufferUsePerStage);

            int constantBufferUsePerStageMask = _constantBufferUsePerStage;
            
            Span<uint> constantBufferUseSpan = ConstantBufferUse.AsSpan();

            while (constantBufferUsePerStageMask != 0)
            {
                int index = BitOperations.TrailingZeroCount(constantBufferUsePerStageMask);
                dataWriter.Write(ref constantBufferUseSpan[index]);
                constantBufferUsePerStageMask &= ~(1 << index);
            }

            bool hasPipelineState = PipelineState.HasValue;

            dataWriter.Write(ref hasPipelineState);

            if (hasPipelineState)
            {
                ProgramPipelineState pipelineState = PipelineState.Value;
                dataWriter.WriteWithMagicAndSize(ref pipelineState, PgpsMagic);
            }

            if ((_queriedState & QueriedStateFlags.TransformFeedback) == QueriedStateFlags.TransformFeedback)
            {
                ushort tfCount = (ushort)TransformFeedbackDescriptors.Length;
                dataWriter.Write(ref tfCount);

                for (int index = 0; index < TransformFeedbackDescriptors.Length; index++)
                {
                    dataWriter.WriteWithMagicAndSize(ref TransformFeedbackDescriptors[index], TfbdMagic);
                }
            }

            ushort count = (ushort)_textureSpecialization.Count;
            dataWriter.Write(ref count);

            foreach (KeyValuePair<TextureKey, Box<TextureSpecializationState>> kv in _textureSpecialization)
            {
                TextureKey textureKey = kv.Key;
                Box<TextureSpecializationState> textureState = kv.Value;

                dataWriter.WriteWithMagicAndSize(ref textureKey, TexkMagic);
                dataWriter.WriteWithMagicAndSize(ref textureState.Value, TexsMagic);
            }

            if ((_queriedState & QueriedStateFlags.TextureArrayFromBuffer) == QueriedStateFlags.TextureArrayFromBuffer)
            {
                count = (ushort)_textureArrayFromBufferSpecialization.Count;
                dataWriter.Write(ref count);

                foreach (KeyValuePair<TextureKey, int> kv in _textureArrayFromBufferSpecialization)
                {
                    TextureKey textureKey = kv.Key;
                    int length = kv.Value;

                    dataWriter.WriteWithMagicAndSize(ref textureKey, TexkMagic);
                    dataWriter.Write(ref length);
                }
            }

            if ((_queriedState & QueriedStateFlags.TextureArrayFromPool) == QueriedStateFlags.TextureArrayFromPool)
            {
                count = (ushort)_textureArrayFromPoolSpecialization.Count;
                dataWriter.Write(ref count);

                foreach (KeyValuePair<bool, int> kv in _textureArrayFromPoolSpecialization)
                {
                    bool textureKey = kv.Key;
                    int length = kv.Value;

                    dataWriter.WriteWithMagicAndSize(ref textureKey, TexkMagic);
                    dataWriter.Write(ref length);
                }
            }

            if ((_queriedState & QueriedStateFlags.S2AUsageTracked) != 0) dataWriter.Write(ref _s2aAttrRead);   // S2A
        }

        // S2A: 离线批量翻译（ryu_judge --shbake，10-19）统计已有缓存里的缺省值用：只读导出纹理登记与查询标记
        internal byte S2ACbUsePerStage => _constantBufferUsePerStage;
        internal IEnumerable<(int Stage, int Handle, int Slot, uint Format, bool Srgb, TextureTarget Target, bool Norm, int Queried)> S2ATextures()
        {
            foreach (var kv in _textureSpecialization)
            {
                TextureSpecializationState t = kv.Value.Value;
                yield return (kv.Key.StageIndex, kv.Key.Handle, kv.Key.CbufSlot, t.Format, t.FormatSrgb, t.TextureTarget, t.CoordNormalized, (int)t.QueriedFlags);
            }
        }
        internal IEnumerable<(bool IsSampler, int Length)> S2AArrayFromPool()
        {
            foreach (var kv in _textureArrayFromPoolSpecialization) yield return (kv.Key, kv.Value);
        }
        internal IEnumerable<(int Stage, int Slot, int Length)> S2AArrayFromBuffer()
        {
            foreach (var kv in _textureArrayFromBufferSpecialization) yield return (kv.Key.StageIndex, kv.Key.CbufSlot, kv.Value);
        }

        // S2A: 特化评估记录（渲染线 10-18，只读，不改逻辑）：把本程序进键的全部状态按「字段=值」写成一行，供 S2ASpecLog 落盘统计
        internal string S2ADescribe()
        {
            var sb = new System.Text.StringBuilder();
            if (_compute)
            {
                ref GpuChannelComputeState c = ref ComputeState;
                sb.Append($"local={c.LocalSizeX}x{c.LocalSizeY}x{c.LocalSizeZ}\tsmem={c.SharedMemorySize}\tlmem={c.LocalMemorySize}\tunaligned={c.HasUnalignedStorageBuffer}");
            }
            else
            {
                ref GpuChannelGraphicsState g = ref GraphicsState;
                sb.Append($"early_z={g.EarlyZForce}\ttopology={g.Topology}\ttess={g.TessellationMode.Packed}\ta2c={g.AlphaToCoverageEnable}\ta2c_dither={g.AlphaToCoverageDitherEnable}");
                sb.Append($"\tvp_disable={g.ViewportTransformDisable}\tdepth_mode={g.DepthMode}\tprog_psize={g.ProgramPointSizeEnable}\tpsize={g.PointSize}");
                sb.Append($"\talpha_test={g.AlphaTestEnable}\talpha_op={g.AlphaTestCompare}\talpha_ref={g.AlphaTestReference}");
                sb.Append("\tattr=");
                for (int i = 0; i < 32; i++) sb.Append((int)g.AttributeTypes[i]).Append(i < 31 ? "," : "");
                sb.Append("\tfout=");
                for (int i = 0; i < 8; i++) sb.Append((int)g.FragmentOutputTypes[i]).Append(i < 7 ? "," : "");
                sb.Append($"\tcbdp={g.HasConstantBufferDrawParameters}\tunaligned={g.HasUnalignedStorageBuffer}\tdual_src={g.DualSourceBlendEnable}\tyneg={g.YNegateEnabled}");
                sb.Append($"\ttfb={(TransformFeedbackDescriptors?.Length ?? 0)}");
            }
            sb.Append("\ttex=");
            foreach (var kv in _textureSpecialization)
            {
                TextureSpecializationState t = kv.Value.Value;
                sb.Append($"{kv.Key.StageIndex}:{kv.Key.Handle:X}:{kv.Key.CbufSlot}=");
                if ((t.QueriedFlags & QueriedTextureStateFlags.TextureFormat) != 0) sb.Append($"f{t.Format}{(t.FormatSrgb ? "s" : "")}");
                if ((t.QueriedFlags & QueriedTextureStateFlags.SamplerType) != 0) sb.Append($"t{(int)t.TextureTarget}");
                if ((t.QueriedFlags & QueriedTextureStateFlags.S2ASamplerIsBuffer) != 0) sb.Append($"b{(t.TextureTarget == TextureTarget.TextureBuffer ? 1 : 0)}");
                if ((t.QueriedFlags & QueriedTextureStateFlags.CoordNormalized) != 0) sb.Append($"n{(t.CoordNormalized ? 1 : 0)}");
                sb.Append(';');
            }
            sb.Append($"\tarr_buf={_textureArrayFromBufferSpecialization.Count}\tarr_pool={_textureArrayFromPoolSpecialization.Count}");
            sb.Append((_queriedState & QueriedStateFlags.S2AUsageTracked) != 0 ? $"\tused=a2c:{((_queriedState & QueriedStateFlags.S2AA2cRead) != 0 ? 1 : 0)},depth:{((_queriedState & QueriedStateFlags.S2ADepthRead) != 0 ? 1 : 0)},cbdp:{((_queriedState & QueriedStateFlags.S2ACbdpRead) != 0 ? 1 : 0)},attr:{_s2aAttrRead:X8}{((_queriedState & QueriedStateFlags.S2AUsageV2) != 0 ? $",v2:{((uint)(_queriedState & QueriedStateFlags.S2AReadMask) >> 13):X2}" : "")}" : "\tused=无记录");   // S2A：翻译读过的状态（缓存匹配只比这些）
            return sb.ToString();
        }

        // ================= S2A（10-21 画面·着色器线 spec）：包内 / 磁盘缓存条目首次命中时的全字段核对 =================
        // 上游 MatchesGraphics / MatchesCompute 只比一部分翻译读过的状态（上游假设缓存条目来自同一运行时）；出包离线烘焙取不到的字段落缺省值，
        // 包内条目与运行时不符却静默上屏（10-20 动森远景景深 = 采样器类型、怪猎脸黑 = 计算共享内存）。这里在条目首次被命中时，把「翻译读过、匹配不比」的
        // 每个字段与运行时真值逐一核对：不符 → 条目作废（之后查找跳过它，走现翻）、报红；相符 → 记下，之后不再核（不进每次绘制的路径，稳态零分配）。
        // 只比翻译真读过的（使用记录位 / 纹理查询标记 / 登记过的数组长度 / 读过的 c1 长度），比的是翻译器看到的值（换算后的拓扑、格式等），避免误杀。
        private int _s2aDiskIndex = -1;
        // 0 未核，1 相符，2 不符（作废）
        private byte _s2aVerdict;

        /// <summary>S2A：标记本条目来自磁盘缓存（含出包种入的包内条目），programIndex = 缓存里的程序序号（= 出包 programs.tsv 的 idx 列）</summary>
        internal void S2AMarkLoaded(int programIndex) => _s2aDiskIndex = programIndex;

        /// <summary>S2A：首次命中时核对过且与运行时不符的条目（查找时跳过）</summary>
        internal bool S2ARejected => _s2aVerdict == 2;

        // S2A（10-24）：片元输出类型只比片元着色器写到的渲染目标。翻译器只给写到的目标（OmapTargets，双源混合另写 1 号）声明输出、只在那里读输出类型
        //   （ShaderDefinitions.GetFragmentOutputColorType），没写的目标是什么类型翻出来都一样；原先整组 8 个比，同一份着色器画进「没写的槽绑着整数目标」的帧缓冲就判不符、
        //   现翻一份逐字节相同的（10-24 xc3 冷局加载段：条目 0,0,0,0,0,0,0,0 对运行时 0,0,0,2,0,0,0,0 / 0,0,2,0,… 等，Mac 冷局 200 秒 122 支首遇现编的主因）。
        //   -1 = 不知道写了哪些（没有片元阶段信息），整组比；0 = 没有片元着色器，不比
        private int _s2aFoutTargets = -1;

        private static int S2AWrittenTargets(CachedShaderStage[] stages)
        {
            if (stages.Length <= 5)
            {
                return -1;
            }

            CachedShaderStage fs = stages[5];

            if (fs == null)
            {
                return 0;
            }

            if (fs.Info == null || fs.Info.FragmentOutputMap < 0)
            {
                return -1;
            }

            int mask = 0;

            for (int rt = 0; rt < 8; rt++)
            {
                if ((fs.Info.FragmentOutputMap >> (rt * 4) & 0xf) != 0)
                {
                    mask |= 1 << rt;
                }
            }

            return mask;
        }

        internal bool S2AFoutMatches(ref GpuChannelGraphicsState graphicsState)
        {
            int written = _s2aFoutTargets;

            if (written >= 0 && GraphicsState.DualSourceBlendEnable)
            {
                written |= 1 << 1;   // 双源混合：翻译器另给 1 号目标写 0（Translator.InitializeOutputs）
            }

            for (int rt = 0; rt < 8; rt++)
            {
                if ((written < 0 || (written >> rt & 1) != 0) && graphicsState.FragmentOutputTypes[rt] != GraphicsState.FragmentOutputTypes[rt])
                {
                    return false;
                }
            }

            return true;
        }

        /// <summary>S2A：按需实化的宿主程序补查到链接失败（DiskCacheHostStorage.S2AProcessPendingLink）：作废，查找时跳过</summary>
        internal void S2ARejectLink() => _s2aVerdict = 2;

        /// <summary>S2A：来自磁盘缓存、还没核对过</summary>
        internal bool S2ANeedsVerify => _s2aDiskIndex >= 0 && _s2aVerdict == 0;

        internal int S2ADiskIndex => _s2aDiskIndex;

        /// <summary>S2A：一处不符（字段名、条目里的值、运行时的值）</summary>
        internal readonly record struct S2ASpecMismatch(string Field, string Entry, string Runtime);

        // 计算着色器的局部 / 共享内存：翻译按 4 字节向上取整声明数组、≤0 用缺省大小，比声明出来的那个
        private static int S2AMemWords(int size) => size <= 0 ? -1 : (size + 3) / 4;

        // 绑定数组长度：翻译取 Math.Max(BindlessToArray.MinimumArrayLength = 2, 查询值)，比取整后的
        private static int S2AArrayLen(int length) => Math.Max(2, length);

        private bool S2ARead(QueriedStateFlags bit, bool conservative) =>
            (_queriedState & QueriedStateFlags.S2AUsageV2) != 0 ? (_queriedState & bit) != 0 : conservative;

        /// <summary>
        /// S2A：按运行时真值核对本条目翻译读过、但 MatchesGraphics / MatchesCompute 不比的字段；不符的逐项追加到 mismatches，返回不符项数，并记下结论（之后不再核）。
        /// 图形：早期深度、输入拓扑、四边形折半图元号、曲面细分模式、点大小、变换反馈；计算：线程组尺寸、局部 / 共享内存大小；
        /// 两者：查询过格式的贴图的格式、按常量缓冲 / 贴图池 / 采样器池算的绑定数组长度、常量缓冲 1 数据（翻译读过的那段）。
        /// 没有第二代使用记录的旧条目：早期深度 / 曲面 / 点大小按「对应阶段在就算读过」（与翻译器实际读取条件相同），局部 / 共享内存按读过，
        /// 输入拓扑只认上游的几何阶段标记，折半图元号不比（读取条件依赖片元着色器是否读图元号，旧记录里没有）。
        /// </summary>
        internal int S2AVerify(S2ASpecRuntime rt, CachedShaderStage[] shaders, bool isVulkan, bool supportsQuads, List<S2ASpecMismatch> mismatches)
        {
            int n0 = mismatches.Count;

            if (_compute)
            {
                GpuChannelComputeState c = ComputeState, r = rt.Compute;
                if (c.LocalSizeX != r.LocalSizeX || c.LocalSizeY != r.LocalSizeY || c.LocalSizeZ != r.LocalSizeZ)
                {
                    mismatches.Add(new("ComputeLocalSize", $"{c.LocalSizeX}x{c.LocalSizeY}x{c.LocalSizeZ}", $"{r.LocalSizeX}x{r.LocalSizeY}x{r.LocalSizeZ}"));
                }

                if (S2ARead(QueriedStateFlags.S2ALocalMemRead, true) && S2AMemWords(c.LocalMemorySize) != S2AMemWords(r.LocalMemorySize))
                {
                    mismatches.Add(new("ComputeLocalMemorySize", c.LocalMemorySize.ToString(), r.LocalMemorySize.ToString()));
                }

                if (S2ARead(QueriedStateFlags.S2ASharedMemRead, true) && S2AMemWords(c.SharedMemorySize) != S2AMemWords(r.SharedMemorySize))
                {
                    mismatches.Add(new("ComputeSharedMemorySize", c.SharedMemorySize.ToString(), r.SharedMemorySize.ToString()));
                }
            }
            else
            {
                bool hasVs = shaders.Length > 1 && shaders[1] != null;
                bool hasTes = shaders.Length > 3 && shaders[3] != null;
                bool hasGs = shaders.Length > 4 && shaders[4] != null;
                bool hasFs = shaders.Length > 5 && shaders[5] != null;

                // 与 GpuAccessor.QueryGraphicsState 同一换算：比翻译器看到的值
                GpuGraphicsState e = GraphicsState.CreateShaderGraphicsState(!isVulkan, supportsQuads, hasGs, isVulkan || GraphicsState.YNegateEnabled);
                GpuGraphicsState g = rt.Graphics.CreateShaderGraphicsState(!isVulkan, supportsQuads, hasGs, isVulkan || rt.Graphics.YNegateEnabled);

                if (S2ARead(QueriedStateFlags.S2AEarlyZRead, hasFs) && e.EarlyZForce != g.EarlyZForce)
                {
                    mismatches.Add(new("EarlyZForce", e.EarlyZForce.ToString(), g.EarlyZForce.ToString()));
                }

                if ((S2ARead(QueriedStateFlags.S2ATopologyRead, false) || IsPrimitiveTopologyQueried()) && e.Topology != g.Topology)
                {
                    mismatches.Add(new("Topology", $"{e.Topology}（{GraphicsState.Topology}）", $"{g.Topology}（{rt.Graphics.Topology}）"));
                }

                if (S2ARead(QueriedStateFlags.S2AHalvePrimRead, false) && e.HalvePrimitiveId != g.HalvePrimitiveId)
                {
                    mismatches.Add(new("HalvePrimitiveId", $"{e.HalvePrimitiveId}（{GraphicsState.Topology}）", $"{g.HalvePrimitiveId}（{rt.Graphics.Topology}）"));
                }

                if (S2ARead(QueriedStateFlags.S2ATessRead, hasTes) && (e.TessCw != g.TessCw || e.TessPatchType != g.TessPatchType || e.TessSpacing != g.TessSpacing))
                {
                    mismatches.Add(new("TessellationMode", $"{e.TessPatchType}/{e.TessSpacing}/cw={e.TessCw}", $"{g.TessPatchType}/{g.TessSpacing}/cw={g.TessCw}"));
                }

                if (S2ARead(QueriedStateFlags.S2APointSizeRead, hasVs) && BitConverter.SingleToInt32Bits(e.PointSize) != BitConverter.SingleToInt32Bits(g.PointSize))
                {
                    mismatches.Add(new("PointSize", e.PointSize.ToString("R"), g.PointSize.ToString("R")));
                }

                // 变换反馈：顶点管线最后一级翻译时总查「开没开」，开了再读各缓冲的步长与变量位置
                TransformFeedbackDescriptor[] et = TransformFeedbackDescriptors, gt = rt.TransformFeedback;
                if ((et != null) != (gt != null))
                {
                    mismatches.Add(new("TransformFeedback", et != null ? "开" : "关", gt != null ? "开" : "关"));
                }
                else if (et != null)
                {
                    for (int i = 0; i < et.Length && i < gt.Length; i++)
                    {
                        if (et[i].BufferIndex != gt[i].BufferIndex || et[i].Stride != gt[i].Stride || !et[i].AsSpan().SequenceEqual(gt[i].AsSpan()))
                        {
                            mismatches.Add(new($"TransformFeedback[{i}]", $"buf{et[i].BufferIndex}/stride{et[i].Stride}/n{et[i].VaryingCount}", $"buf{gt[i].BufferIndex}/stride{gt[i].Stride}/n{gt[i].VaryingCount}"));
                            break;
                        }
                    }
                }
            }

            // 查询过格式的贴图（QueryTextureFormat：无格式图像读写 / 原子 / snorm 归一化），比换算后的翻译器格式
            foreach (KeyValuePair<TextureKey, Box<TextureSpecializationState>> kv in _textureSpecialization)
            {
                TextureSpecializationState t = kv.Value.Value;
                if ((t.QueriedFlags & QueriedTextureStateFlags.TextureFormat) == 0)
                {
                    continue;
                }

                Image.TextureDescriptor d = rt.GetTextureDescriptor(kv.Key.StageIndex, kv.Key.Handle, kv.Key.CbufSlot);
                TextureFormat ef = GpuAccessorBase.ConvertToTextureFormat(t.Format, t.FormatSrgb), gf = GpuAccessorBase.ConvertToTextureFormat(d.UnpackFormat(), d.UnpackSrgb());
                if (ef != gf)
                {
                    mismatches.Add(new($"TextureFormat[{kv.Key.StageIndex}:{kv.Key.Handle:X}:{kv.Key.CbufSlot}]", ef.ToString(), gf.ToString()));
                }
            }

            foreach (KeyValuePair<TextureKey, int> kv in _textureArrayFromBufferSpecialization)
            {
                int g = S2AArrayLen(rt.UniformBufferSize(kv.Key.StageIndex, kv.Key.CbufSlot) / Constants.TextureHandleSizeInBytes);
                if (S2AArrayLen(kv.Value) != g)
                {
                    mismatches.Add(new($"TextureArrayFromBuffer[{kv.Key.StageIndex}:c{kv.Key.CbufSlot}]", S2AArrayLen(kv.Value).ToString(), g.ToString()));
                }
            }

            foreach (KeyValuePair<bool, int> kv in _textureArrayFromPoolSpecialization)
            {
                int g = S2AArrayLen(kv.Key ? rt.SamplerPoolLength : rt.TexturePoolLength);
                if (S2AArrayLen(kv.Value) != g)
                {
                    mismatches.Add(new(kv.Key ? "SamplerArrayFromPool" : "TextureArrayFromPool", S2AArrayLen(kv.Value).ToString(), g.ToString()));
                }
            }

            // 常量缓冲 1（翻译读来解间接跳转表；条目里存的就是翻译读过的那段）：顶点 A / B 都读第 0 阶段的 c1，其余阶段读本阶段的
            for (int i = 0; i < shaders.Length; i++)
            {
                byte[] e1 = shaders[i]?.Cb1Data;
                if (e1 == null || e1.Length == 0)
                {
                    continue;
                }

                int stage = _compute ? 0 : Math.Max(i - 1, 0);
                if (!rt.TryGetCb1(stage, e1.Length, out ReadOnlySpan<byte> g1))
                {
                    continue;
                }

                int at = e1.AsSpan().CommonPrefixLength(g1);
                if (at < e1.Length)
                {
                    mismatches.Add(new($"Cb1Data[{(_compute ? "cs" : S2AStageNames[i])}]",
                        $"+0x{at:X}={S2AWord(e1, at)}（共 {e1.Length} 字节）", at < g1.Length ? $"+0x{at:X}={S2AWord(g1, at)}" : $"只有 {g1.Length} 字节"));
                }
            }

            int bad = mismatches.Count - n0;
            _s2aVerdict = bad == 0 ? (byte)1 : (byte)2;
            return bad;
        }

        private static readonly string[] S2AStageNames = { "vs_a", "vs", "tcs", "tes", "gs", "fs" };

        // 报红：每个字段前 S2AReportExamples 个不符程序逐行列出（每程序每字段只核一次，所以每行都是该程序该字段的首例），之后只在累计数到 2 的幂时打一行累计
        internal const int S2AReportExamples = 16;
        private static readonly Dictionary<string, int> _s2aMismatchCount = new();

        /// <summary>S2A：已核对的条目数（相符 / 不符）与各字段累计不符程序数（单测 / 健康表读）</summary>
        internal static int S2AVerifiedOk, S2AVerifiedBad;
        internal static int S2AMismatchCount(string field) { lock (_s2aMismatchCount) return _s2aMismatchCount.TryGetValue(field, out int n) ? n : 0; }

        /// <summary>S2A：一行红（格式固定，健康表 / 单测按它数）。fromPack = 程序序号落在出包种入的那段（否则是运行时追加进磁盘缓存的）</summary>
        internal static string S2AFormatRed(S2ASpecMismatch m, int programIndex, bool compute, bool fromPack) =>
            $"[gal] 【红】{(fromPack ? "包内" : "缓存")}特化不符：{m.Field} 程序 #{programIndex}（{(compute ? "计算" : "图形")}） {(fromPack ? "包内" : "缓存")}={m.Entry} 运行时={m.Runtime}";

        /// <summary>S2A：核对结果入账并按上面的规则打红；返回实际打出的行（单测看）</summary>
        internal static void S2AReport(List<S2ASpecMismatch> mismatches, int programIndex, bool compute, bool fromPack, Action<string> sink)
        {
            if (mismatches.Count == 0) S2AVerifiedOk++; else S2AVerifiedBad++;
            // 射程：已核条目数到 2 的幂打一行（信息，非红），局里据此知道核了多少、分母多少
            int done = S2AVerifiedOk + S2AVerifiedBad;
            if ((done & (done - 1)) == 0) sink($"[gal] 包内特化核对：已核 {done} 个磁盘缓存条目（相符 {S2AVerifiedOk}、不符 {S2AVerifiedBad}）");
            if (mismatches.Count == 0) return;
            foreach (S2ASpecMismatch m in mismatches)
            {
                int br = m.Field.IndexOf('[');
                string key = br < 0 ? m.Field : m.Field[..br];
                int n;
                lock (_s2aMismatchCount) { _s2aMismatchCount.TryGetValue(key, out n); _s2aMismatchCount[key] = ++n; }
                if (n <= S2AReportExamples) sink(S2AFormatRed(m, programIndex, compute, fromPack));
                else if ((n & (n - 1)) == 0) sink($"[gal] 【红】{(fromPack ? "包内" : "缓存")}特化不符：{key} 累计 {n} 个程序（前 {S2AReportExamples} 例已逐行列出，之后只计数）");
            }
        }

        private static string S2AWord(ReadOnlySpan<byte> b, int at) => b.Length - (at & ~3) >= 4 ? $"{BitConverter.ToUInt32(b[(at & ~3)..]):X8}" : $"{b[at]:X2}";
    }

    /// <summary>
    /// S2A：包内条目核对用的运行时真值（ShaderSpecializationState.S2AVerify）。由 ShaderCache 在条目首次命中时按当前通道状态填（一个实例复用），单测按假值填。
    /// </summary>
    internal abstract class S2ASpecRuntime
    {
        public GpuChannelGraphicsState Graphics;
        public GpuChannelComputeState Compute;
        public TransformFeedbackDescriptor[] TransformFeedback;
        public int TexturePoolLength;
        public int SamplerPoolLength;

        /// <summary>翻译时 GpuAccessor 会读到的贴图描述符（池里无效 id 时同样给缺省描述符）</summary>
        public abstract Image.TextureDescriptor GetTextureDescriptor(int stageIndex, int handle, int cbufSlot);

        /// <summary>stageIndex 阶段 slot 号常量缓冲当前绑定的字节数（计算忽略 stageIndex）</summary>
        public abstract int UniformBufferSize(int stageIndex, int slot);

        /// <summary>stageIndex 阶段常量缓冲 1 开头 size 字节；没绑定返回 false（核不了，不判不符）</summary>
        public abstract bool TryGetCb1(int stageIndex, int size, out ReadOnlySpan<byte> data);
    }
}
