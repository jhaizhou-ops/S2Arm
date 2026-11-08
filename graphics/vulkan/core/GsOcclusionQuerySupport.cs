using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace S2Arm.Backends.Vulkan;

/// <summary>
/// SupportsGeometryShaderOcclusionQuery (#1456): the capability bit both
/// Vulkan device construction paths (generic and native direct) read.
/// The Android capprobe writes files/capprobe/&lt;fingerprint-hash&gt;.json
/// before any device exists and publishes its path through
/// S2A_CAPPROBE_RESULT. Only verdict.gs_occlusion == "supported" is true;
/// a missing/unreadable file and every other verdict are false, which
/// routes geometry work through the #1469 GS-as-compute fallback.
///
/// Apple/Metal: the Metal capability table never constructs a Vulkan
/// device and never reads this file — the bit is always false there
/// (NxCaps), by contract, not by platform branching here.
/// </summary>
public static class GsOcclusionQuerySupport
{
    public const string ResultPathVariable = "S2A_CAPPROBE_RESULT";

    // Injectable seams: host tests substitute file contents and observe the
    // writeback without a device or the native library.
    internal static Func<string> ResultPath = () =>
        Environment.GetEnvironmentVariable(ResultPathVariable);

    internal static Action RuntimeLostWrite = () =>
    {
        try { s2a_capprobe_runtime_lost(); }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
    };

    [DllImport("s2arm_android")] private static extern void s2a_capprobe_runtime_lost();

    /// <summary>Reads the published result file; false on any absence or doubt.</summary>
    public static bool Supported()
    {
        string path = ResultPath();
        if (string.IsNullOrEmpty(path))
        {
            return false;
        }
        try
        {
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            return doc.RootElement.TryGetProperty("verdict", out JsonElement verdict) &&
                verdict.TryGetProperty("gs_occlusion", out JsonElement gs) &&
                gs.ValueKind == JsonValueKind.String &&
                gs.GetString() == "supported";
        }
        catch (Exception e) when (e is IOException || e is JsonException || e is UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// True when the GPU fatal chain carries a Vulkan DEVICE_LOST.
    /// Ryujinx.Graphics.Vulkan.VulkanException stays internal to its
    /// assembly and does not retain the VkResult; the result enum name is
    /// in its message ("Unexpected API error \"ErrorDeviceLost\"."), which
    /// is the same identification the runtime feature tests use.
    /// </summary>
    public static bool IsDeviceLostError(Exception error)
    {
        for (Exception e = error; e != null; e = e.InnerException)
        {
            if (e.GetType().FullName == "Ryujinx.Graphics.Vulkan.VulkanException" &&
                e.Message.Contains("ErrorDeviceLost"))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Runtime DEVICE_LOST writeback: the native hook asks Java CapProbe to
    /// rewrite the current fingerprint's result file with
    /// source=runtime-lost and gs_occlusion=unsupported — the fingerprint
    /// only, never the game. Called from the GPU fatal path when a real
    /// session loses the device on this combination.
    /// </summary>
    public static void MarkRuntimeLost() => RuntimeLostWrite();
}
