using S2Arm.Backends.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Runtime.InteropServices;

internal static unsafe class Program
{
    private static int _checks;

    private static void Check(bool value, string message)
    {
        _checks++;
        if (!value) throw new InvalidOperationException(message);
    }

    private static DeviceFeatureSnapshot Capture(void* chain, params string[] extensions)
    {
        nint* names = stackalloc nint[extensions.Length];
        int allocated = 0;
        try
        {
            for (; allocated < extensions.Length; allocated++)
                names[allocated] = Marshal.StringToCoTaskMemUTF8(extensions[allocated]);
            DeviceCreateInfo request = new()
            {
                SType = StructureType.DeviceCreateInfo,
                PNext = chain,
                PpEnabledExtensionNames = (byte**)names,
                EnabledExtensionCount = (uint)extensions.Length,
            };
            return DeviceFeatureSnapshot.Capture(in request);
        }
        finally
        {
            for (int i = 0; i < allocated; i++) Marshal.FreeCoTaskMem(names[i]);
        }
    }

    private static void RequestedFeaturesAreNotHardwareFeatures()
    {
        PhysicalDeviceFeatures raw = new() { SparseBinding = true, GeometryShader = true };
        PhysicalDeviceFeatures selected = new() { GeometryShader = raw.GeometryShader };
        PhysicalDeviceVulkan12Features vk12 = new()
        {
            SType = StructureType.PhysicalDeviceVulkan12Features,
            ShaderOutputLayer = false,
            ShaderOutputViewportIndex = false,
            ShaderSampledImageArrayNonUniformIndexing = true,
            ShaderStorageImageArrayNonUniformIndexing = false,
        };
        DeviceCreateInfo request = new()
        {
            SType = StructureType.DeviceCreateInfo,
            PEnabledFeatures = &selected,
            PNext = &vk12,
        };
        DeviceFeatureSnapshot snapshot = DeviceFeatureSnapshot.Capture(in request);
        Check(raw.SparseBinding && !snapshot.Core.SparseBinding, "Advertised sparse binding is not enabled binding.");
        Check(snapshot.Core.GeometryShader, "An explicitly selected core feature was lost.");
        Check(!snapshot.Vulkan12.ShaderOutputLayer && !snapshot.Vulkan12.ShaderOutputViewportIndex,
            "Omitted layer/viewport features must remain disabled.");
        Check(snapshot.Vulkan12.ShaderSampledImageArrayNonUniformIndexing &&
            !snapshot.Vulkan12.ShaderStorageImageArrayNonUniformIndexing,
            "A selected indexing feature must not imply the other one.");
        selected.GeometryShader = false;
        vk12.ShaderOutputLayer = true;
        Check(snapshot.Core.GeometryShader && !snapshot.Vulkan12.ShaderOutputLayer,
            "The snapshot borrowed stack storage instead of copying it.");
    }

    private static void ExtensionNameAndFeatureAreBothRequired()
    {
        PhysicalDeviceTransformFeedbackFeaturesEXT transform = new()
        {
            SType = StructureType.PhysicalDeviceTransformFeedbackFeaturesExt,
            TransformFeedback = true,
        };
        Check(!Capture(&transform).TransformFeedback, "A pNext bit without its extension is not enabled.");
        Check(!Capture(null, "VK_EXT_transform_feedback").TransformFeedback,
            "An extension string without its feature is not enabled.");
        DeviceFeatureSnapshot enabled = Capture(&transform, "VK_EXT_transform_feedback");
        Check(enabled.TransformFeedback && enabled.HasExtension("VK_EXT_transform_feedback"),
            "Both feature and copied extension name must survive native storage retirement.");
        Check(!enabled.HasExtension("VK_EXT_TRANSFORM_FEEDBACK"), "Extension names are ordinal and case-sensitive.");
        transform.TransformFeedback = false;
        Check(!Capture(&transform, "VK_EXT_transform_feedback").TransformFeedback,
            "Advertising an extension must not turn a false feature on.");
        Check(enabled.TransformFeedback, "Changing another device request changed the first device's features.");
    }

    private static void ChainCopiesAreIndependentAndPointerFree()
    {
        PhysicalDeviceConditionalRenderingFeaturesEXT conditional = new()
        {
            SType = StructureType.PhysicalDeviceConditionalRenderingFeaturesExt,
            ConditionalRendering = true,
        };
        PhysicalDeviceVulkan12Features vk12 = new()
        {
            SType = StructureType.PhysicalDeviceVulkan12Features,
            PNext = &conditional,
            ShaderInt8 = true,
        };
        PhysicalDeviceCustomBorderColorFeaturesEXT border = new()
        {
            SType = StructureType.PhysicalDeviceCustomBorderColorFeaturesExt,
            PNext = &vk12,
            CustomBorderColors = true,
            CustomBorderColorWithoutFormat = false,
        };
        DeviceFeatureSnapshot snapshot = Capture(&border,
            "VK_EXT_conditional_rendering", "VK_EXT_custom_border_color");
        Check(snapshot.ConditionalRendering && snapshot.Vulkan12.ShaderInt8,
            "Features were not read from the entire chain.");
        Check(snapshot.CustomBorderColors && !snapshot.CustomBorderColorWithoutFormat,
            "Independent border-color requirements must not be conflated.");
        Check(snapshot.Vulkan12.PNext == null, "A published value retains a dangling native chain pointer.");
        PhysicalDeviceVulkan12Features copy = snapshot.Vulkan12;
        copy.ShaderInt8 = false;
        Check(snapshot.Vulkan12.ShaderInt8, "The consumer mutated the stored feature set.");
        Check(!Capture(null).ConditionalRendering && !Capture(null).Core.GeometryShader,
            "An empty request inherited features from another device.");
    }

    private static void ConflictingOrCyclicRequestsAreRejected()
    {
        PhysicalDeviceVulkan12Features cyclic = new() { SType = StructureType.PhysicalDeviceVulkan12Features };
        cyclic.PNext = &cyclic;
        bool rejected = false;
        try { Capture(&cyclic); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "A cyclic request must fail instead of hanging or publishing partial support.");

        PhysicalDeviceFeatures2 alternate = new() { SType = StructureType.PhysicalDeviceFeatures2 };
        rejected = false;
        try { Capture(&alternate); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "An unsupported creation convention must not silently publish an empty feature set.");

        DeviceCreateInfo missingNames = new() { EnabledExtensionCount = 1 };
        rejected = false;
        try { DeviceFeatureSnapshot.Capture(in missingNames); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "A missing extension-name array must fail before dereferencing it.");
    }

    private static void DrawParametersAreCopiedFromTheRequest()
    {
        PhysicalDeviceShaderDrawParametersFeatures draw = new()
        {
            SType = StructureType.PhysicalDeviceShaderDrawParametersFeatures,
            ShaderDrawParameters = true,
        };
        DeviceFeatureSnapshot enabled = Capture(&draw);
        Check(enabled.ShaderDrawParameters, "Core 1.1 draw parameters require no extension name.");
        draw.ShaderDrawParameters = false;
        Check(enabled.ShaderDrawParameters && !Capture(&draw).ShaderDrawParameters && !Capture(null).ShaderDrawParameters,
            "Draw-parameters snapshots must own their copied bit and never inherit it from another request.");
    }

    private static void Main()
    {
        RequestedFeaturesAreNotHardwareFeatures();
        ExtensionNameAndFeatureAreBothRequired();
        ChainCopiesAreIndependentAndPointerFree();
        ConflictingOrCyclicRequestsAreRejected();
        DrawParametersAreCopiedFromTheRequest();
        DriverQuirkTests.Run(Check);
        GsOcclusionQueryTests.Run(Check);
        RuntimeFeatureTests.Run(Check);
        RuntimeSubgroupTests.Run(Check);
        Console.WriteLine($"Device feature snapshot: {_checks} assertions passed (CPU only).");
    }
}
