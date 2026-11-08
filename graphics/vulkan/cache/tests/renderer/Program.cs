// Exercises the real renderer identity/export commit half with captured CPU facts.
// It deliberately bypasses native device construction; this is not Vulkan/GPU execution.
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Vulkan;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;

static class RendererProfileTests
{
    static int count;
    static void Check(bool value, string message)
    {
        if (!value) throw new Exception("FAIL renderer-profile: " + message);
        count++;
        Console.WriteLine("PASS renderer-profile " + message);
    }
    static object Field(VulkanRenderer renderer, string name) => typeof(VulkanRenderer)
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(renderer);
    static void Set(VulkanRenderer renderer, string name, object value) => typeof(VulkanRenderer)
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(renderer, value);
    static void Reject(Action action, string name)
    {
        try { action(); }
        catch (InvalidOperationException) { Check(true, name); return; }
        catch (TargetInvocationException e) when (e.InnerException is InvalidOperationException) { Check(true, name); return; }
        throw new Exception("FAIL renderer-profile accepted " + name);
    }
    static object Identity(VulkanRenderer renderer) => typeof(VulkanRenderer)
        .GetProperty("S2AProgramBinaryIdentity", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(renderer);
    static void Complete(VulkanRenderer renderer, Capabilities caps, ComputeTranslationProfile selection) => typeof(VulkanRenderer)
        .GetMethod("S2ACompleteProgramProfile", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(renderer, [caps, selection]);
    static VulkanRenderer Renderer()
    {
        // No constructor: on macOS it initializes MoltenVK. Set only the CPU profile gate's
        // readonly owner; all native fields remain absent and must never be read by this test.
        VulkanRenderer renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        Set(renderer, "_s2aProfileOwner", new object());
        Set(renderer, "_s2aProgramIdentityGate", new object());
        return renderer;
    }
    public static void Main()
    {
        VulkanRenderer renderer = Renderer();
        Check(renderer.ComputeTranslationProfile == null, "default is unprofiled/legacy");
        renderer.S2AConfigureProgramProfileFreeze(true, typeof(GpuContext).Assembly.ManifestModule.ModuleVersionId.ToString("N"));
        Reject(() => renderer.S2ASerializeProgramProfile(), "export before initialized selection rejected");
        Reject(() => Identity(renderer), "identity before initialized selection rejected");
        Reject(() => renderer.GetCapabilities(), "capability access before initialized selection rejected");
        Capabilities caps = NxGal.NxCaps.Build([31, 32768]);
        Complete(renderer, caps, ComputeTranslationProfile.Select(true, true, true, false));
        byte[] first = renderer.S2ASerializeProgramProfile();
        VulkanProfile profile = VulkanProfile.Parse(first);
        Check(profile.IsFrozen && profile.Identity.Equals(Identity(renderer)) &&
            ReferenceEquals(renderer.ComputeTranslationProfile, ((ProgramBinaryProfileSnapshot)Field(renderer, "_s2aProfileSnapshot")).Profile.ComputeProfile),
            "real identity/export/provider share one selected object");
        string discriminator = renderer.HostProgramCacheDiscriminator;
        Check(renderer.S2ASerializeProgramProfile().SequenceEqual(first) &&
            renderer.HostProgramCacheDiscriminator == discriminator, "repeated real exports/cache identity remain stable");
        // Later input changes do not rebuild from mutable input fields.
        Set(renderer, "_s2aRequestedSpirv", false);
        Set(renderer, "_s2aGpuTranslationProducer", new string('a', 32));
        Check(renderer.S2ASerializeProgramProfile().SequenceEqual(first) && profile.Identity.Equals(Identity(renderer)),
            "post-freeze producer/selection inputs cannot rewrite the chosen profile");
        Reject(() => Complete(renderer, caps, ComputeTranslationProfile.Select(false, true, true, false)),
            "same renderer cannot replace its selected device profile");
        Reject(() => renderer.S2AConfigureProgramProfileFreeze(false, new string('b', 32)), "live profile cannot be reconfigured");
        var snapshot = (ProgramBinaryProfileSnapshot)Field(renderer, "_s2aProfileSnapshot");
        snapshot.Retire(Field(renderer, "_s2aProfileOwner"));
        Reject(() => renderer.S2ASerializeProgramProfile(), "real export rejects retired profile");
        Reject(() => Identity(renderer), "cached identity cannot bypass retirement");
        Reject(() => { _ = renderer.HostProgramCacheDiscriminator; }, "cached discriminator cannot bypass retirement");
        VulkanRenderer rebuilt = Renderer();
        rebuilt.S2AConfigureProgramProfileFreeze(true, typeof(GpuContext).Assembly.ManifestModule.ModuleVersionId.ToString("N"));
        Complete(rebuilt, caps, ComputeTranslationProfile.Select(true, true, true, false));
        Check(rebuilt.S2ASerializeProgramProfile().SequenceEqual(first) &&
            !ReferenceEquals(rebuilt.ComputeTranslationProfile, profile.ComputeProfile),
            "new renderer has a new generation and equal portable bytes");
        Reject(() => snapshot.RequireCurrent(Field(rebuilt, "_s2aProfileOwner")), "old snapshot cannot enter rebuilt renderer");
        Console.WriteLine($"RENDERER_PROFILE checks={count} native_device_initialized=false gpu_executed=false");
    }
}
