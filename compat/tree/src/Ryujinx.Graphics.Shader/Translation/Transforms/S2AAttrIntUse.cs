using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Shader.Translation.Transforms
{
    /// <summary>
    /// S2A（着色器全量预编，10-20）：只分析不改写——找出顶点阶段里「属性读出值直接进整数运算」的位置（整数转浮点、整数加减乘移位比较极值、
    /// 当常量 / 存储缓冲下标），记进 ShaderDefinitions.S2AAttrIntUse / S2AAttrSintUse。离线烘焙器据此给这些位置额外出整数类别的特化状态变体
    /// （顶点输入声明类型须与顶点格式类别一致，不能运行时化；推断不准时变体只是多一个永不命中的条目，不影响正确性）
    /// </summary>
    class S2AAttrIntUse : ITransformPass
    {
        public static bool IsEnabled(IGpuAccessor gpuAccessor, ShaderStage stage, TargetLanguage targetLanguage, FeatureFlags usedFeatures)
        {
            return stage == ShaderStage.Vertex;
        }

        public static LinkedListNode<INode> RunPass(TransformContext context, LinkedListNode<INode> node)
        {
            // 顶点输入按原始位读（S2AVertexRaw）时翻译与属性类型无关，不用推断整数类别变体
            if (context.Definitions.S2AVertexRaw)
            {
                return node;
            }

            Operation operation = (Operation)node.Value;
            Instruction inst = operation.Inst;
            if ((inst & (Instruction.FP32 | Instruction.FP64)) != 0)
            {
                return node;
            }

            bool signed = false;
            int first = 0;
            switch (inst & Instruction.Mask)
            {
                case Instruction.ConvertS32ToFP32: case Instruction.ConvertS32ToFP64: case Instruction.ShiftRightS32: signed = true; break;
                case Instruction.ConvertU32ToFP32: case Instruction.ConvertU32ToFP64: case Instruction.ShiftRightU32: case Instruction.ShiftLeft:
                case Instruction.Add: case Instruction.Subtract: case Instruction.Multiply: case Instruction.Divide:
                case Instruction.Minimum: case Instruction.Maximum: case Instruction.MinimumU32: case Instruction.MaximumU32:
                case Instruction.CompareEqual: case Instruction.CompareNotEqual: case Instruction.CompareLessU32: case Instruction.CompareGreaterU32:
                case Instruction.CompareLessOrEqualU32: case Instruction.CompareGreaterOrEqualU32:
                    break;
                case Instruction.CompareLess: case Instruction.CompareGreater: case Instruction.CompareLessOrEqual: case Instruction.CompareGreaterOrEqual:
                    signed = true; break;
                case Instruction.Load:
                    if (operation.StorageKind != StorageKind.ConstantBuffer && operation.StorageKind != StorageKind.StorageBuffer) return node;
                    first = 1;   // 第 0 个源是绑定号，之后是下标
                    break;
                default:
                    return node;
            }

            for (int i = first; i < operation.SourcesCount; i++)
            {
                if (AttrLocation(operation.GetSource(i)) is int loc)
                {
                    context.Definitions.S2AAttrIntUse |= 1u << loc;
                    if (signed) context.Definitions.S2AAttrSintUse |= 1u << loc;
                }
            }

            return node;
        }

        private static int? AttrLocation(Operand src)
        {
            for (int hop = 0; hop < 4 && src != null && src.Type == OperandType.LocalVariable; hop++)
            {
                if (src.AsgOp is not Operation def) return null;
                if (def.Inst == Instruction.Copy) { src = def.GetSource(0); continue; }
                if (def.Inst == Instruction.Load && def.StorageKind == StorageKind.Input && def.SourcesCount >= 2 &&
                    def.GetSource(0).Type == OperandType.Constant && def.GetSource(0).Value == (int)IoVariable.UserDefined &&
                    def.GetSource(1).Type == OperandType.Constant)
                {
                    return def.GetSource(1).Value;
                }
                return null;
            }
            return null;
        }
    }
}
