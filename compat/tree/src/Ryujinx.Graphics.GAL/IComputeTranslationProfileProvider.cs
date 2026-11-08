namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// Optional immutable selection for a renderer/device lifetime. Null keeps the legacy
    /// path. A provider must reject access after retirement; a new device returns a new
    /// object even when its portable disk identity is equal. Consumers must not cache a
    /// selection across provider generations. This interface grants no device features.
    /// </summary>
    public interface IComputeTranslationProfileProvider
    {
        ComputeTranslationProfile ComputeTranslationProfile { get; }

        /// <summary>Capabilities from that same immutable selection; runtime memory budgets are separate.</summary>
        Capabilities FrozenTranslationCapabilities { get; }
    }
}
