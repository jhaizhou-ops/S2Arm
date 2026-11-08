using System;
using System.Linq;
using System.Collections.Generic;
using Ryujinx.Graphics.GAL;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Graphics.Vulkan.Queries;
using Silk.NET.Vulkan;
using Buffer = Silk.NET.Vulkan.Buffer;

internal unsafe static class Proof
{
    private const long Sentinel = unchecked((long)0xFFFFFFFEFFFFFFFE);
    private static int _checks;
    private static void Check(bool b, string message) { _checks++; if (!b) throw new Exception(message); }
    private static void Set(object obj, string name, object value)
    {
        var t = obj.GetType();
        while (t != null)
        {
            var f = t.GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            if (f != null) { f.SetValue(obj, value); return; }
            t = t.BaseType;
        }
        throw new Exception("missing field " + name + " on " + obj.GetType().Name);
    }
    private static MethodInfo Method(object obj, string name) =>
        obj.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);

    private sealed class World : IDisposable
    {
        public readonly Vk Api; public readonly Device Device; public readonly CommandBufferPool Pool;
        public readonly MemoryAllocatorBlockList Allocator; public readonly VulkanRenderer Gd;
        public readonly PipelineFull Pipeline; public readonly QueryPool QueryPool;
        public readonly nint Map; private readonly BufferHolder _holder;
        public readonly CommandBufferScoped Cbs;

        public World()
        {
            Api = new Vk(new Dispatch()); Device = new Device(1);
            Pool = new CommandBufferPool(Api, Device, new Queue(2), new Lock(), 0, false);
            Allocator = new MemoryAllocatorBlockList(Api, Device, 0, 4096, true);
            var gd = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
            Set(gd, "<Api>k__BackingField", Api); Set(gd, "<CommandBufferPool>k__BackingField", Pool);
            Set(gd, "_counters", RuntimeHelpers.GetUninitializedObject(typeof(Counters)));
            Set(GetField(gd, "_counters"), "_counterQueues", Array.Empty<CounterQueue>());
            var barriers = (BarrierBatch)RuntimeHelpers.GetUninitializedObject(typeof(BarrierBatch));
            Set(gd, "<Barriers>k__BackingField", barriers); Set(barriers, "_gd", gd);
            Gd = gd;
            var p = (PipelineFull)RuntimeHelpers.GetUninitializedObject(typeof(PipelineFull));
            Set(p, "Gd", gd); Set(p, "Device", Device);
            Set(p, "_activeQueries", new List<(QueryPool, bool, BufferedQuery)>());
            Set(p, "_pendingQueryBegins", new List<(QueryPool, bool, BufferedQuery)>());
            Set(p, "_resumeQueries", new List<(QueryPool, bool, BufferedQuery)>());
            Set(p, "_pendingQueryCopies", new List<(BufferedQuery, int)>());
            Set(p, "_activeBufferMirrors", new List<BufferHolder>());
            Set(p, "AutoFlush", new AutoFlushCounter(gd));
            var fb = RuntimeHelpers.GetUninitializedObject(typeof(FramebufferParams));
            Set(fb, "_colors", null); Set(fb, "_depthStencil", null);
            Set(p, "FramebufferParams", fb);
            Cbs = Pool.Rent();
            Set(p, "Cbs", Cbs); Set(p, "CommandBuffer", Cbs.CommandBuffer);
            Set(p, "EndRenderPassDelegate", (Action)(() => p.EndRenderPass()));
            Pipeline = p;
            QueryPoolCreateInfo qi = new() { SType = StructureType.QueryPoolCreateInfo, QueryCount = 16, QueryType = QueryType.Occlusion };
            Api.CreateQueryPool(Device, in qi, null, out QueryPool qpool).ThrowOnError();
            QueryPool = qpool;
            _holder = NewBuffer();
            Map = Marshal.AllocHGlobal(1024);
        }
        private static object GetField(object obj, string name) =>
            obj.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(obj);
        private BufferHolder NewBuffer()
        {
            BufferCreateInfo info = new() { SType = StructureType.BufferCreateInfo, Size = 4096, Usage = BufferUsageFlags.TransferDstBit };
            Api.CreateBuffer(Device, in info, null, out Buffer buffer).ThrowOnError();
            var allocation = Allocator.Allocate(4096, 256, false);
            Api.BindBufferMemory(Device, buffer, allocation.Memory, allocation.Offset).ThrowOnError();
            return new BufferHolder(Gd, Device, buffer, allocation, 4096, BufferAllocationType.HostMapped, BufferAllocationType.HostMapped);
        }
        public BufferedQuery NewQuery(int? resetSequence = null)
        {
            var q = (BufferedQuery)RuntimeHelpers.GetUninitializedObject(typeof(BufferedQuery));
            Set(q, "_api", Api); Set(q, "_device", Device); Set(q, "_pipeline", Pipeline);
            Set(q, "_gd", Gd);
            Set(q, "_type", CounterType.SamplesPassed); Set(q, "_result32Bit", false);
            Set(q, "_isSupported", true); Set(q, "_queryPool", QueryPool);
            Set(q, "_buffer", _holder); Set(q, "_bufferMap", Map); Set(q, "_defaultValue", Sentinel);
            if (resetSequence.HasValue) Set(q, "_resetSequence", resetSequence);
            return q;
        }
        public void OpenPass()
        {
            RenderPassBeginInfo info = new() { SType = StructureType.RenderPassBeginInfo };
            Api.CmdBeginRenderPass(Cbs.CommandBuffer, in info, SubpassContents.Inline);
            Set(Pipeline, "<RenderPassActive>k__BackingField", true);
            Method(Pipeline, "DrainPendingQueryBegins")?.Invoke(Pipeline, null);
        }
        public void Dispose()
        {
            Pool.Return(Cbs); Dispatch.CompleteAll(); Pool.CollectCompleted(); Marshal.FreeHGlobal(Map); Pool.Dispose();
        }
    }

    private static void BasicPair()
    {
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); q.End(true); w.Pipeline.EndRenderPass();
        Check(Dispatch.Violations.Count == 0, "clean in-subpass pair produced violations: " + string.Join(';', Dispatch.Violations));
        Check(Dispatch.Events.OfType<object>().Any(e => e.ToString()!.Contains("CmdCopyQueryPoolResults")), "copy recorded");
    }
    private static void ResetMidpass()
    {
        using var w = new World();
        var q = w.NewQuery();
        w.OpenPass(); q.Begin(null);
        q.End(true); w.Pipeline.EndRenderPass();
        Check(Dispatch.Violations.Count == 0, "reset-midpass produced violations: " + string.Join(';', Dispatch.Violations));
    }
    private static void RpEndActive()
    {
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); w.Pipeline.EndRenderPass();
        Check(Dispatch.Violations.Count == 0, "rp-end with active query produced violations: " + string.Join(';', Dispatch.Violations));
    }
    private static void DeferEnd()
    {
        using var w = new World();
        var q = w.NewQuery();
        q.Begin(null); q.End(true);
        w.OpenPass(); w.Pipeline.EndRenderPass();
        Check(Dispatch.Violations.Count == 0, "deferred end produced violations: " + string.Join(';', Dispatch.Violations));
    }
    private static void TwoSegmentSum()
    {
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); w.Pipeline.EndRenderPass();
        w.OpenPass(); q.End(true); w.Pipeline.EndRenderPass();
        Marshal.WriteInt64(w.Map, 0, 5); Marshal.WriteInt64(w.Map, 8, 7);
        bool ok = q.AwaitResult(out long result, null);
        Check(ok && result == 12, $"segmented result should sum to 12, got ok={ok} result={result}");
        Check(Dispatch.Violations.Count == 0, "segmented pass produced violations: " + string.Join(';', Dispatch.Violations));
    }
    private static void EndClearsSeg0()
    {
        // A segment copy can complete before End(): its value lands in the buffer early.
        // Clearing at End() would wipe it and the accumulated read could never succeed.
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); w.Pipeline.EndRenderPass();
        Marshal.WriteInt64(w.Map, 0, 5);   // GPU completes segment 0's copy before End()
        w.OpenPass(); q.End(true); w.Pipeline.EndRenderPass();
        Marshal.WriteInt64(w.Map, 8, 7);   // then segment 1's copy
        bool ok = q.AwaitResult(out long result, null);
        Check(ok && result == 12, $"early-landed segment must survive End(), got ok={ok} result={result}");
    }
    private static void TimeoutNoLatch()
    {
        // A bounded-wait expiry counts and reports, but must not permanently latch the
        // result: a late-arriving value is still consumable (only segment overflow latches).
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); q.End(true); w.Pipeline.EndRenderPass();
        long before = w.Gd.QueryTimeouts;
        Check(!q.AwaitResult(out _, null), "AwaitResult on never-written slot must time out");
        Check(w.Gd.QueryTimeouts > before, "timeout must increment the renderer-visible counter");
        Marshal.WriteInt64(w.Map, 0, 9);   // value arrives late
        Check(q.TryGetResult(out long result) && result == 9, $"late result must still be readable after a timeout, got {result}");
    }
    private static void QueueFlushBounded()
    {
        // Real CounterQueue.EventConsumer + FlushTo: a pending event with no result must
        // stay queued (not lost on a failed consume), FlushTo must return bounded, and the
        // event must still complete once the result lands.
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0); q.End(true); w.Pipeline.EndRenderPass();

        var cq = (CounterQueue)RuntimeHelpers.GetUninitializedObject(typeof(CounterQueue));
        Set(cq, "_gd", w.Gd); Set(cq, "_device", w.Device); Set(cq, "_pipeline", w.Pipeline);
        Set(cq, "<Type>k__BackingField", CounterType.SamplesPassed);
        Set(cq, "_events", new Queue<CounterQueueEvent>());
        Set(cq, "_queryPool", new Queue<BufferedQuery>());
        Set(cq, "_lock", new Lock());
        Set(cq, "_queuedEvent", new AutoResetEvent(false));
        Set(cq, "_wakeSignal", new AutoResetEvent(false));
        Set(cq, "_eventConsumed", new AutoResetEvent(false));
        Set(cq, "_s2aCallbackGate", new object());
        var consumer = new Thread(() => Method(cq, "EventConsumer").Invoke(cq, null)) { IsBackground = true };
        Set(cq, "_consumerThread", consumer);

        var evt = (CounterQueueEvent)RuntimeHelpers.GetUninitializedObject(typeof(CounterQueueEvent));
        Set(evt, "_queue", cq); Set(evt, "_counter", q); Set(evt, "_lock", new Lock());
        Set(evt, "_divisor", 1.0); Set(evt, "_refCount", 1); Set(evt, "_result", ulong.MaxValue);
        Set(evt, "<Type>k__BackingField", CounterType.SamplesPassed);
        Set(evt, "<DrawIndex>k__BackingField", 0UL);

        Queue<CounterQueueEvent> events = (Queue<CounterQueueEvent>)typeof(CounterQueue).GetField("_events", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(cq)!;
        events.Enqueue(evt);
        consumer.Start();

        var flushDone = new ManualResetEventSlim();
        var ft = new Thread(() => { cq.FlushTo(evt); flushDone.Set(); }) { IsBackground = true };
        ft.Start();
        Check(flushDone.Wait(3000), "FlushTo must return bounded when the result never lands");
        Check(!evt.Disposed, "failed consume must keep the event pending, not drop it");
        Marshal.WriteInt64(w.Map, 0, 11);   // result lands after the bounded flush returned
        var consumed = new ManualResetEventSlim();
        var wt = new Thread(() => { while (!evt.Disposed) Thread.Sleep(5); consumed.Set(); }) { IsBackground = true };
        wt.Start();
        Check(consumed.Wait(3000), "event still queued must consume once the result lands");
        Check(w.Gd.QueryTimeouts > 0, "timed-out event must count on the renderer summary counter");
        Set(cq, "<Disposed>k__BackingField", true);
    }
    private static void ResetDeferredCopies()
    {
        // Per-pass segment copies can land after a Reset's Begin-clear and read back as
        // stale-but-ready data. Copies must only be queued at End(true): a mid-cycle Reset
        // leaves nothing pending, and a new cycle copies only its own segments.
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        int Copies() => Dispatch.Events.Count(e => e.ToString()!.Contains("CmdCopyQueryPoolResults"));
        w.OpenPass(); q.Begin(0); w.Pipeline.EndRenderPass();   // segment 0 recorded+ended
        w.OpenPass(); w.Pipeline.EndRenderPass();               // segment 1 recorded+ended
        Check(Copies() == 0, $"segment copies must not record before End(true), got {Copies()}");
        q.Reset();                                              // End(false) + Begin: new cycle, 0 segments so far
        w.OpenPass();                                           // drains the deferred begin: new segment 0 records
        w.Pipeline.EndRenderPass();                             // new cycle's only segment ends (1 <= old 2)
        Check(Copies() == 0, $"copies of a reset cycle must never record, got {Copies()}");
        Marshal.WriteInt64(w.Map, 0, 4);
        q.End(true);
        w.OpenPass(); w.Pipeline.EndRenderPass();               // pass-end drains the queued End copies
        Check(Copies() == 1, $"new cycle must copy exactly its own 1 segment at End, got {Copies()}");
    }
    private static void OverflowFail()
    {
        using var w = new World();
        var q = w.NewQuery(0);
        q.PoolReset(w.Cbs.CommandBuffer, 0);
        w.OpenPass(); q.Begin(0);
        for (int i = 0; i < BufferedQuery.MaxQuerySegments + 4; i++) { w.Pipeline.EndRenderPass(); w.OpenPass(); }
        q.End(true);
        bool ok = q.AwaitResult(out _, null);
        Check(!ok, $"query over {BufferedQuery.MaxQuerySegments} segments must fail explicitly, AwaitResult={ok}");
    }
    private static void BoundedAwait()
    {
        using var w = new World();
        var q = w.NewQuery(0);
        Marshal.WriteInt64(w.Map, Sentinel);
        bool ok = true; var done = new ManualResetEventSlim();
        var t = new Thread(() => { ok = q.AwaitResult(out _, null); done.Set(); }) { IsBackground = true };
        t.Start();
        Check(done.Wait(2000), "AwaitResult(null) unbounded - still spinning after 2s");
        Check(!ok, "AwaitResult(null) should report timeout as failure, not sentinel data");
        Check(w.Gd.QueryTimeouts > 0, "timeout must be counted on the renderer summary counter");
    }

    public static int Main(string[] args)
    {
        var cases = new Dictionary<string, Action>
        {
            ["basic-pair"] = BasicPair, ["reset-midpass"] = ResetMidpass,
            ["rpend-active"] = RpEndActive, ["defer-end"] = DeferEnd,
            ["two-segment-sum"] = TwoSegmentSum, ["end-clears-seg0"] = EndClearsSeg0,
            ["timeout-no-latch"] = TimeoutNoLatch, ["queue-flush-bounded"] = QueueFlushBounded,
            ["reset-deferred-copies"] = ResetDeferredCopies,
            ["overflow-fail"] = OverflowFail, ["bounded-await"] = BoundedAwait,
        };
        var status = "PASS";
        try { cases[args[0]](); }
        catch (Exception e) { status = "FAIL"; Console.Error.WriteLine($"{args[0]}: {e.Message}"); }
        Console.WriteLine(JsonSerializer.Serialize(new { status, checks = _checks, events = Dispatch.Events, violations = Dispatch.Violations }));
        return status == "PASS" ? 0 : 1;
    }
}
