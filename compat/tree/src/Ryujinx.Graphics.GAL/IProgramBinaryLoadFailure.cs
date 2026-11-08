namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// Marks a program object returned from a host program record that could not be used.
    /// The GPU shader cache turns this into an on-demand translation before the program is
    /// bound; it is not a renderer capability and grants no shader semantics.
    /// </summary>
    public interface IProgramBinaryLoadFailure
    {
        /// <summary>Typed reason, or null when the record is still being processed.</summary>
        string ProgramBinaryLoadFailure { get; }
    }
}
