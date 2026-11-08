using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System;
using System.Collections.Generic;
using System.Linq;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Translation.Transforms
{
    class TexturePass : ITransformPass
    {
        public static bool IsEnabled(IGpuAccessor gpuAccessor, ShaderStage stage, TargetLanguage targetLanguage, FeatureFlags usedFeatures)
        {
            return true;
        }

        public static LinkedListNode<INode> RunPass(TransformContext context, LinkedListNode<INode> node)
        {
            if (node.Value is TextureOperation texOp)
            {
                if (texOp.SamplerBinding >= 0)
                {
                    bool textureArray = context.ResourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage: false);
                    bool samplerArray = context.ResourceManager.IsArrayOfTexturesOrImages(new(texOp.SamplerSet, texOp.SamplerBinding), isImage: false);
                    if (!textureArray || !samplerArray)
                    {
                        throw new InvalidOperationException("Separate texture and sampler must both be indexed arrays.");
                    }
                }
                bool exactSizeTable = context.GpuAccessor.QueryHostSupportsTextureSizeTable();
                node = InsertTexelFetchScale(context.Hfm, node, context.ResourceManager, context.Stage, exactSizeTable);
                node = InsertTextureSizeUnscale(context.Hfm, node, context.ResourceManager, context.Stage, exactSizeTable);

                if (texOp.Inst == Instruction.TextureSample)
                {
                    node = InsertCoordNormalization(context.Hfm, node, context.ResourceManager, context.GpuAccessor, context.Stage);
                    node = InsertCoordGatherBias(node, context.ResourceManager, context.GpuAccessor);
                    node = InsertConstOffsets(node, context.ResourceManager, context.GpuAccessor, context.Stage);

                    if (texOp.Type == SamplerType.TextureBuffer && !context.GpuAccessor.QueryHostSupportsSnormBufferTextureFormat())
                    {
                        node = InsertSnormNormalization(node, context.ResourceManager, context.GpuAccessor);
                    }
                }
            }

            return node;
        }

        private static LinkedListNode<INode> InsertTexelFetchScale(
            HelperFunctionManager hfm,
            LinkedListNode<INode> node,
            ResourceManager resourceManager,
            ShaderStage stage,
            bool exactSizeTable = false)
        {
            TextureOperation texOp = (TextureOperation)node.Value;

            bool isBindless = (texOp.Flags & TextureFlags.Bindless) != 0;
            bool intCoords = (texOp.Flags & TextureFlags.IntCoords) != 0;

            bool isImage = IsImageInstructionWithScale(texOp.Inst);
            bool isIndexed = resourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage);

            if ((texOp.Inst == Instruction.TextureSample || isImage) &&
                (intCoords || isImage) &&
                !isBindless &&
                !isIndexed &&
                stage.SupportsRenderScale &&
                TypeSupportsScale(texOp.Type))
            {
                int functionId = hfm.GetOrCreateFunctionId(exactSizeTable ? HelperFunctionName.TexelFetchScaleExact : HelperFunctionName.TexelFetchScale);
                int samplerIndex = isImage
                    ? resourceManager.GetTextureDescriptors(includeArrays: false).Length + resourceManager.FindImageDescriptorIndex(new(texOp.Set, texOp.Binding))
                    : resourceManager.FindTextureDescriptorIndex(new(texOp.Set, texOp.Binding));

                int coordsCount = texOp.Type.Dimensions;
                int coordsIndex = isBindless ? 1 : 0;

                int lodIndex = coordsIndex + coordsCount
                    + ((texOp.Type & SamplerType.Array) != 0 ? 1 : 0)
                    + ((texOp.Type & SamplerType.Shadow) != 0 ? 1 : 0)
                    + ((texOp.Flags & TextureFlags.Derivatives) != 0 ? coordsCount * 2 : 0);
                // A multisample operand is a sample index, never a mip level.
                Operand lod = exactSizeTable && !isImage && (texOp.Type & SamplerType.Multisample) == 0 && (texOp.Flags & TextureFlags.LodLevel) != 0
                    ? texOp.GetSource(lodIndex) : Const(0);

                for (int index = 0; index < coordsCount; index++)
                {
                    int componentFunctionId = !exactSizeTable && index == 1 && stage == ShaderStage.Fragment
                        ? hfm.GetOrCreateFunctionId(HelperFunctionName.TexelFetchScaleY) : functionId;
                    Operand scaledCoord = Local();
                    Operand[] callArgs;

                    if (exactSizeTable)
                    {
                        callArgs = [Const(functionId), texOp.GetSource(coordsIndex + index), Const(samplerIndex), Const(index), lod, Const(SupportBuffer.TextureSizeTableAbi)];
                    }
                    else if (stage == ShaderStage.Fragment)
                    {
                        callArgs = [Const(componentFunctionId), texOp.GetSource(coordsIndex + index), Const(samplerIndex), Const(index)
                        ];
                    }
                    else
                    {
                        callArgs = [Const(functionId), texOp.GetSource(coordsIndex + index), Const(samplerIndex)];
                    }

                    node.List.AddBefore(node, new Operation(Instruction.Call, 0, scaledCoord, callArgs));

                    texOp.SetSource(coordsIndex + index, scaledCoord);
                }
            }

            return node;
        }

        private static LinkedListNode<INode> InsertTextureSizeUnscale(
            HelperFunctionManager hfm,
            LinkedListNode<INode> node,
            ResourceManager resourceManager,
            ShaderStage stage,
            bool exactSizeTable = false)
        {
            TextureOperation texOp = (TextureOperation)node.Value;

            bool isBindless = (texOp.Flags & TextureFlags.Bindless) != 0;
            bool isIndexed = resourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage: false);

            if (texOp.Inst == Instruction.TextureQuerySize &&
                texOp.Index < 2 &&
                !isBindless &&
                !isIndexed &&
                stage.SupportsRenderScale &&
                TypeSupportsScale(texOp.Type))
            {
                int functionId = hfm.GetOrCreateFunctionId(exactSizeTable ? HelperFunctionName.TextureSizeExact : HelperFunctionName.TextureSizeUnscale);
                int samplerIndex = resourceManager.FindTextureDescriptorIndex(new(texOp.Set, texOp.Binding));

                for (int index = texOp.DestsCount - 1; index >= 0; index--)
                {
                    // Queries may return width/height together with array layers,
                    // depth, or the number of mip levels. Only W/H use this ABI.
                    if (exactSizeTable && texOp.Index + index >= 2)
                    {
                        continue;
                    }

                    Operand dest = texOp.GetDest(index);

                    Operand unscaledSize = Local();

                    // Replace all uses with the unscaled size value.
                    // This must be done before the call is added, since it also is a use of the original size.
                    foreach (INode useOp in dest.UseOps)
                    {
                        for (int srcIndex = 0; srcIndex < useOp.SourcesCount; srcIndex++)
                        {
                            if (useOp.GetSource(srcIndex) == dest)
                            {
                                useOp.SetSource(srcIndex, unscaledSize);
                            }
                        }
                    }

                    int componentFunctionId = !exactSizeTable && index == 1 && stage == ShaderStage.Fragment
                        ? hfm.GetOrCreateFunctionId(HelperFunctionName.TextureSizeUnscaleY) : functionId;
                    Operand lod = exactSizeTable && (texOp.Type & SamplerType.Multisample) == 0 ? texOp.GetSource(0) : Const(0);
                    Operand[] callArgs = exactSizeTable
                        ? [Const(functionId), dest, Const(samplerIndex), Const(texOp.Index + index), lod]
                        : [Const(componentFunctionId), dest, Const(samplerIndex)];

                    node.List.AddAfter(node, new Operation(Instruction.Call, 0, unscaledSize, callArgs));
                }
            }

            return node;
        }

        private static LinkedListNode<INode> InsertCoordNormalization(
            HelperFunctionManager hfm,
            LinkedListNode<INode> node,
            ResourceManager resourceManager,
            IGpuAccessor gpuAccessor,
            ShaderStage stage)
        {
            // Emulate non-normalized coordinates by normalizing the coordinates on the shader.
            // Without normalization, the coordinates are expected to the in the [0, W or H] range,
            // and otherwise, it is expected to be in the [0, 1] range.
            // We normalize by dividing the coords by the texture size.

            TextureOperation texOp = (TextureOperation)node.Value;

            bool isBindless = (texOp.Flags & TextureFlags.Bindless) != 0;
            bool isIndexed = resourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage: false);

            if (isBindless || isIndexed || !resourceManager.TryGetCbufSlotAndHandleForTexture(new(texOp.Set, texOp.Binding), out int cbufSlot, out int handle))
            {
                return node;
            }

            bool intCoords = (texOp.Flags & TextureFlags.IntCoords) != 0;

            if (gpuAccessor.QueryS2ARuntimeState() && !intCoords && SupportBuffer.S2ATexUnnormBit(texOp.Binding) >= 0)
            {
                return S2AInsertCoordNormalizationRuntime(hfm, node, resourceManager, stage, texOp, gpuAccessor.QueryHostSupportsTextureSizeTable());
            }

            // S2A：整数坐标（texelFetch 一类）不做归一化换算，不用查——原版先查后返回，查询白白进特化状态，核对时按这张贴图的归一化位判不符重翻
            //   （10-21 晚真机首遇重翻拒因：暗黑2「贴图坐标归一化」90 次、八方2 54 次，含计算着色器）。翻出的代码不变
            if (intCoords)
            {
                return node;
            }

            bool isCoordNormalized = gpuAccessor.QueryTextureCoordNormalized(handle, cbufSlot);

            if (isCoordNormalized)
            {
                return node;
            }

            int coordsCount = texOp.Type.Dimensions;

            int normCoordsCount = (texOp.Type & SamplerType.Mask) == SamplerType.TextureCube ? 2 : coordsCount;

            for (int index = 0; index < normCoordsCount; index++)
            {
                Operand coordSize = Local();

                Operand[] texSizeSources = [Const(0)];

                LinkedListNode<INode> textureSizeNode = node.List.AddBefore(node, new TextureOperation(
                    Instruction.TextureQuerySize,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags,
                    texOp.Set,
                    texOp.Binding,
                    index,
                    [coordSize],
                    texSizeSources));

                resourceManager.SetUsageFlagsForTextureQuery(new(texOp.Set, texOp.Binding), texOp.Type);

                Operand source = texOp.GetSource(index);

                Operand coordNormalized = Local();

                node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Divide, coordNormalized, source, GenerateI2f(node, coordSize)));

                texOp.SetSource(index, coordNormalized);

                InsertTextureSizeUnscale(hfm, textureSizeNode, resourceManager, stage, gpuAccessor.QueryHostSupportsTextureSizeTable());
            }

            return node;
        }

        // S2A：坐标是否归一化运行时化——支持缓冲 s2a_flags.yzw 按贴图绑定号一位（Gpu 层逐次绑定按贴图描述符填，置位 = 非归一化坐标），
        // 除数 = 置位 ? 贴图尺寸 : 1。不查询 QueryTextureCoordNormalized（不进特化状态、匹配不比），一份客体代码一个程序
        private static LinkedListNode<INode> S2AInsertCoordNormalizationRuntime(HelperFunctionManager hfm, LinkedListNode<INode> node, ResourceManager resourceManager, ShaderStage stage, TextureOperation texOp, bool exactSizeTable)
        {
            int pos = SupportBuffer.S2ATexUnnormBit(texOp.Binding);
            Operand lane = Local(), shifted = Local(), bit = Local(), on = Local();
            node.List.AddBefore(node, new Operation(Instruction.Load, StorageKind.ConstantBuffer, lane, Const(SupportBuffer.Binding), Const((int)SupportBufferField.S2AFlags), Const(1 + pos / 32)));
            node.List.AddBefore(node, new Operation(Instruction.ShiftRightU32, shifted, lane, Const(pos % 32)));
            node.List.AddBefore(node, new Operation(Instruction.BitwiseAnd, bit, shifted, Const(1)));
            node.List.AddBefore(node, new Operation(Instruction.CompareNotEqual, on, bit, Const(0)));

            int coordsCount = texOp.Type.Dimensions;
            int normCoordsCount = (texOp.Type & SamplerType.Mask) == SamplerType.TextureCube ? 2 : coordsCount;

            for (int index = 0; index < normCoordsCount; index++)
            {
                Operand coordSize = Local();
                LinkedListNode<INode> textureSizeNode = node.List.AddBefore(node, new TextureOperation(
                    Instruction.TextureQuerySize, texOp.Type, texOp.Format, texOp.Flags, texOp.Set, texOp.Binding, index, [coordSize], [Const(0)]));
                resourceManager.SetUsageFlagsForTextureQuery(new(texOp.Set, texOp.Binding), texOp.Type);

                Operand divisor = Local(), coordNormalized = Local();
                node.List.AddBefore(node, new Operation(Instruction.ConditionalSelect, divisor, on, GenerateI2f(node, coordSize), ConstF(1.0f)));
                node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Divide, coordNormalized, texOp.GetSource(index), divisor));
                texOp.SetSource(index, coordNormalized);

                InsertTextureSizeUnscale(hfm, textureSizeNode, resourceManager, stage, exactSizeTable);
            }

            return node;
        }

        private static LinkedListNode<INode> InsertCoordGatherBias(LinkedListNode<INode> node, ResourceManager resourceManager, IGpuAccessor gpuAccessor)
        {
            // The gather behavior when the coordinate sits right in the middle of two texels is not well defined.
            // To ensure the correct texel is sampled, we add a small bias value to the coordinate.
            // This value is calculated as the minimum value required to change the texel it will sample from,
            // and is 0 if the host does not require the bias.

            TextureOperation texOp = (TextureOperation)node.Value;

            bool isBindless = (texOp.Flags & TextureFlags.Bindless) != 0;
            bool isGather = (texOp.Flags & TextureFlags.Gather) != 0;

            int gatherBiasPrecision = gpuAccessor.QueryHostGatherBiasPrecision();

            if (!isGather || gatherBiasPrecision == 0)
            {
                return node;
            }

            bool isIndexed = resourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage: false);

            int coordsCount = texOp.Type.Dimensions;
            int coordsIndex = ResourceSourceCount(resourceManager, texOp, isBindless, isIndexed);

            int normCoordsCount = (texOp.Type & SamplerType.Mask) == SamplerType.TextureCube ? 2 : coordsCount;

            for (int index = 0; index < normCoordsCount; index++)
            {
                Operand coordSize = Local();
                Operand scaledSize = Local();
                Operand bias = Local();

                Operand[] texSizeSources;

                texSizeSources = new Operand[coordsIndex + 1];
                for (int sourceIndex = 0; sourceIndex < coordsIndex; sourceIndex++)
                {
                    texSizeSources[sourceIndex] = texOp.GetSource(sourceIndex);
                }
                texSizeSources[coordsIndex] = Const(0);

                node.List.AddBefore(node, CopySamplerBinding(texOp, new TextureOperation(
                    Instruction.TextureQuerySize,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags,
                    texOp.Set,
                    texOp.Binding,
                    index,
                    [coordSize],
                    texSizeSources)));
                if (!isBindless)
                {
                    resourceManager.SetUsageFlagsForTextureQuery(new(texOp.Set, texOp.Binding), texOp.Type);
                }

                node.List.AddBefore(node, new Operation(
                    Instruction.FP32 | Instruction.Multiply,
                    scaledSize,
                    GenerateI2f(node, coordSize),
                    ConstF((float)(1 << (gatherBiasPrecision + 1)))));
                node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Divide, bias, ConstF(1f), scaledSize));

                Operand source = texOp.GetSource(coordsIndex + index);

                Operand coordBiased = Local();

                node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Add, coordBiased, source, bias));

                texOp.SetSource(coordsIndex + index, coordBiased);
            }

            return node;
        }

        private static int ResourceSourceCount(ResourceManager resourceManager, TextureOperation texOp, bool isBindless, bool isIndexed)
        {
            int count = isBindless || isIndexed ? 1 : 0;
            if (texOp.SamplerBinding >= 0 && resourceManager.IsArrayOfTexturesOrImages(new(texOp.SamplerSet, texOp.SamplerBinding), isImage: false))
            {
                count++;
            }
            return count;
        }

        private static TextureOperation CopySamplerBinding(TextureOperation source, TextureOperation destination)
        {
            if (source.SamplerBinding >= 0)
            {
                destination.TurnIntoArray(new(source.Set, source.Binding), new(source.SamplerSet, source.SamplerBinding));
            }
            return destination;
        }

        private static LinkedListNode<INode> InsertConstOffsets(LinkedListNode<INode> node, ResourceManager resourceManager, IGpuAccessor gpuAccessor, ShaderStage stage)
        {
            // Non-constant texture offsets are not allowed (according to the spec),
            // however some GPUs does support that.
            // For GPUs where it is not supported, we can replace the instruction with the following:
            // For texture*Offset, we replace it by texture*, and add the offset to the P coords.
            // The offset can be calculated as offset / textureSize(lod), where lod = textureQueryLod(coords).
            // For texelFetchOffset, we replace it by texelFetch and add the offset to the P coords directly.
            // For textureGatherOffset, we split the operation into up to 4 operations, one for each component
            // that is accessed, where each textureGather operation has a different offset for each pixel.

            TextureOperation texOp = (TextureOperation)node.Value;

            bool hasOffset = (texOp.Flags & TextureFlags.Offset) != 0;
            bool hasOffsets = (texOp.Flags & TextureFlags.Offsets) != 0;

            bool needsOffsetsEmulation = hasOffsets && !gpuAccessor.QueryHostSupportsTextureGatherOffsets();

            // S2Arm: SPIR-V ConstOffsets only takes constants, so four per-texel gather offsets that are runtime values cannot be expressed natively
            // on any host; treat them as invalid here and let the constant check below keep the constant case native (upstream emitted an
            // OpConstantComposite of non-constant ids, i.e. invalid SPIR-V).
            bool hasInvalidOffset = needsOffsetsEmulation || hasOffsets || (hasOffset && !gpuAccessor.QueryHostSupportsNonConstantTextureOffset());

            bool isBindless = (texOp.Flags & TextureFlags.Bindless) != 0;

            if (!hasInvalidOffset)
            {
                return node;
            }

            bool isGather = (texOp.Flags & TextureFlags.Gather) != 0;
            bool hasDerivatives = (texOp.Flags & TextureFlags.Derivatives) != 0;
            bool intCoords = (texOp.Flags & TextureFlags.IntCoords) != 0;
            bool hasLodBias = (texOp.Flags & TextureFlags.LodBias) != 0;
            bool hasLodLevel = (texOp.Flags & TextureFlags.LodLevel) != 0;

            bool isArray = (texOp.Type & SamplerType.Array) != 0;
            bool isMultisample = (texOp.Type & SamplerType.Multisample) != 0;
            bool isShadow = (texOp.Type & SamplerType.Shadow) != 0;

            int coordsCount = texOp.Type.Dimensions;

            int offsetsCount;

            if (hasOffsets)
            {
                offsetsCount = coordsCount * 4;
            }
            else if (hasOffset)
            {
                offsetsCount = coordsCount;
            }
            else
            {
                offsetsCount = 0;
            }

            bool isIndexed = resourceManager.IsArrayOfTexturesOrImages(new(texOp.Set, texOp.Binding), isImage: false);

            Operand[] offsets = new Operand[offsetsCount];
            Operand[] sources = new Operand[texOp.SourcesCount - offsetsCount];

            int copyCount = ResourceSourceCount(resourceManager, texOp, isBindless, isIndexed);

            Operand[] lodSources = new Operand[copyCount + coordsCount];

            for (int index = 0; index < lodSources.Length; index++)
            {
                lodSources[index] = texOp.GetSource(index);
            }

            copyCount += coordsCount;

            if (isArray)
            {
                copyCount++;
            }

            if (isShadow)
            {
                copyCount++;
            }

            if (hasDerivatives)
            {
                copyCount += coordsCount * 2;
            }

            if (isMultisample)
            {
                copyCount++;
            }
            else if (hasLodLevel)
            {
                copyCount++;
            }

            int srcIndex = 0;
            int dstIndex = 0;

            for (int index = 0; index < copyCount; index++)
            {
                sources[dstIndex++] = texOp.GetSource(srcIndex++);
            }
            Operand explicitLod = hasLodLevel && !isMultisample ? sources[copyCount - 1] : null;

            bool areAllOffsetsConstant = true;

            for (int index = 0; index < offsetsCount; index++)
            {
                Operand offset = texOp.GetSource(srcIndex++);

                areAllOffsetsConstant &= offset.Type == OperandType.Constant;

                offsets[index] = offset;
            }

            if (!needsOffsetsEmulation)
            {
                hasInvalidOffset &= !areAllOffsetsConstant;

                if (!hasInvalidOffset)
                {
                    return node;
                }
            }

            if (hasLodBias)
            {
                sources[dstIndex++] = texOp.GetSource(srcIndex++);
            }

            if (isGather && !isShadow)
            {
                sources[dstIndex++] = texOp.GetSource(srcIndex++);
            }

            int coordsIndex = ResourceSourceCount(resourceManager, texOp, isBindless, isIndexed);

            int componentIndex = texOp.Index;

            Operand[] dests = new Operand[texOp.DestsCount];

            for (int i = 0; i < texOp.DestsCount; i++)
            {
                dests[i] = texOp.GetDest(i);
            }

            Operand[] resourceSources = new Operand[coordsIndex];
            Array.Copy(sources, resourceSources, coordsIndex);

            LinkedListNode<INode> oldNode = node;

            if (isGather && !isShadow && hasOffsets)
            {
                Operand[] newSources = new Operand[sources.Length];

                sources.CopyTo(newSources, 0);

                Operand[] texSizes = InsertTextureBaseSize(node, texOp, resourceManager, resourceSources, coordsCount);

                int destIndex = 0;

                for (int compIndex = 0; compIndex < 4; compIndex++)
                {
                    if (((texOp.Index >> compIndex) & 1) == 0)
                    {
                        continue;
                    }

                    for (int index = 0; index < coordsCount; index++)
                    {
                        Operand offset = Local();

                        Operand intOffset = offsets[index + compIndex * coordsCount];

                        node.List.AddBefore(node, new Operation(
                            Instruction.FP32 | Instruction.Divide,
                            offset,
                            GenerateI2f(node, intOffset),
                            GenerateI2f(node, texSizes[index])));

                        Operand source = sources[coordsIndex + index];

                        Operand coordPlusOffset = Local();

                        node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Add, coordPlusOffset, source, offset));

                        newSources[coordsIndex + index] = coordPlusOffset;
                    }

                    TextureOperation newTexOp = new(
                        Instruction.TextureSample,
                        texOp.Type,
                        texOp.Format,
                        texOp.Flags & ~(TextureFlags.Offset | TextureFlags.Offsets),
                        texOp.Set,
                        texOp.Binding,
                        1 << 3, // W component: i=0, j=0
                        [dests[destIndex++]],
                        newSources);

                    node = node.List.AddBefore(node, CopySamplerBinding(texOp, newTexOp));
                }
            }
            else
            {
                if (intCoords)
                {
                    for (int index = 0; index < coordsCount; index++)
                    {
                        Operand source = sources[coordsIndex + index];

                        Operand coordPlusOffset = Local();

                        node.List.AddBefore(node, new Operation(Instruction.Add, coordPlusOffset, source, offsets[index]));

                        sources[coordsIndex + index] = coordPlusOffset;
                    }
                }
                else
                {
                    Operand[] texSizes = isGather
                        ? InsertTextureBaseSize(node, texOp, resourceManager, resourceSources, coordsCount)
                        : InsertTextureLod(node, texOp, resourceManager, lodSources, resourceSources, explicitLod, coordsCount, stage);

                    for (int index = 0; index < coordsCount; index++)
                    {
                        Operand offset = Local();

                        Operand intOffset = offsets[index];

                        node.List.AddBefore(node, new Operation(
                            Instruction.FP32 | Instruction.Divide,
                            offset,
                            GenerateI2f(node, intOffset),
                            GenerateI2f(node, texSizes[index])));

                        Operand source = sources[coordsIndex + index];

                        Operand coordPlusOffset = Local();

                        node.List.AddBefore(node, new Operation(Instruction.FP32 | Instruction.Add, coordPlusOffset, source, offset));

                        sources[coordsIndex + index] = coordPlusOffset;
                    }
                }

                TextureOperation newTexOp = new(
                    Instruction.TextureSample,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags & ~(TextureFlags.Offset | TextureFlags.Offsets),
                    texOp.Set,
                    texOp.Binding,
                    componentIndex,
                    dests,
                    sources);

                node = node.List.AddBefore(node, CopySamplerBinding(texOp, newTexOp));
            }

            node.List.Remove(oldNode);

            for (int index = 0; index < texOp.SourcesCount; index++)
            {
                texOp.SetSource(index, null);
            }

            return node;
        }

        private static Operand[] InsertTextureBaseSize(
            LinkedListNode<INode> node,
            TextureOperation texOp,
            ResourceManager resourceManager,
            Operand[] resourceSources,
            int coordsCount)
        {
            Operand[] texSizes = new Operand[coordsCount];

            for (int index = 0; index < coordsCount; index++)
            {
                texSizes[index] = Local();

                Operand[] texSizeSources;

                texSizeSources = [.. resourceSources, Const(0)];

                node.List.AddBefore(node, CopySamplerBinding(texOp, new TextureOperation(
                    Instruction.TextureQuerySize,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags,
                    texOp.Set,
                    texOp.Binding,
                    index,
                    [texSizes[index]],
                    texSizeSources)));
                if (!texOp.Flags.HasFlag(TextureFlags.Bindless))
                {
                    resourceManager.SetUsageFlagsForTextureQuery(new(texOp.Set, texOp.Binding), texOp.Type);
                }
            }

            return texSizes;
        }

        private static Operand[] InsertTextureLod(
            LinkedListNode<INode> node,
            TextureOperation texOp,
            ResourceManager resourceManager,
            Operand[] lodSources,
            Operand[] resourceSources,
            Operand explicitLod,
            int coordsCount,
            ShaderStage stage)
        {
            Operand[] texSizes = new Operand[coordsCount];

            Operand lod;

            if (explicitLod != null)
            {
                lod = explicitLod;
            }
            else if (stage == ShaderStage.Fragment)
            {
                lod = Local();

                node.List.AddBefore(node, CopySamplerBinding(texOp, new TextureOperation(
                    Instruction.Lod,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags,
                    texOp.Set,
                    texOp.Binding,
                    0,
                    [lod],
                    lodSources)));
            }
            else
            {
                lod = Const(0);
            }

            for (int index = 0; index < coordsCount; index++)
            {
                texSizes[index] = Local();

                Operand[] texSizeSources;

                texSizeSources = [.. resourceSources, GenerateF2i(node, lod)];

                node.List.AddBefore(node, CopySamplerBinding(texOp, new TextureOperation(
                    Instruction.TextureQuerySize,
                    texOp.Type,
                    texOp.Format,
                    texOp.Flags,
                    texOp.Set,
                    texOp.Binding,
                    index,
                    [texSizes[index]],
                    texSizeSources)));
                if (!texOp.Flags.HasFlag(TextureFlags.Bindless))
                {
                    resourceManager.SetUsageFlagsForTextureQuery(new(texOp.Set, texOp.Binding), texOp.Type);
                }
            }

            return texSizes;
        }

        private static LinkedListNode<INode> InsertSnormNormalization(LinkedListNode<INode> node, ResourceManager resourceManager, IGpuAccessor gpuAccessor)
        {
            TextureOperation texOp = (TextureOperation)node.Value;

            // We can't query the format of a bindless texture,
            // because the handle is unknown, it can have any format.
            if (texOp.Flags.HasFlag(TextureFlags.Bindless) || !resourceManager.TryGetCbufSlotAndHandleForTexture(new(texOp.Set, texOp.Binding), out int cbufSlot, out int handle))
            {
                return node;
            }

            TextureFormat format = gpuAccessor.QueryTextureFormat(handle, cbufSlot);

            int maxPositive = format switch
            {
                TextureFormat.R8Snorm => sbyte.MaxValue,
                TextureFormat.R8G8Snorm => sbyte.MaxValue,
                TextureFormat.R8G8B8A8Snorm => sbyte.MaxValue,
                TextureFormat.R16Snorm => short.MaxValue,
                TextureFormat.R16G16Snorm => short.MaxValue,
                TextureFormat.R16G16B16A16Snorm => short.MaxValue,
                _ => 0,
            };

            // The value being 0 means that the format is not a SNORM format,
            // so there's nothing to do here.
            if (maxPositive == 0)
            {
                return node;
            }

            // Do normalization. We assume SINT formats are being used
            // as replacement for SNORM (which is not supported).
            for (int i = 0; i < texOp.DestsCount; i++)
            {
                Operand dest = texOp.GetDest(i);

                INode[] uses = dest.UseOps.ToArray();

                Operation convOp = new(Instruction.ConvertS32ToFP32, Local(), dest);
                Operation normOp = new(Instruction.FP32 | Instruction.Multiply, Local(), convOp.Dest, ConstF(1f / maxPositive));

                node = node.List.AddAfter(node, convOp);
                node = node.List.AddAfter(node, normOp);

                foreach (INode useOp in uses)
                {
                    if (useOp is not Operation op)
                    {
                        continue;
                    }

                    // Replace all uses of the texture pixel value with the normalized value.
                    for (int index = 0; index < op.SourcesCount; index++)
                    {
                        if (op.GetSource(index) == dest)
                        {
                            op.SetSource(index, normOp.Dest);
                        }
                    }
                }
            }

            return node;
        }

        private static Operand GenerateI2f(LinkedListNode<INode> node, Operand value)
        {
            Operand res = Local();

            node.List.AddBefore(node, new Operation(Instruction.ConvertS32ToFP32, res, value));

            return res;
        }

        private static Operand GenerateF2i(LinkedListNode<INode> node, Operand value)
        {
            Operand res = Local();

            node.List.AddBefore(node, new Operation(Instruction.ConvertFP32ToS32, res, value));

            return res;
        }

        private static bool IsImageInstructionWithScale(Instruction inst)
        {
            // Currently, we don't support scaling images that are modified,
            // so we only need to care about the load instruction.
            return inst == Instruction.ImageLoad;
        }

        private static bool TypeSupportsScale(SamplerType type)
        {
            return (type & SamplerType.Mask) == SamplerType.Texture2D;
        }
    }
}
