namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// S2A: optional program capability used by the loading-screen pipeline warm.
    /// The GPU layer checks this without depending on the Vulkan backend type.
    /// </summary>
    public interface IS2APipelineWarm
    {
        /// <summary>
        /// Waits for this program's background pipeline prebuild to finish.
        /// Returns false on timeout/failure instead of blocking the loading screen forever.
        /// </summary>
        bool S2AWaitForBackgroundPipeline(int timeoutMs);
    }
}
