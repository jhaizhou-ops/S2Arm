// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using Ryujinx.Graphics.Shader.Decoders;
using Ryujinx.Graphics.Shader.Instructions;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;

static class Probe
{
    static uint Run(bool left, bool wrap, int wide, bool immediate, uint count, uint a, uint c, bool cc)
    {
        var ctx = new EmitterContext();
        ulong raw = (immediate ? (left ? 0x36f8000000000000UL : 0x38f8000000000000UL) : (left ? 0x5bf8000000000000UL : 0x5cf8000000000000UL))
            | (wrap ? 1UL << 50 : 0) | (cc ? 1UL << 47 : 0) | 5UL << 39 | (ulong)wide << 37 | (immediate ? count : 6UL) << 20 | 7UL << 16 | 4UL << 8;
        InstEmitter emit = immediate ? (left ? InstEmit.ShfLI : InstEmit.ShfRI) : (left ? InstEmit.ShfLR : InstEmit.ShfRR);
        ctx.CurrOp = new InstOp(0, raw, default, emit, default);
        emit(ctx);
        var values = new Dictionary<Operand, uint>();
        var registers = new Dictionary<int, uint> { [((int)RegisterType.Gpr << 24) | 4] = a, [((int)RegisterType.Gpr << 24) | 5] = c, [((int)RegisterType.Gpr << 24) | 6] = count };
        uint Read(Operand x) => x.Type switch
        {
            OperandType.Constant => (uint)x.Value,
            OperandType.Register => registers[x.Value],
            OperandType.LocalVariable => values[x],
            _ => throw new Exception("unsupported operand " + x.Type)
        };
        uint Shift(Instruction inst, uint x, uint n)
        {
            if (n >= 32) throw new Exception("emitted " + inst + " by " + n);
            return inst == Instruction.ShiftLeft ? x << (int)n : inst == Instruction.ShiftRightS32 ? (uint)((int)x >> (int)n) : x >> (int)n;
        }
        foreach (var op in ctx.GetOperations())
        {
            uint x = op.SourcesCount > 0 ? Read(op.GetSource(0)) : 0;
            uint y = op.SourcesCount > 1 ? Read(op.GetSource(1)) : 0;
            uint value = op.Inst switch
            {
                Instruction.Copy => x,
                Instruction.BitwiseAnd => x & y,
                Instruction.BitwiseOr => x | y,
                Instruction.Subtract => x - y,
                Instruction.ShiftLeft or Instruction.ShiftRightU32 or Instruction.ShiftRightS32 => Shift(op.Inst, x, y),
                Instruction.CompareEqual => x == y ? uint.MaxValue : 0,
                Instruction.CompareLess => (int)x < (int)y ? uint.MaxValue : 0,
                Instruction.CompareLessU32 => x < y ? uint.MaxValue : 0,
                Instruction.CompareGreaterOrEqualU32 => x >= y ? uint.MaxValue : 0,
                Instruction.ConditionalSelect => x != 0 ? y : Read(op.GetSource(2)),
                _ => throw new Exception("unsupported instruction " + op.Inst)
            };
            if (op.Dest.Type == OperandType.Register) registers[op.Dest.Value] = value;
            else values[op.Dest] = value;
        }
        uint result = registers[(int)RegisterType.Gpr << 24];
        if (cc && (registers[(int)RegisterType.Flag << 24] != (result == 0 ? uint.MaxValue : 0)
            || registers[((int)RegisterType.Flag << 24) | 1] != ((int)result < 0 ? uint.MaxValue : 0))) throw new Exception("condition flags mismatch");
        return result;
    }
    static uint Expected(bool left, bool wrap, int wide, uint count, uint a, uint c)
    {
        int limit = wide == 0 ? 32 : 64;
        int n = (int)(wrap ? count & (uint)(limit - 1) : Math.Min(count, (uint)limit));
        ulong pair = (ulong)c << 32 | a;
        if (left) return n >= 64 ? 0 : (uint)((pair << n) >> 32);
        if (wide == 3) return n >= 64 ? ((int)c < 0 ? uint.MaxValue : 0) : (uint)((long)pair >> n);
        return n >= 64 ? 0 : (uint)(pair >> n);
    }
    static int Main()
    {
        int total = 0, bad = 0;
        foreach (bool left in new[] { true, false })
        foreach (bool wrap in new[] { true, false })
        foreach (int wide in new[] { 0, 2, 3 })
        foreach (bool imm in new[] { true, false })
        foreach (bool cc in new[] { false, true })
        foreach (uint count in new uint[] { 0, 1, 31, 32, 63, 64, 127, uint.MaxValue })
        foreach (var pair in new (uint a, uint c)[] { (0x01234567, 0x89abcdef), (0x80000001, 0x12345678), (0xffffffff, 0), (0, 0xffffffff) })
        {
            if (imm && count >= 64 || !wrap && (wide == 0 && count >= 32 || wide != 0 && count >= 64)) continue; // Out-of-scope clamp endpoints; explicit, not redefined.
            total++;
            try
            {
                uint got = Run(left, wrap, wide, imm, count, pair.a, pair.c, cc), want = Expected(left, wrap, wide, count, pair.a, pair.c);
                if (got != want) throw new Exception($"expected {want:x8}, got {got:x8}");
            }
            catch (Exception e) { bad++; if (bad < 12) Console.WriteLine($"FAIL left={left} wrap={wrap} wide={wide} imm={imm} cc={cc} n={count}: {e.Message}"); }
        }
        Console.WriteLine($"Strict emitted IR: {total-bad}/{total}; failures={bad}; CPU only, no GPU execution");
        return bad == 0 ? 0 : 1;
    }
}
