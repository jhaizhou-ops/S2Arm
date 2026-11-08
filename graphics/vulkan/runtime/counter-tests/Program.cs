// 实际 CounterQueue / CounterQueueEvent；仅驱动查询的 AwaitResult 为可控 CPU 门。
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Graphics.Vulkan.Queries;
using Ryujinx.Graphics.GAL;
using System.Diagnostics;

BufferedQuery.Entered.Reset(); BufferedQuery.Release.Reset();
int callbacks = 0, teardown = 0, late = 0;
var queue = new CounterQueue(new VulkanRenderer(), new(), new PipelineFull(), CounterType.SamplesPassed);
queue.QueueReport((_, _) => { Interlocked.Increment(ref callbacks); if (Volatile.Read(ref teardown) != 0) Interlocked.Increment(ref late); }, 1f, 1, false);
if (!BufferedQuery.Entered.Wait(1000)) throw new Exception("consumer did not enter");
var watch = Stopwatch.StartNew();
if (args.Length == 0 || args[0] != "old-order")
{
    if (queue.S2AStopForExit(100)) throw new Exception("paused CPU consumer cannot have joined");
    if (watch.ElapsedMilliseconds > 250) throw new Exception("counter fast stop was unbounded");
}
Volatile.Write(ref teardown, 1);
BufferedQuery.Release.Set();
queue.Dispose();
if (callbacks != 0 || late != 0) throw new Exception($"FAIL late guest callback: callbacks={callbacks}, after_teardown={late}");
// 已经在执行的回调不能被跳过：有界等不到时必须拒绝 GPU teardown。
BufferedQuery.Entered.Reset(); BufferedQuery.Release.Set();
using var entered = new ManualResetEventSlim();
using var release = new ManualResetEventSlim();
queue = new CounterQueue(new VulkanRenderer(), new(), new PipelineFull(), CounterType.SamplesPassed);
queue.QueueReport((_, _) => { entered.Set(); release.Wait(); }, 1f, 1, false);
if (!entered.Wait(1000)) throw new Exception("callback did not start");
bool refused = false;
try { queue.S2AStopForExit(50); } catch (TimeoutException) { refused = true; }
if (!refused) throw new Exception("FAIL active callback must prevent teardown");
release.Set();
if (!queue.S2AStopForExit(1000)) throw new Exception("released callback should join");
queue.Dispose();
Console.WriteLine("PASS counters: late callback rejected; CPU consumer bounded; active callback refuses teardown until quiescent");

namespace Ryujinx.Graphics.GAL {
    enum CounterType { SamplesPassed, TransformFeedbackPrimitivesWritten }
    interface ICounterEvent : IDisposable { bool Invalid {get;set;} void Flush(); bool ReserveForHostAccess(); }
}
namespace Silk.NET.Vulkan { struct Device {} struct CommandBuffer {} }
namespace Ryujinx.Graphics.Vulkan {
    class VulkanRenderer { public bool IsAmdWindows => false; public Action S2AWaitCheck { get; set; } public bool S2ACounterLifetime = true; }
    class PipelineFull {}
    class Auto<T> {} class DisposableBuffer {}
}
namespace Ryujinx.Graphics.Vulkan.Queries {
    class BufferedQuery : IDisposable {
        public static readonly ManualResetEventSlim Entered = new(), Release = new();
        public BufferedQuery(VulkanRenderer gd, Silk.NET.Vulkan.Device device, PipelineFull p, CounterType type, bool broken) {}
        public void PoolReset(Silk.NET.Vulkan.CommandBuffer c, int seq) {} public void Begin(int seq) {}
        public void Reset() {} public void End(bool result) {}
        public Auto<DisposableBuffer> GetBuffer() => new();
        public bool AwaitResult(out long result, AutoResetEvent wake) { Entered.Set(); Release.Wait(); result = 7; return true; }
        public bool TryGetResult(out long result) { result=7; return true; }
        public bool Overflowed => false;
        public void Dispose() {}
    }
}
namespace Ryujinx.Common.Logging {
    enum LogClass { Gpu }
    class Log { public void Print(LogClass c, string msg) {} }
    static class Logger { public static Log Warning = new(); public static Log Error = new(); }
}
