using Ryujinx.Graphics.Shader.Decoders;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System;
using System.Collections.Generic;
using System.Linq;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Translation
{
    public static class Translator
    {
        private const int ThreadsPerWarp = 32;
        private const int HeaderSize = 0x50;
        private const int AmpereHeaderSize = 0x80;

        internal readonly struct FunctionCode
        {
            public Operation[] Code { get; }

            public FunctionCode(Operation[] code)
            {
                Code = code;
            }
        }

        public static TranslatorContext CreateContext(ulong address, IGpuAccessor gpuAccessor, TranslationOptions options)
        {
            return DecodeShader(address, gpuAccessor, options);
        }

        private static TranslatorContext DecodeShader(ulong address, IGpuAccessor gpuAccessor, TranslationOptions options)
        {
            int localMemorySize;
            ShaderDefinitions definitions;
            DecodedProgram program;
            bool ampere = options.Flags.HasFlag(TranslationFlags.Ampere);
            int headerSize = ampere ? AmpereHeaderSize : HeaderSize;

            if (options.Flags.HasFlag(TranslationFlags.Compute))
            {
                definitions = CreateComputeDefinitions(gpuAccessor);
                localMemorySize = gpuAccessor.QueryComputeLocalMemorySize();

                program = ampere ? Decoder.DecodeAmpere(definitions, gpuAccessor, address) : Decoder.Decode(definitions, gpuAccessor, address);
            }
            else
            {
                ShaderHeader header = new(gpuAccessor, address);

                definitions = CreateGraphicsDefinitions(gpuAccessor, header);
                localMemorySize = GetLocalMemorySize(header);

                program = ampere
                    ? Decoder.DecodeAmpere(definitions, gpuAccessor, address + (ulong)headerSize)
                    : Decoder.Decode(definitions, gpuAccessor, address + (ulong)headerSize);
            }

            definitions.Ampere = ampere;

            ulong maxEndAddress = 0;

            foreach (DecodedFunction function in program)
            {
                foreach (Block block in function.Blocks)
                {
                    if (maxEndAddress < block.EndAddress)
                    {
                        maxEndAddress = block.EndAddress;
                    }
                }
            }

            int size = (int)maxEndAddress + (options.Flags.HasFlag(TranslationFlags.Compute) ? 0 : headerSize);

            return new TranslatorContext(address, size, localMemorySize, definitions, gpuAccessor, options, program);
        }

        private static ShaderDefinitions CreateComputeDefinitions(IGpuAccessor gpuAccessor)
        {
            return new ShaderDefinitions(
                ShaderStage.Compute,
                gpuAccessor.QueryComputeLocalSizeX(),
                gpuAccessor.QueryComputeLocalSizeY(),
                gpuAccessor.QueryComputeLocalSizeZ());
        }

        private static ShaderDefinitions CreateGraphicsDefinitions(IGpuAccessor gpuAccessor, ShaderHeader header)
        {
            TransformFeedbackOutput[] transformFeedbackOutputs = GetTransformFeedbackOutputs(gpuAccessor, out ulong transformFeedbackVecMap);

            return new ShaderDefinitions(
                header.Stage,
                gpuAccessor.QueryGraphicsState(),
                header.Stage == ShaderStage.Geometry && header.GpPassthrough,
                header.ThreadsPerInputPrimitive,
                header.OutputTopology,
                header.MaxOutputVertexCount,
                header.ImapTypes,
                header.OmapTargets,
                header.OmapSampleMask,
                header.OmapDepth,
                gpuAccessor.QueryHostSupportsScaledVertexFormats(),
                transformFeedbackVecMap,
                transformFeedbackOutputs);
        }

        internal static TransformFeedbackOutput[] GetTransformFeedbackOutputs(IGpuAccessor gpuAccessor, out ulong transformFeedbackVecMap)
        {
            bool transformFeedbackEnabled =
                gpuAccessor.QueryTransformFeedbackEnabled() &&
                gpuAccessor.QueryHostSupportsTransformFeedback();
            TransformFeedbackOutput[] transformFeedbackOutputs = null;
            transformFeedbackVecMap = 0UL;

            if (transformFeedbackEnabled)
            {
                transformFeedbackOutputs = new TransformFeedbackOutput[0xc0];

                for (int tfbIndex = 0; tfbIndex < 4; tfbIndex++)
                {
                    ReadOnlySpan<byte> locations = gpuAccessor.QueryTransformFeedbackVaryingLocations(tfbIndex);
                    int stride = gpuAccessor.QueryTransformFeedbackStride(tfbIndex);

                    for (int i = 0; i < locations.Length; i++)
                    {
                        byte wordOffset = locations[i];
                        if (wordOffset < 0xc0)
                        {
                            transformFeedbackOutputs[wordOffset] = new TransformFeedbackOutput(tfbIndex, i * 4, stride);
                            transformFeedbackVecMap |= 1UL << (wordOffset / 4);
                        }
                    }
                }
            }

            return transformFeedbackOutputs;
        }

        private static int GetLocalMemorySize(ShaderHeader header)
        {
            return header.ShaderLocalMemoryLowSize + header.ShaderLocalMemoryHighSize + (header.ShaderLocalMemoryCrsSize / ThreadsPerWarp);
        }

        internal static FunctionCode[] EmitShader(
            TranslatorContext translatorContext,
            ResourceManager resourceManager,
            DecodedProgram program,
            bool vertexAsCompute,
            bool initializeOutputs,
            out int initializationOperations)
        {
            initializationOperations = 0;

            bool ampere = translatorContext.Options.Flags.HasFlag(TranslationFlags.Ampere);

            if (!ampere)
            {
                FunctionMatch.RunPass(program);
            }

            foreach (DecodedFunction function in program.Where(x => !x.IsCompilerGenerated).OrderBy(x => x.Address))
            {
                program.AddFunctionAndSetId(function);
            }

            FunctionCode[] functions = new FunctionCode[program.FunctionsWithIdCount];

            for (int index = 0; index < functions.Length; index++)
            {
                EmitterContext context = new(translatorContext, resourceManager, program, vertexAsCompute, index != 0);

                if (initializeOutputs && index == 0)
                {
                    EmitOutputsInitialization(context, translatorContext.AttributeUsage, translatorContext.GpuAccessor, translatorContext.Stage);
                    initializationOperations = context.OperationsCount;
                }

                DecodedFunction function = program.GetFunctionById(index);

                foreach (Block block in function.Blocks)
                {
                    context.CurrBlock = block;

                    context.EnterBlock(block.Address);

                    if (ampere)
                    {
                        EmitOpsAmpere(context, block);
                    }
                    else
                    {
                        EmitOps(context, block);
                    }
                }

                functions[index] = new(context.GetOperations());
            }

            return functions;
        }

        private static void EmitOutputsInitialization(EmitterContext context, AttributeUsage attributeUsage, IGpuAccessor gpuAccessor, ShaderStage stage)
        {
            // Compute has no output attributes, so we
            // don't need to initialize outputs on that stage.
            if (stage == ShaderStage.Compute)
            {
                return;
            }

            if (stage == ShaderStage.Fragment)
            {
                // Fragment is the last stage, so we don't need to
                // initialize outputs unless we're using DSB, in which
                // we need to make sure the ouput has a valid value.
                if (gpuAccessor.QueryGraphicsState().DualSourceBlendEnable)
                {
                    for (int i = 0; i < 4; i++)
                    {
                        context.Store(StorageKind.Output, IoVariable.FragmentOutputColor, null, Const(1), Const(i), ConstF(0));
                    }
                }

                return;
            }

            if (stage == ShaderStage.Vertex)
            {
                InitializeVertexOutputs(context);
            }

            UInt128 usedAttributes = context.TranslatorContext.AttributeUsage.NextInputAttributesComponents;
            while (usedAttributes != UInt128.Zero)
            {
                int index = (int)UInt128.TrailingZeroCount(usedAttributes);
                int vecIndex = index / 4;

                usedAttributes &= ~(UInt128.One << index);

                // We don't need to initialize passthrough attributes.
                if ((context.TranslatorContext.AttributeUsage.PassthroughAttributes & (1 << vecIndex)) != 0)
                {
                    continue;
                }

                InitializeOutputComponent(context, vecIndex, index & 3, perPatch: false);
            }

            if (context.TranslatorContext.AttributeUsage.NextUsedInputAttributesPerPatch != null)
            {
                foreach (int vecIndex in context.TranslatorContext.AttributeUsage.NextUsedInputAttributesPerPatch.Order())
                {
                    InitializeOutput(context, vecIndex, perPatch: true);
                }
            }

            if (attributeUsage.NextUsesFixedFuncAttributes)
            {
                bool supportsLayerFromVertexOrTess = gpuAccessor.QueryHostSupportsLayerVertexTessellation();
                int fixedStartAttr = supportsLayerFromVertexOrTess ? 0 : 1;

                for (int i = fixedStartAttr; i < fixedStartAttr + 5 + AttributeConsts.TexCoordCount; i++)
                {
                    int index = attributeUsage.GetFreeUserAttribute(isOutput: true, i);
                    if (index < 0)
                    {
                        break;
                    }

                    InitializeOutput(context, index, perPatch: false);
                }
            }
        }

        private static void InitializeVertexOutputs(EmitterContext context)
        {
            for (int c = 0; c < 4; c++)
            {
                context.Store(StorageKind.Output, IoVariable.Position, null, Const(c), ConstF(c == 3 ? 1f : 0f));
            }

            if (context.Program.ClipDistancesWritten != 0)
            {
                for (int i = 0; i < 8; i++)
                {
                    context.Store(StorageKind.Output, IoVariable.ClipDistance, null, Const(i), ConstF(0f));
                }
            }
        }

        private static void InitializeOutput(EmitterContext context, int location, bool perPatch)
        {
            for (int c = 0; c < 4; c++)
            {
                InitializeOutputComponent(context, location, c, perPatch);
            }
        }

        private static void InitializeOutputComponent(EmitterContext context, int location, int c, bool perPatch)
        {
            StorageKind storageKind = perPatch ? StorageKind.OutputPerPatch : StorageKind.Output;

            if (context.TranslatorContext.Definitions.OaIndexing)
            {
                Operand invocationId = null;

                if (context.TranslatorContext.Definitions.Stage == ShaderStage.TessellationControl && !perPatch)
                {
                    invocationId = context.Load(StorageKind.Input, IoVariable.InvocationId);
                }

                int index = location * 4 + c;

                context.Store(storageKind, IoVariable.UserDefined, invocationId, Const(index), ConstF(c == 3 ? 1f : 0f));
            }
            else
            {
                if (context.TranslatorContext.Definitions.Stage == ShaderStage.TessellationControl && !perPatch)
                {
                    Operand invocationId = context.Load(StorageKind.Input, IoVariable.InvocationId);
                    context.Store(storageKind, IoVariable.UserDefined, Const(location), invocationId, Const(c), ConstF(c == 3 ? 1f : 0f));
                }
                else
                {
                    context.Store(storageKind, IoVariable.UserDefined, null, Const(location), Const(c), ConstF(c == 3 ? 1f : 0f));
                }
            }
        }

        // Ampere: the guard is bits 12..15 (a uniform predicate on the uniform datapath); BRA evaluates its guard with its condition itself.
        // Scoreboards: a variable-latency instruction (one that sets a write barrier, control bits 110..113; 7 = none) writes its registers when the result
        // arrives, and the compiler lets later instructions that do not wait on that barrier (wait mask, bits 116..122) read the registers' old values (LDG R2,
        // [R2.64] then LDG R4, [R2.64 + 4] reads the address twice). Such an instruction's writes go to locals that start as the registers' values; they are
        // copied to the registers before the first instruction that waits on the barrier, at DEPBAR, and at the end of the block.
        // S2Arm（上游参考实现（MIT）9507c221c 的语义，做法另定）：带守卫的这种指令，守卫在发出时为假就什么都不写；落地时照抄局部量会把这期间别的指令写进同一寄存器的值
        // 冲掉（上游记耀西与神秘图鉴的局部光源：@P4 EXP2 R17 发出后、等待前 @!P4 自己写 R17，旧值的抄回把场景过曝）。上游给每个这样写的寄存器各存一份发出时的守卫
        // （一次选择）、落地时各判一次；这里落地时才看：发出到落地之间（同一块内的直线代码）没有别的运算写这个寄存器，照抄就对（守卫假时局部量就是原值），一条不加；
        // 有写才按守卫跳过抄回，守卫的谓词寄存器这期间没被写就直接判它，被写了才在发出处补一份快照（一个局部量，同一条指令的寄存器共用）
        private sealed class AmpereGuard
        {
            public Operand Pred;
            public bool Inv;
            public int At;            // the issue's first operation (kept current when an operation is inserted before it)
            public Operand Snapshot;  // the guard at issue, once a commit needed one
        }

        private static void EmitOpsAmpere(EmitterContext context, Block block)
        {
            List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)>[] pending = new List<(Register, Operand, AmpereGuard, int)>[7];
            int shadows = 0, seq = 0;
            Stack<int> freeShadows = new();

            bool WrittenSince(int from, Register reg)
            {
                for (int i = from; i < context.OperationsCount; i++)
                {
                    Operation operation = context.GetOperation(i);

                    for (int d = 0; d < operation.DestsCount; d++)
                    {
                        Operand dest = operation.GetDest(d);

                        if (dest != null && dest.Type == OperandType.Register && dest.GetRegister().Equals(reg))
                        {
                            return true;
                        }
                    }
                }

                return false;
            }

            void CommitGuarded(Register reg, Operand value, AmpereGuard g)
            {
                Operand cond = g.Snapshot ?? g.Pred;

                if (g.Snapshot == null && WrittenSince(g.At, g.Pred.GetRegister()))
                {
                    g.Snapshot = cond = Local();
                    context.InsertOperation(g.At, new Operation(Instruction.Copy, g.Snapshot, g.Pred));

                    foreach (List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)> list in pending)
                    {
                        foreach ((_, _, AmpereGuard other, _) in list ?? [])
                        {
                            if (other != null && other != g && other.At >= g.At)
                            {
                                other.At++;
                            }
                        }
                    }
                }

                Operand skip = Label();

                if (g.Inv)
                {
                    context.BranchIfTrue(skip, cond);
                }
                else
                {
                    context.BranchIfFalse(skip, cond);
                }

                context.Copy(Register(reg), value);
                context.MarkLabel(skip);
            }

            void Commit(int barrier)
            {
                if (pending[barrier] != null)
                {
                    foreach ((Register reg, Operand value, AmpereGuard guard, int s) in pending[barrier])
                    {
                        if (guard != null && WrittenSince(guard.At, reg))
                        {
                            CommitGuarded(reg, value, guard);
                        }
                        else
                        {
                            context.Copy(Register(reg), value);
                        }

                        freeShadows.Push(value.GetRegister().Index);

                        // Writes to the same register issued before this one and still pending are in its value already (DeferAmpereWrites starts it from them): landing later they would undo it
                        for (int b = 0; b < pending.Length; b++)
                        {
                            if (b == barrier || pending[b] == null)
                            {
                                continue;
                            }

                            foreach ((_, Operand v, _, _) in pending[b].FindAll(p => p.Reg.Equals(reg) && p.Seq < s))
                            {
                                freeShadows.Push(v.GetRegister().Index);
                            }

                            pending[b].RemoveAll(p => p.Reg.Equals(reg) && p.Seq < s);
                        }
                    }

                    pending[barrier] = null;
                }
            }

            void CommitAll()
            {
                for (int b = 0; b < pending.Length; b++)
                {
                    Commit(b);
                }
            }

            for (int opIndex = 0; opIndex < block.OpCodes.Count; opIndex++)
            {
                InstOp op = block.OpCodes[opIndex];
                AmpereOp a = new(op);
                int wait = a.Bits(116, 122);
                int writeBarrier = a.Bits(110, 113);

                for (int b = 0; b < 6; b++)
                {
                    if ((wait & (1 << b)) != 0)
                    {
                        Commit(b);
                    }
                }

                if (a.Opcode == 0x91a || op.Props.HasFlag(InstProps.Bra))
                {
                    CommitAll();
                }

                if (context.TranslatorContext.Options.Flags.HasFlag(TranslationFlags.DebugMode))
                {
                    context.Add(new CommentNode($"0x{op.Address:X6}: 0x{op.RawOpCodeHi:X16}{op.RawOpCode:X16} {op.Name}"));
                }

                if (a.Pred == RegisterConsts.PredicateTrueIndex && a.PredInv)
                {
                    continue;
                }

                int opStart = context.OperationsCount;

                Operand predSkipLbl = null;
                AmpereGuard guard = null;

                if (a.Pred != RegisterConsts.PredicateTrueIndex && a.Opcode != Instructions.AmpereOpcodes.Bra)
                {
                    Operand label;

                    // Straight to the next block only when nothing waits for this block's end to be committed (upstream (MIT) 9507c221c: the jump skipped the commits)
                    if (opIndex == block.OpCodes.Count - 1 && block.HasNext() && writeBarrier >= 6 && Array.TrueForAll(pending, list => list == null || list.Count == 0))
                    {
                        label = context.GetLabel(block.Successors[0].Address);
                    }
                    else
                    {
                        label = Label();

                        predSkipLbl = label;
                    }

                    RegisterType predType = Instructions.AmpereTable.HasUniformGuard(a.Opcode) ? RegisterType.UniformPredicate : RegisterType.Predicate;
                    Operand pred = Register(a.Pred, predType);

                    guard = new AmpereGuard { Pred = pred, Inv = a.PredInv, At = opStart };

                    if (a.PredInv)
                    {
                        context.BranchIfTrue(label, pred);
                    }
                    else
                    {
                        context.BranchIfFalse(label, pred);
                    }
                }

                context.CurrOp = op;

                op.Emitter?.Invoke(context);

                if (predSkipLbl != null)
                {
                    context.MarkLabel(predSkipLbl);
                }

                if (writeBarrier < 6 && !op.Props.HasFlag(InstProps.Bra))
                {
                    DeferAmpereWrites(context, opStart, pending, writeBarrier, ref shadows, freeShadows, guard, seq++);
                }
            }

            CommitAll();
        }

        // The registers written by the operations from opStart on become shadow registers (every use in the range too), each first set to the register's value
        private static void DeferAmpereWrites(
            EmitterContext context,
            int opStart,
            List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)>[] pendingAll,
            int barrier,
            ref int shadows,
            Stack<int> freeShadows,
            AmpereGuard guard,
            int seq)
        {
            List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)> pending = pendingAll[barrier] ??= [];

            int end = context.OperationsCount;
            Dictionary<Register, Operand> locals = new();

            for (int i = opStart; i < end; i++)
            {
                Operation operation = context.GetOperation(i);

                for (int d = 0; d < operation.DestsCount; d++)
                {
                    Operand dest = operation.GetDest(d);

                    if (dest != null && dest.Type == OperandType.Register && !locals.ContainsKey(dest.GetRegister()))
                    {
                        if (freeShadows.Count == 0 && shadows == RegisterConsts.ShadowsCount)
                        {
                            throw new InvalidOperationException("Ampere: more deferred register writes pending at once than shadow registers");
                        }

                        locals[dest.GetRegister()] = Register(freeShadows.Count != 0 ? freeShadows.Pop() : shadows++, RegisterType.Shadow);
                    }
                }
            }

            if (locals.Count == 0)
            {
                return;
            }

            for (int i = opStart; i < end; i++)
            {
                Operation operation = context.GetOperation(i);

                for (int d = 0; d < operation.DestsCount; d++)
                {
                    Operand dest = operation.GetDest(d);

                    if (dest != null && dest.Type == OperandType.Register && locals.TryGetValue(dest.GetRegister(), out Operand local))
                    {
                        operation.SetDest(d, local);
                    }
                }

                for (int s = 0; s < operation.SourcesCount; s++)
                {
                    Operand src = operation.GetSource(s);

                    if (src != null && src.Type == OperandType.Register && locals.TryGetValue(src.GetRegister(), out Operand local))
                    {
                        operation.SetSource(s, local);
                    }
                }
            }

            int at = opStart;

            foreach ((Register reg, Operand local) in locals)
            {
                // The local starts as the value the register has once the writes still pending to it land, the latest issued of them, else the register: what a guarded or partial write
                // leaves alone. The Legend of Zelda: Ocarina of Time's e1c9adbcf6bd2996: IPA R10 ← attribute 4 (barrier 3), then @P0 IPA R10 ← attribute 5 (barrier 0) before either is waited on,
                // so R10 = P0 ? attribute 5 : attribute 4. Started from the register, the guarded write dropped attribute 4 (or, the earlier write kept, landed after it and undid the guard)
                Operand init = Register(reg);
                int latest = -1;

                foreach (List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)> list in pendingAll)
                {
                    foreach ((Register r, Operand v, _, int s) in list ?? [])
                    {
                        if (r.Equals(reg) && s > latest)
                        {
                            (init, latest) = (v, s);
                        }
                    }
                }

                context.InsertOperation(at++, new Operation(Instruction.Copy, local, init));

                // A register written again before its earlier deferred write landed: the later write wins, the earlier shadow is free. A guarded later write may not happen, so the earlier one stays
                if (guard == null)
                {
                    foreach (List<(Register Reg, Operand Value, AmpereGuard Guard, int Seq)> list in pendingAll)
                    {
                        if (list == null)
                        {
                            continue;
                        }

                        foreach ((Register r, Operand v, AmpereGuard g, int s) in list.FindAll(p => p.Reg.Equals(reg)))
                        {
                            freeShadows.Push(v.GetRegister().Index);
                        }

                        list.RemoveAll(p => p.Reg.Equals(reg));
                    }
                }

                pending.Add((reg, local, guard, seq));
            }
        }

        private static void EmitOps(EmitterContext context, Block block)
        {
            for (int opIndex = 0; opIndex < block.OpCodes.Count; opIndex++)
            {
                InstOp op = block.OpCodes[opIndex];

                if (context.TranslatorContext.Options.Flags.HasFlag(TranslationFlags.DebugMode))
                {
                    string instName;

                    if (op.Emitter != null)
                    {
                        instName = op.Name.ToString();
                    }
                    else
                    {
                        instName = "???";

                        context.TranslatorContext.GpuAccessor.Log($"Invalid instruction at 0x{op.Address:X6} (0x{op.RawOpCode:X16}).");
                    }

                    string dbgComment = $"0x{op.Address:X6}: 0x{op.RawOpCode:X16} {instName}";

                    context.Add(new CommentNode(dbgComment));
                }

                InstConditional opConditional = new(op.RawOpCode);

                bool noPred = op.Props.HasFlag(InstProps.NoPred);
                if (!noPred && opConditional.Pred == RegisterConsts.PredicateTrueIndex && opConditional.PredInv)
                {
                    continue;
                }

                Operand predSkipLbl = null;

                if (Decoder.IsPopBranch(op.Name))
                {
                    // If the instruction is a SYNC or BRK instruction with only one
                    // possible target address, then the instruction is basically
                    // just a simple branch, we can generate code similar to branch
                    // instructions, with the condition check on the branch itself.
                    noPred = block.SyncTargets.Count <= 1;
                }
                else if (op.Name == InstName.Bra)
                {
                    noPred = true;
                }

                if (!(opConditional.Pred == RegisterConsts.PredicateTrueIndex || noPred))
                {
                    Operand label;

                    if (opIndex == block.OpCodes.Count - 1 && block.HasNext())
                    {
                        label = context.GetLabel(block.Successors[0].Address);
                    }
                    else
                    {
                        label = Label();

                        predSkipLbl = label;
                    }

                    Operand pred = Register(opConditional.Pred, RegisterType.Predicate);

                    if (opConditional.PredInv)
                    {
                        context.BranchIfTrue(label, pred);
                    }
                    else
                    {
                        context.BranchIfFalse(label, pred);
                    }
                }

                context.CurrOp = op;

                op.Emitter?.Invoke(context);

                if (predSkipLbl != null)
                {
                    context.MarkLabel(predSkipLbl);
                }
            }
        }
    }
}
