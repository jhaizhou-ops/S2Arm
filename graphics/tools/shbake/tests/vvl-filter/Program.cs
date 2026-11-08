// VUID-04552/04553：LINEAR 采样器不得绑到不含 SAMPLED_IMAGE_FILTER_LINEAR 的视图格式。
// 修前红基准：旧代码把 LINEAR 采样器原样透传绑定——本文件引用的变换/判定函数
//   在旧树上不可见，编译即红；修后语义逐项断言为绿。
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Linq;
using System.Reflection;
using VkFormat = Silk.NET.Vulkan.Format;

namespace S2A.VvlTest
{
    static class Program
    {
        static int _fail;

        static void Check(bool cond, string name, string expect, string actual)
        {
            if (!cond)
            {
                _fail++;
                Console.WriteLine($"FAIL {name}：期望 {expect} → 真结果 {actual}");
            }
        }

        // ---- ④ LINEAR 采样器 × 不支持线性滤波的视图格式 → 降级 NEAREST ----
        static void TestSamplerFallback()
        {
            // 9000 logcat：R16G16_UNORM 无 SAMPLED_IMAGE_FILTER_LINEAR，却绑了 LINEAR 采样器。
            Silk.NET.Vulkan.SamplerCreateInfo info = new()
            {
                SType = StructureType.SamplerCreateInfo,
                MagFilter = Filter.Linear,
                MinFilter = Filter.Linear,
                MipmapMode = SamplerMipmapMode.Linear,
                AnisotropyEnable = true,
                MaxAnisotropy = 8f,
                AddressModeU = SamplerAddressMode.Repeat,
                CompareEnable = true,
                CompareOp = Silk.NET.Vulkan.CompareOp.LessOrEqual,
            };

            Check(SamplerHolder.ComputeUsesLinearFiltering(in info), "filter.linear.detect", "true", "false");

            Silk.NET.Vulkan.SamplerCreateInfo near = info;
            SamplerHolder.ForceNearestFiltering(ref near);

            Check(near.MagFilter == Filter.Nearest
                && near.MinFilter == Filter.Nearest
                && near.MipmapMode == SamplerMipmapMode.Nearest
                && !near.AnisotropyEnable
                && near.MaxAnisotropy == 1f, "filter.fallback",
                "NEAREST×3/aniso off", $"{near.MagFilter}/{near.MinFilter}/{near.MipmapMode}/aniso={near.AnisotropyEnable}");

            // 负对照：非滤波字段必须原样保留（寻址模式、比较采样、结构类型不动）。
            Check(near.AddressModeU == SamplerAddressMode.Repeat
                && near.CompareEnable
                && near.CompareOp == Silk.NET.Vulkan.CompareOp.LessOrEqual
                && near.SType == StructureType.SamplerCreateInfo, "filter.fallback.keep",
                "字段保留", $"{near.AddressModeU}/cmp={near.CompareEnable}/{near.CompareOp}");

            // 负对照：降级不影响原采样器描述（原 info 未被改动）。
            Check(info.MagFilter == Filter.Linear && info.AnisotropyEnable, "filter.original",
                "原样保留", $"{info.MagFilter}/aniso={info.AnisotropyEnable}");

            // 负对照：本就 NEAREST 的采样器不算用线性滤波，不触发降级。
            Silk.NET.Vulkan.SamplerCreateInfo alreadyNearest = new()
            {
                SType = StructureType.SamplerCreateInfo,
                MagFilter = Filter.Nearest,
                MinFilter = Filter.Nearest,
                MipmapMode = SamplerMipmapMode.Nearest,
            };
            Check(!SamplerHolder.ComputeUsesLinearFiltering(in alreadyNearest), "filter.nearest.detect", "false", "true");

            // 仅 aniso 打开（滤波器 NEAREST）也算用线性滤波路径——各向异性要求线性。
            Silk.NET.Vulkan.SamplerCreateInfo anisoOnly = alreadyNearest;
            anisoOnly.AnisotropyEnable = true;
            Check(SamplerHolder.ComputeUsesLinearFiltering(in anisoOnly), "filter.aniso.detect", "true", "false");

            // 每格式只告警一次（黄行不刷屏），键为视图真实 VkFormat。
            Check(SamplerHolder.WarnLinearFilterFallbackOnce(VkFormat.R16G16Unorm), "filter.warn.first", "true", "false");
            Check(!SamplerHolder.WarnLinearFilterFallbackOnce(VkFormat.R16G16Unorm), "filter.warn.again", "false", "true");
            Check(SamplerHolder.WarnLinearFilterFallbackOnce(VkFormat.R8G8B8A8Unorm), "filter.warn.other", "true", "false");
        }

        // 在 caller 的 IL 里找 call/callvirt（0x28/0x6F）+ 4 字节元数据令牌指向 target。
        // 不按指令边界走：扫到 opcode 字节就解后面 4 字节，解不出或解到别的方法就跳过；
        // 真实调用必然命中，操作数字节凑巧解成同一目标在事实上不可能。
        static bool IlCalls(MethodInfo caller, MethodBase target)
        {
            byte[] il = caller.GetMethodBody()?.GetILAsByteArray();
            if (il == null || target == null)
            {
                return false;
            }

            for (int i = 0; i + 4 < il.Length; i++)
            {
                if (il[i] != 0x28 && il[i] != 0x6F)
                {
                    continue;
                }

                int token = il[i + 1] | (il[i + 2] << 8) | (il[i + 3] << 16) | (il[i + 4] << 24);
                MethodBase m;
                try
                {
                    m = caller.Module.ResolveMethod(token);
                }
                catch
                {
                    continue;
                }

                if (m != null && m.MetadataToken == target.MetadataToken && m.Module == target.Module)
                {
                    return true;
                }
            }

            return false;
        }

        // ---- 负对照（owner 复审）：所有绑定点必须经共用 SelectSampler 取采样器（含
        // 纹理数组在 GetImageInfos 的配对点），能力查询按视图真实 VkFormat。
        // SelectSampler(...) 换回 GetSampler()、或查询退回 view.Info.Format 时以下断言
        // 变红——用 IL 调用令牌证明修复真的被调用，不是只测了判定零件。
        static void TestSelectSamplerWiring()
        {
            var select = typeof(SamplerHolder).GetMethod("SelectSampler", BindingFlags.NonPublic | BindingFlags.Instance);
            Check(select != null, "wire.select.exists", "SamplerHolder.SelectSampler 存在", "找不到");
            if (select == null)
            {
                return;
            }

            var dsu = typeof(DescriptorSetUpdater);
            foreach (string name in new[] { "SetTextureAndSampler", "SetTextureAndSamplerIdentitySwizzle" })
            {
                var sites = dsu
                    .GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static)
                    .Where(m => m.Name == name)
                    .ToArray();
                Check(sites.Any(m => IlCalls(m, select)), $"wire.{name}",
                    "IL 里调 SelectSampler", $"{sites.Length} 个重载均未调");
            }

            // 纹理数组：SetSamplers 只记 SamplerHolder，配对在 GetImageInfos 写
            // ImageView+Sampler 时发生——该点退回 GetSampler() 本断言变红。
            var arraySites = typeof(TextureArray)
                .GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .Where(m => m.Name == "GetImageInfos")
                .ToArray();
            Check(arraySites.Any(m => IlCalls(m, select)), "wire.TextureArray.pair",
                "GetImageInfos 配对点 IL 里调 SelectSampler", $"{arraySites.Length} 个重载均未调");

            var getVkFormat = typeof(TextureView).GetProperty("VkFormat")?.GetGetMethod();
            Check(getVkFormat != null && IlCalls(select, getVkFormat), "wire.vkformat",
                "SelectSampler 读 view.VkFormat", "未读");

            var optimalVk = typeof(FormatCapabilities).GetMethods()
                .SingleOrDefault(m => m.Name == "OptimalFormatSupports"
                    && m.GetParameters() is { Length: 2 } p
                    && p[1].ParameterType == typeof(VkFormat));
            Check(optimalVk != null && IlCalls(select, optimalVk), "wire.optimal.vkformat",
                "SelectSampler 走 VkFormat 重载查能力", "未走");

            var getNearest = typeof(SamplerHolder).GetMethod("GetNearestSampler");
            Check(getNearest != null && IlCalls(select, getNearest), "wire.nearest",
                "SelectSampler 可达 GetNearestSampler", "不可达");
        }

        static int Main()
        {
            TestSamplerFallback();
            TestSelectSamplerWiring();
            Console.WriteLine(_fail == 0 ? "期望 → 真结果：全过" : $"失败 {_fail} 条");
            return _fail;
        }
    }
}
