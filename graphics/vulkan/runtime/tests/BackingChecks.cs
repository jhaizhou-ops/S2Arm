using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Memory.Tracking;
using S2A.Services;
using S2Arm.Backends.Vulkan.Runtime;
using System;
using System.Reflection;
using System.Runtime.CompilerServices;

// Exercises the actual runtime transaction and actual MemoryTracking state. No native GPU
// exists in these cases; active-GPU flush/fence and native VM integration need device testing.
internal static class BackingChecks
{
    private static int _checks;
    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    public static void Run()
    {
        AndroidVulkanRuntime runtime = new(1, 1, error => throw error);
        GuestMemory memory = new();
        typeof(AndroidVulkanRuntime).GetField("_tracking", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(runtime, memory.Tracking);
        MethodInfo begin = typeof(AndroidVulkanRuntime).GetMethod("BeginBackingChange", BindingFlags.Instance | BindingFlags.NonPublic);
        MethodInfo end = typeof(AndroidVulkanRuntime).GetMethod("EndBackingChange", BindingFlags.Instance | BindingFlags.NonPublic);
        void Begin(ulong address = 0x10000, ulong size = 0x1000, ulong source = 0) => begin.Invoke(runtime, [address, size, source]);
        void End(ulong address = 0x10000, int mapped = 1) => end.Invoke(runtime, [address, 0x1000UL, mapped]);
        bool Reject(Action action)
        {
            try { action(); return false; }
            catch (TargetInvocationException) { return true; }
        }

        using RegionHandle handle = memory.Tracking.BeginTracking(0x10000, 0x1000, 1);
        handle.Reprotect();
        Check(!handle.Dirty, "Tracking setup must begin clean.");
        Begin(); // Initial map is legal without any renderer/device.
        Check(handle.Unmapped, "Before replacement must unmap the old tracking handle.");
        Check(Reject(() => Begin()), "Overlapping native transactions must be rejected.");
        Check(Reject(() => End(0x20000)), "A different completion range must not resume GPU access.");
        End();
        Check(!handle.Unmapped && handle.Dirty, "New backing must remap and dirty old cached contents.");
        handle.Reprotect();
        Begin();
        End(mapped: 0);
        Check(handle.Unmapped, "Actual unmap must not pretend a new mapping exists.");
        Begin();
        End(); // Also covers a failed replacement that retained/restored the original mapping.
        Check(!handle.Unmapped && handle.Dirty, "Rollback to an existing mapping must re-enable tracking and upload.");
        Check(Reject(() => Begin(size: 0)), "Empty native transactions must be rejected.");
        Check(Reject(() => Begin(address: 1)), "Unaligned native transactions must be rejected.");
        using RegionHandle sourceHandle = memory.Tracking.BeginTracking(0x30000, 0x1000, 2);
        Begin(source: 0x30000);
        Check(!sourceHandle.Unmapped, "Alias source must not be unmapped with its destination.");
        End();

        // No Vk dispatch is available: these production methods must reject import before
        // touching the allocator. Hardware capability facts are not modified by the policy.
        VulkanRenderer renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        typeof(VulkanRenderer).GetProperty("AllowHostMemoryImport", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(renderer, false);
        Check(!renderer.PrepareHostMapping(1, 4096), "Android must use ordinary texture readback.");
        Check(renderer.CreateBuffer((nint)1, 4096) == BufferHandle.Null, "Android must use ordinary buffer uploads.");
        int admissions = 0;
        memory.Tracking.BeforeTracking = (address, size) =>
        {
            admissions++;
            Check((address | size) % 4096 == 0, "Admission must cover the aligned tracked pages.");
            throw new NotSupportedException("Controlled alias admission rejection.");
        };
        long handlesBefore = RegionHandle.S2ACreated;
        try { memory.Tracking.BeginTracking(0x50001, 31, 3); throw new Exception("Alias admission was bypassed."); }
        catch (NotSupportedException) { }
        Check(admissions == 1 && RegionHandle.S2ACreated == handlesBefore, "Rejected ordinary handle must not be published.");
        try { memory.Tracking.BeginGranularTracking(0x60000, 0x2000, null, 0x1000, 4); throw new Exception("Bitmap admission was bypassed."); }
        catch (NotSupportedException) { }
        Check(admissions == 2 && RegionHandle.S2ACreated == handlesBefore, "Rejected bitmap handle must not be published.");
        Console.WriteLine($"PASS: {_checks} production backing/import checks; active GPU/native VM NOT RUN.");
    }
}
