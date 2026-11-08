using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System;
using System.Collections.Generic;
using System.Numerics;

namespace Ryujinx.Graphics.Shader.Translation
{
    class ShaderDefinitions
    {
        private readonly GpuGraphicsState _graphicsState;

        public ShaderStage Stage { get; }

        public int ComputeLocalSizeX { get; }
        public int ComputeLocalSizeY { get; }
        public int ComputeLocalSizeZ { get; }

        // S2A：曲面模式读了就记（上游缓存匹配不比曲面模式：同一 TES / TCS 换了域照样命中旧翻译，画成错的域；离线烘焙没有参考局时按缺省状态翻，更会撞上）
        public bool TessCw { get { S2ATessRead = true; return _graphicsState.TessCw; } }
        public TessPatchType TessPatchType { get { S2ATessRead = true; return _graphicsState.TessPatchType; } }
        public TessSpacing TessSpacing { get { S2ATessRead = true; return _graphicsState.TessSpacing; } }
        public bool S2ATessRead;

        // S2A（10-19 出包线）：记下这次翻译实际读了哪些特化状态，缓存匹配只比读过的（ShaderSpecializationState.MatchesGraphics）；原版无条件比 a2c 抖动与全部 32 个属性类型，
        // 同一份翻译结果因没读过的字段不同而未命中、运行时现翻（动森首局现翻 8 支：代码全同，只差 a2c_dither / 未用位置的属性类型）
        public bool S2AA2cRead, S2ADepthRead, S2AAlphaRead;
        // S2A（10-21）：其余翻译读了才比的状态（S2AStateRead.EarlyZ / Topology / HalvePrim / PointSize；Tess 见上，0099）
        public bool S2AEarlyZRead, S2ATopologyRead, S2AHalvePrimRead, S2APointSizeRead;
        public uint S2AAttrIntUse, S2AAttrSintUse;   // S2A：顶点属性读出值进了整数运算的位置 / 其中有带符号用法的（Transforms/S2AAttrIntUse，离线烘焙器出整数类别变体用）
        public uint S2AAttrRead;
        // S2A（10-21 画面·着色器线）：顶点输入按原始位读（TranslatorContext.Translate 设：宿主顶点自取 + NXGAL_VPULL 不为 0 + 非顶点转计算）。
        // 硬件语义：顶点取数单元按格式把数据转成寄存器位（浮点 / unorm / snorm / scaled → 浮点位，int / uint → 整数位），着色器指令再按自己的类型解释；
        // 宿主自取解码（graphics/metal/gal_vpull.m s2a_vr）照此产出原始位，于是翻译结果与属性类型无关：不读 AttributeTypes、不进特化比较（S2AAttrRead 不记）
        public bool S2AVertexRaw;
        // S2A：Ampere（Switch 2 NVN2，TranslationFlags.Ampere）代码；只为 Ampere 生效的共用遍（GotoElimination / BindlessToArray / GlobalToStorage 里 参考实现 的改动）看它，Maxwell 路径行为不变
        public bool Ampere;
        public bool S2AIsRawInput(int location, bool isOutput) => S2AVertexRaw && Stage == ShaderStage.Vertex && !isOutput && !IaIndexing;
        public bool AlphaToCoverageDitherEnable { get { S2AA2cRead = true; return _graphicsState.AlphaToCoverageEnable && _graphicsState.AlphaToCoverageDitherEnable; } }
        public bool ViewportTransformDisable => _graphicsState.ViewportTransformDisable;

        public bool DepthMode { get { S2ADepthRead = true; return _graphicsState.DepthMode; } }   // S2A：运行时化后不再读（EmitterContext），读了才进匹配

        public float PointSize { get { S2APointSizeRead = true; return _graphicsState.PointSize; } }

        public AlphaTestOp AlphaTestCompare { get { S2AAlphaRead = true; return _graphicsState.AlphaTestCompare; } }   // S2A：读了才进匹配（比较方式 / 参考值）
        public float AlphaTestReference { get { S2AAlphaRead = true; return _graphicsState.AlphaTestReference; } }
        public bool S2AAlphaTestEnabled => _graphicsState.AlphaTestCompare != AlphaTestOp.Always;   // S2A：运行时化只要「开没开」（匹配仍比 AlphaTestEnable），不记读过

        public bool GpPassthrough { get; }
        public bool LastInVertexPipeline { get; set; }

        public int ThreadsPerInputPrimitive { get; private set; }

        public InputTopology InputTopology { get { S2ATopologyRead = true; return _graphicsState.Topology; } }
        public OutputTopology OutputTopology { get; }

        public int MaxOutputVertices { get; }

        public bool DualSourceBlend => _graphicsState.DualSourceBlendEnable;
        public bool EarlyZForce { get { S2AEarlyZRead = true; return _graphicsState.EarlyZForce; } }

        public bool YNegateEnabled => _graphicsState.YNegateEnabled;
        public bool OriginUpperLeft => _graphicsState.OriginUpperLeft;

        public bool HalvePrimitiveId { get { S2AHalvePrimRead = true; return _graphicsState.HalvePrimitiveId; } }

        public ImapPixelType[] ImapTypes { get; }
        public bool IaIndexing { get; private set; }
        public bool OaIndexing { get; private set; }

        public int OmapTargets { get; }
        public bool OmapSampleMask { get; }
        public bool OmapDepth { get; }

        public bool SupportsScaledVertexFormats { get; }

        public bool TransformFeedbackEnabled { get; }

        private readonly TransformFeedbackOutput[] _transformFeedbackOutputs;

        readonly struct TransformFeedbackVariable : IEquatable<TransformFeedbackVariable>
        {
            public IoVariable IoVariable { get; }
            public int Location { get; }
            public int Component { get; }

            public TransformFeedbackVariable(IoVariable ioVariable, int location = 0, int component = 0)
            {
                IoVariable = ioVariable;
                Location = location;
                Component = component;
            }

            public override bool Equals(object other)
            {
                return other is TransformFeedbackVariable tfbVar && Equals(tfbVar);
            }

            public bool Equals(TransformFeedbackVariable other)
            {
                return IoVariable == other.IoVariable &&
                    Location == other.Location &&
                    Component == other.Component;
            }

            public override int GetHashCode()
            {
                return (int)IoVariable | (Location << 8) | (Component << 16);
            }

            public override string ToString()
            {
                return $"{IoVariable}.{Location}.{Component}";
            }
        }

        private readonly Dictionary<TransformFeedbackVariable, TransformFeedbackOutput> _transformFeedbackDefinitions;

        public ShaderDefinitions(ShaderStage stage, ulong transformFeedbackVecMap, TransformFeedbackOutput[] transformFeedbackOutputs)
        {
            Stage = stage;
            TransformFeedbackEnabled = transformFeedbackOutputs != null;
            _transformFeedbackOutputs = transformFeedbackOutputs;
            _transformFeedbackDefinitions = new();

            PopulateTransformFeedbackDefinitions(transformFeedbackVecMap, transformFeedbackOutputs);
        }

        public ShaderDefinitions(
            ShaderStage stage,
            int computeLocalSizeX,
            int computeLocalSizeY,
            int computeLocalSizeZ)
        {
            Stage = stage;
            ComputeLocalSizeX = computeLocalSizeX;
            ComputeLocalSizeY = computeLocalSizeY;
            ComputeLocalSizeZ = computeLocalSizeZ;
        }

        public ShaderDefinitions(
            ShaderStage stage,
            GpuGraphicsState graphicsState,
            bool gpPassthrough,
            int threadsPerInputPrimitive,
            OutputTopology outputTopology,
            int maxOutputVertices)
        {
            Stage = stage;
            _graphicsState = graphicsState;
            GpPassthrough = gpPassthrough;
            ThreadsPerInputPrimitive = threadsPerInputPrimitive;
            OutputTopology = outputTopology;
            MaxOutputVertices = maxOutputVertices;
        }

        public ShaderDefinitions(
            ShaderStage stage,
            GpuGraphicsState graphicsState,
            bool gpPassthrough,
            int threadsPerInputPrimitive,
            OutputTopology outputTopology,
            int maxOutputVertices,
            ImapPixelType[] imapTypes,
            int omapTargets,
            bool omapSampleMask,
            bool omapDepth,
            bool supportsScaledVertexFormats,
            ulong transformFeedbackVecMap,
            TransformFeedbackOutput[] transformFeedbackOutputs)
        {
            Stage = stage;
            _graphicsState = graphicsState;
            GpPassthrough = gpPassthrough;
            ThreadsPerInputPrimitive = threadsPerInputPrimitive;
            OutputTopology = outputTopology;
            MaxOutputVertices = gpPassthrough ? graphicsState.Topology.InputVertexCountNoAdjacency : maxOutputVertices;
            S2ATopologyRead = gpPassthrough;
            ImapTypes = imapTypes;
            OmapTargets = omapTargets;
            OmapSampleMask = omapSampleMask;
            OmapDepth = omapDepth;
            LastInVertexPipeline = stage < ShaderStage.Fragment;
            SupportsScaledVertexFormats = supportsScaledVertexFormats;
            TransformFeedbackEnabled = transformFeedbackOutputs != null;
            _transformFeedbackOutputs = transformFeedbackOutputs;
            _transformFeedbackDefinitions = new();

            PopulateTransformFeedbackDefinitions(transformFeedbackVecMap, transformFeedbackOutputs);
        }

        private void PopulateTransformFeedbackDefinitions(ulong transformFeedbackVecMap, TransformFeedbackOutput[] transformFeedbackOutputs)
        {
            while (transformFeedbackVecMap != 0)
            {
                int vecIndex = BitOperations.TrailingZeroCount(transformFeedbackVecMap);

                for (int subIndex = 0; subIndex < 4; subIndex++)
                {
                    int wordOffset = vecIndex * 4 + subIndex;
                    int byteOffset = wordOffset * 4;

                    if (transformFeedbackOutputs[wordOffset].Valid)
                    {
                        IoVariable ioVariable = Instructions.AttributeMap.GetIoVariable(this, byteOffset, out int location);
                        int component = 0;

                        if (HasPerLocationInputOrOutputComponent(ioVariable, location, subIndex, isOutput: true))
                        {
                            component = subIndex;
                        }

                        TransformFeedbackVariable transformFeedbackVariable = new(ioVariable, location, component);
                        _transformFeedbackDefinitions.TryAdd(transformFeedbackVariable, transformFeedbackOutputs[wordOffset]);
                    }
                }

                transformFeedbackVecMap &= ~(1UL << vecIndex);
            }
        }

        public void EnableInputIndexing()
        {
            IaIndexing = true;
        }

        public void EnableOutputIndexing()
        {
            OaIndexing = true;
        }

        public bool TryGetTransformFeedbackOutput(IoVariable ioVariable, int location, int component, out TransformFeedbackOutput transformFeedbackOutput)
        {
            if (!HasTransformFeedbackOutputs())
            {
                transformFeedbackOutput = default;
                return false;
            }

            TransformFeedbackVariable transformFeedbackVariable = new(ioVariable, location, component);
            return _transformFeedbackDefinitions.TryGetValue(transformFeedbackVariable, out transformFeedbackOutput);
        }

        private bool HasTransformFeedbackOutputs()
        {
            return TransformFeedbackEnabled && (LastInVertexPipeline || Stage == ShaderStage.Fragment);
        }

        public bool HasTransformFeedbackOutputs(bool isOutput)
        {
            return TransformFeedbackEnabled && ((isOutput && LastInVertexPipeline) || (!isOutput && Stage == ShaderStage.Fragment));
        }

        public bool HasPerLocationInputOrOutput(IoVariable ioVariable, bool isOutput)
        {
            if (ioVariable == IoVariable.UserDefined)
            {
                return (!isOutput && !IaIndexing) || (isOutput && !OaIndexing);
            }

            return ioVariable == IoVariable.FragmentOutputColor;
        }

        public bool HasPerLocationInputOrOutputComponent(IoVariable ioVariable, int location, int component, bool isOutput)
        {
            if (ioVariable != IoVariable.UserDefined || !HasTransformFeedbackOutputs(isOutput))
            {
                return false;
            }

            return GetTransformFeedbackOutputComponents(location, component) == 1;
        }

        public TransformFeedbackOutput GetTransformFeedbackOutput(int wordOffset)
        {
            return _transformFeedbackOutputs[wordOffset];
        }

        public TransformFeedbackOutput GetTransformFeedbackOutput(int location, int component)
        {
            return GetTransformFeedbackOutput((AttributeConsts.UserAttributeBase / 4) + location * 4 + component);
        }

        public int GetTransformFeedbackOutputComponents(int location, int component)
        {
            int baseIndex = (AttributeConsts.UserAttributeBase / 4) + location * 4;
            int index = baseIndex + component;
            int count = 1;

            for (; count < 4; count++)
            {
                ref TransformFeedbackOutput prev = ref _transformFeedbackOutputs[baseIndex + count - 1];
                ref TransformFeedbackOutput curr = ref _transformFeedbackOutputs[baseIndex + count];

                int prevOffset = prev.Offset;
                int currOffset = curr.Offset;

                if (!prev.Valid || !curr.Valid || prevOffset + 4 != currOffset)
                {
                    break;
                }
            }

            if (baseIndex + count <= index)
            {
                return 1;
            }

            return count;
        }

        public AggregateType GetFragmentOutputColorType(int location)
        {
            return AggregateType.Vector4 | _graphicsState.FragmentOutputTypes[location].Aggregate;
        }

        public AggregateType GetUserDefinedType(int location, bool isOutput)
        {
            if ((!isOutput && IaIndexing) || (isOutput && OaIndexing))
            {
                return AggregateType.Array | AggregateType.Vector4 | AggregateType.FP32;
            }

            AggregateType type = AggregateType.Vector4;

            if (S2AIsRawInput(location, isOutput))
            {
                type |= AggregateType.U32;
            }
            else if (Stage == ShaderStage.Vertex && !isOutput)
            {
                S2AAttrRead |= 1u << location;
                type |= _graphicsState.AttributeTypes[location].AsAggregate(SupportsScaledVertexFormats);
            }
            else
            {
                type |= AggregateType.FP32;
            }

            return type;
        }

        public AttributeType GetAttributeType(int location)
        {
            S2AAttrRead |= 1u << location;
            return _graphicsState.AttributeTypes[location];
        }

        public bool IsAttributeSint(int location)
        {
            S2AAttrRead |= 1u << location;
            return (_graphicsState.AttributeTypes[location] & AttributeType.BaseTypeMask) == AttributeType.Sint;
        }

        public bool IsAttributeTexelDecode(int location)
        {
            S2AAttrRead |= 1u << location;
            return _graphicsState.AttributeTypes[location].HasFlag(AttributeType.TexelDecode);
        }

        public bool IsAttributePacked(int location)
        {
            S2AAttrRead |= 1u << location;
            return _graphicsState.AttributeTypes[location].HasFlag(AttributeType.Packed);
        }

        public bool IsAttributePackedRgb10A2Signed(int location)
        {
            S2AAttrRead |= 1u << location;
            return _graphicsState.AttributeTypes[location].HasFlag(AttributeType.PackedRgb10A2Signed);
        }

        public int GetGeometryOutputIndexBufferStridePerInstance(bool fixedInput = false)
        {
            // Even a strip with fewer than three vertices can be ended. Empty
            // ends are ignored by the fixed-input emitter, so at most one
            // restart per emitted vertex is needed.
            if (fixedInput) return MaxOutputVertices * 2;
            return MaxOutputVertices + OutputTopology switch
            {
                OutputTopology.LineStrip => MaxOutputVertices / 2,
                OutputTopology.TriangleStrip => MaxOutputVertices / 3,
                _ => MaxOutputVertices,
            };
        }

        public int GetGeometryOutputIndexBufferStride(bool fixedInput = false)
        {
            return GetGeometryOutputIndexBufferStridePerInstance(fixedInput) * ThreadsPerInputPrimitive;
        }
    }
}
