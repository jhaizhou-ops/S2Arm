using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.Translation;
using Spv.Generator;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using static Spv.Specification;
using SpvInstruction = Spv.Generator.Instruction;

namespace Ryujinx.Graphics.Shader.CodeGen.Spirv
{
    static class Declarations
    {
        public static void DeclareParameters(CodeGenContext context, StructuredFunction function)
        {
            DeclareParameters(context, function.InArguments, 0);
            DeclareParameters(context, function.OutArguments, function.InArguments.Length);
        }

        private static void DeclareParameters(CodeGenContext context, IEnumerable<AggregateType> argTypes, int argIndex)
        {
            foreach (AggregateType argType in argTypes)
            {
                SpvInstruction argPointerType = context.TypePointer(StorageClass.Function, context.GetType(argType));
                SpvInstruction spvArg = context.FunctionParameter(argPointerType);

                context.DeclareArgument(argIndex++, spvArg);
            }
        }

        public static void DeclareLocals(CodeGenContext context, StructuredFunction function)
        {
            foreach (AstOperand local in function.Locals)
            {
                SpvInstruction localPointerType = context.TypePointer(StorageClass.Function, context.GetType(local.VarType));
                SpvInstruction spvLocal = context.Variable(localPointerType, StorageClass.Function);

                context.AddLocalVariable(spvLocal);
                context.DeclareLocal(local, spvLocal);
            }
        }

        public static void DeclareAll(CodeGenContext context, StructuredProgramInfo info)
        {
            DeclareConstantBuffers(context, context.Properties.ConstantBuffers.Values);
            DeclareStorageBuffers(context, context.Properties.StorageBuffers.Values);
            DeclareMemories(context, context.Properties.LocalMemories, context.LocalMemories, StorageClass.Private);
            DeclareMemories(context, context.Properties.SharedMemories, context.SharedMemories, StorageClass.Workgroup);
            DeclareSamplers(context, context.Properties.Textures.Values);
            DeclareImages(context, context.Properties.Images.Values);
            DeclareInputsAndOutputs(context, info);
        }

        private static void DeclareMemories(
            CodeGenContext context,
            IReadOnlyDictionary<int, MemoryDefinition> memories,
            Dictionary<int, SpvInstruction> dict,
            StorageClass storage)
        {
            foreach ((int id, MemoryDefinition memory) in memories)
            {
                SpvInstruction type = context.GetType(memory.Type, memory.ArrayLength);
                SpvInstruction pointerType = context.TypePointer(storage, type);
                SpvInstruction variable = context.Variable(pointerType, storage, memory.ZeroInit ? context.ConstantNull(type) : null);

                context.AddGlobalVariable(variable);

                dict.Add(id, variable);
            }
        }

        private static void DeclareConstantBuffers(CodeGenContext context, IEnumerable<BufferDefinition> buffers)
        {
            DeclareBuffers(context, buffers, isBuffer: false);
        }

        private static void DeclareStorageBuffers(CodeGenContext context, IEnumerable<BufferDefinition> buffers)
        {
            DeclareBuffers(context, buffers, isBuffer: true);
        }

        private static void DeclareBuffers(CodeGenContext context, IEnumerable<BufferDefinition> buffers, bool isBuffer)
        {
            HashSet<SpvInstruction> decoratedTypes = [];

            foreach (BufferDefinition buffer in buffers)
            {
                int setIndex = context.TargetApi == TargetApi.Vulkan ? buffer.Set : 0;
                int alignment = buffer.Layout == BufferLayout.Std140 ? 16 : 4;
                int alignmentMask = alignment - 1;
                int offset = 0;

                SpvInstruction[] structFieldTypes = new SpvInstruction[buffer.Type.Fields.Length];
                int[] structFieldOffsets = new int[buffer.Type.Fields.Length];

                for (int fieldIndex = 0; fieldIndex < buffer.Type.Fields.Length; fieldIndex++)
                {
                    StructureField field = buffer.Type.Fields[fieldIndex];
                    int fieldSize = (field.Type.GetSizeInBytes() + alignmentMask) & ~alignmentMask;

                    structFieldTypes[fieldIndex] = context.GetType(field.Type, field.ArrayLength);
                    structFieldOffsets[fieldIndex] = offset;

                    if (field.Type.HasFlag(AggregateType.Array))
                    {
                        // We can't decorate the type more than once.
                        if (decoratedTypes.Add(structFieldTypes[fieldIndex]))
                        {
                            context.Decorate(structFieldTypes[fieldIndex], Decoration.ArrayStride, (LiteralInteger)fieldSize);
                        }

                        // Zero lengths are assumed to be a "runtime array" (which does not have a explicit length
                        // specified on the shader, and instead assumes the bound buffer length).
                        // It is only valid as the last struct element.

                        Debug.Assert(field.ArrayLength > 0 || fieldIndex == buffer.Type.Fields.Length - 1);

                        offset += fieldSize * field.ArrayLength;
                    }
                    else
                    {
                        offset += fieldSize;
                    }
                }

                SpvInstruction structType = context.TypeStruct(false, structFieldTypes);

                if (decoratedTypes.Add(structType))
                {
                    context.Decorate(structType, isBuffer && !context.IsSpirv15 ? Decoration.BufferBlock : Decoration.Block);

                    for (int fieldIndex = 0; fieldIndex < structFieldOffsets.Length; fieldIndex++)
                    {
                        context.MemberDecorate(structType, fieldIndex, Decoration.Offset, (LiteralInteger)structFieldOffsets[fieldIndex]);
                    }
                }

                StorageClass storageClass = isBuffer && context.IsSpirv15 ? StorageClass.StorageBuffer : StorageClass.Uniform;
                SpvInstruction pointerType = context.TypePointer(storageClass, structType);
                SpvInstruction variable = context.Variable(pointerType, storageClass);

                context.Name(variable, buffer.Name);
                context.Decorate(variable, Decoration.DescriptorSet, (LiteralInteger)setIndex);
                context.Decorate(variable, Decoration.Binding, (LiteralInteger)buffer.Binding);
                context.AddGlobalVariable(variable);

                if (isBuffer)
                {
                    if (!buffer.Flags.HasFlag(BufferUsageFlags.Write))
                    {
                        context.Decorate(variable, Decoration.NonWritable);
                    }
                    context.StorageBuffers.Add(buffer.Binding, variable);
                }
                else
                {
                    context.ConstantBuffers.Add(buffer.Binding, variable);
                }
            }
        }

        private static void DeclareSamplers(CodeGenContext context, IEnumerable<TextureDefinition> samplers)
        {
            bool cubeArrayDeclared = false;

            foreach (TextureDefinition sampler in samplers)
            {
                int setIndex = context.TargetApi == TargetApi.Vulkan ? sampler.Set : 0;

                SpvInstruction imageType;
                SpvInstruction sampledImageType;

                if (sampler.Type != SamplerType.None)
                {
                    Dim dim = (sampler.Type & SamplerType.Mask) switch
                    {
                        SamplerType.Texture1D => Dim.Dim1D,
                        SamplerType.Texture2D => Dim.Dim2D,
                        SamplerType.Texture3D => Dim.Dim3D,
                        SamplerType.TextureCube => Dim.Cube,
                        SamplerType.TextureBuffer => Dim.Buffer,
                        _ => throw new InvalidOperationException($"Invalid sampler type \"{sampler.Type & SamplerType.Mask}\"."),
                    };

                    if (!cubeArrayDeclared && dim == Dim.Cube && sampler.Type.HasFlag(SamplerType.Array))
                    {
                        context.AddCapability(Capability.SampledCubeArray);
                        cubeArrayDeclared = true;
                    }

                    imageType = context.TypeImage(
                        context.GetType(sampler.SampledType),
                        dim,
                        sampler.Type.HasFlag(SamplerType.Shadow),
                        sampler.Type.HasFlag(SamplerType.Array),
                        sampler.Type.HasFlag(SamplerType.Multisample),
                        1,
                        ImageFormat.Unknown);

                    sampledImageType = context.TypeSampledImage(imageType);
                }
                else
                {
                    imageType = sampledImageType = context.TypeSampler();
                }

                SpvInstruction sampledOrSeparateImageType = sampler.Separate ? imageType : sampledImageType;
                SpvInstruction sampledImagePointerType = context.TypePointer(StorageClass.UniformConstant, sampledOrSeparateImageType);
                SpvInstruction sampledImageArrayPointerType = sampledImagePointerType;

                if (sampler.ArrayLength == 0)
                {
                    SpvInstruction sampledImageArrayType = context.TypeRuntimeArray(sampledOrSeparateImageType);
                    sampledImageArrayPointerType = context.TypePointer(StorageClass.UniformConstant, sampledImageArrayType);
                }
                else if (sampler.ArrayLength != 1)
                {
                    SpvInstruction sampledImageArrayType = context.TypeArray(sampledOrSeparateImageType, context.Constant(context.TypeU32(), sampler.ArrayLength));
                    sampledImageArrayPointerType = context.TypePointer(StorageClass.UniformConstant, sampledImageArrayType);
                }

                SpvInstruction sampledImageVariable = context.Variable(sampledImageArrayPointerType, StorageClass.UniformConstant);

                context.Samplers.Add(new(sampler.Set, sampler.Binding), new SamplerDeclaration(
                    imageType,
                    sampledImageType,
                    sampledImagePointerType,
                    sampledImageVariable,
                    sampler.ArrayLength != 1));
                context.SamplersTypes.Add(new(sampler.Set, sampler.Binding), sampler.Type);

                context.Name(sampledImageVariable, sampler.Name);
                context.Decorate(sampledImageVariable, Decoration.DescriptorSet, (LiteralInteger)setIndex);
                context.Decorate(sampledImageVariable, Decoration.Binding, (LiteralInteger)sampler.Binding);
                context.AddGlobalVariable(sampledImageVariable);
            }
        }

        private static void DeclareImages(CodeGenContext context, IEnumerable<TextureDefinition> images)
        {
            foreach (TextureDefinition image in images)
            {
                int setIndex = context.TargetApi == TargetApi.Vulkan ? image.Set : 0;

                Dim dim = GetDim(image.Type);

                ImageFormat imageFormat = GetImageFormat(image.Format);

                // S2A：无格式（ImageFormat.Unknown）存储图像的读/写分别要求 StorageImageReadWithoutFormat /
                //   StorageImageWriteWithoutFormat，否则 spirv-val 判非法（#199）。Unknown 只在宿主支持无格式读
                //   时产出（ResourceManager 的门控一致），读 capability 随之恒可声明；写按 ImageStore 标志。
                //   写具体格式且属扩展集合（R16ui 等）时按规范补 StorageImageExtendedFormats（VUID-08737），
                //   能否真用由设备特性 shaderStorageImageExtendedFormats 决定。
                if (image.Format == TextureFormat.Unknown)
                {
                    context.AddCapability(Capability.StorageImageReadWithoutFormat);

                    if (image.Flags.HasFlag(TextureUsageFlags.ImageStore))
                    {
                        context.AddCapability(Capability.StorageImageWriteWithoutFormat);
                    }
                }
                else if (IsExtendedImageFormat(imageFormat))
                {
                    context.AddCapability(Capability.StorageImageExtendedFormats);
                }

                // S2A：Sampled Type 与 Image Format 分开（VUID-07753 同时成立）：声明格式可为 Unknown，
                //   数值型仍跟绑定视图（image.SampledType 由 ResourceManager 按描述符填）。
                SpvInstruction imageType = context.TypeImage(
                    context.GetType(image.SampledType),
                    dim,
                    image.Type.HasFlag(SamplerType.Shadow),
                    image.Type.HasFlag(SamplerType.Array),
                    image.Type.HasFlag(SamplerType.Multisample),
                    AccessQualifier.ReadWrite,
                    imageFormat);

                SpvInstruction imagePointerType = context.TypePointer(StorageClass.UniformConstant, imageType);
                SpvInstruction imageArrayPointerType = imagePointerType;

                if (image.ArrayLength == 0)
                {
                    SpvInstruction imageArrayType = context.TypeRuntimeArray(imageType);
                    imageArrayPointerType = context.TypePointer(StorageClass.UniformConstant, imageArrayType);
                }
                else if (image.ArrayLength != 1)
                {
                    SpvInstruction imageArrayType = context.TypeArray(imageType, context.Constant(context.TypeU32(), image.ArrayLength));
                    imageArrayPointerType = context.TypePointer(StorageClass.UniformConstant, imageArrayType);
                }

                SpvInstruction imageVariable = context.Variable(imageArrayPointerType, StorageClass.UniformConstant);

                context.Images.Add(new(image.Set, image.Binding), new ImageDeclaration(imageType, imagePointerType, imageVariable, image.ArrayLength != 1));

                context.Name(imageVariable, image.Name);
                context.Decorate(imageVariable, Decoration.DescriptorSet, (LiteralInteger)setIndex);
                context.Decorate(imageVariable, Decoration.Binding, (LiteralInteger)image.Binding);

                if (image.Flags.HasFlag(TextureUsageFlags.ImageCoherent))
                {
                    context.Decorate(imageVariable, Decoration.Coherent);
                }

                // S2Arm（#1165 安卓直连门槛）：没被写过的存储图像 / 存储 texel buffer 打只读标记，同存储缓冲（BufferUsageFlags.Write）。
                //   ImageStore 由 ResourceManager.GetTextureOrImageBinding 按 IsImageStore()（ImageStore 与 ImageAtomic）置位，三条绑定路径（直接、无绑定消除、无绑定转数组）都经它，
                //   同一图像多处使用时用途标志取并集：没有这一位 = 程序里没有写它的指令。Mali 顶点阶段走直连要求全部存储变量 NonWritable
                if (!image.Flags.HasFlag(TextureUsageFlags.ImageStore))
                {
                    context.Decorate(imageVariable, Decoration.NonWritable);
                }

                context.AddGlobalVariable(imageVariable);
            }
        }

        private static Dim GetDim(SamplerType type)
        {
            return (type & SamplerType.Mask) switch
            {
                SamplerType.Texture1D => Dim.Dim1D,
                SamplerType.Texture2D => Dim.Dim2D,
                SamplerType.Texture3D => Dim.Dim3D,
                SamplerType.TextureCube => Dim.Cube,
                SamplerType.TextureBuffer => Dim.Buffer,
                _ => throw new ArgumentException($"Invalid sampler type \"{type & SamplerType.Mask}\"."),
            };
        }

        // S2A：SPIR-V Image Format 中不经 StorageImageExtendedFormats 即可用的集合——spirv-val（vulkan1.2）
        //   实测之外的具体格式（R*/Rg*/Rgba16(Snorm)/Rgb10A2/Rgb10a2ui/R11fG11fB10f/R64*）全要求该 capability。
        private static bool IsExtendedImageFormat(ImageFormat format)
        {
            return format switch
            {
                ImageFormat.Unknown or
                ImageFormat.Rgba32f or ImageFormat.Rgba16f or ImageFormat.Rgba8 or ImageFormat.Rgba8Snorm or
                ImageFormat.Rgba8i or ImageFormat.Rgba8ui or ImageFormat.Rgba16i or ImageFormat.Rgba16ui or
                ImageFormat.Rgba32i or ImageFormat.Rgba32ui or
                ImageFormat.R32f or ImageFormat.R32i or ImageFormat.R32ui => false,
                _ => true,
            };
        }

        private static ImageFormat GetImageFormat(TextureFormat format)
        {
            return format switch
            {
                TextureFormat.Unknown => ImageFormat.Unknown,
                TextureFormat.R8Unorm => ImageFormat.R8,
                TextureFormat.R8Snorm => ImageFormat.R8Snorm,
                TextureFormat.R8Uint => ImageFormat.R8ui,
                TextureFormat.R8Sint => ImageFormat.R8i,
                TextureFormat.R16Float => ImageFormat.R16f,
                TextureFormat.R16Unorm => ImageFormat.R16,
                TextureFormat.R16Snorm => ImageFormat.R16Snorm,
                TextureFormat.R16Uint => ImageFormat.R16ui,
                TextureFormat.R16Sint => ImageFormat.R16i,
                TextureFormat.R32Float => ImageFormat.R32f,
                TextureFormat.R32Uint => ImageFormat.R32ui,
                TextureFormat.R32Sint => ImageFormat.R32i,
                TextureFormat.R8G8Unorm => ImageFormat.Rg8,
                TextureFormat.R8G8Snorm => ImageFormat.Rg8Snorm,
                TextureFormat.R8G8Uint => ImageFormat.Rg8ui,
                TextureFormat.R8G8Sint => ImageFormat.Rg8i,
                TextureFormat.R16G16Float => ImageFormat.Rg16f,
                TextureFormat.R16G16Unorm => ImageFormat.Rg16,
                TextureFormat.R16G16Snorm => ImageFormat.Rg16Snorm,
                TextureFormat.R16G16Uint => ImageFormat.Rg16ui,
                TextureFormat.R16G16Sint => ImageFormat.Rg16i,
                TextureFormat.R32G32Float => ImageFormat.Rg32f,
                TextureFormat.R32G32Uint => ImageFormat.Rg32ui,
                TextureFormat.R32G32Sint => ImageFormat.Rg32i,
                TextureFormat.R8G8B8A8Unorm => ImageFormat.Rgba8,
                TextureFormat.R8G8B8A8Snorm => ImageFormat.Rgba8Snorm,
                TextureFormat.R8G8B8A8Uint => ImageFormat.Rgba8ui,
                TextureFormat.R8G8B8A8Sint => ImageFormat.Rgba8i,
                TextureFormat.R16G16B16A16Float => ImageFormat.Rgba16f,
                TextureFormat.R16G16B16A16Unorm => ImageFormat.Rgba16,
                TextureFormat.R16G16B16A16Snorm => ImageFormat.Rgba16Snorm,
                TextureFormat.R16G16B16A16Uint => ImageFormat.Rgba16ui,
                TextureFormat.R16G16B16A16Sint => ImageFormat.Rgba16i,
                TextureFormat.R32G32B32A32Float => ImageFormat.Rgba32f,
                TextureFormat.R32G32B32A32Uint => ImageFormat.Rgba32ui,
                TextureFormat.R32G32B32A32Sint => ImageFormat.Rgba32i,
                TextureFormat.R10G10B10A2Unorm => ImageFormat.Rgb10A2,
                TextureFormat.R10G10B10A2Uint => ImageFormat.Rgb10a2ui,
                TextureFormat.R11G11B10Float => ImageFormat.R11fG11fB10f,
                _ => throw new ArgumentException($"Invalid texture format \"{format}\"."),
            };
        }

        private static void DeclareInputsAndOutputs(CodeGenContext context, StructuredProgramInfo info)
        {
            int firstLocation = int.MaxValue;
            var budget = new AttributeUsage.InterfaceBudget(context.AttributeUsage, context.Definitions.Stage);

            if (context.Definitions.Stage == ShaderStage.Fragment && context.Definitions.DualSourceBlend)
            {
                foreach (IoDefinition ioDefinition in info.IoDefinitions)
                {
                    if (ioDefinition.IoVariable == IoVariable.FragmentOutputColor && ioDefinition.Location < firstLocation)
                    {
                        firstLocation = ioDefinition.Location;
                    }
                }
            }

            foreach (IoDefinition ioDefinition in info.IoDefinitions)
            {
                PixelImap iq = PixelImap.Unused;

                if (context.Definitions.Stage == ShaderStage.Fragment)
                {
                    IoVariable ioVariable = ioDefinition.IoVariable;
                    if (ioVariable == IoVariable.UserDefined)
                    {
                        iq = context.Definitions.ImapTypes[ioDefinition.Location].GetFirstUsedType();
                    }
                    else
                    {
                        (_, AggregateType varType) = IoMap.GetSpirvBuiltIn(ioVariable);
                        AggregateType elemType = varType & AggregateType.ElementTypeMask;

                        if (elemType is AggregateType.S32 or AggregateType.U32)
                        {
                            iq = PixelImap.Constant;
                        }
                    }
                }
                else if (IoMap.IsPerVertexBuiltIn(ioDefinition.IoVariable))
                {
                    continue;
                }

                if (ioDefinition.StorageKind == StorageKind.Input && Instructions.LaneIdEmulated(context, ioDefinition.IoVariable))
                {
                    continue; // S2Arm: computed instead of declared (see Instructions.LaneIdEmulated)
                }

                bool isOutput = ioDefinition.StorageKind.IsOutput();
                bool isPerPatch = ioDefinition.StorageKind.IsPerPatch();

                DeclareInputOrOutput(context, ioDefinition, isOutput, isPerPatch, budget, iq, firstLocation);
            }

            DeclarePerVertexBlock(context, budget);
            budget.Validate();
        }

        private static void DeclarePerVertexBlock(CodeGenContext context, AttributeUsage.InterfaceBudget budget)
        {
            if (context.Definitions.Stage.IsVtg)
            {
                if (context.Definitions.Stage != ShaderStage.Vertex)
                {
                    SpvInstruction perVertexInputStructType = CreatePerVertexStructType(context, out _);
                    int arraySize = context.Definitions.Stage == ShaderStage.Geometry ? context.Definitions.InputTopology.InputVertexCount : 32;
                    SpvInstruction perVertexInputArrayType = context.TypeArray(perVertexInputStructType, context.Constant(context.TypeU32(), arraySize));
                    SpvInstruction perVertexInputPointerType = context.TypePointer(StorageClass.Input, perVertexInputArrayType);
                    SpvInstruction perVertexInputVariable = context.Variable(perVertexInputPointerType, StorageClass.Input);

                    context.Name(perVertexInputVariable, "gl_in");

                    context.AddGlobalVariable(perVertexInputVariable);
                    context.Inputs.Add(new IoDefinition(StorageKind.Input, IoVariable.Position), perVertexInputVariable);

                    if (context.Definitions.Stage == ShaderStage.Geometry &&
                        context.Definitions.GpPassthrough &&
                        context.HostCapabilities.SupportsGeometryShaderPassthrough)
                    {
                        context.MemberDecorate(perVertexInputStructType, 0, Decoration.PassthroughNV);
                        context.MemberDecorate(perVertexInputStructType, 1, Decoration.PassthroughNV);
                        context.MemberDecorate(perVertexInputStructType, 2, Decoration.PassthroughNV);
                    }
                }

                SpvInstruction perVertexOutputStructType = CreatePerVertexStructType(context, out int components);
                budget.Record(true, 0, 0, components, builtIn: true);

                void DecorateTfo(IoVariable ioVariable, int fieldIndex)
                {
                    if (context.Definitions.TryGetTransformFeedbackOutput(ioVariable, 0, 0, out TransformFeedbackOutput transformFeedbackOutput))
                    {
                        context.MemberDecorate(perVertexOutputStructType, fieldIndex, Decoration.XfbBuffer, (LiteralInteger)transformFeedbackOutput.Buffer);
                        context.MemberDecorate(perVertexOutputStructType, fieldIndex, Decoration.XfbStride, (LiteralInteger)transformFeedbackOutput.Stride);
                        context.MemberDecorate(perVertexOutputStructType, fieldIndex, Decoration.Offset, (LiteralInteger)transformFeedbackOutput.Offset);
                    }
                }

                DecorateTfo(IoVariable.Position, 0);
                DecorateTfo(IoVariable.PointSize, 1);
                DecorateTfo(IoVariable.ClipDistance, 2);

                SpvInstruction perVertexOutputArrayType;

                if (context.Definitions.Stage == ShaderStage.TessellationControl)
                {
                    int arraySize = context.Definitions.ThreadsPerInputPrimitive;
                    perVertexOutputArrayType = context.TypeArray(perVertexOutputStructType, context.Constant(context.TypeU32(), arraySize));
                }
                else
                {
                    perVertexOutputArrayType = perVertexOutputStructType;
                }

                SpvInstruction perVertexOutputPointerType = context.TypePointer(StorageClass.Output, perVertexOutputArrayType);
                SpvInstruction perVertexOutputVariable = context.Variable(perVertexOutputPointerType, StorageClass.Output);

                context.AddGlobalVariable(perVertexOutputVariable);
                context.Outputs.Add(new IoDefinition(StorageKind.Output, IoVariable.Position), perVertexOutputVariable);
            }
        }

        private static SpvInstruction CreatePerVertexStructType(CodeGenContext context, out int components)
        {
            const int positionLength = 4, clipLength = 8;
            // 预算沿用旧口径（含已删除的 CullDistance 1 个分量），不改变接口准入。
            components = positionLength + 1 + clipLength + 1;
            SpvInstruction vec4FloatType = context.TypeVector(context.TypeFP32(), positionLength);
            SpvInstruction floatType = context.TypeFP32();
            SpvInstruction array8FloatType = context.TypeArray(context.TypeFP32(), context.Constant(context.TypeU32(), clipLength));

            // gl_CullDistance 从未被翻译器使用；声明它会与 ClipDistance[8] 相加超出
            // maxCombinedClipAndCullDistances（8E/9000 均为 8），直接不声明。
            SpvInstruction perVertexStructType = context.TypeStruct(true, vec4FloatType, floatType, array8FloatType);

            context.Name(perVertexStructType, "gl_PerVertex");

            context.MemberName(perVertexStructType, 0, "gl_Position");
            context.MemberName(perVertexStructType, 1, "gl_PointSize");
            context.MemberName(perVertexStructType, 2, "gl_ClipDistance");

            context.Decorate(perVertexStructType, Decoration.Block);

            if (context.HostCapabilities.ReducedPrecision)
            {
                context.MemberDecorate(perVertexStructType, 0, Decoration.Invariant);
            }

            context.MemberDecorate(perVertexStructType, 0, Decoration.BuiltIn, (LiteralInteger)BuiltIn.Position);
            context.MemberDecorate(perVertexStructType, 1, Decoration.BuiltIn, (LiteralInteger)BuiltIn.PointSize);
            context.MemberDecorate(perVertexStructType, 2, Decoration.BuiltIn, (LiteralInteger)BuiltIn.ClipDistance);

            return perVertexStructType;
        }

        private static void DeclareInputOrOutput(
            CodeGenContext context,
            IoDefinition ioDefinition,
            bool isOutput,
            bool isPerPatch,
            AttributeUsage.InterfaceBudget budget,
            PixelImap iq = PixelImap.Unused,
            int firstLocation = 0)
        {
            IoVariable ioVariable = ioDefinition.IoVariable;
            StorageClass storageClass = isOutput ? StorageClass.Output : StorageClass.Input;

            bool isBuiltIn;
            BuiltIn builtIn = default;
            AggregateType varType;

            if (ioVariable == IoVariable.UserDefined)
            {
                varType = context.Definitions.GetUserDefinedType(ioDefinition.Location, isOutput);
                isBuiltIn = false;
            }
            else if (ioVariable == IoVariable.FragmentOutputColor)
            {
                varType = context.Definitions.GetFragmentOutputColorType(ioDefinition.Location);
                isBuiltIn = false;
            }
            else
            {
                (builtIn, varType) = IoMap.GetSpirvBuiltIn(ioVariable);
                isBuiltIn = true;

                if (varType == AggregateType.Invalid)
                {
                    throw new InvalidOperationException($"Unknown variable {ioVariable}.");
                }
            }

            bool hasComponent = context.Definitions.HasPerLocationInputOrOutputComponent(ioVariable, ioDefinition.Location, ioDefinition.Component, isOutput);

            if (hasComponent)
            {
                varType &= AggregateType.ElementTypeMask;
            }
            else if (ioVariable == IoVariable.UserDefined && context.Definitions.HasTransformFeedbackOutputs(isOutput))
            {
                varType &= AggregateType.ElementTypeMask;
                varType |= context.Definitions.GetTransformFeedbackOutputComponents(ioDefinition.Location, ioDefinition.Component) switch
                {
                    2 => AggregateType.Vector2,
                    3 => AggregateType.Vector3,
                    4 => AggregateType.Vector4,
                    _ => AggregateType.Invalid,
                };
            }

            int arrayLength = IoMap.GetSpirvBuiltInArrayLength(ioVariable);
            int hostLocation = ioVariable == IoVariable.UserDefined && !isPerPatch
                ? context.AttributeUsage.GetVaryingLocation(ioDefinition.Location, isOutput) : ioDefinition.Location;
            budget.Record(isOutput, hostLocation, hasComponent ? ioDefinition.Component : 0,
                AttributeUsage.InterfaceBudget.Components(varType, arrayLength), isBuiltIn);
            SpvInstruction spvType = context.GetType(varType, arrayLength);
            bool builtInPassthrough = false;

            if (!isPerPatch && IoMap.IsPerVertex(ioVariable, context.Definitions.Stage, isOutput))
            {
                int arraySize = context.Definitions.Stage == ShaderStage.Geometry ? context.Definitions.InputTopology.InputVertexCount : 32;
                spvType = context.TypeArray(spvType, context.Constant(context.TypeU32(), arraySize));

                if (context.Definitions.GpPassthrough && context.HostCapabilities.SupportsGeometryShaderPassthrough)
                {
                    builtInPassthrough = true;
                }
            }

            if (context.Definitions.Stage == ShaderStage.TessellationControl && isOutput && !isPerPatch)
            {
                spvType = context.TypeArray(spvType, context.Constant(context.TypeU32(), context.Definitions.ThreadsPerInputPrimitive));
            }

            SpvInstruction spvPointerType = context.TypePointer(storageClass, spvType);
            SpvInstruction spvVar = context.Variable(spvPointerType, storageClass);

            if (builtInPassthrough)
            {
                context.Decorate(spvVar, Decoration.PassthroughNV);
            }

            if (isBuiltIn)
            {
                if (isPerPatch)
                {
                    context.Decorate(spvVar, Decoration.Patch);
                }

                if (context.HostCapabilities.ReducedPrecision && ioVariable == IoVariable.Position)
                {
                    context.Decorate(spvVar, Decoration.Invariant);
                }

                context.Decorate(spvVar, Decoration.BuiltIn, (LiteralInteger)builtIn);
            }
            else if (isPerPatch)
            {
                context.Decorate(spvVar, Decoration.Patch);

                if (ioVariable == IoVariable.UserDefined)
                {
                    int location = context.AttributeUsage.GetPerPatchAttributeLocation(ioDefinition.Location);

                    context.Decorate(spvVar, Decoration.Location, (LiteralInteger)location);
                }
            }
            else if (ioVariable == IoVariable.UserDefined)
            {
                context.Decorate(spvVar, Decoration.Location, (LiteralInteger)hostLocation);

                // S2A：原始位顶点输入带名字标记，渲染器据此用原始位解码（graphics/metal/gal_vpull.m：成员名 s2a_raw<位置> → s2a_vr，且必须走顶点自取）
                if (context.Definitions.S2AIsRawInput(ioDefinition.Location, isOutput))
                {
                    context.Name(spvVar, $"s2a_raw{ioDefinition.Location}");
                }

                if (hasComponent)
                {
                    context.Decorate(spvVar, Decoration.Component, (LiteralInteger)ioDefinition.Component);
                }

                if (!isOutput &&
                    !isPerPatch &&
                    !builtInPassthrough &&
                    (context.AttributeUsage.PassthroughAttributes & (1 << ioDefinition.Location)) != 0 &&
                    context.HostCapabilities.SupportsGeometryShaderPassthrough)
                {
                    context.Decorate(spvVar, Decoration.PassthroughNV);
                }
            }
            else if (ioVariable == IoVariable.FragmentOutputColor)
            {
                int location = ioDefinition.Location;

                if (context.Definitions.Stage == ShaderStage.Fragment && context.Definitions.DualSourceBlend)
                {
                    int index = location - firstLocation;

                    if ((uint)index < 2)
                    {
                        context.Decorate(spvVar, Decoration.Location, (LiteralInteger)firstLocation);
                        context.Decorate(spvVar, Decoration.Index, (LiteralInteger)index);
                    }
                    else
                    {
                        context.Decorate(spvVar, Decoration.Location, (LiteralInteger)location);
                    }
                }
                else
                {
                    context.Decorate(spvVar, Decoration.Location, (LiteralInteger)location);
                }
            }

            if (!isOutput)
            {
                switch (iq)
                {
                    case PixelImap.Constant:
                        context.Decorate(spvVar, Decoration.Flat);
                        break;
                    case PixelImap.ScreenLinear:
                        context.Decorate(spvVar, Decoration.NoPerspective);
                        break;
                }
            }
            else if (context.Definitions.TryGetTransformFeedbackOutput(
                ioVariable,
                ioDefinition.Location,
                ioDefinition.Component,
                out TransformFeedbackOutput transformFeedbackOutput))
            {
                context.Decorate(spvVar, Decoration.XfbBuffer, (LiteralInteger)transformFeedbackOutput.Buffer);
                context.Decorate(spvVar, Decoration.XfbStride, (LiteralInteger)transformFeedbackOutput.Stride);
                context.Decorate(spvVar, Decoration.Offset, (LiteralInteger)transformFeedbackOutput.Offset);
            }

            context.AddGlobalVariable(spvVar);

            Dictionary<IoDefinition, SpvInstruction> dict = isPerPatch
                ? (isOutput ? context.OutputsPerPatch : context.InputsPerPatch)
                : (isOutput ? context.Outputs : context.Inputs);
            dict.Add(ioDefinition, spvVar);
        }
    }
}
