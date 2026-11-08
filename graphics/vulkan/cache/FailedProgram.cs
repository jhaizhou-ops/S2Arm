using Ryujinx.Graphics.GAL;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// Placeholder for a rejected VKPB record. It reports a link failure so the existing lazy
/// loader rejects the disk entry and translates on demand; it never pretends the cached
/// program was usable and never holds a Vulkan object.
/// </summary>
public sealed class FailedProgram : IProgram, IProgramBinaryLoadFailure
{
    public FailedProgram(string reason) => Reason = reason;

    public string Reason { get; }

    public string ProgramBinaryLoadFailure => Reason;

    public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Failure;

    public byte[] GetBinary() => null;

    public void Dispose()
    {
    }
}
