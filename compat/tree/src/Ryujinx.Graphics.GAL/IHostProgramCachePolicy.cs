namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// Optional renderer policy for the shared GPU host cache. Backends that do not implement
    /// it keep the historical prefetch behavior; this is not a capability bit and does not
    /// grant any shader semantics.
    /// </summary>
    public interface IHostProgramCachePolicy
    {
        /// <summary>
        /// True when host-cache prefetch would create renderer program objects that no draw can
        /// reuse, or when the backend must load its versioned program records on demand.
        /// </summary>
        bool DisableHostProgramPrefetch { get; }

        /// <summary>
        /// Optional bounded ASCII token identifying this backend's program-record profile.
        /// The shared cache appends it to host file names so a changed profile never reuses
        /// or keeps appending to another profile's host file. Null/empty keeps the legacy name.
        /// </summary>
        string HostProgramCacheDiscriminator { get; }
    }
}
