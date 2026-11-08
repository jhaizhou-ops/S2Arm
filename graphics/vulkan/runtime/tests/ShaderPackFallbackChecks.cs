using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Vulkan;
using S2Arm.Backends.Vulkan.Runtime;

// Exercise the production mount method with a real frozen CPU profile and a missing
// Android asset stub. No Vulkan device, game execution, or APK is involved.
static class ShaderPackFallbackChecks
{
    [System.Runtime.InteropServices.DllImport("s2arm_android")]
    private static extern void s2a_test_asset_result(long result);
    static void Set(object target, string name, object value) => target.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(target, value);
    static string Mount(AndroidVulkanRuntime runtime)
    {
        var previousError = Console.Error;
        var previousOut = Console.Out;
        using var output = new StringWriter();
        try
        {
            Console.SetError(output);
            Console.SetOut(output);
            typeof(AndroidVulkanRuntime).GetMethod("MountShaderPack", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(runtime, null);
            return output.ToString();
        }
        finally { Console.SetError(previousError); Console.SetOut(previousOut); }
    }
    static void Require(bool condition, string message)
    {
        if (!condition) throw new Exception("FAIL pack fallback: " + message);
        Console.WriteLine("PASS pack fallback " + message);
    }
    // Minimal controlled Maxwell guest program; real GPU decoder and SPIR-V translator.
    sealed class GuestCode : IGpuAccessor
    {
        readonly ulong[] code = [0x001F8000FC0007E0UL, 0xE30000000007000FUL, 0xE30000000007000FUL, 0xE30000000007000FUL];
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => code.AsSpan(checked((int)(address / 8)));
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => throw new NotSupportedException();
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => throw new NotSupportedException();
        public int QuerySamplerArrayLengthFromPool() => throw new NotSupportedException();
        public int QueryTextureArrayLengthFromBuffer(int index) => throw new NotSupportedException();
        public int QueryTextureArrayLengthFromPool() => throw new NotSupportedException();
    }
    public static void Run()
    {
        string temp = Path.Combine(Path.GetTempPath(), "s2a-pack-fallback-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            AppDataManager.Initialize(temp);
            GraphicsConfig.EnableShaderCache = true;
            GraphicsConfig.TitleId = "0100000000000001";
            var runtime = (AndroidVulkanRuntime)RuntimeHelpers.GetUninitializedObject(typeof(AndroidVulkanRuntime));
            Set(runtime, "_gameDataDirectory", temp);
            string noIndex = Mount(runtime);
            Require(noIndex.Contains("【黄】") && noIndex.Contains("按需翻译"), "missing index reports warning and fallback");
            File.WriteAllText(Path.Combine(temp, "index.tsv"), "game.nca\tfixture\n");
            var renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
            Set(renderer, "_s2aProfileOwner", new object());
            Set(renderer, "_s2aProgramIdentityGate", new object());
            renderer.S2AConfigureProgramProfileFreeze(true, typeof(GpuContext).Assembly.ManifestModule.ModuleVersionId.ToString("N"));
            Set(runtime, "_renderer", renderer);
            string noProfile = Mount(runtime);
            Require(noProfile.Contains("【红】") && noProfile.Contains("按需翻译"), "unavailable renderer profile reports error and fallback");
            typeof(VulkanRenderer).GetMethod("S2ACompleteProgramProfile", BindingFlags.Instance | BindingFlags.NonPublic)
                .Invoke(renderer, [NxGal.NxCaps.Build([31, 32768]), ComputeTranslationProfile.Select(true, true, true, false)]);
            s2a_test_asset_result(-2);
            string noPack = Mount(runtime);
            Require(noPack.Contains("【黄】") && noPack.Contains("首遇现翻") && noPack.Contains("vkpb-profile-json"), "missing package and APK asset report warning, fallback and actual profile");
            Require(!noPack.Contains("已种") && !noPack.Contains("种入") && !noPack.Contains("【红】"), "missing asset cannot be reported as installed or as a native error");
            s2a_test_asset_result(-5);
            string assetError = Mount(runtime);
            Require(assetError.Contains("【红】") && assetError.Contains("APK 资产取出失败（-5）"), "asset I/O failure remains red, distinct from ENOENT");
            s2a_test_asset_result(0);
            string emptyAsset = Mount(runtime);
            Require(emptyAsset.Contains("【红】") && emptyAsset.Contains("大小异常（0）"), "empty asset is not accepted as missing or installed");
            s2a_test_asset_result(-2);
            // This executes the same decoder/translator used by the cache-miss path after
            // the mount returned, but does not claim to run the full GPU/cache loop.
            GraphicsConfig.EnableSpirvCompilationOnVulkan = true;
            var decode = typeof(GpuContext).Assembly.GetType("Ryujinx.Graphics.Gpu.Shader.ShaderCache", true)
                .GetMethod("DecodeComputeShader", BindingFlags.Static | BindingFlags.Public);
            var shader = ((TranslatorContext)decode.Invoke(null, [new GuestCode(), TargetApi.Vulkan, 0UL])).Translate();
            Require(shader.BinaryCode is { Length: > 4 } && BitConverter.ToUInt32(shader.BinaryCode, 0) == 0x07230203, "production compute decoder/translator emits SPIR-V after missing-pack return");
        }
        finally { Directory.Delete(temp, true); }
    }
}
