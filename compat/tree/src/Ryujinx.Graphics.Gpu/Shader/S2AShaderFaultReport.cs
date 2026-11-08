using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using System;
using System.Text;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A（10-29 着色器垃圾代码防线）：取着色器失败的红行现场——分类、原异常，与每个阶段给原生层定因用的地址链
    /// （GPU 地址 + 本次读取长度 → 物理段 → 宿主地址 → 宿主页的写跟踪状态）。StateUpdater（图形）与 ComputeClass（计算）共用。
    /// 防线只留现场、不替代根修：取码读到的不是代码（双人成行 mini 局 r1「Invalid shader stage 15」）的根因在 GpuAccessor.GetCode 不经写跟踪。
    /// </summary>
    internal static class S2AShaderFaultReport
    {
        private const int MaxPagesPerReport = 64;   // 一条红行最多打几个宿主页（取码最多 1 MB = 64 个 16 KB 页）

        /// <summary>取码越界（0012 安全阀 / 0300 负缓存，消息同一前缀）还是翻译失败（其余一切异常：垃圾代码过了取码、在翻译 / 生成 / 建程序时抛）。</summary>
        public static bool IsFetchFault(Exception e) => e is InvalidOperationException && e.Message.StartsWith("S2A: shader code fetch");

        public static string Category(Exception e) => IsFetchFault(e) ? "取码越界" : "翻译失败";

        /// <summary>原异常类型与消息原样，加抛出处最内两帧。</summary>
        public static string Describe(Exception e)
        {
            string[] frames = (e.StackTrace ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            string at = frames.Length == 0 ? "无栈" : string.Join(" ← ", frames, 0, Math.Min(2, frames.Length));
            return $"异常 {e.GetType().FullName}：{e.Message}；抛出处 {at}";
        }

        /// <summary>一个阶段：GPU 地址与本次读取长度；物理段（物理地址 + 长度）；每段的宿主地址与其各宿主页的写跟踪状态。</summary>
        public static void AppendStage(StringBuilder sb, MemoryManager mm, string stage, ulong va, ulong fetchEnd)
        {
            ulong len = fetchEnd > va ? fetchEnd - va : 0;
            sb.Append($"{stage} GPU 地址 0x{va:X} 读取长度 0x{len:X}；");

            // 没读（负缓存命中）就按头部 0x50 字节查链路
            MultiRange range = mm.GetPhysicalRegions(va, len != 0 ? len : 0x50);
            int pages = 0;
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange r = range.GetSubRange(i);
                if (r.Address == MemoryManager.PteUnmapped)
                {
                    sb.Append($"物理段 未映射 长 0x{r.Size:X}；");
                    continue;
                }

                sb.Append($"物理段 0x{r.Address:X} 长 0x{r.Size:X}；");
                nint host = mm.Physical.GetHostPointer(new MultiRange(r.Address, r.Size));
                if (host == 0)
                {
                    sb.Append("宿主地址拿不到（不是单段宿主映射）；");
                    continue;
                }

                sb.Append($"宿主地址 0x{(ulong)host:X}；");
                AppendTrack(sb, (ulong)host, r.Size, ref pages);
            }
        }

        private static unsafe void AppendTrack(StringBuilder sb, ulong host, ulong size, ref int pages)
        {
            delegate*<ulong, ulong> query = MemoryTracking.S2ATrackPageInfo;
            if (query == null)
            {
                sb.Append("写跟踪查询未提供；");
                return;
            }

            ulong pageSize = (ulong)Environment.SystemPageSize;
            for (ulong page = host & ~(pageSize - 1); page < host + size; page += pageSize)
            {
                if (++pages > MaxPagesPerReport)
                {
                    sb.Append($"写跟踪 超过 {MaxPagesPerReport} 页、余下略；");
                    return;
                }

                ulong v = query(page);
                sb.Append(v == ulong.MaxValue
                    ? $"宿主页 0x{page:X}：未跟踪；"
                    : $"宿主页 0x{page:X}：state {v & 0xff} lastp 0x{(v >> 8) & 0xff:X} act 0x{(v >> 16) & 0xff:X} want 0x{(v >> 24) & 0xff:X} READFLUSH {(v >> 32) & 0xff} dirty 0x{(v >> 40) & 0xff:X}；");
            }
        }
    }
}
