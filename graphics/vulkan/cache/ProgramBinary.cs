using Ryujinx.Graphics.GAL;
using System;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// Versioned identity checked by both producer and consumer of a VKPB record. All keys are
/// produced by the trusted renderer-side profile, never derived while decoding.
/// </summary>
public sealed record ProgramBinaryIdentity(string Scheme, string ProfileKey, string TranslationKey,
    string BindingAbi);

public sealed record ProgramBinarySpecializationEntry(uint ConstantId, uint Offset, uint Size);
public sealed record ProgramBinaryStageSpecialization(ProgramBinarySpecializationEntry[] Map, byte[] Data);

// Ordinary graphics/compute programs only. Minimal/helper/VTG composite containers and
// transform-feedback layouts are separate records or future versions, never silently folded in.
public sealed record ProgramBinaryOptions(bool MinimalLayout, bool TransformFeedback, bool Composite);

public sealed record ProgramBinary(ProgramBinaryIdentity Identity, ProgramBinaryOptions Options,
    ShaderSource[] Sources, ShaderInfo Info, ProgramBinaryStageSpecialization[] Specializations);

public sealed class ProgramBinaryException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
