using System;
using System.Collections.Concurrent;
using System.Diagnostics.Tracing;
using System.Linq;

namespace S2A.Services.Tests
{
    // 分配来源采样（S2A_ALLOC_PROFILE=1）：运行时每分配约 100 KB 发一次 GCAllocationTick，带类型名；放大迭代次数后按类型统计
    sealed class AllocProfiler : EventListener
    {
        public readonly ConcurrentDictionary<string, int> Types = new();

        protected override void OnEventSourceCreated(EventSource source)
        {
            if (source.Name == "Microsoft-Windows-DotNETRuntime")
            {
                EnableEvents(source, EventLevel.Verbose, (EventKeywords)0x1); // GC 关键字
            }
        }

        protected override void OnEventWritten(EventWrittenEventArgs e)
        {
            if (e.EventName != null && e.EventName.StartsWith("GCAllocationTick") && e.Payload != null)
            {
                int i = e.PayloadNames.IndexOf("TypeName");

                if (i >= 0)
                {
                    Types.AddOrUpdate($"{e.Payload[i]}@t{e.OSThreadId}", 1, (_, n) => n + 1);
                }
            }
        }

        public string Top(int n) => string.Join("；", Types.OrderByDescending(kv => kv.Value).Take(n).Select(kv => $"{kv.Key}×{kv.Value}"));
    }
}
