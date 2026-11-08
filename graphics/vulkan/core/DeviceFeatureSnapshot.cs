using Silk.NET.Vulkan;
using System;
using System.Collections.Frozen;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Backends.Vulkan;

/// <summary>
/// Pointer-free copy of a device creation request. Publish this as enabled state only
/// after vkCreateDevice succeeds; physical-device queries are not enabled state.
/// Unknown pNext structures confer no feature support through this interface.
/// </summary>
public sealed class DeviceFeatureSnapshot
{
    private readonly FrozenSet<string> _extensions;

    public PhysicalDeviceFeatures Core { get; }
    public PhysicalDeviceVulkan12Features Vulkan12 { get; private set; }
    public bool ShaderDrawParameters { get; private set; }
    public bool TransformFeedback { get; private set; }
    public bool PrimitiveTopologyListRestart { get; private set; }
    public bool PrimitiveTopologyPatchListRestart { get; private set; }
    public bool NullDescriptor { get; private set; }
    public bool ExtendedDynamicState { get; private set; }
    public bool IndexTypeUint8 { get; private set; }
    public bool FragmentShaderPixelInterlock { get; private set; }
    public bool CustomBorderColors { get; private set; }
    public bool CustomBorderColorWithoutFormat { get; private set; }
    public bool DepthClipControl { get; private set; }
    public bool AttachmentFeedbackLoopLayout { get; private set; }
    public bool AttachmentFeedbackLoopDynamicState { get; private set; }
    public bool ConditionalRendering { get; private set; }
    // WSI lifetime only; this must not enter shader compilation/cache identity.
    public bool SwapchainMaintenance1 { get; private set; }

    private DeviceFeatureSnapshot(PhysicalDeviceFeatures core, HashSet<string> extensions)
    {
        Core = core;
        _extensions = extensions.ToFrozenSet(StringComparer.Ordinal);
    }

    public bool HasExtension(string name) => _extensions.Contains(name);

    /// <summary>Copies the request while all native pointers are still alive.</summary>
    public static unsafe DeviceFeatureSnapshot Capture(in DeviceCreateInfo request)
    {
        if (request.EnabledExtensionCount != 0 && request.PpEnabledExtensionNames == null)
        {
            throw new ArgumentException("Device extension names are missing.", nameof(request));
        }

        HashSet<string> extensions = new(StringComparer.Ordinal);
        for (uint i = 0; i < request.EnabledExtensionCount; i++)
        {
            extensions.Add(Marshal.PtrToStringUTF8((nint)request.PpEnabledExtensionNames[i])
                ?? throw new ArgumentException("A device extension name is null.", nameof(request)));
        }

        DeviceFeatureSnapshot snapshot = new(
            request.PEnabledFeatures == null ? default : *request.PEnabledFeatures, extensions);
        HashSet<StructureType> seen = [];
        for (BaseInStructure* item = (BaseInStructure*)request.PNext;
             item != null; item = item->PNext)
        {
            if (!seen.Add(item->SType))
            {
                throw new ArgumentException("Repeated device feature structure.", nameof(request));
            }

            switch (item->SType)
            {
                case StructureType.PhysicalDeviceShaderDrawParametersFeatures:
                    snapshot.ShaderDrawParameters =
                        ((PhysicalDeviceShaderDrawParametersFeatures*)item)->ShaderDrawParameters;
                    break;
                case StructureType.PhysicalDeviceSwapchainMaintenance1FeaturesExt:
                    snapshot.SwapchainMaintenance1 = extensions.Contains("VK_EXT_swapchain_maintenance1") &&
                        ((PhysicalDeviceSwapchainMaintenance1FeaturesEXT*)item)->SwapchainMaintenance1;
                    break;
                case StructureType.PhysicalDeviceFeatures2:
                    // The current runtime supplies pEnabledFeatures. Do not silently accept a
                    // second authority if an adapter changes to a features2 creation chain.
                    throw new ArgumentException("Use pEnabledFeatures for this device plan.", nameof(request));
                // Vulkan 1.1 devices get the promoted features through their own structs; publish
                // them through the same Vulkan12 view so consumers do not need two code paths.
                case StructureType.PhysicalDeviceDescriptorIndexingFeaturesExt:
                    if (extensions.Contains("VK_EXT_descriptor_indexing"))
                    {
                        PhysicalDeviceDescriptorIndexingFeaturesEXT descriptorIndexing =
                            *(PhysicalDeviceDescriptorIndexingFeaturesEXT*)item;
                        PhysicalDeviceVulkan12Features v12 = snapshot.Vulkan12;
                        // The promoted extension makes the aggregate flag true; the individual
                        // non-uniform indexing bits come from the struct itself.
                        v12.DescriptorIndexing = true;
                        v12.ShaderSampledImageArrayNonUniformIndexing = descriptorIndexing.ShaderSampledImageArrayNonUniformIndexing;
                        v12.ShaderStorageImageArrayNonUniformIndexing = descriptorIndexing.ShaderStorageImageArrayNonUniformIndexing;
                        v12.RuntimeDescriptorArray = descriptorIndexing.RuntimeDescriptorArray;
                        snapshot.Vulkan12 = v12;
                    }
                    break;
                case StructureType.PhysicalDeviceUniformBufferStandardLayoutFeatures:
                    if (extensions.Contains("VK_KHR_uniform_buffer_standard_layout"))
                    {
                        PhysicalDeviceVulkan12Features v12 = snapshot.Vulkan12;
                        v12.UniformBufferStandardLayout =
                            ((PhysicalDeviceUniformBufferStandardLayoutFeatures*)item)->UniformBufferStandardLayout;
                        snapshot.Vulkan12 = v12;
                    }
                    break;
                case StructureType.PhysicalDevice8BitStorageFeatures:
                    if (extensions.Contains("VK_KHR_8bit_storage"))
                    {
                        PhysicalDevice8BitStorageFeatures storage = *(PhysicalDevice8BitStorageFeatures*)item;
                        PhysicalDeviceVulkan12Features v12 = snapshot.Vulkan12;
                        v12.StorageBuffer8BitAccess = storage.StorageBuffer8BitAccess;
                        v12.UniformAndStorageBuffer8BitAccess = storage.UniformAndStorageBuffer8BitAccess;
                        snapshot.Vulkan12 = v12;
                    }
                    break;
                case StructureType.PhysicalDeviceShaderFloat16Int8Features:
                    if (extensions.Contains("VK_KHR_shader_float16_int8"))
                    {
                        PhysicalDeviceShaderFloat16Int8Features float16Int8 = *(PhysicalDeviceShaderFloat16Int8Features*)item;
                        PhysicalDeviceVulkan12Features v12 = snapshot.Vulkan12;
                        v12.ShaderFloat16 = float16Int8.ShaderFloat16;
                        v12.ShaderInt8 = float16Int8.ShaderInt8;
                        snapshot.Vulkan12 = v12;
                    }
                    break;
                case StructureType.PhysicalDeviceVulkan12Features:
                    PhysicalDeviceVulkan12Features vk12 = *(PhysicalDeviceVulkan12Features*)item;
                    vk12.PNext = null;
                    snapshot.Vulkan12 = vk12;
                    break;
                case StructureType.PhysicalDeviceTransformFeedbackFeaturesExt:
                    snapshot.TransformFeedback = extensions.Contains("VK_EXT_transform_feedback") &&
                        ((PhysicalDeviceTransformFeedbackFeaturesEXT*)item)->TransformFeedback;
                    break;
                case StructureType.PhysicalDevicePrimitiveTopologyListRestartFeaturesExt:
                    if (extensions.Contains("VK_EXT_primitive_topology_list_restart"))
                    {
                        snapshot.PrimitiveTopologyListRestart =
                            ((PhysicalDevicePrimitiveTopologyListRestartFeaturesEXT*)item)->PrimitiveTopologyListRestart;
                        snapshot.PrimitiveTopologyPatchListRestart =
                            ((PhysicalDevicePrimitiveTopologyListRestartFeaturesEXT*)item)->PrimitiveTopologyPatchListRestart;
                    }
                    break;
                case StructureType.PhysicalDeviceRobustness2FeaturesExt:
                    snapshot.NullDescriptor = extensions.Contains("VK_EXT_robustness2") &&
                        ((PhysicalDeviceRobustness2FeaturesEXT*)item)->NullDescriptor;
                    break;
                case StructureType.PhysicalDeviceExtendedDynamicStateFeaturesExt:
                    snapshot.ExtendedDynamicState = extensions.Contains("VK_EXT_extended_dynamic_state") &&
                        ((PhysicalDeviceExtendedDynamicStateFeaturesEXT*)item)->ExtendedDynamicState;
                    break;
                case StructureType.PhysicalDeviceIndexTypeUint8FeaturesExt:
                    snapshot.IndexTypeUint8 = extensions.Contains("VK_EXT_index_type_uint8") &&
                        ((PhysicalDeviceIndexTypeUint8FeaturesEXT*)item)->IndexTypeUint8;
                    break;
                case StructureType.PhysicalDeviceFragmentShaderInterlockFeaturesExt:
                    snapshot.FragmentShaderPixelInterlock = extensions.Contains("VK_EXT_fragment_shader_interlock") &&
                        ((PhysicalDeviceFragmentShaderInterlockFeaturesEXT*)item)->FragmentShaderPixelInterlock;
                    break;
                case StructureType.PhysicalDeviceCustomBorderColorFeaturesExt:
                    if (extensions.Contains("VK_EXT_custom_border_color"))
                    {
                        snapshot.CustomBorderColors =
                            ((PhysicalDeviceCustomBorderColorFeaturesEXT*)item)->CustomBorderColors;
                        snapshot.CustomBorderColorWithoutFormat =
                            ((PhysicalDeviceCustomBorderColorFeaturesEXT*)item)->CustomBorderColorWithoutFormat;
                    }
                    break;
                case StructureType.PhysicalDeviceDepthClipControlFeaturesExt:
                    snapshot.DepthClipControl = extensions.Contains("VK_EXT_depth_clip_control") &&
                        ((PhysicalDeviceDepthClipControlFeaturesEXT*)item)->DepthClipControl;
                    break;
                case StructureType.PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesExt:
                    snapshot.AttachmentFeedbackLoopLayout = extensions.Contains("VK_EXT_attachment_feedback_loop_layout") &&
                        ((PhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT*)item)->AttachmentFeedbackLoopLayout;
                    break;
                case StructureType.PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesExt:
                    snapshot.AttachmentFeedbackLoopDynamicState =
                        extensions.Contains("VK_EXT_attachment_feedback_loop_dynamic_state") &&
                        ((PhysicalDeviceAttachmentFeedbackLoopDynamicStateFeaturesEXT*)item)->AttachmentFeedbackLoopDynamicState;
                    break;
                case StructureType.PhysicalDeviceConditionalRenderingFeaturesExt:
                    snapshot.ConditionalRendering = extensions.Contains("VK_EXT_conditional_rendering") &&
                        ((PhysicalDeviceConditionalRenderingFeaturesEXT*)item)->ConditionalRendering;
                    break;
            }
        }

        return snapshot;
    }
}
