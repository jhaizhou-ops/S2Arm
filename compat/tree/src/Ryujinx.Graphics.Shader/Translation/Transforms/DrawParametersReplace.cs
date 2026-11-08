using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System.Collections.Generic;

using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Translation.Transforms
{
    class DrawParametersReplace : ITransformPass
    {
        public static bool IsEnabled(IGpuAccessor gpuAccessor, ShaderStage stage, TargetLanguage targetLanguage, FeatureFlags usedFeatures)
        {
            return stage == ShaderStage.Vertex;
        }

        public static LinkedListNode<INode> RunPass(TransformContext context, LinkedListNode<INode> node)
        {
            Operation operation = (Operation)node.Value;

            if (context.GpuAccessor.QueryS2ARuntimeState())
            {
                // S2A：绘制参数来源运行时化——宏 HLE 绘制（cbdp 真）用内建、寄存器绘制用游戏写进 cb0 的值，按支持缓冲 s2a_flags.x 位 1 逐次绘制选，不读 cbdp
                if (S2ASelectDrawParameters(node, operation))
                {
                    context.UsedFeatures |= FeatureFlags.DrawParameters;
                }
            }
            else if (context.GpuAccessor.QueryHasConstantBufferDrawParameters())
            {
                if (ReplaceConstantBufferWithDrawParameters(node, operation))
                {
                    context.UsedFeatures |= FeatureFlags.DrawParameters;
                }
            }
            else if (HasConstantBufferDrawParameters(operation))
            {
                context.UsedFeatures |= FeatureFlags.DrawParameters;
            }

            return node;
        }

        private static bool ReplaceConstantBufferWithDrawParameters(LinkedListNode<INode> node, Operation operation)
        {
            Operand GenerateLoad(IoVariable ioVariable)
            {
                Operand value = Local();
                node.List.AddBefore(node, new Operation(Instruction.Load, StorageKind.Input, value, Const((int)ioVariable)));
                return value;
            }

            bool modified = false;

            for (int srcIndex = 0; srcIndex < operation.SourcesCount; srcIndex++)
            {
                Operand src = operation.GetSource(srcIndex);

                if (src.Type == OperandType.ConstantBuffer && src.GetCbufSlot() == 0)
                {
                    switch (src.GetCbufOffset())
                    {
                        case Constants.NvnBaseVertexByteOffset / 4:
                            operation.SetSource(srcIndex, GenerateLoad(IoVariable.BaseVertex));
                            modified = true;
                            break;
                        case Constants.NvnBaseInstanceByteOffset / 4:
                            operation.SetSource(srcIndex, GenerateLoad(IoVariable.BaseInstance));
                            modified = true;
                            break;
                        case Constants.NvnDrawIndexByteOffset / 4:
                            operation.SetSource(srcIndex, GenerateLoad(IoVariable.DrawIndex));
                            modified = true;
                            break;
                    }
                }
            }

            return modified;
        }

        private static bool S2ASelectDrawParameters(LinkedListNode<INode> node, Operation operation)
        {
            bool modified = false;
            for (int srcIndex = 0; srcIndex < operation.SourcesCount; srcIndex++)
            {
                Operand src = operation.GetSource(srcIndex);
                if (src.Type != OperandType.ConstantBuffer || src.GetCbufSlot() != 0) continue;
                IoVariable io;
                switch (src.GetCbufOffset())
                {
                    case Constants.NvnBaseVertexByteOffset / 4: io = IoVariable.BaseVertex; break;
                    case Constants.NvnBaseInstanceByteOffset / 4: io = IoVariable.BaseInstance; break;
                    case Constants.NvnDrawIndexByteOffset / 4: io = IoVariable.DrawIndex; break;
                    default: continue;
                }
                Operand builtin = Local(), flags = Local(), bit = Local(), on = Local(), value = Local();
                node.List.AddBefore(node, new Operation(Instruction.Load, StorageKind.Input, builtin, Const((int)io)));
                node.List.AddBefore(node, new Operation(Instruction.Load, StorageKind.ConstantBuffer, flags, Const(SupportBuffer.Binding), Const((int)SupportBufferField.S2AFlags), Const(0)));
                node.List.AddBefore(node, new Operation(Instruction.BitwiseAnd, bit, flags, Const(SupportBuffer.S2AFlagCbDrawParameters)));
                node.List.AddBefore(node, new Operation(Instruction.CompareNotEqual, on, bit, Const(0)));
                node.List.AddBefore(node, new Operation(Instruction.ConditionalSelect, value, on, builtin, src));
                operation.SetSource(srcIndex, value);
                modified = true;
            }
            return modified;
        }

        private static bool HasConstantBufferDrawParameters(Operation operation)
        {
            for (int srcIndex = 0; srcIndex < operation.SourcesCount; srcIndex++)
            {
                Operand src = operation.GetSource(srcIndex);

                if (src.Type == OperandType.ConstantBuffer && src.GetCbufSlot() == 0)
                {
                    switch (src.GetCbufOffset())
                    {
                        case Constants.NvnBaseVertexByteOffset / 4:
                        case Constants.NvnBaseInstanceByteOffset / 4:
                        case Constants.NvnDrawIndexByteOffset / 4:
                            return true;
                    }
                }
            }

            return false;
        }
    }
}
