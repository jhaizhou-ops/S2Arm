using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading
{
    /// <summary>
    /// Buffer handles given to the client are not the same as those provided by the backend,
    /// as their handle is created at a later point on the queue.
    /// The handle returned is a unique identifier that will map to the real buffer when it is available.
    /// Note that any uses within the queue should be safe, but outside you must use MapBufferBlocking.
    /// </summary>
    class BufferMap
    {
        private ulong _bufferHandle = 0;

        private readonly Dictionary<BufferHandle, BufferHandle> _bufferMap = new();
        private readonly HashSet<BufferHandle> _inFlight = [];
        private readonly AutoResetEvent _inFlightChanged = new(false);
        // S2A（Android 拆线程）：宿主自起线程且设了上限时等待有界；渲染线程失败 / 卡住后缓冲永远不会建好，放开所有等它的线程，等待方按失败闩重抛
        private readonly ThreadedRenderer _renderer;
        private volatile bool _s2aAbandoned;

        internal BufferMap(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        internal void S2AAbandon()
        {
            _s2aAbandoned = true;
            _inFlightChanged.Set();
        }

        internal BufferHandle CreateBufferHandle()
        {
            ulong handle64 = Interlocked.Increment(ref _bufferHandle);

            BufferHandle threadedHandle = Unsafe.As<ulong, BufferHandle>(ref handle64);

            lock (_inFlight)
            {
                _inFlight.Add(threadedHandle);
            }

            return threadedHandle;
        }

        internal void AssignBuffer(BufferHandle threadedHandle, BufferHandle realHandle)
        {
            lock (_bufferMap)
            {
                _bufferMap[threadedHandle] = realHandle;
            }

            lock (_inFlight)
            {
                _inFlight.Remove(threadedHandle);
            }

            _inFlightChanged.Set();
        }

        internal void UnassignBuffer(BufferHandle threadedHandle)
        {
            lock (_bufferMap)
            {
                _bufferMap.Remove(threadedHandle);
            }
        }

        internal BufferHandle MapBuffer(BufferHandle handle)
        {
            // Maps a threaded buffer to a backend one.
            // Threaded buffers are returned on creation as the buffer
            // isn't actually created until the queue runs the command.

            lock (_bufferMap)
            {
                if (!_bufferMap.TryGetValue(handle, out BufferHandle result))
                {
                    result = BufferHandle.Null;
                }

                return result;
            }
        }

        internal BufferHandle MapBufferBlocking(BufferHandle handle)
        {
            // Blocks until the handle is available.

            lock (_bufferMap)
            {
                if (_bufferMap.TryGetValue(handle, out BufferHandle result))
                {
                    return result;
                }
            }

            bool signal = false;
            bool s2aBounded = _renderer.S2ABounded;
            ThreadedRenderer.S2AStallWatch s2aWatch = s2aBounded ? _renderer.S2AWatch() : default;

            while (true)
            {
                lock (_inFlight)
                {
                    if (!_inFlight.Contains(handle) || _s2aAbandoned)
                    {
                        break;
                    }
                }

                if (!s2aBounded)
                {
                    _inFlightChanged.WaitOne();
                    signal = true;
                }
                else if (_inFlightChanged.WaitOne(50))
                {
                    signal = true;
                }
                else
                {
                    _renderer.S2ACheckStall(ref s2aWatch, "缓冲在渲染线程上建好");
                }
            }

            if (signal)
            {
                // Signal other threads which might still be waiting.
                _inFlightChanged.Set();
            }

            if (s2aBounded)
            {
                _renderer.S2AThrowIfBackendFailed(); // S2A：被失败闩放开时缓冲并没有建好，不返回空句柄
            }

            return MapBuffer(handle);
        }

        internal BufferRange MapBufferRange(BufferRange range)
        {
            return new BufferRange(MapBuffer(range.Handle), range.Offset, range.Size, range.Write);
        }

        internal Span<BufferRange> MapBufferRanges(Span<BufferRange> ranges)
        {
            // Rewrite the buffer ranges to point to the mapped handles.

            lock (_bufferMap)
            {
                for (int i = 0; i < ranges.Length; i++)
                {
                    ref BufferRange range = ref ranges[i];

                    if (!_bufferMap.TryGetValue(range.Handle, out BufferHandle result))
                    {
                        result = BufferHandle.Null;
                    }

                    range = new BufferRange(result, range.Offset, range.Size, range.Write);
                }
            }

            return ranges;
        }

        internal Span<BufferAssignment> MapBufferRanges(Span<BufferAssignment> ranges)
        {
            // Rewrite the buffer ranges to point to the mapped handles.

            lock (_bufferMap)
            {
                for (int i = 0; i < ranges.Length; i++)
                {
                    ref BufferAssignment assignment = ref ranges[i];
                    BufferRange range = assignment.Range;

                    if (!_bufferMap.TryGetValue(range.Handle, out BufferHandle result))
                    {
                        result = BufferHandle.Null;
                    }

                    assignment = new BufferAssignment(ranges[i].Binding, new BufferRange(result, range.Offset, range.Size, range.Write));
                }
            }

            return ranges;
        }

        internal Span<VertexBufferDescriptor> MapBufferRanges(Span<VertexBufferDescriptor> ranges)
        {
            // Rewrite the buffer ranges to point to the mapped handles.

            lock (_bufferMap)
            {
                for (int i = 0; i < ranges.Length; i++)
                {
                    BufferRange range = ranges[i].Buffer;

                    if (!_bufferMap.TryGetValue(range.Handle, out BufferHandle result))
                    {
                        result = BufferHandle.Null;
                    }

                    range = new BufferRange(result, range.Offset, range.Size, range.Write);

                    ranges[i] = new VertexBufferDescriptor(range, ranges[i].Stride, ranges[i].Divisor);
                }
            }

            return ranges;
        }
    }
}
