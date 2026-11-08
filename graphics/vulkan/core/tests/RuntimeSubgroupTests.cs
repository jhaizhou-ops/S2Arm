using Ryujinx.Graphics.Vulkan;
using S2Arm.Backends.Vulkan;
using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// Exercise the renderer's production properties query and HardwareCapabilities
// publication. Only the external Vulkan dispatch is replaced; no GPU is created.
internal static unsafe class RuntimeSubgroupTests
{
    private static readonly Assembly RuntimeAssembly = typeof(VulkanRenderer).Assembly;
    private static readonly Type PhysicalDeviceType = RuntimeAssembly.GetType("Ryujinx.Graphics.Vulkan.VulkanPhysicalDevice", true);
    private static readonly MethodInfo Load = typeof(VulkanRenderer)
        .GetMethod("LoadHardwareCapabilities", BindingFlags.Instance | BindingFlags.NonPublic);
    private static int _queries;
    private static nint _queriedDevice;
    private static bool _subgroupRequested;
    private static bool _unexpectedDevice;

    public static void Run(Action<bool, string> check)
    {
        using Vk api = new(new Dispatch());
        VulkanRenderer renderer = NewRenderer(api, new PhysicalDevice(11));
        Load.Invoke(renderer, null);
        object capabilities = GetField(renderer, "Capabilities");
        check(_queries == 1 && _queriedDevice == 11 && _subgroupRequested,
            "Subgroup properties did not come from the renderer's selected physical device query.");
        check(Read<uint>(capabilities, "SubgroupSize") == 32, "The existing subgroup size was lost.");
        check(Read<ShaderStageFlags>(capabilities, "SubgroupSupportedStages") == ShaderStageFlags.ComputeBit,
            "The queried compute stage was lost before HardwareCapabilities publication.");
        check((uint)Read<SubgroupFeatureFlags>(capabilities, "SubgroupSupportedOperations") == 0x10000039u,
            "The queried operation mask, including an additional bit, was lost or normalized.");
        check(Read<bool>(capabilities, "HasSubgroupProperties"), "Completed properties query was not recorded.");

        var gal = renderer.GetCapabilities();
        check(gal.ShaderSubgroupSize == 32, "The existing GAL subgroup size consumer changed.");
        check(!gal.SupportsShaderBallot && !gal.SupportsGeometryShader && !gal.SupportsLayerVertexTessellation,
            "Preserving queried properties must not authorize new GAL shader paths.");
        check(_queries == 1, "Reading capabilities performed another subgroup query.");

        // Vary one property at a time. A size of 32 says nothing about which
        // stages or operations support it, and an additional bit must survive.
        CheckFacts(Query(api, 12), true, 64, 0x20, 0x10000039, check, "Size-only change");
        CheckFacts(Query(api, 13), true, 32, 0x01, 0x10000039, check, "Stages-only change");
        CheckFacts(Query(api, 14), true, 32, 0x20, 0x00000001, check, "Operations-only change");
        CheckFacts(Query(api, 15), true, 32, 0, 0, check, "Known zero masks");
        CheckFacts(Query(api, 16), true, 0, 0, 0, check, "Returned zero properties");

        // An unqueried renderer must remain unknown, even after another device
        // has published support. Later queries cannot mutate earlier snapshots.
        VulkanRenderer unqueried = NewRenderer(api, new PhysicalDevice(99));
        CheckFacts(GetField(unqueried, "Capabilities"), false, 0, 0, 0, check, "Unqueried device");
        CheckFacts(GetField(renderer, "Capabilities"), true, 32, 0x20, 0x10000039, check, "Retained first device");
        check(_queries == 6 && !_unexpectedDevice, "A device's query was missing or used a different physical device.");

        // Merely advertising an extension must not fill either returned mask.
        nint extension = Marshal.StringToCoTaskMemUTF8("VK_EXT_subgroup_size_control");
        try
        {
            DeviceCreateInfo request = new()
            {
                SType = StructureType.DeviceCreateInfo,
                EnabledExtensionCount = 1,
                PpEnabledExtensionNames = (byte**)&extension,
            };
            DeviceFeatureSnapshot enabled = DeviceFeatureSnapshot.Capture(in request);
            VulkanRenderer extensionOnly = NewRenderer(api, new PhysicalDevice(15));
            SetField(extensionOnly, "_enabledFeatures", enabled);
            Load.Invoke(extensionOnly, null);
            CheckFacts(GetField(extensionOnly, "Capabilities"), true, 32, 0, 0, check, "Extension without properties support");
            check(ReferenceEquals(GetField(extensionOnly, "_enabledFeatures"), enabled) && !enabled.Core.GeometryShader,
                "The properties query changed the created device's enabled feature snapshot.");
        }
        finally
        {
            Marshal.FreeCoTaskMem(extension);
        }
    }

    private static object Query(Vk api, nint handle)
    {
        VulkanRenderer renderer = NewRenderer(api, new PhysicalDevice(handle));
        Load.Invoke(renderer, null);
        return GetField(renderer, "Capabilities");
    }

    private static void CheckFacts(object capabilities, bool known, uint size, uint stages, uint operations,
        Action<bool, string> check, string scenario)
    {
        check(Read<bool>(capabilities, "HasSubgroupProperties") == known, scenario + ": query state was lost.");
        check(Read<uint>(capabilities, "SubgroupSize") == size, scenario + ": size changed.");
        check((uint)Read<ShaderStageFlags>(capabilities, "SubgroupSupportedStages") == stages, scenario + ": stages changed.");
        check((uint)Read<SubgroupFeatureFlags>(capabilities, "SubgroupSupportedOperations") == operations, scenario + ": operations changed.");
    }

    private static VulkanRenderer NewRenderer(Vk api, PhysicalDevice handle)
    {
        object physicalDevice = Activator.CreateInstance(PhysicalDeviceType);
        SetField(physicalDevice, "PhysicalDevice", handle);
        SetField(physicalDevice, "DeviceExtensions", new HashSet<string>(StringComparer.Ordinal));
        SetField(physicalDevice, "QueueFamilyProperties", new[] { new QueueFamilyProperties() });
        VulkanRenderer renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        SetField(renderer, "_physicalDevice", physicalDevice);
        DeviceCreateInfo request = new() { SType = StructureType.DeviceCreateInfo };
        SetField(renderer, "_enabledFeatures", DeviceFeatureSnapshot.Capture(in request));
        SetField(renderer, "<Api>k__BackingField", api);
        Type formatsType = RuntimeAssembly.GetType("Ryujinx.Graphics.Vulkan.FormatCapabilities", true);
        SetField(renderer, "<FormatCapabilities>k__BackingField", Activator.CreateInstance(formatsType, api, handle));
        return renderer;
    }

    private static object GetField(object target, string name)
    {
        FieldInfo field = target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            ?? throw new MissingFieldException(target.GetType().FullName, name);
        return field.GetValue(target)
            ?? throw new InvalidOperationException($"Field {target.GetType().FullName}.{name} is unexpectedly null.");
    }

    private static T Read<T>(object target, string name) => GetField(target, name) is T value
        ? value
        : throw new InvalidOperationException($"Field {target.GetType().FullName}.{name} is not {typeof(T).FullName}.");

    private static void SetField(object target, string name, object value) => target.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).SetValue(target, value);

    [UnmanagedCallersOnly]
    private static void QueryProperties(PhysicalDevice device, PhysicalDeviceProperties2* properties)
    {
        _queries++;
        _queriedDevice = device.Handle;
        properties->Properties.VendorID = 0x13b5;
        properties->Properties.ApiVersion = (1u << 22) | (2u << 12);
        for (BaseInStructure* item = (BaseInStructure*)properties->PNext; item != null; item = item->PNext)
        {
            if (item->SType == StructureType.PhysicalDeviceSubgroupProperties)
            {
                _subgroupRequested = true;
                PhysicalDeviceSubgroupProperties* subgroup = (PhysicalDeviceSubgroupProperties*)item;
                switch (device.Handle)
                {
                    case 11:
                        subgroup->SubgroupSize = 32;
                        subgroup->SupportedStages = ShaderStageFlags.ComputeBit;
                        subgroup->SupportedOperations = SubgroupFeatureFlags.BasicBit | SubgroupFeatureFlags.BallotBit |
                            SubgroupFeatureFlags.ShuffleBit | SubgroupFeatureFlags.ShuffleRelativeBit | (SubgroupFeatureFlags)0x10000000u;
                        break;
                    case 12:
                        subgroup->SubgroupSize = 64;
                        subgroup->SupportedStages = ShaderStageFlags.ComputeBit;
                        subgroup->SupportedOperations = (SubgroupFeatureFlags)0x10000039u;
                        break;
                    case 13:
                        subgroup->SubgroupSize = 32;
                        subgroup->SupportedStages = ShaderStageFlags.VertexBit;
                        subgroup->SupportedOperations = (SubgroupFeatureFlags)0x10000039u;
                        break;
                    case 14:
                        subgroup->SubgroupSize = 32;
                        subgroup->SupportedStages = ShaderStageFlags.ComputeBit;
                        subgroup->SupportedOperations = SubgroupFeatureFlags.BasicBit;
                        break;
                    case 15:
                        subgroup->SubgroupSize = 32;
                        subgroup->SupportedStages = 0;
                        subgroup->SupportedOperations = 0;
                        break;
                    case 16:
                        subgroup->SubgroupSize = 0;
                        subgroup->SupportedStages = 0;
                        subgroup->SupportedOperations = 0;
                        break;
                    default:
                        _unexpectedDevice = true;
                        break;
                }
            }
        }
    }

    [UnmanagedCallersOnly]
    private static void QueryFormats(PhysicalDevice device, Format format, FormatProperties* properties) => *properties = default;

    [UnmanagedCallersOnly]
    private static void QueryMemory(PhysicalDevice device, PhysicalDeviceMemoryProperties* properties) => *properties = default;

    private sealed class Dispatch : INativeContext
    {
        public nint GetProcAddress(string name, int? slot = null) => name switch
        {
            "vkGetPhysicalDeviceProperties2" => (nint)(delegate* unmanaged<PhysicalDevice, PhysicalDeviceProperties2*, void>)&QueryProperties,
            "vkGetPhysicalDeviceFormatProperties" => (nint)(delegate* unmanaged<PhysicalDevice, Format, FormatProperties*, void>)&QueryFormats,
            "vkGetPhysicalDeviceMemoryProperties" => (nint)(delegate* unmanaged<PhysicalDevice, PhysicalDeviceMemoryProperties*, void>)&QueryMemory,
            _ => 0,
        };

        public bool TryGetProcAddress(string name, out nint address, int? slot = null)
        {
            address = GetProcAddress(name, slot);
            return address != 0;
        }

        public void Dispose() { }
    }
}
