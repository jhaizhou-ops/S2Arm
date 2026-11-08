using Ryujinx.Graphics.Vulkan;
using S2Arm.Backends.Vulkan;
using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

// Executes the production device request against a controlled dispatch. This proves the
// query/request/publication boundary, not Android entry points or GPU presentation.
internal static unsafe class Program
{
    private static bool _feature, _fail, _queried;
    private static DeviceFeatureSnapshot _request;
    private static Exception _callbackFailure;
    private static int _checks;
    private const string Extension = "VK_EXT_swapchain_maintenance1";

    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Main()
    {
        foreach (bool advertised in new[] { false, true })
        foreach (bool instanceEnabled in new[] { false, true })
        foreach (bool feature in new[] { false, true })
            Run(advertised, instanceEnabled, feature, false);
        Run(true, true, true, true);
        QaMaintenancePolicy();
        BackingChecks.Run();
        ShaderPackFallbackChecks.Run();
        SpirvValidityChecks.Run();
        Console.WriteLine($"PASS: {_checks} production maintenance feature checks; GPU/Android NOT RUN.");
    }

    private static void QaMaintenancePolicy()
    {
        MethodInfo policy = typeof(VulkanRenderer).GetMethod("S2ASurfaceMaintenanceEnabled", BindingFlags.NonPublic | BindingFlags.Static);
        Check(policy != null, "production maintenance QA policy missing");
        foreach (bool android in new[] { false, true })
        foreach (bool instance in new[] { false, true })
        foreach (bool forceOff in new[] { false, true })
        {
            bool enabled = (bool)policy.Invoke(null, new object[] { android, instance, forceOff });
            Check(enabled == (android && instance && !forceOff), "QA policy must preserve default and disable only when requested");
            // Feed the actual policy result to the production device creation routine and
            // inspect vkCreateDevice's real extension list and feature pNext.
            Run(true, enabled, true, false);
        }
    }

    private static void Run(bool advertised, bool instanceEnabled, bool feature, bool fail)
    {
        _feature = feature; _fail = fail; _queried = false; _request = null; _callbackFailure = null;
        using Vk api = new(new Dispatch());
        Assembly assembly = typeof(VulkanRenderer).Assembly;
        Type physicalType = assembly.GetType("Ryujinx.Graphics.Vulkan.VulkanPhysicalDevice", true);
        object physical = Activator.CreateInstance(physicalType);
        void Set(string name, object value) => physicalType.GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).SetValue(physical, value);
        Set("PhysicalDeviceProperties", new PhysicalDeviceProperties { ApiVersion = Vk.Version12.Value });
        Set("PhysicalDevice", new PhysicalDevice(1));
        HashSet<string> extensions = new(StringComparer.Ordinal) { "VK_KHR_swapchain" };
        if (advertised) extensions.Add(Extension);
        Set("DeviceExtensions", extensions);
        Set("QueueFamilyProperties", new[] { new QueueFamilyProperties { QueueFlags = QueueFlags.GraphicsBit, QueueCount = 1 } });
        MethodInfo create = typeof(VulkanInitialization).GetMethod("CreateDeviceWithSurfaceMaintenance", BindingFlags.NonPublic | BindingFlags.Static);
        object[] args = { api, physical, 0u, 1u, null, instanceEnabled };
        bool rejected = false;
        try { create.Invoke(null, args); }
        catch (TargetInvocationException) when (fail) { rejected = true; }
        if (_callbackFailure != null) throw _callbackFailure;
        Check(_queried == (advertised && instanceEnabled), "Unadvertised or missing instance dependency entered query pNext.");
        Check(_request != null, "vkCreateDevice was bypassed.");
        bool enabled = advertised && instanceEnabled && feature;
        Check(_request.SwapchainMaintenance1 == enabled, "Snapshot does not match the actually requested feature.");
        Check(_request.HasExtension(Extension) == enabled, "Device extension enabled without all its dependencies/feature.");
        if (fail)
        {
            Check(rejected && args[4] == null, "Failed vkCreateDevice published enabled state.");
        }
        else
        {
            Check(args[4] is DeviceFeatureSnapshot published && published.SwapchainMaintenance1 == enabled,
                "Successful creation did not publish its exact request.");
        }
    }

    [UnmanagedCallersOnly]
    private static void Query(PhysicalDevice device, PhysicalDeviceFeatures2* features)
    {
        for (BaseOutStructure* item = (BaseOutStructure*)features->PNext; item != null; item = item->PNext)
        {
            if (item->SType == StructureType.PhysicalDeviceShaderDrawParametersFeatures)
                ((PhysicalDeviceShaderDrawParametersFeatures*)item)->ShaderDrawParameters = true;
            if (item->SType == StructureType.PhysicalDeviceSwapchainMaintenance1FeaturesExt)
            {
                _queried = true;
                ((PhysicalDeviceSwapchainMaintenance1FeaturesEXT*)item)->SwapchainMaintenance1 = _feature;
            }
        }
    }

    [UnmanagedCallersOnly]
    private static Result Create(PhysicalDevice physical, DeviceCreateInfo* request, AllocationCallbacks* allocator, Device* device)
    {
        try
        {
            _request = DeviceFeatureSnapshot.Capture(in *request);
            *device = _fail ? default : new Device(2);
            return _fail ? Result.ErrorInitializationFailed : Result.Success;
        }
        catch (Exception error) { _callbackFailure = error; *device = default; return Result.ErrorInitializationFailed; }
    }

    private sealed class Dispatch : INativeContext
    {
        public nint GetProcAddress(string name, int? slot = null) => name switch
        {
            "vkGetPhysicalDeviceFeatures2" => (nint)(delegate* unmanaged<PhysicalDevice, PhysicalDeviceFeatures2*, void>)&Query,
            "vkCreateDevice" => (nint)(delegate* unmanaged<PhysicalDevice, DeviceCreateInfo*, AllocationCallbacks*, Device*, Result>)&Create,
            _ => 0,
        };
        public bool TryGetProcAddress(string name, out nint address, int? slot = null)
        { address = GetProcAddress(name, slot); return address != 0; }
        public void Dispose() { }
    }
}
