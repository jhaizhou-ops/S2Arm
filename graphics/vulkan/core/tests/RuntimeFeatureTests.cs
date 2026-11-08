using Ryujinx.Graphics.Vulkan;
using S2Arm.Backends.Vulkan;
using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// Execute the production device request and GAL capability consumer with a controlled
// Vulkan dispatch. This verifies request/consumer agreement, not a real driver's behavior.
internal static unsafe partial class RuntimeFeatureTests
{
    private static readonly Assembly RuntimeAssembly = typeof(VulkanRenderer).Assembly;
    private static readonly Type PhysicalDeviceType = RuntimeAssembly.GetType("Ryujinx.Graphics.Vulkan.VulkanPhysicalDevice", true);
    private static readonly MethodInfo Create = RuntimeAssembly.GetType("Ryujinx.Graphics.Vulkan.VulkanInitialization", true)
        .GetMethod("CreateDevice", BindingFlags.Static | BindingFlags.NonPublic);
    private static DeviceFeatureSnapshot _received;
    private static Exception _callbackError;
    private static bool _failCreation;
    private static bool _drawParametersSupport = true;
    private static int _createCalls;
    private static int _featureQueries;
    private static bool _capturePromotedFeatures;
    private static PhysicalDeviceVulkan12Features _promotedSupport;
    private static StructureType[] _queriedChain;
    private static StructureType[] _requestedChain;

    private static readonly string[] PromotedExtensions =
    {
        "VK_EXT_descriptor_indexing", "VK_KHR_uniform_buffer_standard_layout",
        "VK_KHR_8bit_storage", "VK_KHR_shader_float16_int8",
    };

    private static readonly StructureType[] PromotedStructures =
    {
        StructureType.PhysicalDeviceDescriptorIndexingFeaturesExt,
        StructureType.PhysicalDeviceUniformBufferStandardLayoutFeatures,
        StructureType.PhysicalDevice8BitStorageFeatures,
        StructureType.PhysicalDeviceShaderFloat16Int8Features,
    };

    public static void Run(Action<bool, string> check)
    {
        using Vk api = new(new Dispatch());
        object physicalDevice = Activator.CreateInstance(PhysicalDeviceType);
        PhysicalDeviceProperties properties = new() { VendorID = 0x10de, ApiVersion = Vk.Version12.Value };
        SetField(physicalDevice, "PhysicalDeviceProperties", properties);
        SetField(physicalDevice, "PhysicalDevice", new PhysicalDevice(1));
        SetField(physicalDevice, "DeviceExtensions", new HashSet<string>(StringComparer.Ordinal)
        {
            "VK_KHR_swapchain", "VK_EXT_extended_dynamic_state", "VK_EXT_index_type_uint8",
            "VK_EXT_fragment_shader_interlock", "VK_EXT_conditional_rendering",
        });
        SetField(physicalDevice, "QueueFamilyProperties", new[]
        {
            new QueueFamilyProperties { QueueFlags = QueueFlags.GraphicsBit | QueueFlags.SparseBindingBit, QueueCount = 1 },
        });

        object[] arguments = { api, physicalDevice, 0u, 1u, null };
        Device device = (Device)Create.Invoke(null, arguments);
        if (_callbackError != null)
        {
            throw new InvalidOperationException("Native test callback failed.", _callbackError);
        }
        DeviceFeatureSnapshot enabled = (DeviceFeatureSnapshot)arguments[4];
        check(device.Handle != 0 && enabled != null, "Successful creation did not publish its request.");
        check(_received != null && _featureQueries == 1, "The production request did not cross the Vulkan dispatch.");
        check(!enabled.IndexTypeUint8 && !enabled.FragmentShaderPixelInterlock && !enabled.ExtendedDynamicState,
            "Advertised extension names enabled unsupported feature bits in the production device request.");
        check(enabled.ConditionalRendering && _received.ConditionalRendering,
            "Conditional rendering was advertised without enabling its feature in vkCreateDevice.");
        check(!enabled.Core.RobustBufferAccess, "The NVIDIA workaround enabled unsupported robustness.");
        check(enabled.Core.TextureCompressionBC && enabled.Core.TextureCompressionEtc2 && enabled.Core.TextureCompressionAstcLdr,
            "Native compression paths were exposed without enabling their supported feature bits.");
        check(!enabled.Core.SparseBinding, "Sparse binding requires a separate queue/resource qualification policy.");
        check(!enabled.Core.GeometryShader && enabled.Vulkan12.ShaderOutputLayer && enabled.Vulkan12.ShaderOutputViewportIndex,
            "The native layer/viewport path was exposed without enabling its supported features.");

        // Avoid renderer startup/WSI; call the real GAL consumer with the device's
        // actual request and a physical device advertising more than that request.
        VulkanRenderer renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        SetField(renderer, "_physicalDevice", physicalDevice);
        SetField(renderer, "_enabledFeatures", enabled);
        SetField(renderer, "<Api>k__BackingField", api);
        Type formatsType = RuntimeAssembly.GetType("Ryujinx.Graphics.Vulkan.FormatCapabilities", true);
        SetField(renderer, "<FormatCapabilities>k__BackingField",
            Activator.CreateInstance(formatsType, api, new PhysicalDevice(1)));
        var capabilities = renderer.GetCapabilities();
        check(!capabilities.SupportsSparseBuffer, "GAL advertised physical sparse support that was never enabled.");
        check(capabilities.SupportsLayerVertexTessellation && capabilities.SupportsViewportIndexVertexTessellation,
            "GAL lost the explicitly enabled native layer/viewport path.");
        check(!capabilities.SupportsShaderNonUniformIndexing,
            "GAL must require both enabled sampled-image and storage-image indexing features.");
        check(capabilities.SupportsBc123Compression && capabilities.SupportsEtc2Compression,
            "Enabled compression with valid format support was lost by GAL.");

        // A restricted request must stay restricted even when hardware queries and
        // format queries advertise more. Exercise the actual consumer a second time.
        DeviceCreateInfo restrictedRequest = new() { SType = StructureType.DeviceCreateInfo };
        SetField(renderer, "_enabledFeatures", DeviceFeatureSnapshot.Capture(in restrictedRequest));
        var restricted = renderer.GetCapabilities();
        check(!restricted.SupportsLayerVertexTessellation && !restricted.SupportsViewportIndexVertexTessellation,
            "GAL resurrected layer/viewport features omitted from the request.");
        check(!restricted.SupportsBc123Compression && !restricted.SupportsEtc2Compression,
            "Format support alone resurrected disabled compression features.");

        PhysicalDeviceVulkan12Features layerOnly = new()
        {
            SType = StructureType.PhysicalDeviceVulkan12Features,
            ShaderOutputLayer = true,
        };
        restrictedRequest.PNext = &layerOnly;
        SetField(renderer, "_enabledFeatures", DeviceFeatureSnapshot.Capture(in restrictedRequest));
        var singleOutput = renderer.GetCapabilities();
        check(singleOutput.SupportsLayerVertexTessellation && !singleOutput.SupportsViewportIndexVertexTessellation,
            "Layer alone must authorize only the SPIR-V 1.5 ShaderLayer path.");
        layerOnly.ShaderOutputLayer = false;
        layerOnly.ShaderOutputViewportIndex = true;
        SetField(renderer, "_enabledFeatures", DeviceFeatureSnapshot.Capture(in restrictedRequest));
        singleOutput = renderer.GetCapabilities();
        check(!singleOutput.SupportsLayerVertexTessellation && singleOutput.SupportsViewportIndexVertexTessellation,
            "Viewport alone must authorize only the SPIR-V 1.5 ShaderViewportIndex path.");
        check(_featureQueries == 1, "GAL re-queried hardware support instead of consuming the created device's features.");

        _failCreation = true;
        arguments[4] = null;
        bool failed = false;
        try
        {
            Create.Invoke(null, arguments);
        }
        catch (TargetInvocationException error) when (
            error.InnerException?.GetType().FullName == "Ryujinx.Graphics.Vulkan.VulkanException" &&
            error.InnerException.Message.Contains(nameof(Result.ErrorInitializationFailed), StringComparison.Ordinal))
        {
            failed = true;
        }
        finally
        {
            _failCreation = false;
        }
        check(failed && arguments[4] == null, "Failed device creation published an enabled feature set.");

        // A Vulkan 1.1 device must not be handed the 1.2 core feature struct, and must not
        // publish capability bits the 1.1 chain never enabled.
        _callbackError = null;
        SetField(physicalDevice, "PhysicalDeviceProperties", new PhysicalDeviceProperties
        {
            VendorID = 0x10de,
            ApiVersion = Vk.Version11.Value,
        });
        SetField(physicalDevice, "DeviceExtensions", new HashSet<string>(StringComparer.Ordinal) { "VK_KHR_swapchain" });
        object[] v11Arguments = { api, physicalDevice, 0u, 1u, null };
        Device v11Device = (Device)Create.Invoke(null, v11Arguments);
        if (_callbackError != null)
        {
            throw new InvalidOperationException("Vulkan 1.1 device creation failed.", _callbackError);
        }
        DeviceFeatureSnapshot v11 = (DeviceFeatureSnapshot)v11Arguments[4];
        check(v11Device.Handle != 0 && v11 != null, "A Vulkan 1.1 device did not publish its request.");
        check(Array.IndexOf(_queriedChain, StructureType.PhysicalDeviceVulkan11Features) < 0 &&
              Array.IndexOf(_requestedChain, StructureType.PhysicalDeviceVulkan11Features) < 0 &&
              Array.IndexOf(_queriedChain, StructureType.PhysicalDeviceShaderDrawParametersFeatures) >= 0 &&
              Array.IndexOf(_requestedChain, StructureType.PhysicalDeviceShaderDrawParametersFeatures) >= 0,
            "A Vulkan 1.1 device needs the 1.1 draw-parameters node, not the Vulkan 1.2 aggregate.");
        check(!v11.Vulkan12.DescriptorIndexing && !v11.Vulkan12.DrawIndirectCount &&
              !v11.Vulkan12.ShaderInt8 && !v11.Vulkan12.ShaderOutputLayer,
            "A Vulkan 1.1 device published Vulkan 1.2 feature bits.");
        check(!v11.HasExtension("VK_EXT_descriptor_indexing") && !v11.HasExtension("VK_KHR_8bit_storage"),
            "A Vulkan 1.1 device enabled extensions it never advertised.");

        SetField(physicalDevice, "DeviceExtensions", new HashSet<string>(StringComparer.Ordinal)
        {
            "VK_KHR_swapchain", "VK_EXT_shader_viewport_index_layer",
        });
        object[] layerExtArgs = { api, physicalDevice, 0u, 1u, null };
        Create.Invoke(null, layerExtArgs);
        check(((DeviceFeatureSnapshot)layerExtArgs[4]).HasExtension("VK_EXT_shader_viewport_index_layer") &&
              _received.HasExtension("VK_EXT_shader_viewport_index_layer"),
            "Vulkan 1.1 must enable the advertised layer extension in the actual request.");

        DrawParametersChains(api, physicalDevice, check);
        PromotedFeatureChains(api, physicalDevice, check);
        DriverQuirkRequests(api, physicalDevice, check);
    }

    private static void DrawParametersChains(Vk api, object physicalDevice, Action<bool, string> check)
    {
        try
        {
            foreach (uint version in new[] { Vk.Version11.Value, Vk.Version12.Value, Vk.Version13.Value })
            {
                SetField(physicalDevice, "PhysicalDeviceProperties", new PhysicalDeviceProperties
                {
                    VendorID = 0x10de,
                    ApiVersion = version,
                });
                foreach (bool supported in new[] { true, false })
                {
                    _drawParametersSupport = supported;
                    int previousCreateCalls = _createCalls;
                    object[] arguments = { api, physicalDevice, 0u, 1u, null };
                    bool rejected = false;
                    try
                    {
                        Create.Invoke(null, arguments);
                    }
                    catch (TargetInvocationException error) when (
                        error.InnerException?.GetType().FullName == "Ryujinx.Graphics.Vulkan.VulkanException" &&
                        error.InnerException.Message.Contains("shaderDrawParameters", StringComparison.Ordinal))
                    {
                        rejected = true;
                    }
                    check(_callbackError == null, "Draw-parameters dispatch callback failed.");
                    check(Array.IndexOf(_queriedChain, StructureType.PhysicalDeviceVulkan11Features) < 0 &&
                          Array.FindAll(_queriedChain, type => type == StructureType.PhysicalDeviceShaderDrawParametersFeatures).Length == 1,
                        "Query must contain exactly one standalone draw-parameters node and no aggregate alias.");
                    if (supported)
                    {
                        check(!rejected && _createCalls == previousCreateCalls + 1 &&
                              ((DeviceFeatureSnapshot)arguments[4]).ShaderDrawParameters && _received.ShaderDrawParameters,
                            "Supported draw parameters were not copied into the actual successful device request.");
                        check(Array.IndexOf(_requestedChain, StructureType.PhysicalDeviceVulkan11Features) < 0 &&
                              Array.FindAll(_requestedChain, type => type == StructureType.PhysicalDeviceShaderDrawParametersFeatures).Length == 1,
                            "Device creation must contain exactly one standalone draw-parameters node and no aggregate alias.");
                    }
                    else
                    {
                        check(rejected && _createCalls == previousCreateCalls && arguments[4] == null,
                            "Unsupported draw parameters must fail before device creation and enabled-state publication.");
                    }
                }
            }
        }
        finally
        {
            _drawParametersSupport = true;
        }
    }

    private static void PromotedFeatureChains(Vk api, object physicalDevice, Action<bool, string> check)
    {
        List<string> failures = new();
        int cases = 0;
        int assertions = 0;
        _capturePromotedFeatures = true;
        try
        {
            // All 16 advertised extension subsets, with all-true, mixed and all-false
            // support. Only nodes reached by the real query receive feature values.
            for (int profile = 0; profile < 3; profile++)
            {
                for (int mask = 0; mask < 16; mask++)
                {
                    RunCase(Vk.Version11.Value, mask, profile);
                }

                // Advertising the promoted extension names on 1.2 must still use
                // exactly one aggregate core node, with no alias structures.
                RunCase(Vk.Version12.Value, 15, profile);
            }
        }
        finally
        {
            _capturePromotedFeatures = false;
        }

        Console.WriteLine($"Promoted feature chains: {cases} cases, {assertions} checks, {failures.Count} failures (CPU dispatch only).");
        check(failures.Count == 0, string.Join(Environment.NewLine, failures));

        void RunCase(uint apiVersion, int mask, int profile)
        {
            cases++;
            bool core12 = apiVersion >= Vk.Version12.Value;
            bool all = profile == 0;
            bool mixed = profile == 1;
            _promotedSupport = new PhysicalDeviceVulkan12Features
            {
                DescriptorIndexing = all || mixed,
                ShaderSampledImageArrayNonUniformIndexing = all || mixed,
                ShaderStorageImageArrayNonUniformIndexing = all,
                RuntimeDescriptorArray = all || mixed,
                UniformBufferStandardLayout = all,
                StorageBuffer8BitAccess = all || mixed,
                UniformAndStorageBuffer8BitAccess = all,
                ShaderFloat16 = all,
                ShaderInt8 = all || mixed,
            };
            HashSet<string> extensions = new(StringComparer.Ordinal) { "VK_KHR_swapchain" };
            for (int i = 0; i < PromotedExtensions.Length; i++)
            {
                if ((mask & (1 << i)) != 0) extensions.Add(PromotedExtensions[i]);
            }
            SetField(physicalDevice, "PhysicalDeviceProperties", new PhysicalDeviceProperties
            {
                VendorID = 0x10de,
                ApiVersion = apiVersion,
            });
            SetField(physicalDevice, "DeviceExtensions", extensions);
            _callbackError = null;
            _queriedChain = null;
            _requestedChain = null;
            _received = null;
            int previousQueries = _featureQueries;
            object[] arguments = { api, physicalDevice, 0u, 1u, null };
            Device device = (Device)Create.Invoke(null, arguments);
            if (_callbackError != null) throw new InvalidOperationException("Promoted feature dispatch failed.", _callbackError);
            DeviceFeatureSnapshot enabled = (DeviceFeatureSnapshot)arguments[4];
            string label = $"Vulkan {(core12 ? "1.2" : "1.1")} extensions=0x{mask:x} support={profile}";

            Verify(device.Handle != 0 && enabled != null && _received != null, "creation/snapshot missing");
            Verify(_featureQueries == previousQueries + 1, "query did not cross the real dispatch exactly once");
            Verify(_queriedChain != null && _requestedChain != null, "query/create chain was not captured");
            Verify(Contains(_queriedChain, StructureType.PhysicalDeviceVulkan12Features) == core12,
                "wrong aggregate query node");
            Verify(Contains(_requestedChain, StructureType.PhysicalDeviceVulkan12Features) == core12,
                "wrong aggregate enabled node");
            for (int i = 0; i < PromotedStructures.Length; i++)
            {
                bool advertised = (mask & (1 << i)) != 0;
                bool expected = !core12 && advertised;
                Verify(Contains(_queriedChain, PromotedStructures[i]) == expected, $"query lost/duplicated {PromotedStructures[i]}");
                Verify(Contains(_requestedChain, PromotedStructures[i]) == expected, $"enable lost/duplicated {PromotedStructures[i]}");
                if (!core12)
                {
                    Verify(enabled.HasExtension(PromotedExtensions[i]) == advertised, $"wrong enabled extension {PromotedExtensions[i]}");
                }
            }

            CheckFeatures(enabled.Vulkan12, "published");
            CheckFeatures(_received.Vulkan12, "vkCreateDevice");

            void CheckFeatures(PhysicalDeviceVulkan12Features actual, string boundary)
            {
                bool descriptor = core12 || (mask & 1) != 0;
                bool uniform = core12 || (mask & 2) != 0;
                bool storage = core12 || (mask & 4) != 0;
                Verify(actual.ShaderSampledImageArrayNonUniformIndexing == (descriptor && (all || mixed)), boundary + " sampled-image indexing mismatch");
                Verify(actual.ShaderStorageImageArrayNonUniformIndexing == (descriptor && all), boundary + " storage-image indexing mismatch");
                Verify(actual.UniformBufferStandardLayout == (uniform && all), boundary + " uniform layout mismatch");
                Verify(actual.StorageBuffer8BitAccess == (storage && (all || mixed)), boundary + " storage8 mismatch");
                Verify(actual.UniformAndStorageBuffer8BitAccess == (storage && all), boundary + " uniform/storage8 mismatch");
                if (!core12)
                {
                    bool arithmetic = (mask & 8) != 0;
                    Verify(actual.RuntimeDescriptorArray == (descriptor && (all || mixed)), boundary + " runtime descriptor array mismatch");
                    Verify(actual.ShaderFloat16 == (arithmetic && all), boundary + " float16 mismatch");
                    Verify(actual.ShaderInt8 == (arithmetic && (all || mixed)), boundary + " int8 mismatch");
                }
            }

            void Verify(bool condition, string message)
            {
                assertions++;
                if (!condition) failures.Add(label + ": " + message);
            }
        }
    }

    private static bool Contains(StructureType[] chain, StructureType type) => Array.IndexOf(chain, type) >= 0;

    private static StructureType[] ReadChain(void* head)
    {
        List<StructureType> chain = new();
        HashSet<StructureType> seen = new();
        for (BaseInStructure* item = (BaseInStructure*)head; item != null; item = item->PNext)
        {
            if (!seen.Add(item->SType)) throw new InvalidOperationException("Repeated/cyclic native feature node: " + item->SType);
            chain.Add(item->SType);
        }
        return chain.ToArray();
    }

    private static void FillPromotedFeatures(PhysicalDeviceFeatures2* features)
    {
        _queriedChain = ReadChain(features->PNext);
        for (BaseInStructure* item = (BaseInStructure*)features->PNext; item != null; item = item->PNext)
        {
            switch (item->SType)
            {
                case StructureType.PhysicalDeviceVulkan12Features:
                    PhysicalDeviceVulkan12Features* core = (PhysicalDeviceVulkan12Features*)item;
                    core->DescriptorIndexing = _promotedSupport.DescriptorIndexing;
                    core->ShaderSampledImageArrayNonUniformIndexing = _promotedSupport.ShaderSampledImageArrayNonUniformIndexing;
                    core->ShaderStorageImageArrayNonUniformIndexing = _promotedSupport.ShaderStorageImageArrayNonUniformIndexing;
                    core->UniformBufferStandardLayout = _promotedSupport.UniformBufferStandardLayout;
                    core->StorageBuffer8BitAccess = _promotedSupport.StorageBuffer8BitAccess;
                    core->UniformAndStorageBuffer8BitAccess = _promotedSupport.UniformAndStorageBuffer8BitAccess;
                    break;
                case StructureType.PhysicalDeviceDescriptorIndexingFeaturesExt:
                    PhysicalDeviceDescriptorIndexingFeaturesEXT* descriptor = (PhysicalDeviceDescriptorIndexingFeaturesEXT*)item;
                    descriptor->ShaderSampledImageArrayNonUniformIndexing = _promotedSupport.ShaderSampledImageArrayNonUniformIndexing;
                    descriptor->ShaderStorageImageArrayNonUniformIndexing = _promotedSupport.ShaderStorageImageArrayNonUniformIndexing;
                    descriptor->RuntimeDescriptorArray = _promotedSupport.RuntimeDescriptorArray;
                    break;
                case StructureType.PhysicalDeviceUniformBufferStandardLayoutFeatures:
                    ((PhysicalDeviceUniformBufferStandardLayoutFeatures*)item)->UniformBufferStandardLayout = _promotedSupport.UniformBufferStandardLayout;
                    break;
                case StructureType.PhysicalDevice8BitStorageFeatures:
                    PhysicalDevice8BitStorageFeatures* storage = (PhysicalDevice8BitStorageFeatures*)item;
                    storage->StorageBuffer8BitAccess = _promotedSupport.StorageBuffer8BitAccess;
                    storage->UniformAndStorageBuffer8BitAccess = _promotedSupport.UniformAndStorageBuffer8BitAccess;
                    break;
                case StructureType.PhysicalDeviceShaderFloat16Int8Features:
                    PhysicalDeviceShaderFloat16Int8Features* arithmetic = (PhysicalDeviceShaderFloat16Int8Features*)item;
                    arithmetic->ShaderFloat16 = _promotedSupport.ShaderFloat16;
                    arithmetic->ShaderInt8 = _promotedSupport.ShaderInt8;
                    break;
            }
        }
    }

    private static void SetField(object target, string name, object value)
    {
        target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).SetValue(target, value);
    }

    [UnmanagedCallersOnly]
    private static void QueryFeatures(PhysicalDevice device, PhysicalDeviceFeatures2* features)
    {
        _featureQueries++;
        _queriedChain = ReadChain(features->PNext);
        for (BaseInStructure* item = (BaseInStructure*)features->PNext; item != null; item = item->PNext)
        {
            if (item->SType == StructureType.PhysicalDeviceShaderDrawParametersFeatures)
            {
                ((PhysicalDeviceShaderDrawParametersFeatures*)item)->ShaderDrawParameters = _drawParametersSupport;
            }
        }
        features->Features = new PhysicalDeviceFeatures
        {
            SparseBinding = true, GeometryShader = _quirkFixture, TextureCompressionBC = true,
            RobustBufferAccess = _quirkSupported,
            TextureCompressionEtc2 = true, TextureCompressionAstcLdr = true,
        };
        if (_quirkFixture) FillQuirkFeatures(features);
        if (_capturePromotedFeatures)
        {
            try { FillPromotedFeatures(features); }
            catch (Exception error) { _callbackError = error; }
            return;
        }
        for (BaseInStructure* item = (BaseInStructure*)features->PNext; item != null; item = item->PNext)
        {
            if (item->SType == StructureType.PhysicalDeviceVulkan12Features)
            {
                PhysicalDeviceVulkan12Features* vk12 = (PhysicalDeviceVulkan12Features*)item;
                vk12->ShaderOutputLayer = true;
                vk12->ShaderOutputViewportIndex = true;
                vk12->ShaderSampledImageArrayNonUniformIndexing = true;
                vk12->ShaderStorageImageArrayNonUniformIndexing = false;
            }
            else if (item->SType == StructureType.PhysicalDeviceConditionalRenderingFeaturesExt)
            {
                ((PhysicalDeviceConditionalRenderingFeaturesEXT*)item)->ConditionalRendering = true;
            }
        }
    }

    [UnmanagedCallersOnly]
    private static Result CreateDevice(PhysicalDevice physicalDevice, DeviceCreateInfo* request, AllocationCallbacks* allocator, Device* device)
    {
        _createCalls++;
        try
        {
            _requestedChain = ReadChain(request->PNext);
            _received = DeviceFeatureSnapshot.Capture(in *request);
            *device = _failCreation ? default : new Device(2);
            return _failCreation ? Result.ErrorInitializationFailed : Result.Success;
        }
        catch (Exception error)
        {
            _callbackError = error;
            *device = default;
            return Result.ErrorInitializationFailed;
        }
    }

    [UnmanagedCallersOnly]
    private static void QueryFormats(PhysicalDevice device, Format format, FormatProperties* properties)
    {
        *properties = new FormatProperties
        {
            BufferFeatures = FormatFeatureFlags.VertexBufferBit,
            OptimalTilingFeatures = FormatFeatureFlags.SampledImageBit | FormatFeatureFlags.SampledImageFilterLinearBit |
                FormatFeatureFlags.BlitSrcBit | FormatFeatureFlags.TransferSrcBit | FormatFeatureFlags.TransferDstBit,
        };
    }

    [UnmanagedCallersOnly]
    private static void QueryMemory(PhysicalDevice device, PhysicalDeviceMemoryProperties* properties)
    {
        *properties = default;
    }

    private sealed class Dispatch : INativeContext
    {
        public nint GetProcAddress(string name, int? slot = null) => name switch
        {
            "vkGetPhysicalDeviceFeatures2" => (nint)(delegate* unmanaged<PhysicalDevice, PhysicalDeviceFeatures2*, void>)&QueryFeatures,
            "vkGetPhysicalDeviceProperties2" => (nint)(delegate* unmanaged<PhysicalDevice, PhysicalDeviceProperties2*, void>)&QueryDriverProperties,
            "vkCreateDevice" => (nint)(delegate* unmanaged<PhysicalDevice, DeviceCreateInfo*, AllocationCallbacks*, Device*, Result>)&CreateDevice,
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
