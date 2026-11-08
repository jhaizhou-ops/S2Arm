using Ryujinx.Common;
using Ryujinx.Graphics.GAL;
using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Engine.Threed
{
    /// <summary>
    /// Semaphore updater.
    /// </summary>
    class SemaphoreUpdater
    {
        /// <summary>
        /// GPU semaphore operation.
        /// </summary>
        private enum SemaphoreOperation
        {
            Release = 0,
            Acquire = 1,
            Counter = 2,
        }

        /// <summary>
        /// Counter type for GPU counter reset.
        /// </summary>
        private enum ResetCounterType
        {
            SamplesPassed = 1,
            ZcullStats = 2,
            TransformFeedbackPrimitivesWritten = 0x10,
            InputVertices = 0x12,
            InputPrimitives = 0x13,
            VertexShaderInvocations = 0x15,
            TessControlShaderInvocations = 0x16,
            TessEvaluationShaderInvocations = 0x17,
            TessEvaluationShaderPrimitives = 0x18,
            GeometryShaderInvocations = 0x1a,
            GeometryShaderPrimitives = 0x1b,
            ClipperInputPrimitives = 0x1c,
            ClipperOutputPrimitives = 0x1d,
            FragmentShaderInvocations = 0x1e,
            PrimitivesGenerated = 0x1f,
        }

        /// <summary>
        /// Counter type for GPU counter reporting.
        /// </summary>
        private enum ReportCounterType
        {
            Payload = 0,
            InputVertices = 1,
            InputPrimitives = 3,
            VertexShaderInvocations = 5,
            GeometryShaderInvocations = 7,
            GeometryShaderPrimitives = 9,
            ZcullStats0 = 0xa,
            TransformFeedbackPrimitivesWritten = 0xb,
            ZcullStats1 = 0xc,
            ZcullStats2 = 0xe,
            ClipperInputPrimitives = 0xf,
            ZcullStats3 = 0x10,
            ClipperOutputPrimitives = 0x11,
            PrimitivesGenerated = 0x12,
            FragmentShaderInvocations = 0x13,
            SamplesPassed = 0x15,
            TransformFeedbackOffset = 0x1a,
            TessControlShaderInvocations = 0x1b,
            TessEvaluationShaderInvocations = 0x1d,
            TessEvaluationShaderPrimitives = 0x1f,
        }

        private readonly GpuContext _context;
        private readonly GpuChannel _channel;
        private readonly DeviceStateWithShadow<ThreedClassState> _state;

        /// <summary>
        /// Creates a new instance of the semaphore updater.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="channel">GPU channel</param>
        /// <param name="state">Channel state</param>
        public SemaphoreUpdater(GpuContext context, GpuChannel channel, DeviceStateWithShadow<ThreedClassState> state)
        {
            _context = context;
            _channel = channel;
            _state = state;
        }

        /// <summary>
        /// Resets the value of an internal GPU counter back to zero.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void ResetCounter(int argument)
        {
            ResetCounterType type = (ResetCounterType)argument;

            switch (type)
            {
                case ResetCounterType.SamplesPassed:
                    S2AGsDiag.OccBegin();   // #1456：遮挡查询在飞计数（复位=打开）
                    _context.Renderer.ResetCounter(CounterType.SamplesPassed);
                    break;
                case ResetCounterType.PrimitivesGenerated:
                    _context.Renderer.ResetCounter(CounterType.PrimitivesGenerated);
                    break;
                case ResetCounterType.TransformFeedbackPrimitivesWritten:
                    _context.Renderer.ResetCounter(CounterType.TransformFeedbackPrimitivesWritten);
                    break;
            }
        }

        /// <summary>
        /// Writes a GPU counter to guest memory.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void Report(int argument)
        {
            SemaphoreOperation op = (SemaphoreOperation)(argument & 3);
            ReportCounterType type = (ReportCounterType)((argument >> 23) & 0x1f);

            switch (op)
            {
                case SemaphoreOperation.Release:
                    ReleaseSemaphore();
                    break;
                case SemaphoreOperation.Counter:
                    ReportCounter(type);
                    break;
            }
        }

        /// <summary>
        /// Writes (or Releases) a GPU semaphore value to guest memory.
        /// </summary>
        private void ReleaseSemaphore()
        {
            _channel.MemoryManager.S2AEngineWrite(_state.State.SemaphoreAddress.Pack(), _state.State.SemaphorePayload);

            _context.AdvanceSequence();
        }

        /// <summary>
        /// Packed GPU counter data (including GPU timestamp) in memory.
        /// </summary>
        private struct CounterData
        {
            public ulong Counter;
            public ulong Timestamp;
        }

        /// <summary>
        /// Writes a GPU counter to guest memory.
        /// This also writes the current timestamp value.
        /// </summary>
        /// <param name="type">Counter to be written to memory</param>
        private void ReportCounter(ReportCounterType type)
        {
            // S2A：Payload（信号量值，最常见）当场写、不经回调——原本本地函数捕获 gpuVa / ticks / counter / this，
            // C# 把它们提进方法开头就分配的闭包对象（48 B），Payload 也照付，动森岛上每帧约 3 次。语义同原版：写 {payload, 时间戳}、计数缓存记 null
            if (type == ReportCounterType.Payload)
            {
                ulong va = _state.State.SemaphoreAddress.Pack();
                CounterData data = new()
                {
                    Counter = (ulong)_state.State.SemaphorePayload,
                    Timestamp = _context.GetTimestamp(),
                };

                _channel.MemoryManager.S2AEngineWrite(va, data);
                _channel.MemoryManager.CounterCache.AddOrUpdate(va, null);

                // S2A_GPU_TS：载荷照旧当场写（信号量语义不变），时间戳字段另由渲染器在 GPU 做完这段后给出真实 GPU 时刻，攒到下一次同步点推进整批回写（GpuContext.S2ATs*）
                if (GpuContext.S2AGpuTs)
                {
                    CounterReport ts;

                    lock (_reports)
                    {
                        ts = _reports.Count != 0 ? _reports.Pop() : new CounterReport(this);
                    }

                    ts.GpuVa = va;
                    ts.Ticks = data.Counter;   // 时间戳报告里借 Ticks 存载荷
                    ts.Counter = null;
                    ts.Pending = true;
                    ts.IsTs = true;
                    _context.S2ATsBegin();
                    ICounterEvent tsEvt = _context.Renderer.ReportCounter(CounterType.S2ATimestamp, ts.Handler, 1f, false);
                    _context.S2ATsTrack(tsEvt);   // 事件对象只在 GPU 线程上释放（同计数缓存替换时的做法）；回调里释放会让线程化渲染器的包装与底层对象错配
                }

                return;
            }

            ReportCounterQuery(type);
        }

        // S2Arm: per-report state (address, timestamp, event) lives in a pooled object whose result callback is bound once, back in the
        // pool when the result arrives (was a closure + a delegate per report: 112 B, d3 reports SamplesPassed ~18 times per frame).
        private sealed class CounterReport
        {
            public readonly EventHandler<ulong> Handler;
            private readonly SemaphoreUpdater _owner;
            public ulong GpuVa;
            public ulong Ticks;
            public ICounterEvent Counter;
            public bool Pending;
            public bool IsTs;

            public CounterReport(SemaphoreUpdater owner)
            {
                _owner = owner;
                Handler = OnResult;
            }

            private void OnResult(object evt, ulong result)
            {
                if (IsTs)
                {
                    // 计数线程：真实 GPU 时刻换成客体时钟，进待写批（同步点推进时整批写，免得游戏读到「帧头新、帧尾旧」的一对）
                    _owner._context.S2ATsResult(_owner._channel.MemoryManager, GpuVa, Ticks, result);
                    IsTs = false;
                    Counter = null;
                    Pending = false;
                    _owner.ReturnReport(this);
                    return;
                }

                CounterData counterData = new()
                {
                    Counter = result,
                    Timestamp = Ticks,
                };

                if (Counter?.Invalid != true)
                {
                    _owner._channel.MemoryManager.Write(GpuVa, counterData);
                }

                Counter = null;
                Pending = false;
                _owner.ReturnReport(this);
            }
        }

        private readonly Stack<CounterReport> _reports = new();

        private void ReturnReport(CounterReport report)
        {
            lock (_reports)
            {
                _reports.Push(report);
            }
        }

        private void ReportCounterQuery(ReportCounterType type)
        {
            ulong gpuVa = _state.State.SemaphoreAddress.Pack();

            ulong ticks = _context.GetTimestamp();

            CounterType counterType;
            float divisor = 1f;

            switch (type)
            {
                case ReportCounterType.SamplesPassed:
                    float scale = _channel.TextureManager.RenderTargetScale;
                    divisor = scale * scale;
                    counterType = CounterType.SamplesPassed;
                    S2AGsDiag.OccEnd();   // #1456：报告=关闭
                    break;
                case ReportCounterType.PrimitivesGenerated:
                    counterType = CounterType.PrimitivesGenerated;
                    break;
                case ReportCounterType.TransformFeedbackPrimitivesWritten:
                    counterType = CounterType.TransformFeedbackPrimitivesWritten;
                    break;
                default:
                    // Unsupported counter: nothing is written, the cache forgets any older counter at this address (as before)
                    _channel.MemoryManager.CounterCache.AddOrUpdate(gpuVa, null);
                    return;
            }

            CounterReport report;

            lock (_reports)
            {
                report = _reports.Count != 0 ? _reports.Pop() : new CounterReport(this);
            }

            report.GpuVa = gpuVa;
            report.Ticks = ticks;
            report.Counter = null;
            report.Pending = true;

            ICounterEvent counter = _context.Renderer.ReportCounter(counterType, report.Handler, divisor, false);

            // A result delivered inside ReportCounter saw no event yet (same as the original local function)
            if (report.Pending)
            {
                report.Counter = counter;
            }

            _channel.MemoryManager.CounterCache.AddOrUpdate(gpuVa, counter);
        }
    }
}
