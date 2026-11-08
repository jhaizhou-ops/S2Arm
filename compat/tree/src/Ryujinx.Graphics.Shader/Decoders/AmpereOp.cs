// Ported (MIT, Copyright (c) 2026 seedds; license: graphics/nvn/LICENSE) from src/Ryujinx.Graphics.Shader/Decoders/AmpereOp.cs
// at 0a759de7 (Ampere frontend: d3995ca4, a7bd05f4, fdb3710d, 5251763d, c4b0618c, 4de40e62, c8521eeb, 0a759de7); S2Arm keeps it unchanged except where its patch says
using System;

namespace Ryujinx.Graphics.Shader.Decoders
{
    // One 128-bit Ampere (sm_86, NVN2) instruction. Field positions follow Mesa NAK's SM70 encoder (sm70_encode.rs) and CuAssembler's sm_86 tables.
    readonly struct AmpereOp
    {
        public readonly ulong Lo;
        public readonly ulong Hi;

        public AmpereOp(ulong lo, ulong hi)
        {
            Lo = lo;
            Hi = hi;
        }

        public AmpereOp(InstOp op) : this(op.RawOpCode, op.RawOpCodeHi)
        {
        }

        // Bits [lo, hi) as an unsigned value (at most 64 bits wide).
        public ulong Field(int lo, int hi)
        {
            UInt128 v = ((UInt128)Hi << 64) | Lo;
            int n = hi - lo;
            UInt128 mask = n >= 64 ? ulong.MaxValue : (((UInt128)1 << n) - 1);
            return (ulong)((v >> lo) & mask);
        }

        public int Bits(int lo, int hi) => (int)Field(lo, hi);
        public bool Bit(int n) => Field(n, n + 1) != 0;

        public long SignedField(int lo, int hi)
        {
            int n = hi - lo;
            return (long)(Field(lo, hi) << (64 - n)) >> (64 - n);
        }

        public int Opcode => (int)(Lo & 0xfff);
        public int Form => Bits(9, 12);              // ALU operand form: 1 R-R, 2 R-imm (C slot), 3 R-cbuf (C slot), 4 imm, 5 cbuf, 6 UR, 7 UR (C slot)
        public int Pred => Bits(12, 15);
        public bool PredInv => Bit(15);
        public int Rd => Bits(16, 24);
        public int Ra => Bits(24, 32);
        public int Rb => Bits(32, 40);
        public int Rc => Bits(64, 72);
        public uint Imm32 => (uint)(Lo >> 32);

        // Branch-like instructions: a signed word offset at 34..82, relative to the next instruction.
        public long BranchOffset => SignedField(34, 82) * 4;
    }
}
