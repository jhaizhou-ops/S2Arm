using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Buffer = Silk.NET.Vulkan.Buffer;

namespace Ryujinx.Graphics.Vulkan.Queries
{
    class BufferedQuery : IDisposable
    {
        private const int MaxQueryRetries = 5000;
        private const long AwaitResultTimeoutMs = 500;
        private const long DefaultValue = unchecked((long)0xFFFFFFFEFFFFFFFE);
        private const long DefaultValueInt = 0xFFFFFFFE;
        private const ulong HighMask = 0xFFFFFFFF00000000;

        // A query result is accumulated from per-render-pass segments. Each segment owns one
        // pool slot and one buffer slot; Vulkan requires an occlusion query's begin/end to be
        // inside the same subpass, so a query that stays open across a pass boundary must split.
        // 64 slots = 512 B of mapped buffer per query; far beyond observed pass-split counts.
        public const int MaxQuerySegments = 64;

        private readonly Vk _api;
        private readonly Device _device;
        private readonly PipelineFull _pipeline;
        private readonly VulkanRenderer _gd;

        private QueryPool _queryPool;

        private readonly BufferHolder _buffer;
        private readonly nint _bufferMap;
        private readonly CounterType _type;
        private readonly bool _result32Bit;
        private readonly bool _isSupported;

        private readonly long _defaultValue;
        private int? _resetSequence;

        private int _segment;          // next free pool/buffer slot; also open slot+1 while open
        private int _segmentMax;       // slots the guest-visible result must cover
        private int _ended;            // End() observed; result expected
        private int _overflowed;       // segment budget exceeded; no valid result ever
        private int _endDeferred;      // End() arrived while the begin was still pending

        public unsafe BufferedQuery(VulkanRenderer gd, Device device, PipelineFull pipeline, CounterType type, bool result32Bit)
        {
            _api = gd.Api;
            _device = device;
            _pipeline = pipeline;
            _gd = gd;
            _type = type;
            _result32Bit = result32Bit;

            _isSupported = QueryTypeSupported(gd, type);

            if (_isSupported)
            {
                QueryPipelineStatisticFlags flags = type == CounterType.PrimitivesGenerated ?
                    QueryPipelineStatisticFlags.GeometryShaderPrimitivesBit : 0;

                QueryPoolCreateInfo queryPoolCreateInfo = new()
                {
                    SType = StructureType.QueryPoolCreateInfo,
                    QueryCount = MaxQuerySegments,
                    QueryType = GetQueryType(type),
                    PipelineStatistics = flags,
                };

                gd.Api.CreateQueryPool(device, in queryPoolCreateInfo, null, out _queryPool).ThrowOnError();
            }

            BufferHolder buffer = gd.BufferManager.Create(gd, sizeof(long) * MaxQuerySegments, forConditionalRendering: true);

            _bufferMap = buffer.Map(0, sizeof(long) * MaxQuerySegments);
            _defaultValue = result32Bit ? DefaultValueInt : DefaultValue;
            ClearResult();
            _buffer = buffer;
        }

        private static bool QueryTypeSupported(VulkanRenderer gd, CounterType type)
        {
            return type switch
            {
                CounterType.SamplesPassed => true,
                CounterType.PrimitivesGenerated => gd.Capabilities.SupportsPipelineStatisticsQuery,
                CounterType.TransformFeedbackPrimitivesWritten => gd.Capabilities.SupportsTransformFeedbackQueries,
                _ => false,
            };
        }

        private static QueryType GetQueryType(CounterType type)
        {
            return type switch
            {
                CounterType.SamplesPassed => QueryType.Occlusion,
                CounterType.PrimitivesGenerated => QueryType.PipelineStatistics,
                CounterType.TransformFeedbackPrimitivesWritten => QueryType.TransformFeedbackStreamExt,
                _ => QueryType.Occlusion,
            };
        }

        private void ClearResult()
        {
            if (_result32Bit)
            {
                for (int i = 0; i < MaxQuerySegments; i++)
                {
                    Marshal.WriteInt32(_bufferMap, i * sizeof(int), (int)_defaultValue);
                }
            }
            else
            {
                for (int i = 0; i < MaxQuerySegments; i++)
                {
                    Marshal.WriteInt64(_bufferMap, i * sizeof(long), _defaultValue);
                }
            }
        }

        public Auto<DisposableBuffer> GetBuffer()
        {
            return _buffer.GetBuffer();
        }

        public void Reset()
        {
            End(false);
            Begin(null);
        }

        public void Begin(int? resetSequence)
        {
            if (_isSupported)
            {
                // Clear at the start of the cycle: segment copies may land before End(),
                // so the slots must already hold the sentinel for TryGetResult to wait on.
                ClearResult();
                Volatile.Write(ref _ended, 0);
                Volatile.Write(ref _overflowed, 0);
                Volatile.Write(ref _segmentMax, 0);
                bool needsReset = resetSequence == null || _resetSequence == null || resetSequence.Value != _resetSequence.Value;
                bool isOcclusion = _type == CounterType.SamplesPassed;
                _pipeline.BeginQuery(this, _queryPool, needsReset, isOcclusion, isOcclusion && resetSequence != null);
            }

            _resetSequence = null;
        }

        // Pool slots were reset outside a render pass; segment numbering restarts.
        public void OnPoolReset()
        {
            _segment = 0;
            _endDeferred = 0;
        }

        // Reserve the next segment slot for an in-subpass begin. -1 on pool exhaustion.
        public int BeginSegment()
        {
            int slot = _segment;
            if (slot >= MaxQuerySegments)
            {
                // Past the segment budget a partial sum would read back as a smaller (but
                // plausible) value — fail the whole query explicitly instead of returning one.
                if (Interlocked.Exchange(ref _overflowed, 1) == 0)
                {
                    _gd?.IncrementQueryTimeouts();
                    Logger.Error?.Print(LogClass.Gpu, $"Error: Query result {_type} exceeded {MaxQuerySegments} render-pass segments.");
                }
                return -1;
            }
            _segment = slot + 1;
            return slot;
        }

        // The recording segment just ended at its slot; the query may still resume later.
        public int SegmentEnded()
        {
            return _segment - 1;
        }

        public bool EndDeferred
        {
            get => _endDeferred != 0;
            set => _endDeferred = value ? 1 : 0;
        }

        // Latched at segment-overflow: the query can never produce a valid result.
        // Consumers drop such events instead of retrying them forever.
        public bool Overflowed => Volatile.Read(ref _overflowed) != 0;

        public void End(bool withResult)
        {
            bool recordedEnd = false;
            if (_isSupported)
            {
                recordedEnd = _pipeline.EndQuery(_queryPool);
            }

            if (withResult && _isSupported)
            {
                Volatile.Write(ref _segmentMax, Math.Max(_segment, 1));
                Volatile.Write(ref _ended, 1);
                // All segment copies queue only at End: every slot the reader will sum is
                // written by a copy recorded after the last Begin-clear, so a stale copy
                // from a previous cycle can never masquerade as a fresh result.
                if (_segment > 0 || recordedEnd || _endDeferred != 0)
                {
                    _pipeline.CopyQueryResults(this, 0, Math.Max(_segment, 1));
                }
            }
            else
            {
                // Dummy result, just return 0.
                Marshal.WriteInt64(_bufferMap, 0);
                Volatile.Write(ref _ended, 1);
                Volatile.Write(ref _segmentMax, 1);
            }
        }

        private bool WaitingForValue(long data)
        {
            return data == _defaultValue ||
                (!_result32Bit && ((ulong)data & HighMask) == ((ulong)_defaultValue & HighMask));
        }

        public bool TryGetResult(out long result)
        {
            result = _defaultValue;
            if (Volatile.Read(ref _ended) == 0 || Volatile.Read(ref _overflowed) != 0)
            {
                return false;
            }

            int count = Volatile.Read(ref _segmentMax);
            long sum = 0;
            if (_result32Bit)
            {
                for (int i = 0; i < count; i++)
                {
                    int v = Marshal.ReadInt32(_bufferMap, i * sizeof(int));
                    if (v == unchecked((int)DefaultValueInt))
                    {
                        return false;
                    }
                    sum += v;
                }
            }
            else
            {
                for (int i = 0; i < count; i++)
                {
                    long v = Marshal.ReadInt64(_bufferMap, i * sizeof(long));
                    if (WaitingForValue(v))
                    {
                        return false;
                    }
                    sum += v;
                }
            }

            result = sum;
            return true;
        }

        // Bounded wait: returns false on timeout instead of handing the sentinel back as guest
        // data. Callers keep the event pending so the host stall check surfaces the failure.
        public bool AwaitResult(out long result, AutoResetEvent wakeSignal = null)
        {
            long deadline = Stopwatch.GetTimestamp() +
                (AwaitResultTimeoutMs * Stopwatch.Frequency) / 1000;
            int iterations = 0;

            while (!TryGetResult(out result) && iterations++ < MaxQueryRetries)
            {
                if (Stopwatch.GetTimestamp() >= deadline)
                {
                    break;
                }

                if (wakeSignal != null)
                {
                    wakeSignal.WaitOne(1);
                }
                else
                {
                    Thread.Sleep(1);
                }
            }

            if (!TryGetResult(out result))
            {
                // Bounded-wait expiry only counts and reports; it never latches the result.
                // The event stays pending and a late-arriving value remains consumable.
                _gd?.IncrementQueryTimeouts();
                Logger.Error?.Print(LogClass.Gpu, $"Error: Query result {_type} timed out after {AwaitResultTimeoutMs} ms.");

                return false;
            }

            return true;
        }

        public void PoolReset(CommandBuffer cmd, int resetSequence)
        {
            if (_isSupported)
            {
                _api.CmdResetQueryPool(cmd, _queryPool, 0, MaxQuerySegments);
            }

            _resetSequence = resetSequence;
            OnPoolReset();
        }

        public void PoolCopy(CommandBufferScoped cbs, int segment)
        {
            int stride = _result32Bit ? sizeof(int) : sizeof(long);
            Buffer buffer = _buffer.GetBuffer(cbs.CommandBuffer, true).Get(cbs, segment * stride, stride, true).Value;

            QueryResultFlags flags = QueryResultFlags.ResultWaitBit;

            if (!_result32Bit)
            {
                flags |= QueryResultFlags.Result64Bit;
            }

            _api.CmdCopyQueryPoolResults(
                cbs.CommandBuffer,
                _queryPool,
                (uint)segment,
                1,
                buffer,
                (ulong)(segment * stride),
                (ulong)stride,
                flags);
        }

        public unsafe void Dispose()
        {
            _buffer.Dispose();
            if (_isSupported)
            {
                _api.DestroyQueryPool(_device, _queryPool, null);
            }

            _queryPool = default;
        }
    }
}
