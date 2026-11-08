using S2Arm.Backends.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

internal static unsafe partial class RuntimeFeatureTests
{
    private static bool _quirkFixture;
    private static bool _quirkSupported;
    private static DriverId _quirkDriver;
    private static int _driverQueries;

    private static void DriverQuirkRequests(Vk api, object physicalDevice, Action<bool, string> check)
    {
        _quirkFixture = true;
        // #1456：设备创建现在还乘 capprobe 能力位；驱动怪癖矩阵与探测结果正交，
        // 这里钉一个 supported 结果文件，让用例只量化怪癖表路径。
        Func<string> originalResultPath = GsOcclusionQuerySupport.ResultPath;
        string gsoccFile = Path.Combine(Path.GetTempPath(),
            "gsocc-quirk-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(gsoccFile,
            "{\"schema\":1,\"verdict\":{\"gs_occlusion\":\"supported\",\"tess_occlusion\":\"supported\"}}");
        GsOcclusionQuerySupport.ResultPath = () => gsoccFile;
        try
        {
            // Expected results are literal contract outcomes, not computed by the table.
            Run("Qualcomm high unsigned version", 0x5143, DriverId.QualcommProprietary, 0x80267001, 2, true, true, false, true, true, false, true);
            Run("Turnip", 0x5143, DriverId.MesaTurnip, 0x80267001, 2, true, true, true, true, true, false, true);
            Run("PanVK", 0x13b5, DriverId.MesaPanvk, 0x08001000, 2, true, true, true, true, true, false, true);
            // #1456：A-GSOCC 已移除——Arm 各版本 GS 期望全部按设备上报值（夹具恒 true），
            // 禁 GS 只由 capprobe 能力位决定，不在这个怪癖表路径里。
            Run("Mali r44p0", 0x13b5, DriverId.ArmProprietary, 44u << 22, 2, true, true, true, false, true, false, true, edsExtension: false);
            Run("Mali r48 CSF", 0x13b5, DriverId.ArmProprietary, 48u << 22, 2, true, true, true, true, true, false, true);
            Run("Mali r48 JM", 0x13b5, DriverId.ArmProprietary, 48u << 22, 1, true, true, true, false, true, false, true, edsExtension: false);
            Run("Mali r51 JM", 0x13b5, DriverId.ArmProprietary, 51u << 22, 1, true, true, true, true, true, false, true);
            Run("ARM vendor but other driver", 0x13b5, (DriverId)0x7fffffff, 0, 1, true, true, true, true, true, false, true);
            Run("Missing driver properties", 0x13b5, DriverId.ArmProprietary, 0, 1, false, true, true, true, true, false, true);
            Run("Maleoon supported", 0x19e5, (DriverId)0, 0xffffffff, 2, false, true, true, true, false, true, true);
            Run("Maleoon unsupported", 0x19e5, (DriverId)0, 0, 2, false, false, true, false, false, false, true);
            Run("NVIDIA unchanged", 0x10de, DriverId.NvidiaProprietary, 0, 2, true, true, true, true, true, true, true);
            Run("Unknown unchanged", 0x1234, (DriverId)0x7fffffff, 0, 2, true, true, true, true, true, false, true);
        }
        finally
        {
            _quirkFixture = false;
            _quirkSupported = false;
            GsOcclusionQuerySupport.ResultPath = originalResultPath;
            File.Delete(gsoccFile);
        }

        void Run(string label, uint vendor, DriverId driver, uint version, uint indirectCount,
            bool driverProperties, bool supported, bool push, bool eds, bool nullDescriptor, bool robust, bool gs, bool edsExtension = true)
        {
            _quirkSupported = supported;
            _quirkDriver = driver;
            SetField(physicalDevice, "PhysicalDeviceProperties", new PhysicalDeviceProperties
            {
                VendorID = vendor, DriverVersion = version, ApiVersion = Vk.Version12.Value,
                Limits = new PhysicalDeviceLimits { MaxDrawIndirectCount = indirectCount },
            });
            HashSet<string> extensions = new(StringComparer.Ordinal)
            {
                "VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_EXT_extended_dynamic_state", "VK_EXT_robustness2",
            };
            if (driverProperties) extensions.Add("VK_KHR_driver_properties");
            SetField(physicalDevice, "DeviceExtensions", extensions);
            _callbackError = null;
            int queriesBefore = _driverQueries;
            object[] args = { api, physicalDevice, 0u, 1u, null };
            Create.Invoke(null, args);
            check(_callbackError == null, label + ": callback failed");
            check(_driverQueries - queriesBefore == (driverProperties ? 1 : 0), label + ": driver properties query mismatch");
            foreach (DeviceFeatureSnapshot snapshot in new[] { _received, (DeviceFeatureSnapshot)args[4] })
            {
                check(snapshot.HasExtension("VK_KHR_push_descriptor") == push, label + ": push descriptor request mismatch");
                // Unsupported EDS still advertises its extension on the unchanged path.
                check(snapshot.HasExtension("VK_EXT_extended_dynamic_state") == edsExtension, label + ": EDS extension mismatch");
                check(snapshot.ExtendedDynamicState == eds, label + ": EDS bit mismatch");
                check(snapshot.NullDescriptor == nullDescriptor, label + ": null descriptor mismatch");
                check((bool)snapshot.Core.RobustBufferAccess == robust, label + ": robust access mismatch");
                check((bool)snapshot.Core.GeometryShader == gs, label + ": geometry shader quirk mismatch");
                check(snapshot.HasExtension("VK_EXT_robustness2"), label + ": unrelated robustness extension removed");
            }
            check(Contains(_requestedChain, StructureType.PhysicalDeviceExtendedDynamicStateFeaturesExt) ==
                  edsExtension, label + ": EDS request chain mismatch");
        }
    }

    private static void FillQuirkFeatures(PhysicalDeviceFeatures2* features)
    {
        for (BaseInStructure* node = (BaseInStructure*)features->PNext; node != null; node = node->PNext)
        {
            if (node->SType == StructureType.PhysicalDeviceExtendedDynamicStateFeaturesExt)
                ((PhysicalDeviceExtendedDynamicStateFeaturesEXT*)node)->ExtendedDynamicState = _quirkSupported;
            if (node->SType == StructureType.PhysicalDeviceRobustness2FeaturesExt)
                ((PhysicalDeviceRobustness2FeaturesEXT*)node)->NullDescriptor = _quirkSupported;
        }
    }

    [UnmanagedCallersOnly]
    private static void QueryDriverProperties(PhysicalDevice device, PhysicalDeviceProperties2* properties)
    {
        _driverQueries++;
        for (BaseOutStructure* node = (BaseOutStructure*)properties->PNext; node != null; node = node->PNext)
        {
            if (node->SType == StructureType.PhysicalDeviceDriverPropertiesKhr)
            {
                var driver = (PhysicalDeviceDriverPropertiesKHR*)node;
                driver->DriverID = _quirkDriver;
                // Deliberately misleading: strings must not control rule matching.
                byte[] info = System.Text.Encoding.UTF8.GetBytes("Mali r1p0 Adreno 512.615.0 Maleoon\0");
                for (int i = 0; i < info.Length; i++) driver->DriverInfo[i] = info[i];
            }
        }
    }
}
