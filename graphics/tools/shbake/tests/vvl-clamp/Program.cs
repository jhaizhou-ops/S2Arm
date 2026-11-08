// VUID-00332：描述符范围上限与不足报红计数。
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using AccessFlags = Silk.NET.Vulkan.AccessFlags;
using PipelineStageFlags = Silk.NET.Vulkan.PipelineStageFlags;
using ShaderStage = Ryujinx.Graphics.Shader.ShaderStage;

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

        // ---- ① VUID-00332：ClampBufferRange ----
        static void TestClamp()
        {
            const ulong Max = 0x10000; // 9000 maxUniformBufferRange = 65536
            const ulong Cb = 0x10000;  // 着色器声明 cbuffer = 64 KiB

            // 请求 4096，缓冲 1MiB：不动。
            ulong r = DescriptorSetUpdater.ClampBufferRange(4096, 0x100000, 0, Max, out bool insuf);
            Check(r == 4096 && !insuf, "clamp.small", "4096/覆盖", $"{r}/insuf={insuf}");

            // 请求 1MiB > 64KiB：钳到 64KiB；着色器声明 64KiB → 仍全覆盖，不报红。
            r = DescriptorSetUpdater.ClampBufferRange(0x100000, 0x100000, 0, Max, out insuf);
            Check(r == Max && !insuf, "clamp.big", "65536/覆盖", $"{r}/insuf={insuf}");

            // VK_WHOLE_SIZE：按 (size - offset) 解析后钳制。1MiB 缓冲 off0 → 64KiB。
            r = DescriptorSetUpdater.ClampBufferRange(ulong.MaxValue, 0x100000, 0, Max, out insuf);
            Check(r == Max && !insuf, "clamp.whole", "65536/覆盖", $"{r}/insuf={insuf}");

            // VK_WHOLE_SIZE + 非零偏移：bound = size - offset。
            r = DescriptorSetUpdater.ClampBufferRange(ulong.MaxValue, 0x100000, 0x8000, Max, out insuf);
            Check(r == Max && !insuf, "clamp.whole.off", "65536/覆盖", $"{r}/insuf={insuf}");

            // 上限不足 64KiB 声明：请求 64KiB，限 16KiB → 钳到 16KiB 且标记不足（调用方报红）。
            r = DescriptorSetUpdater.ClampBufferRange(Cb, 0x100000, 0, 0x4000, out insuf);
            Check(r == 0x4000 && insuf, "clamp.insuf", "16384/不足", $"{r}/insuf={insuf}");

            // 请求本身小于声明（部分 cbuffer）：32KiB → 不动、不算截断。
            r = DescriptorSetUpdater.ClampBufferRange(0x8000, 0x8000, 0, Max, out insuf);
            Check(r == 0x8000 && !insuf, "clamp.partial", "32768/覆盖", $"{r}/insuf={insuf}");

            // 实际计数和日志事件：多次失败只打印一次，但计数逐次增长。
            var renderer = (VulkanRenderer)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
            var messages = new List<string>();
            EventHandler<LogEventArgs> capture = (_, e) => { if (e.Message.Contains("Uniform buffer descriptor range")) messages.Add(e.Message); };
            Logger.Updated += capture;
            var info = new DescriptorBufferInfo { Offset = 0, Range = Cb };
            for (int i = 0; i < 3; i++) { info.Range = Cb; DescriptorSetUpdater.ClampAndReportUniformBufferRange(ref info, 0x100000, 0x4000, renderer); }
            Logger.Updated -= capture;
            Check(info.Range == 0x4000 && renderer.S2AUniformBufferRangeErrors == 3 && messages.Count == 1
                && messages[0].Contains("65536") && messages[0].Contains("16384"),
                "clamp.report", "16384/日志1次/计数3次", $"{info.Range}/{messages.Count}/{renderer.S2AUniformBufferRangeSummary}");
            info.Range = 0x1000;
            DescriptorSetUpdater.ClampAndReportUniformBufferRange(ref info, 0x100000, Max, renderer);
            Check(info.Range == 0x1000 && renderer.S2AUniformBufferRangeErrors == 3, "clamp.report.control", "4096/仍3次", $"{info.Range}/{renderer.S2AUniformBufferRangeErrors}");

            // 越界的计算结果为零，生产更新路径改绑有非零范围的 dummy。
            Check(!DescriptorSetUpdater.UniformRangeNeedsDummy(0x8000, 0x7fff, 1)
                && DescriptorSetUpdater.UniformRangeNeedsDummy(0x8000, 0, 0), "clamp.oob.control", "最后字节合法/空范围非法", "判据不符");
            foreach (long offset in new long[] { 0x8000, 0x8001 })
            {
                r = DescriptorSetUpdater.ClampBufferRange(0x1000, 0x8000, offset, Max, out insuf);
                info = new DescriptorBufferInfo { Buffer = new Silk.NET.Vulkan.Buffer { Handle = 1 }, Offset = (ulong)offset, Range = r };
                DescriptorSetUpdater.BindEmptyUniformDummy(ref info, new Silk.NET.Vulkan.Buffer { Handle = 99 }, 0x10000, 0x4000);
                Check(DescriptorSetUpdater.UniformRangeNeedsDummy(0x8000, offset, 0x1000) && r == 0 && info.Buffer.Handle == 99 && info.Offset == 0 && info.Range == 0x4000,
                    "clamp.oob", "dummy/offset0/range16384", $"{info.Buffer.Handle}/{info.Offset}/{info.Range}");
            }

        }

        static int Main()
        {
            TestClamp();

            Console.WriteLine(_fail == 0 ? "期望 → 真结果：全过" : $"失败 {_fail} 条");
            return _fail;
        }
    }
}
