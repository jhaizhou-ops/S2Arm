using S2Arm.Backends.Vulkan;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Silk.NET.Core;
using Silk.NET.Vulkan;
using Silk.NET.Vulkan.Extensions.EXT;
using Silk.NET.Vulkan.Extensions.KHR;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Vulkan
{
    public unsafe static class VulkanInitialization
    {
        private const uint InvalidIndex = uint.MaxValue;
        private static readonly uint _minimalVulkanVersion = Vk.Version11.Value;
        private static readonly uint _minimalInstanceVulkanVersion = Vk.Version12.Value;
        private static readonly uint _maximumVulkanVersion = Vk.Version12.Value;
        private const string AppName = "Ryujinx.Graphics.Vulkan";
        private const int QueuesCount = 2;

        private static readonly string[] _desirableExtensions =
        [
            ExtConditionalRendering.ExtensionName,
            ExtExtendedDynamicState.ExtensionName,
            ExtTransformFeedback.ExtensionName,
            KhrDrawIndirectCount.ExtensionName,
            KhrPushDescriptor.ExtensionName,
            ExtExternalMemoryHost.ExtensionName,
            "VK_EXT_blend_operation_advanced",
            "VK_EXT_custom_border_color",
            "VK_EXT_descriptor_indexing", // Enabling this works around an issue with disposed buffer bindings on RADV.
            "VK_EXT_fragment_shader_interlock",
            "VK_EXT_index_type_uint8",
            "VK_EXT_primitive_topology_list_restart",
            "VK_EXT_robustness2",
            "VK_EXT_shader_stencil_export",
            "VK_KHR_shader_float16_int8",
            "VK_EXT_shader_subgroup_ballot",
            "VK_NV_geometry_shader_passthrough",
            "VK_NV_viewport_array2",
            "VK_EXT_depth_clip_control",
            "VK_KHR_portability_subset", // As per spec, we should enable this if present.
            "VK_EXT_4444_formats",
            "VK_KHR_8bit_storage",
            "VK_KHR_maintenance2",
            "VK_EXT_attachment_feedback_loop_layout",
            "VK_EXT_attachment_feedback_loop_dynamic_state"
        ];

        private static readonly string[] _requiredExtensions =
        [
            KhrSwapchain.ExtensionName
        ];

        internal static VulkanInstance CreateInstance(Vk api, GraphicsDebugLevel logLevel, string[] requiredExtensions)
        {
            List<string> enabledLayers = [];

            IReadOnlySet<string> instanceExtensions = VulkanInstance.GetInstanceExtensions(api);
            IReadOnlySet<string> instanceLayers = VulkanInstance.GetInstanceLayers(api);

            void AddAvailableLayer(string layerName)
            {
                if (instanceLayers.Contains(layerName))
                {
                    enabledLayers.Add(layerName);
                }
                else
                {
                    Logger.Warning?.Print(LogClass.Gpu, $"Missing layer {layerName}");
                }
            }

            if (logLevel != GraphicsDebugLevel.None)
            {
                AddAvailableLayer("VK_LAYER_KHRONOS_validation");
            }

            string[] enabledExtensions = requiredExtensions;

            if (instanceExtensions.Contains("VK_EXT_debug_utils"))
            {
                enabledExtensions = enabledExtensions.Append(ExtDebugUtils.ExtensionName).ToArray();
            }

            nint appName = Marshal.StringToHGlobalAnsi(AppName);

            ApplicationInfo applicationInfo = new()
            {
                PApplicationName = (byte*)appName,
                ApplicationVersion = 1,
                PEngineName = (byte*)appName,
                EngineVersion = 1,
                ApiVersion = _maximumVulkanVersion,
            };

            nint* ppEnabledExtensions = stackalloc nint[enabledExtensions.Length];
            nint* ppEnabledLayers = stackalloc nint[enabledLayers.Count];

            for (int i = 0; i < enabledExtensions.Length; i++)
            {
                ppEnabledExtensions[i] = Marshal.StringToHGlobalAnsi(enabledExtensions[i]);
            }

            for (int i = 0; i < enabledLayers.Count; i++)
            {
                ppEnabledLayers[i] = Marshal.StringToHGlobalAnsi(enabledLayers[i]);
            }

            InstanceCreateInfo instanceCreateInfo = new()
            {
                SType = StructureType.InstanceCreateInfo,
                PApplicationInfo = &applicationInfo,
                PpEnabledExtensionNames = (byte**)ppEnabledExtensions,
                PpEnabledLayerNames = (byte**)ppEnabledLayers,
                EnabledExtensionCount = (uint)enabledExtensions.Length,
                EnabledLayerCount = (uint)enabledLayers.Count,
            };

            Result result = VulkanInstance.Create(api, ref instanceCreateInfo, out VulkanInstance instance);

            Marshal.FreeHGlobal(appName);

            for (int i = 0; i < enabledExtensions.Length; i++)
            {
                Marshal.FreeHGlobal(ppEnabledExtensions[i]);
            }

            for (int i = 0; i < enabledLayers.Count; i++)
            {
                Marshal.FreeHGlobal(ppEnabledLayers[i]);
            }

            result.ThrowOnError();

            return instance;
        }

        internal static VulkanPhysicalDevice FindSuitablePhysicalDevice(Vk api, VulkanInstance instance, SurfaceKHR surface, string preferredGpuId)
        {
            instance.EnumeratePhysicalDevices(out VulkanPhysicalDevice[] physicalDevices).ThrowOnError();

            // First we try to pick the user preferred GPU.
            for (int i = 0; i < physicalDevices.Length; i++)
            {
                if (IsPreferredAndSuitableDevice(api, physicalDevices[i], surface, preferredGpuId))
                {
                    return physicalDevices[i];
                }
            }

            // If we fail to do that, just use the first compatible GPU.
            for (int i = 0; i < physicalDevices.Length; i++)
            {
                if (IsSuitableDevice(api, physicalDevices[i], surface))
                {
                    return physicalDevices[i];
                }
            }

            throw new VulkanException("Initialization failed, none of the available GPUs meets the minimum requirements.");
        }

        internal static DeviceInfo[] GetSuitablePhysicalDevices(Vk api)
        {
            nint appName = Marshal.StringToHGlobalAnsi(AppName);

            ApplicationInfo applicationInfo = new()
            {
                PApplicationName = (byte*)appName,
                ApplicationVersion = 1,
                PEngineName = (byte*)appName,
                EngineVersion = 1,
                ApiVersion = _maximumVulkanVersion,
            };

            InstanceCreateInfo instanceCreateInfo = new()
            {
                SType = StructureType.InstanceCreateInfo,
                PApplicationInfo = &applicationInfo,
                PpEnabledExtensionNames = null,
                PpEnabledLayerNames = null,
                EnabledExtensionCount = 0,
                EnabledLayerCount = 0,
            };

            Result result = VulkanInstance.Create(api, ref instanceCreateInfo, out VulkanInstance rawInstance);

            Marshal.FreeHGlobal(appName);

            result.ThrowOnError();

            using VulkanInstance instance = rawInstance;

            // We currently assume that the instance is compatible with Vulkan 1.2
            // TODO: Remove this once we relax our initialization codepaths.
            if (instance.InstanceVersion < _minimalInstanceVulkanVersion)
            {
                return [];
            }

            instance.EnumeratePhysicalDevices(out VulkanPhysicalDevice[] physicalDevices).ThrowOnError();

            List<DeviceInfo> deviceInfos = [];

            foreach (VulkanPhysicalDevice physicalDevice in physicalDevices)
            {
                if (physicalDevice.PhysicalDeviceProperties.ApiVersion < _minimalVulkanVersion)
                {
                    continue;
                }

                deviceInfos.Add(physicalDevice.ToDeviceInfo());
            }

            return deviceInfos.ToArray();
        }

        private static bool IsPreferredAndSuitableDevice(Vk api, VulkanPhysicalDevice physicalDevice, SurfaceKHR surface, string preferredGpuId)
        {
            if (physicalDevice.Id != preferredGpuId)
            {
                return false;
            }

            return IsSuitableDevice(api, physicalDevice, surface);
        }

        private static bool IsSuitableDevice(Vk api, VulkanPhysicalDevice physicalDevice, SurfaceKHR surface)
        {
            int extensionMatches = 0;

            foreach (string requiredExtension in _requiredExtensions)
            {
                if (physicalDevice.IsDeviceExtensionPresent(requiredExtension))
                {
                    extensionMatches++;
                }
            }

            return extensionMatches == _requiredExtensions.Length && FindSuitableQueueFamily(api, physicalDevice, surface, out _) != InvalidIndex;
        }

        internal static uint FindSuitableQueueFamily(Vk api, VulkanPhysicalDevice physicalDevice, SurfaceKHR surface, out uint queueCount)
        {
            const QueueFlags RequiredFlags = QueueFlags.GraphicsBit | QueueFlags.ComputeBit;

            KhrSurface khrSurface = new(api.Context);

            for (uint index = 0; index < physicalDevice.QueueFamilyProperties.Length; index++)
            {
                ref QueueFamilyProperties property = ref physicalDevice.QueueFamilyProperties[index];

                khrSurface.GetPhysicalDeviceSurfaceSupport(physicalDevice.PhysicalDevice, index, surface, out Bool32 surfaceSupported).ThrowOnError();

                if (property.QueueFlags.HasFlag(RequiredFlags) && surfaceSupported)
                {
                    queueCount = property.QueueCount;

                    return index;
                }
            }

            queueCount = 0;

            return InvalidIndex;
        }

        internal static Device CreateDevice(Vk api, VulkanPhysicalDevice physicalDevice, uint queueFamilyIndex, uint queueCount, out DeviceFeatureSnapshot enabledFeatures)
        {
            return CreateDeviceWithSurfaceMaintenance(api, physicalDevice, queueFamilyIndex, queueCount, out enabledFeatures, false);
        }

        internal static Device CreateDeviceWithSurfaceMaintenance(Vk api, VulkanPhysicalDevice physicalDevice, uint queueFamilyIndex, uint queueCount, out DeviceFeatureSnapshot enabledFeatures, bool surfaceMaintenanceEnabled)
        {
            enabledFeatures = null;
            if (queueCount > QueuesCount)
            {
                queueCount = QueuesCount;
            }

            float* queuePriorities = stackalloc float[(int)queueCount];

            for (int i = 0; i < queueCount; i++)
            {
                queuePriorities[i] = 1f;
            }

            DeviceQueueCreateInfo queueCreateInfo = new()
            {
                SType = StructureType.DeviceQueueCreateInfo,
                QueueFamilyIndex = queueFamilyIndex,
                QueueCount = queueCount,
                PQueuePriorities = queuePriorities,
            };

            PhysicalDeviceProperties properties = physicalDevice.PhysicalDeviceProperties;
            bool hasDriverProperties = physicalDevice.TryGetPhysicalDeviceDriverPropertiesKHR(api, out PhysicalDeviceDriverPropertiesKHR driverProperties);
            DriverQuirkSelection quirks = DriverQuirks.Query(properties.VendorID,
                hasDriverProperties ? driverProperties.DriverID : null,
                properties.DriverVersion, properties.Limits.MaxDrawIndirectCount);
            bool disableDynamicState = quirks.Disabled.HasFlag(DisabledDriverFeatures.ExtendedDynamicState);
            bool useRobustBufferAccess = VendorUtils.FromId(properties.VendorID) == Vendor.Nvidia ||
                quirks.Forced.HasFlag(ForcedDriverFeatures.RobustBufferAccess);
            if (quirks.RuleIds.Count != 0)
            {
                string driverInfo = hasDriverProperties ? Marshal.PtrToStringUTF8((nint)driverProperties.DriverInfo) : "unavailable";
                Logger.Info?.Print(LogClass.Gpu,
                    $"Vulkan driver quirks: rules={string.Join(",", quirks.RuleIds)}, vendorID=0x{properties.VendorID:X}, " +
                    $"driverID={(hasDriverProperties ? driverProperties.DriverID.ToString() : "unavailable")}, " +
                    $"driverVersion={properties.DriverVersion} (0x{properties.DriverVersion:X8}, {DriverQuirks.FormatVersion(properties.DriverVersion)}), " +
                    $"driverInfo={driverInfo}, disabled={quirks.Disabled}, forced={quirks.Forced}");
            }

            PhysicalDeviceFeatures2 features2 = new()
            {
                SType = StructureType.PhysicalDeviceFeatures2,
            };

            // The Vulkan11 aggregate was introduced in Vulkan 1.2. The standalone
            // draw-parameters structure is legal on every supported device (1.1+).
            PhysicalDeviceShaderDrawParametersFeatures supportedDrawParameters = new()
            {
                SType = StructureType.PhysicalDeviceShaderDrawParametersFeatures,
                PNext = features2.PNext,
            };

            features2.PNext = &supportedDrawParameters;

            PhysicalDeviceCustomBorderColorFeaturesEXT supportedFeaturesCustomBorderColor = new()
            {
                SType = StructureType.PhysicalDeviceCustomBorderColorFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_custom_border_color"))
            {
                features2.PNext = &supportedFeaturesCustomBorderColor;
            }

            PhysicalDevicePrimitiveTopologyListRestartFeaturesEXT supportedFeaturesPrimitiveTopologyListRestart = new()
            {
                SType = StructureType.PhysicalDevicePrimitiveTopologyListRestartFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_primitive_topology_list_restart"))
            {
                features2.PNext = &supportedFeaturesPrimitiveTopologyListRestart;
            }

            PhysicalDeviceTransformFeedbackFeaturesEXT supportedFeaturesTransformFeedback = new()
            {
                SType = StructureType.PhysicalDeviceTransformFeedbackFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent(ExtTransformFeedback.ExtensionName))
            {
                features2.PNext = &supportedFeaturesTransformFeedback;
            }

            PhysicalDeviceRobustness2FeaturesEXT supportedFeaturesRobustness2 = new()
            {
                SType = StructureType.PhysicalDeviceRobustness2FeaturesExt,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_robustness2"))
            {
                supportedFeaturesRobustness2.PNext = features2.PNext;

                features2.PNext = &supportedFeaturesRobustness2;
            }

            PhysicalDeviceDepthClipControlFeaturesEXT supportedFeaturesDepthClipControl = new()
            {
                SType = StructureType.PhysicalDeviceDepthClipControlFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_depth_clip_control"))
            {
                features2.PNext = &supportedFeaturesDepthClipControl;
            }

            PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT supportedFeaturesAttachmentFeedbackLoopLayout = new()
            {
                SType = StructureType.PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_attachment_feedback_loop_layout"))
            {
                features2.PNext = &supportedFeaturesAttachmentFeedbackLoopLayout;
            }

            PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesEXT supportedFeaturesDynamicAttachmentFeedbackLoopLayout = new()
            {
                SType = StructureType.PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesExt,
                PNext = features2.PNext,
            };

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_attachment_feedback_loop_dynamic_state"))
            {
                features2.PNext = &supportedFeaturesDynamicAttachmentFeedbackLoopLayout;
            }

            // Vulkan 1.2 core feature structs are not legal in a 1.1 instance/device query chain;
            // on a 1.1 device the matching KHR/EXT feature structs are chained instead (below).
            bool hasVulkan12 = physicalDevice.PhysicalDeviceProperties.ApiVersion >= Vk.Version12.Value;

            PhysicalDeviceVulkan12Features supportedPhysicalDeviceVulkan12Features = new()
            {
                SType = StructureType.PhysicalDeviceVulkan12Features,
                PNext = features2.PNext,
            };

            if (hasVulkan12)
            {
                features2.PNext = &supportedPhysicalDeviceVulkan12Features;
            }

            // Vulkan 1.1 devices expose the same features through promoted extensions. Query them
            // with their own structs and enable those extensions at device creation.
            bool hasDescriptorIndexing = !hasVulkan12 && physicalDevice.IsDeviceExtensionPresent("VK_EXT_descriptor_indexing");
            bool hasUniformBufferStandardLayout = !hasVulkan12 && physicalDevice.IsDeviceExtensionPresent("VK_KHR_uniform_buffer_standard_layout");
            bool has8BitStorage = !hasVulkan12 && physicalDevice.IsDeviceExtensionPresent("VK_KHR_8bit_storage");
            bool hasFloat16Int8 = !hasVulkan12 && physicalDevice.IsDeviceExtensionPresent("VK_KHR_shader_float16_int8");

            PhysicalDeviceDescriptorIndexingFeaturesEXT supportedDescriptorIndexing = new()
            {
                SType = StructureType.PhysicalDeviceDescriptorIndexingFeaturesExt,
            };
            PhysicalDeviceUniformBufferStandardLayoutFeatures supportedUniformBufferStandardLayout = new()
            {
                SType = StructureType.PhysicalDeviceUniformBufferStandardLayoutFeatures,
            };
            PhysicalDevice8BitStorageFeatures supported8BitStorage = new()
            {
                SType = StructureType.PhysicalDevice8BitStorageFeatures,
            };
            PhysicalDeviceShaderFloat16Int8Features supportedFloat16Int8 = new()
            {
                SType = StructureType.PhysicalDeviceShaderFloat16Int8Features,
            };

            if (hasFloat16Int8)
            {
                supportedFloat16Int8.PNext = features2.PNext;
                features2.PNext = &supportedFloat16Int8;
            }
            if (has8BitStorage)
            {
                supported8BitStorage.PNext = features2.PNext;
                features2.PNext = &supported8BitStorage;
            }
            if (hasUniformBufferStandardLayout)
            {
                supportedUniformBufferStandardLayout.PNext = features2.PNext;
                features2.PNext = &supportedUniformBufferStandardLayout;
            }
            if (hasDescriptorIndexing)
            {
                supportedDescriptorIndexing.PNext = features2.PNext;
                features2.PNext = &supportedDescriptorIndexing;
            }

            PhysicalDeviceExtendedDynamicStateFeaturesEXT supportedDynamicState = new()
            {
                SType = StructureType.PhysicalDeviceExtendedDynamicStateFeaturesExt,
                PNext = features2.PNext,
            };
            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_extended_dynamic_state"))
            {
                features2.PNext = &supportedDynamicState;
            }

            PhysicalDeviceIndexTypeUint8FeaturesEXT supportedIndexType = new()
            {
                SType = StructureType.PhysicalDeviceIndexTypeUint8FeaturesExt,
                PNext = features2.PNext,
            };
            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_index_type_uint8"))
            {
                features2.PNext = &supportedIndexType;
            }

            PhysicalDeviceFragmentShaderInterlockFeaturesEXT supportedInterlock = new()
            {
                SType = StructureType.PhysicalDeviceFragmentShaderInterlockFeaturesExt,
                PNext = features2.PNext,
            };
            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_fragment_shader_interlock"))
            {
                features2.PNext = &supportedInterlock;
            }

            PhysicalDeviceConditionalRenderingFeaturesEXT supportedConditional = new()
            {
                SType = StructureType.PhysicalDeviceConditionalRenderingFeaturesExt,
                PNext = features2.PNext,
            };
            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_conditional_rendering"))
            {
                features2.PNext = &supportedConditional;
            }

            PhysicalDeviceSwapchainMaintenance1FeaturesEXT supportedSwapchainMaintenance = new()
            {
                SType = StructureType.PhysicalDeviceSwapchainMaintenance1FeaturesExt,
                PNext = features2.PNext,
            };
            bool canQuerySwapchainMaintenance = surfaceMaintenanceEnabled &&
                physicalDevice.IsDeviceExtensionPresent("VK_EXT_swapchain_maintenance1");
            if (canQuerySwapchainMaintenance)
            {
                features2.PNext = &supportedSwapchainMaintenance;
            }

            api.GetPhysicalDeviceFeatures2(physicalDevice.PhysicalDevice, &features2);

            // The SPIR-V vertex emitter always declares DrawParameters. Do not
            // create a device that cannot legally consume its shader modules.
            if (!supportedDrawParameters.ShaderDrawParameters)
            {
                throw new VulkanException("Required Vulkan feature shaderDrawParameters is not supported.");
            }

            PhysicalDeviceFeatures supportedFeatures = features2.Features;

            // #1456: the runtime probe's capability bit — gs_occlusion judged
            // "supported" in the capprobe result file permits the GS+occlusion
            // combination; a missing/unreadable file and every other verdict
            // route geometry through the #1469 GS-as-compute path.
            bool gsOcclusionQuery = GsOcclusionQuerySupport.Supported();
            if (supportedFeatures.GeometryShader && !gsOcclusionQuery)
            {
                Logger.Warning?.Print(LogClass.Gpu,
                    "GS + occlusion probe verdict is not supported (known-bad, probe failure, " +
                    "runtime-lost writeback, or no result file); falling back to GS-as-compute " +
                    "(SupportsGeometryShader=false)");
            }

            PhysicalDeviceFeatures features = new()
            {
                DepthBiasClamp = supportedFeatures.DepthBiasClamp,
                DepthClamp = supportedFeatures.DepthClamp,
                DualSrcBlend = supportedFeatures.DualSrcBlend,
                FragmentStoresAndAtomics = supportedFeatures.FragmentStoresAndAtomics,
                GeometryShader = supportedFeatures.GeometryShader && gsOcclusionQuery,
                ImageCubeArray = supportedFeatures.ImageCubeArray,
                IndependentBlend = supportedFeatures.IndependentBlend,
                LogicOp = supportedFeatures.LogicOp,
                OcclusionQueryPrecise = supportedFeatures.OcclusionQueryPrecise,
                MultiViewport = supportedFeatures.MultiViewport,
                PipelineStatisticsQuery = supportedFeatures.PipelineStatisticsQuery,
                SamplerAnisotropy = supportedFeatures.SamplerAnisotropy,
                ShaderClipDistance = supportedFeatures.ShaderClipDistance,
                ShaderFloat64 = supportedFeatures.ShaderFloat64,
                ShaderImageGatherExtended = supportedFeatures.ShaderImageGatherExtended,
                // S2A：存储图像 / texel buffer 必须写具体格式而属扩展集合时，模块声明
                // StorageImageExtendedFormats（VUID-08737 根修）——特性开与关由设备支持度决定。
                ShaderStorageImageExtendedFormats = supportedFeatures.ShaderStorageImageExtendedFormats,
                ShaderStorageImageMultisample = supportedFeatures.ShaderStorageImageMultisample,
                ShaderStorageImageReadWithoutFormat = supportedFeatures.ShaderStorageImageReadWithoutFormat,
                ShaderStorageImageWriteWithoutFormat = supportedFeatures.ShaderStorageImageWriteWithoutFormat,
                TessellationShader = supportedFeatures.TessellationShader,
                VertexPipelineStoresAndAtomics = supportedFeatures.VertexPipelineStoresAndAtomics,
                RobustBufferAccess = useRobustBufferAccess && supportedFeatures.RobustBufferAccess,
                TextureCompressionAstcLdr = supportedFeatures.TextureCompressionAstcLdr,
                TextureCompressionBC = supportedFeatures.TextureCompressionBC,
                TextureCompressionEtc2 = supportedFeatures.TextureCompressionEtc2,
                SampleRateShading = supportedFeatures.SampleRateShading,
            };

            void* pExtendedFeatures = null;

            PhysicalDeviceTransformFeedbackFeaturesEXT featuresTransformFeedback;

            if (physicalDevice.IsDeviceExtensionPresent(ExtTransformFeedback.ExtensionName))
            {
                featuresTransformFeedback = new PhysicalDeviceTransformFeedbackFeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceTransformFeedbackFeaturesExt,
                    PNext = pExtendedFeatures,
                    TransformFeedback = supportedFeaturesTransformFeedback.TransformFeedback,
                };

                pExtendedFeatures = &featuresTransformFeedback;
            }

            PhysicalDevicePrimitiveTopologyListRestartFeaturesEXT featuresPrimitiveTopologyListRestart;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_primitive_topology_list_restart"))
            {
                featuresPrimitiveTopologyListRestart = new PhysicalDevicePrimitiveTopologyListRestartFeaturesEXT
                {
                    SType = StructureType.PhysicalDevicePrimitiveTopologyListRestartFeaturesExt,
                    PNext = pExtendedFeatures,
                    PrimitiveTopologyListRestart = supportedFeaturesPrimitiveTopologyListRestart.PrimitiveTopologyListRestart,
                    PrimitiveTopologyPatchListRestart = supportedFeaturesPrimitiveTopologyListRestart.PrimitiveTopologyPatchListRestart,
                };

                pExtendedFeatures = &featuresPrimitiveTopologyListRestart;
            }

            PhysicalDeviceRobustness2FeaturesEXT featuresRobustness2;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_robustness2"))
            {
                featuresRobustness2 = new PhysicalDeviceRobustness2FeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceRobustness2FeaturesExt,
                    PNext = pExtendedFeatures,
                    NullDescriptor = supportedFeaturesRobustness2.NullDescriptor && !quirks.Disabled.HasFlag(DisabledDriverFeatures.NullDescriptor),
                };

                pExtendedFeatures = &featuresRobustness2;
            }

            PhysicalDeviceExtendedDynamicStateFeaturesEXT featuresExtendedDynamicState = new()
            {
                SType = StructureType.PhysicalDeviceExtendedDynamicStateFeaturesExt,
                PNext = pExtendedFeatures,
                ExtendedDynamicState = supportedDynamicState.ExtendedDynamicState,
            };

            if (physicalDevice.IsDeviceExtensionPresent(ExtExtendedDynamicState.ExtensionName) && !disableDynamicState)
            {
                pExtendedFeatures = &featuresExtendedDynamicState;
            }

            PhysicalDeviceConditionalRenderingFeaturesEXT featuresConditional = new()
            {
                SType = StructureType.PhysicalDeviceConditionalRenderingFeaturesExt,
                PNext = pExtendedFeatures,
                ConditionalRendering = supportedConditional.ConditionalRendering,
            };
            if (physicalDevice.IsDeviceExtensionPresent(ExtConditionalRendering.ExtensionName))
            {
                pExtendedFeatures = &featuresConditional;
            }

            PhysicalDeviceShaderDrawParametersFeatures drawParameters = new()
            {
                SType = StructureType.PhysicalDeviceShaderDrawParametersFeatures,
                PNext = pExtendedFeatures,
                ShaderDrawParameters = supportedDrawParameters.ShaderDrawParameters,
            };

            pExtendedFeatures = &drawParameters;

            PhysicalDeviceVulkan12Features featuresVk12 = new()
            {
                SType = StructureType.PhysicalDeviceVulkan12Features,
                PNext = pExtendedFeatures,
                DescriptorIndexing = supportedPhysicalDeviceVulkan12Features.DescriptorIndexing,
                DrawIndirectCount = supportedPhysicalDeviceVulkan12Features.DrawIndirectCount,
                UniformBufferStandardLayout = supportedPhysicalDeviceVulkan12Features.UniformBufferStandardLayout,
                UniformAndStorageBuffer8BitAccess = supportedPhysicalDeviceVulkan12Features.UniformAndStorageBuffer8BitAccess,
                StorageBuffer8BitAccess = supportedPhysicalDeviceVulkan12Features.StorageBuffer8BitAccess,
                ShaderSampledImageArrayNonUniformIndexing = supportedPhysicalDeviceVulkan12Features.ShaderSampledImageArrayNonUniformIndexing,
                ShaderStorageImageArrayNonUniformIndexing = supportedPhysicalDeviceVulkan12Features.ShaderStorageImageArrayNonUniformIndexing,
                ShaderOutputLayer = supportedPhysicalDeviceVulkan12Features.ShaderOutputLayer,
                ShaderOutputViewportIndex = supportedPhysicalDeviceVulkan12Features.ShaderOutputViewportIndex,
            };

            if (hasVulkan12)
            {
                pExtendedFeatures = &featuresVk12;
            }

            PhysicalDeviceDescriptorIndexingFeaturesEXT featuresDescriptorIndexing = new()
            {
                SType = StructureType.PhysicalDeviceDescriptorIndexingFeaturesExt,
                ShaderSampledImageArrayNonUniformIndexing = supportedDescriptorIndexing.ShaderSampledImageArrayNonUniformIndexing,
                ShaderStorageImageArrayNonUniformIndexing = supportedDescriptorIndexing.ShaderStorageImageArrayNonUniformIndexing,
                RuntimeDescriptorArray = supportedDescriptorIndexing.RuntimeDescriptorArray,
            };
            PhysicalDeviceUniformBufferStandardLayoutFeatures featuresUniformBufferStandardLayout = new()
            {
                SType = StructureType.PhysicalDeviceUniformBufferStandardLayoutFeatures,
                UniformBufferStandardLayout = supportedUniformBufferStandardLayout.UniformBufferStandardLayout,
            };
            PhysicalDevice8BitStorageFeatures features8BitStorage = new()
            {
                SType = StructureType.PhysicalDevice8BitStorageFeatures,
                StorageBuffer8BitAccess = supported8BitStorage.StorageBuffer8BitAccess,
                UniformAndStorageBuffer8BitAccess = supported8BitStorage.UniformAndStorageBuffer8BitAccess,
            };
            PhysicalDeviceShaderFloat16Int8Features featuresFloat16Int8 = new()
            {
                SType = StructureType.PhysicalDeviceShaderFloat16Int8Features,
                ShaderFloat16 = supportedFloat16Int8.ShaderFloat16,
                ShaderInt8 = supportedFloat16Int8.ShaderInt8,
            };

            if (hasFloat16Int8)
            {
                featuresFloat16Int8.PNext = pExtendedFeatures;
                pExtendedFeatures = &featuresFloat16Int8;
            }
            if (has8BitStorage)
            {
                features8BitStorage.PNext = pExtendedFeatures;
                pExtendedFeatures = &features8BitStorage;
            }
            if (hasUniformBufferStandardLayout)
            {
                featuresUniformBufferStandardLayout.PNext = pExtendedFeatures;
                pExtendedFeatures = &featuresUniformBufferStandardLayout;
            }
            if (hasDescriptorIndexing)
            {
                featuresDescriptorIndexing.PNext = pExtendedFeatures;
                pExtendedFeatures = &featuresDescriptorIndexing;
            }

            PhysicalDeviceIndexTypeUint8FeaturesEXT featuresIndexU8;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_index_type_uint8"))
            {
                featuresIndexU8 = new PhysicalDeviceIndexTypeUint8FeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceIndexTypeUint8FeaturesExt,
                    PNext = pExtendedFeatures,
                    IndexTypeUint8 = supportedIndexType.IndexTypeUint8,
                };

                pExtendedFeatures = &featuresIndexU8;
            }

            PhysicalDeviceFragmentShaderInterlockFeaturesEXT featuresFragmentShaderInterlock;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_fragment_shader_interlock"))
            {
                featuresFragmentShaderInterlock = new PhysicalDeviceFragmentShaderInterlockFeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceFragmentShaderInterlockFeaturesExt,
                    PNext = pExtendedFeatures,
                    FragmentShaderPixelInterlock = supportedInterlock.FragmentShaderPixelInterlock,
                };

                pExtendedFeatures = &featuresFragmentShaderInterlock;
            }

            PhysicalDeviceCustomBorderColorFeaturesEXT featuresCustomBorderColor;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_custom_border_color") &&
                supportedFeaturesCustomBorderColor.CustomBorderColors &&
                supportedFeaturesCustomBorderColor.CustomBorderColorWithoutFormat)
            {
                featuresCustomBorderColor = new PhysicalDeviceCustomBorderColorFeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceCustomBorderColorFeaturesExt,
                    PNext = pExtendedFeatures,
                    CustomBorderColors = true,
                    CustomBorderColorWithoutFormat = true,
                };

                pExtendedFeatures = &featuresCustomBorderColor;
            }

            PhysicalDeviceDepthClipControlFeaturesEXT featuresDepthClipControl;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_depth_clip_control") &&
                supportedFeaturesDepthClipControl.DepthClipControl)
            {
                featuresDepthClipControl = new PhysicalDeviceDepthClipControlFeaturesEXT
                {
                    SType = StructureType.PhysicalDeviceDepthClipControlFeaturesExt,
                    PNext = pExtendedFeatures,
                    DepthClipControl = true,
                };

                pExtendedFeatures = &featuresDepthClipControl;
            }

            PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT featuresAttachmentFeedbackLoopLayout;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_attachment_feedback_loop_layout") &&
                supportedFeaturesAttachmentFeedbackLoopLayout.AttachmentFeedbackLoopLayout)
            {
                featuresAttachmentFeedbackLoopLayout = new()
                {
                    SType = StructureType.PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesExt,
                    PNext = pExtendedFeatures,
                    AttachmentFeedbackLoopLayout = true,
                };

                pExtendedFeatures = &featuresAttachmentFeedbackLoopLayout;
            }

            PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesEXT featuresDynamicAttachmentFeedbackLoopLayout;

            if (physicalDevice.IsDeviceExtensionPresent("VK_EXT_attachment_feedback_loop_dynamic_state") &&
                supportedFeaturesDynamicAttachmentFeedbackLoopLayout.AttachmentFeedbackLoopDynamicState)
            {
                featuresDynamicAttachmentFeedbackLoopLayout = new()
                {
                    SType = StructureType.PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesExt,
                    PNext = pExtendedFeatures,
                    AttachmentFeedbackLoopDynamicState = true,
                };

                pExtendedFeatures = &featuresDynamicAttachmentFeedbackLoopLayout;
            }

            string[] enabledExtensions = _requiredExtensions.Union(_desirableExtensions.Intersect(physicalDevice.DeviceExtensions)).ToArray();
            enabledExtensions = enabledExtensions.Where(extension =>
                !(extension == "VK_KHR_push_descriptor" && quirks.Disabled.HasFlag(DisabledDriverFeatures.PushDescriptor)) &&
                !(extension == ExtExtendedDynamicState.ExtensionName && disableDynamicState)).ToArray();
            if (hasDescriptorIndexing) enabledExtensions = enabledExtensions.Append("VK_EXT_descriptor_indexing").ToArray();
            if (hasUniformBufferStandardLayout) enabledExtensions = enabledExtensions.Append("VK_KHR_uniform_buffer_standard_layout").ToArray();
            if (has8BitStorage) enabledExtensions = enabledExtensions.Append("VK_KHR_8bit_storage").ToArray();
            if (hasFloat16Int8) enabledExtensions = enabledExtensions.Append("VK_KHR_shader_float16_int8").ToArray();
            // Vulkan 1.1 requires the legacy extension for its combined Layer/Viewport capability.
            // Vulkan 1.2 uses the queried core feature bits and SPIR-V 1.5 instead.
            if (!hasVulkan12 && physicalDevice.IsDeviceExtensionPresent("VK_EXT_shader_viewport_index_layer") &&
                !enabledExtensions.Contains("VK_EXT_shader_viewport_index_layer"))
            {
                enabledExtensions = enabledExtensions.Append("VK_EXT_shader_viewport_index_layer").ToArray();
            }
            PhysicalDeviceSwapchainMaintenance1FeaturesEXT enabledSwapchainMaintenance = new();
            if (canQuerySwapchainMaintenance && supportedSwapchainMaintenance.SwapchainMaintenance1)
            {
                enabledSwapchainMaintenance = new()
                {
                    SType = StructureType.PhysicalDeviceSwapchainMaintenance1FeaturesExt,
                    PNext = pExtendedFeatures,
                    SwapchainMaintenance1 = true,
                };
                pExtendedFeatures = &enabledSwapchainMaintenance;
                enabledExtensions = enabledExtensions.Append("VK_EXT_swapchain_maintenance1").ToArray();
            }

            nint* ppEnabledExtensions = stackalloc nint[enabledExtensions.Length];
            int allocatedNames = 0;
            try
            {
                for (; allocatedNames < enabledExtensions.Length; allocatedNames++)
                {
                    ppEnabledExtensions[allocatedNames] = Marshal.StringToHGlobalAnsi(enabledExtensions[allocatedNames]);
                }

                DeviceCreateInfo deviceCreateInfo = new()
                {
                    SType = StructureType.DeviceCreateInfo,
                    PNext = pExtendedFeatures,
                    QueueCreateInfoCount = 1,
                    PQueueCreateInfos = &queueCreateInfo,
                    PpEnabledExtensionNames = (byte**)ppEnabledExtensions,
                    EnabledExtensionCount = (uint)enabledExtensions.Length,
                    PEnabledFeatures = &features,
                };

                // Copy the actual request, not a second physical-device query. Nothing is
                // published as enabled until creation has succeeded.
                DeviceFeatureSnapshot requestedFeatures = DeviceFeatureSnapshot.Capture(in deviceCreateInfo);
                api.CreateDevice(physicalDevice.PhysicalDevice, in deviceCreateInfo, null, out Device device).ThrowOnError();
                enabledFeatures = requestedFeatures;
                Logger.Info?.Print(LogClass.Gpu,
                    $"Vulkan device features: apiVersion={(Version)(Version32)physicalDevice.PhysicalDeviceProperties.ApiVersion}, " +
                    $"structure={nameof(PhysicalDeviceShaderDrawParametersFeatures)}, " +
                    $"shaderDrawParameters queried={(bool)supportedDrawParameters.ShaderDrawParameters}, " +
                    $"requested={(bool)drawParameters.ShaderDrawParameters}, enabled={enabledFeatures.ShaderDrawParameters}");
                Logger.Info?.Print(LogClass.Gpu,
                    $"Vulkan layer/viewport features: apiVersion={(Version)(Version32)physicalDevice.PhysicalDeviceProperties.ApiVersion}, " +
                    $"shaderOutputLayer queried={(hasVulkan12 ? ((bool)supportedPhysicalDeviceVulkan12Features.ShaderOutputLayer).ToString() : "not-queried")}, " +
                    $"requested={(bool)featuresVk12.ShaderOutputLayer}, enabled={(bool)enabledFeatures.Vulkan12.ShaderOutputLayer}; " +
                    $"shaderOutputViewportIndex queried={(hasVulkan12 ? ((bool)supportedPhysicalDeviceVulkan12Features.ShaderOutputViewportIndex).ToString() : "not-queried")}, " +
                    $"requested={(bool)featuresVk12.ShaderOutputViewportIndex}, enabled={(bool)enabledFeatures.Vulkan12.ShaderOutputViewportIndex}; " +
                    $"VK_EXT_shader_viewport_index_layer supported={physicalDevice.IsDeviceExtensionPresent("VK_EXT_shader_viewport_index_layer")}, " +
                    $"requested={requestedFeatures.HasExtension("VK_EXT_shader_viewport_index_layer")}, " +
                    $"enabled={enabledFeatures.HasExtension("VK_EXT_shader_viewport_index_layer")}; " +
                    $"VK_NV_viewport_array2 enabled={enabledFeatures.HasExtension("VK_NV_viewport_array2")}");
                return device;
            }
            finally
            {
                for (int i = 0; i < allocatedNames; i++)
                {
                    Marshal.FreeHGlobal(ppEnabledExtensions[i]);
                }
            }
        }
    }
}
