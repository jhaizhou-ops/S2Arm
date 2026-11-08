// 实际 BufferedQuery / CounterQueue / CounterQueueEvent；管线与设备是桩，段生命周期与结果写盘由用例驱动。
// 覆盖：Begin 清零（End 不得清掉早落地的段拷贝）、超时有界计数不锁结果、段溢出显式失败、
// 消费线程 Peek 失败留队、FlushTo 自带上限报红返回、Flush(true) 不持锁等超时。
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Graphics.Vulkan.Queries;
using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

const long Sentinel = unchecked((long)0xFFFFFFFEFFFFFFFE);
static nint MapOf(BufferedQuery q) => (nint)typeof(BufferedQuery).GetField("_bufferMap", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(q)!;
static BufferedQuery CounterOf(CounterQueueEvent e) => (BufferedQuery)typeof(CounterQueueEvent).GetField("_counter", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(e)!;
static void Check(bool b, string m) { if (!b) throw new Exception(m); }

var gd = new VulkanRenderer(); var device = new Device(); var pipe = new PipelineFull();

// ① 段拷贝可在 End 前落地：Begin 周期起点清零，End 不再清掉已写好的第 0 段。
var q = new BufferedQuery(gd, device, pipe, CounterType.SamplesPassed, false);
nint map = MapOf(q);
q.Begin(0); q.BeginSegment(); q.SegmentEnded();
Marshal.WriteInt64(map, 0, 5);                 // 第 0 段拷贝先于 End 完成
q.BeginSegment();
Marshal.WriteInt64(map, 8, 7);
q.End(true);
Check(q.TryGetResult(out long sum) && sum == 12, $"early-landed segment must survive End(), got {sum}");

// ② 超时有界、计数、不锁结果：等待到期报红计数一次，迟到的值仍可被消费（只有段溢出才锁）。
var q2 = new BufferedQuery(gd, device, pipe, CounterType.SamplesPassed, false);
q2.Begin(0); q2.BeginSegment(); q2.SegmentEnded(); q2.End(true);
long before = gd.QueryTimeouts;
var watch = Stopwatch.StartNew();
Check(!q2.AwaitResult(out _, null), "AwaitResult on unwritten slot must time out");
Check(watch.ElapsedMilliseconds < 2000, "AwaitResult must stay bounded");
Check(gd.QueryTimeouts == before + 1, "each expiry must count exactly once");
Marshal.WriteInt64(MapOf(q2), 0, 9);
Check(q2.TryGetResult(out long late) && late == 9, $"late result must remain consumable after timeout, got {late}");

// ③ 段溢出显式失败：超过 64 段闩死，写满数值也不得回投。
var q3 = new BufferedQuery(gd, device, pipe, CounterType.SamplesPassed, false);
q3.Begin(0);
for (int i = 0; i < BufferedQuery.MaxQuerySegments; i++) Check(q3.BeginSegment() == i, "in-budget segment must allocate");
Check(q3.BeginSegment() < 0, "over-budget segment must refuse");
q3.SegmentEnded(); q3.End(true);
for (int i = 0; i < BufferedQuery.MaxQuerySegments; i++) Marshal.WriteInt64(MapOf(q3), i * 8, 1);
Check(!q3.TryGetResult(out _), "overflowed query must never return a partial result");

// ④ 真消费线程：Peek 失败留队（事件不丢）、FlushTo 自带上限返回、值到后照常交付。
var queue = new CounterQueue(gd, device, pipe, CounterType.SamplesPassed);
CounterQueueEvent evt = queue.QueueReport(null, 1f, 1, false);
nint map4 = MapOf(CounterOf(evt));
var flushDone = new ManualResetEventSlim();
new Thread(() => { evt.Flush(); flushDone.Set(); }) { IsBackground = true }.Start();
Check(flushDone.Wait(3000), "FlushTo must return bounded when the result never lands");
Check(!evt.Disposed, "failed consume must keep the event pending");
Marshal.WriteInt64(map4, 0, 11);
var consumed = new ManualResetEventSlim();
new Thread(() => { while (!evt.Disposed) Thread.Sleep(5); consumed.Set(); }) { IsBackground = true }.Start();
Check(consumed.Wait(3000), "queued event must still consume once the result lands");
Check(gd.QueryTimeouts >= 2, "queue-path expiries must count on the renderer counter");

// ⑤ 溢出事件计一次、报红、Dispose、出队：不得永久堵头或反复计数；溢出后的正常事件照常交付。
//    审计 #1534 P1-60：溢出事件仍要回调（客人在等这个地址被写上）——本次查询记 0；累计值 0 起步 → 回调值 0。
//    不标 Invalid：SemaphoreUpdater.OnResult 见 Invalid 就不写客内存，标了客人照样等不到。
var queue3 = new CounterQueue(gd, device, pipe, CounterType.SamplesPassed);
ulong badDelivered = ulong.MaxValue;
CounterQueueEvent bad = queue3.QueueReport((_, r) => badDelivered = r, 1f, 1, false);
var oq = CounterOf(bad);
for (int i = 0; i <= BufferedQuery.MaxQuerySegments; i++) oq.BeginSegment();   // 第 65 次越界闩死
long timeoutsBefore = gd.QueryTimeouts;
ulong delivered = ulong.MaxValue;
CounterQueueEvent good = queue3.QueueReport((_, r) => delivered = r, 1f, 2, false);
Marshal.WriteInt64(MapOf(CounterOf(good)), 0, 7);
var settled = new ManualResetEventSlim();
new Thread(() => { while (!bad.Disposed || delivered == ulong.MaxValue) Thread.Sleep(5); settled.Set(); }) { IsBackground = true }.Start();
Check(settled.Wait(3000), $"overflowed event must drop and let later events deliver: bad.Disposed={bad.Disposed} delivered={delivered}");
Check(delivered == 7, $"normal event after overflow must deliver its value, got {delivered}");
Check(badDelivered == 0 && !bad.Invalid, $"P1-60 overflowed event must still call back with 0 (not invalid, so the guest write happens), got {badDelivered} invalid={bad.Invalid}");
Check(gd.QueryTimeouts - timeoutsBefore <= 1, "overflowed event counts at most once, not per retry");
queue3.Dispose();

// ⑥ Flush(true) 不持锁等超时：阻塞消费期间 QueueReport 不得被 _lock 卡一个超时周期。
var queue2 = new CounterQueue(gd, device, pipe, CounterType.SamplesPassed);
CounterQueueEvent evt2 = queue2.QueueReport(null, 1f, 1, false);
var flushing = new ManualResetEventSlim(); var flushed = new ManualResetEventSlim();
new Thread(() => { flushing.Set(); queue2.Flush(true); flushed.Set(); }) { IsBackground = true }.Start();
Check(flushing.Wait(1000), "flush did not start");
Thread.Sleep(50);                               // 让它先吃到队头并进入 500 ms 有界消费
var qwatch = Stopwatch.StartNew();
queue2.QueueReport(null, 1f, 2, false);
Check(qwatch.ElapsedMilliseconds < 400, $"QueueReport blocked {qwatch.ElapsedMilliseconds} ms behind a locked consume");
Marshal.WriteInt64(MapOf(CounterOf(evt2)), 0, 3);
Check(flushed.Wait(3000), "Flush(true) must finish once the head event lands");
queue2.Dispose(); queue.Dispose(); q3.Dispose(); q2.Dispose(); q.Dispose();
Console.WriteLine("PASS query-semantics: clear-at-begin, bounded count no latch, overflow fails but still calls back 0, peek keeps queue, bounded FlushTo, lock-free flush");

namespace Ryujinx.Common.Logging {
    enum LogClass { Gpu }
    class Log { public void Print(LogClass c, string msg) {} }
    static class Logger { public static Log Warning = new(); public static Log Error = new(); }
}
namespace Ryujinx.Graphics.GAL {
    enum CounterType { SamplesPassed, PrimitivesGenerated, TransformFeedbackPrimitivesWritten }
    interface ICounterEvent : IDisposable { bool Invalid {get;set;} void Flush(); bool ReserveForHostAccess(); }
}
namespace Silk.NET.Vulkan {
    struct Device {} struct CommandBuffer {} struct Buffer { public ulong Handle; }
    struct QueryPool { public ulong Handle; }
    class AllocationCallbacks {}
    struct Result { public void ThrowOnError() {} }
    enum StructureType { QueryPoolCreateInfo }
    enum QueryType { Occlusion, PipelineStatistics, TransformFeedbackStreamExt }
    [Flags] enum QueryPipelineStatisticFlags { None = 0, GeometryShaderPrimitivesBit = 1 }
    [Flags] enum QueryResultFlags { None = 0, Result64Bit = 1, ResultWaitBit = 2 }
    struct QueryPoolCreateInfo { public StructureType SType; public uint QueryCount; public QueryType QueryType; public QueryPipelineStatisticFlags PipelineStatistics; }
    class Vk {
        public Result CreateQueryPool(Device d, in QueryPoolCreateInfo ci, AllocationCallbacks ac, out QueryPool qp) { qp = new(); return new(); }
        public void CmdResetQueryPool(CommandBuffer c, QueryPool p, uint first, uint count) {}
        public void CmdCopyQueryPoolResults(CommandBuffer c, QueryPool p, uint first, uint count, Buffer b, ulong off, ulong stride, QueryResultFlags f) {}
        public void DestroyQueryPool(Device d, QueryPool p, AllocationCallbacks ac) {}
    }
}
namespace Ryujinx.Graphics.Vulkan {
    class DisposableBuffer { public Silk.NET.Vulkan.Buffer Value; }
    class Auto<T> { public DisposableBuffer Get(CommandBufferScoped cbs, long off, long size, bool write) => new(); }
    class CommandBufferScoped { public Silk.NET.Vulkan.CommandBuffer CommandBuffer; }
    class BufferHolder {
        private readonly nint _map = Marshal.AllocHGlobal(1024);
        public nint Map(long off, long size) => _map;
        public Auto<DisposableBuffer> GetBuffer() => new();
        public Auto<DisposableBuffer> GetBuffer(Silk.NET.Vulkan.CommandBuffer c, bool write) => new();
        public void Dispose() => Marshal.FreeHGlobal(_map);
    }
    class BufferManager { public BufferHolder Create(VulkanRenderer gd, int size, bool forConditionalRendering) => new(); }
    class Capabilities { public bool SupportsPreciseOcclusionQueries; public bool SupportsPipelineStatisticsQuery; public bool SupportsTransformFeedbackQueries; }
    class VulkanRenderer {
        public Silk.NET.Vulkan.Vk Api { get; } = new();
        public BufferManager BufferManager { get; } = new();
        public Capabilities Capabilities { get; } = new();
        public bool IsAmdWindows => false;
        public Action? S2AWaitCheck { get; set; }
        public bool S2ACounterLifetime { get; set; }
        private long _queryTimeouts;
        public long QueryTimeouts => Interlocked.Read(ref _queryTimeouts);
        internal void IncrementQueryTimeouts() => Interlocked.Increment(ref _queryTimeouts);
    }
    class PipelineFull {
        public void BeginQuery(Queries.BufferedQuery q, Silk.NET.Vulkan.QueryPool p, bool reset, bool occ, bool fromSample) {}
        public bool EndQuery(Silk.NET.Vulkan.QueryPool p) => true;
        public void CopyQueryResults(Queries.BufferedQuery q, int segment) {}
        public void CopyQueryResults(Queries.BufferedQuery q, int first, int count) {}
    }
}
