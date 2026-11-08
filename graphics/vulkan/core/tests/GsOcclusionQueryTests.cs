using S2Arm.Backends.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.IO;
using System.Reflection;

internal static class GsOcclusionQueryTests
{
    // The internal Vulkan exception type: IsDeviceLostError must key on the
    // real type + result enum name, never a hand-rolled look-alike.
    private static Exception VulkanError(Result result)
    {
        Type type = typeof(DeviceFeatureSnapshot).Assembly
            .GetType("Ryujinx.Graphics.Vulkan.VulkanException");
        return (Exception)Activator.CreateInstance(type,
            BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance,
            null, new object[] { result }, null);
    }

    private static string WriteResult(string dir, string verdict)
    {
        string path = Path.Combine(dir, "result.json");
        File.WriteAllText(path,
            "{\"schema\":1,\"verdict\":{\"gs_occlusion\":\"" + verdict + "\"," +
            "\"tess_occlusion\":\"supported\"}}");
        return path;
    }

    public static void Run(Action<bool, string> check)
    {
        Func<string> originalPath = GsOcclusionQuerySupport.ResultPath;
        Action originalWrite = GsOcclusionQuerySupport.RuntimeLostWrite;
        string dir = Path.Combine(Path.GetTempPath(), "gsocc-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            // Capability bit reads the published verdict file exactly.
            GsOcclusionQuerySupport.ResultPath = () => WriteResult(dir, "supported");
            check(GsOcclusionQuerySupport.Supported(), "supported verdict must enable the bit");
            GsOcclusionQuerySupport.ResultPath = () => WriteResult(dir, "unsupported");
            check(!GsOcclusionQuerySupport.Supported(), "unsupported verdict must disable the bit");
            GsOcclusionQuerySupport.ResultPath = () => WriteResult(dir, "inconclusive");
            check(!GsOcclusionQuerySupport.Supported(), "inconclusive verdict must disable the bit");
            GsOcclusionQuerySupport.ResultPath = () => Path.Combine(dir, "absent.json");
            check(!GsOcclusionQuerySupport.Supported(), "missing result file must disable the bit");
            string garbage = Path.Combine(dir, "garbage.json");
            File.WriteAllText(garbage, "not json at all");
            GsOcclusionQuerySupport.ResultPath = () => garbage;
            check(!GsOcclusionQuerySupport.Supported(), "unreadable result file must disable the bit");
            string noVerdict = Path.Combine(dir, "noverdict.json");
            File.WriteAllText(noVerdict, "{\"schema\":1}");
            GsOcclusionQuerySupport.ResultPath = () => noVerdict;
            check(!GsOcclusionQuerySupport.Supported(), "verdict-less file must disable the bit");
            GsOcclusionQuerySupport.ResultPath = () => null;
            check(!GsOcclusionQuerySupport.Supported(), "unpublished result must disable the bit");

            // DEVICE_LOST identification walks the exception chain and needs
            // both the real VulkanException type and the result enum name.
            check(GsOcclusionQuerySupport.IsDeviceLostError(VulkanError(Result.ErrorDeviceLost)),
                "DEVICE_LOST exception not identified");
            check(!GsOcclusionQuerySupport.IsDeviceLostError(VulkanError(Result.ErrorOutOfHostMemory)),
                "non-LOST Vulkan error misidentified as DEVICE_LOST");
            check(GsOcclusionQuerySupport.IsDeviceLostError(
                    new InvalidOperationException("wrapper", VulkanError(Result.ErrorDeviceLost))),
                "DEVICE_LOST must be found through InnerException");
            check(!GsOcclusionQuerySupport.IsDeviceLostError(
                    new InvalidOperationException("ErrorDeviceLost")),
                "message look-alike without the VulkanException type must not match");
            check(!GsOcclusionQuerySupport.IsDeviceLostError(new Exception()),
                "unrelated exception misidentified as DEVICE_LOST");

            // Runtime-lost writeback goes through the injectable seam; the
            // production seam P/Invokes into the native CapProbe host.
            int writes = 0;
            GsOcclusionQuerySupport.RuntimeLostWrite = () => writes++;
            GsOcclusionQuerySupport.MarkRuntimeLost();
            check(writes == 1, "runtime-lost writeback was not invoked exactly once");

            // Apple/Metal contract (#1456): the Metal capability table must
            // keep both GS bits false and never consult the probe file —
            // NxCaps.Build simply does not pass the parameter. Point the
            // probe seam at a supported verdict anyway and prove the Metal
            // answer does not move.
            GsOcclusionQuerySupport.ResultPath = () => WriteResult(dir, "supported");
            var metal = NxGal.NxCaps.Build(new ulong[] { 0xffffffffffffffffUL, 1UL << 30 });
            check(!metal.SupportsGeometryShader && !metal.SupportsGeometryShaderOcclusionQuery,
                "Metal must keep GS and the occlusion-query bit false");
            check(!metal.SupportsGeometryShaderOcclusionQuery,
                "Metal must not read the capprobe result file");
        }
        finally
        {
            GsOcclusionQuerySupport.ResultPath = originalPath;
            GsOcclusionQuerySupport.RuntimeLostWrite = originalWrite;
            Directory.Delete(dir, true);
        }
    }
}
