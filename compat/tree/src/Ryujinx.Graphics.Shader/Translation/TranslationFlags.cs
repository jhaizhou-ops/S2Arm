using System;

namespace Ryujinx.Graphics.Shader.Translation
{
    [Flags]
    public enum TranslationFlags
    {
        None = 0,

        VertexA = 1 << 0,
        Compute = 1 << 1,
        DebugMode = 1 << 2,
        // Ampere (sm_86) machine code, as NVN2 (Switch 2) ships it: a 0x80-byte shader header (SPH version 4, its first 0x50 bytes laid out as version 3)
        // and 128-bit instructions, decoded and emitted by the Ampere frontend (reference port d3995ca4, MIT).
        Ampere = 1 << 4,
    }
}
