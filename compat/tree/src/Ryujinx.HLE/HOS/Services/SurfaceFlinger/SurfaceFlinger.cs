using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Common.PreciseSleep;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvMap;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    /// <summary>S2A：合成节拍的宿主接口（SurfaceFlinger 本身是 internal）</summary>
    public static class S2AFramePacing
    {
        /// <summary>交换间隔下限（宿主按测试契约 S2A_FPS 设：60 Hz 下 30 帧 = 2）。合成按 max(游戏的交换间隔, 下限) 隔几个 vsync 取一帧，
        /// 游戏照常每个 vsync 收到事件，取不到空缓冲就等——从生产端限住出帧，不出「算完就扔」的帧。游戏交换间隔 0（关 vsync）与 Unbounded 不受影响。缺省 1 = 原样。</summary>
        public static int MinSwapInterval = 1;

        /// <summary>生效的交换间隔变了时调（参数 = 每帧秒数，0 = 不限），宿主据此设出图最短显示间隔，让上屏节拍与合成节拍一致</summary>
        public static Action<float> FrameIntervalChanged;
    }

    class SurfaceFlinger : IConsumerListener, IDisposable
    {
        private readonly Switch _device;

        private readonly Dictionary<long, Layer> _layers;

        private bool _isRunning;

        private readonly Thread _composerThread;

        private readonly AutoResetEvent _nextFrameEvent = new(true);
        private long _ticks;
        private long _ticksPerFrame;

        private VSyncMode _vSyncMode;
        private long _targetVSyncInterval;

        private int _swapInterval;
        private int _swapIntervalDelay;

        private static int S2AEffective(int swapInterval) => swapInterval == 0 ? 0 : Math.Max(swapInterval, S2AFramePacing.MinSwapInterval);

        // S2A：已通知宿主的生效交换间隔（-1 = 还没通知过：游戏第一帧合成时必通知一次）
        private int _s2aNotified = -1;

        private readonly Lock _lock = new();

        public long RenderLayerId { get; private set; }

        private class Layer
        {
            public int ProducerBinderId;
            public IGraphicBufferProducer Producer;
            public BufferItemConsumer Consumer;
            public BufferQueueCore Core;
            public ulong Owner;
            public LayerState State;
        }

        private class TextureCallbackInformation
        {
            public Layer Layer;
            public BufferItem Item;
        }

        // S2Arm: per-frame callback objects created once (method groups and the fence lambda allocated a delegate per frame),
        // callback information recycled after the release callback. The pool is shared by the compositor and the GPU thread.
        private readonly Action<GpuContext, object> _acquireBufferCallback;
        private readonly Action<object> _releaseBufferCallback;
        private readonly Action<Ryujinx.Graphics.Gpu.Synchronization.SyncpointWaiterHandle> _frameReadyCallback;
        private readonly Stack<TextureCallbackInformation> _callbackInfoPool = new();

        public SurfaceFlinger(Switch device)
        {
            _device = device;
            _layers = new Dictionary<long, Layer>();
            RenderLayerId = 0;

            _acquireBufferCallback = AcquireBuffer;
            _releaseBufferCallback = ReleaseBuffer;
            _frameReadyCallback = _ =>
            {
                _device.Gpu.Window.SignalFrameReady();
                _device.Gpu.GPFifo.Interrupt();
            };

            _composerThread = new Thread(HandleComposition)
            {
                Name = "SurfaceFlinger.Composer",
                Priority = ThreadPriority.AboveNormal
            };

            _ticks = 0;

            UpdateSwapInterval(1);

            _composerThread.Start();
        }

        private void UpdateSwapInterval(int swapInterval)
        {
            _swapInterval = S2AEffective(swapInterval);

            // If the swap interval is 0, Game VSync is disabled.
            if (_swapInterval == 0)
            {
                _nextFrameEvent.Set();
                _ticksPerFrame = 1;
            }
            else
            {
                _ticksPerFrame = ((Stopwatch.Frequency / _device.TargetVSyncInterval) * 100) / _device.TickScalar;
                _targetVSyncInterval = _device.TargetVSyncInterval;
            }
        }

        public IGraphicBufferProducer CreateLayer(out long layerId, ulong pid, LayerState initialState = LayerState.ManagedClosed)
        {
            layerId = 1;

            lock (_lock)
            {
                foreach (KeyValuePair<long, Layer> pair in _layers)
                {
                    if (pair.Key >= layerId)
                    {
                        layerId = pair.Key + 1;
                    }
                }
            }

            CreateLayerFromId(pid, layerId, initialState);

            return GetProducerByLayerId(layerId);
        }

        private void CreateLayerFromId(ulong pid, long layerId, LayerState initialState)
        {
            lock (_lock)
            {
                Logger.Info?.Print(LogClass.SurfaceFlinger, $"Creating layer {layerId}");

                BufferQueueCore core = BufferQueue.CreateBufferQueue(_device, pid, out BufferQueueProducer producer, out BufferQueueConsumer consumer);

                core.BufferQueued += () =>
                {
                    _nextFrameEvent.Set();
                };

                _layers.Add(layerId, new Layer
                {
                    ProducerBinderId = HOSBinderDriverServer.RegisterBinderObject(producer),
                    Producer = producer,
                    Consumer = new BufferItemConsumer(_device, consumer, 0, -1, false, this),
                    Core = core,
                    Owner = pid,
                    State = initialState,
                });
            }
        }

        public Vi.ResultCode OpenLayer(ulong pid, long layerId, out IBinder producer)
        {
            Layer layer = GetLayerByIdLocked(layerId);

            if (layer == null || layer.State != LayerState.ManagedClosed)
            {
                producer = null;

                return Vi.ResultCode.InvalidArguments;
            }

            layer.State = LayerState.ManagedOpened;
            producer = layer.Producer;

            return Vi.ResultCode.Success;
        }

        public Vi.ResultCode CloseLayer(long layerId)
        {
            lock (_lock)
            {
                Layer layer = GetLayerByIdLocked(layerId);

                if (layer == null)
                {
                    Logger.Error?.Print(LogClass.SurfaceFlinger, $"Failed to close layer {layerId}");

                    return Vi.ResultCode.InvalidValue;
                }

                CloseLayer(layerId, layer);

                return Vi.ResultCode.Success;
            }
        }

        public Vi.ResultCode DestroyManagedLayer(long layerId)
        {
            lock (_lock)
            {
                Layer layer = GetLayerByIdLocked(layerId);

                if (layer == null)
                {
                    Logger.Error?.Print(LogClass.SurfaceFlinger, $"Failed to destroy managed layer {layerId} (not found)");

                    return Vi.ResultCode.InvalidValue;
                }

                if (layer.State is not LayerState.ManagedClosed and not LayerState.ManagedOpened)
                {
                    Logger.Error?.Print(LogClass.SurfaceFlinger, $"Failed to destroy managed layer {layerId} (permission denied)");

                    return Vi.ResultCode.PermissionDenied;
                }

                HOSBinderDriverServer.UnregisterBinderObject(layer.ProducerBinderId);

                if (_layers.Remove(layerId) && layer.State == LayerState.ManagedOpened)
                {
                    CloseLayer(layerId, layer);
                }

                return Vi.ResultCode.Success;
            }
        }

        public Vi.ResultCode DestroyStrayLayer(long layerId)
        {
            lock (_lock)
            {
                Layer layer = GetLayerByIdLocked(layerId);

                if (layer == null)
                {
                    Logger.Error?.Print(LogClass.SurfaceFlinger, $"Failed to destroy stray layer {layerId} (not found)");

                    return Vi.ResultCode.InvalidValue;
                }

                if (layer.State != LayerState.Stray)
                {
                    Logger.Error?.Print(LogClass.SurfaceFlinger, $"Failed to destroy stray layer {layerId} (permission denied)");

                    return Vi.ResultCode.PermissionDenied;
                }

                HOSBinderDriverServer.UnregisterBinderObject(layer.ProducerBinderId);

                if (_layers.Remove(layerId))
                {
                    CloseLayer(layerId, layer);
                }

                return Vi.ResultCode.Success;
            }
        }

        private void CloseLayer(long layerId, Layer layer)
        {
            // If the layer was removed and the current in use, we need to change the current layer in use.
            if (RenderLayerId == layerId)
            {
                // If no layer is availaible, reset to default value.
                if (_layers.Count == 0)
                {
                    SetRenderLayer(0);
                }
                else
                {
                    SetRenderLayer(_layers.Last().Key);
                }
            }

            if (layer.State == LayerState.ManagedOpened)
            {
                layer.State = LayerState.ManagedClosed;
            }
        }

        public void SetRenderLayer(long layerId)
        {
            lock (_lock)
            {
                RenderLayerId = layerId;
            }
        }

        private Layer GetLayerByIdLocked(long layerId)
        {
            foreach (KeyValuePair<long, Layer> pair in _layers)
            {
                if (pair.Key == layerId)
                {
                    return pair.Value;
                }
            }

            return null;
        }

        public IGraphicBufferProducer GetProducerByLayerId(long layerId)
        {
            lock (_lock)
            {
                Layer layer = GetLayerByIdLocked(layerId);

                if (layer != null)
                {
                    return layer.Producer;
                }
            }

            return null;
        }

        private void HandleComposition()
        {
            _isRunning = true;

            long lastTicks = PerformanceCounter.ElapsedTicks;

            while (_isRunning)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("合成"); // S2Arm: per-thread allocation accounting

                long ticks = PerformanceCounter.ElapsedTicks;

                if (_swapInterval == 0)
                {
                    Compose();

                    _device.System?.SignalVsync();

                    _nextFrameEvent.WaitOne(17);
                    lastTicks = ticks;
                }
                else
                {
                    _ticks += ticks - lastTicks;
                    lastTicks = ticks;

                    if (_ticks >= _ticksPerFrame)
                    {
                        long s2aA = Ryujinx.Common.S2AThreadAlloc.On ? GC.GetAllocatedBytesForCurrentThread() : 0;   // S2Arm: per-part allocation accounting (diagnostics)

                        if (_swapIntervalDelay-- == 0)
                        {
                            Compose();

                            // When a frame is presented, delay the next one by its swap interval value.
                            _swapIntervalDelay = Math.Max(0, _swapInterval - 1);
                        }

                        if (Ryujinx.Common.S2AThreadAlloc.On) { long a = GC.GetAllocatedBytesForCurrentThread(); Ryujinx.Common.S2AThreadAlloc.Part("合成·取帧上屏", a - s2aA); s2aA = a; }

                        _device.System?.SignalVsync();

                        if (Ryujinx.Common.S2AThreadAlloc.On) Ryujinx.Common.S2AThreadAlloc.Part("合成·垂直同步", GC.GetAllocatedBytesForCurrentThread() - s2aA);

                        // Apply a maximum bound of 3 frames to the tick remainder, in case some event causes Ryujinx to pause for a long time or messes with the timer.
                        _ticks = Math.Min(_ticks - _ticksPerFrame, _ticksPerFrame * 3);
                    }

                    // Sleep if possible. If the time til the next frame is too low, spin wait instead.
                    long diff = _ticksPerFrame - (_ticks + PerformanceCounter.ElapsedTicks - ticks);
                    // S2Arm: one sleep to the vsync point instead of sleep + up to 2 ms spin per frame (spinning keeps a core busy, costs iPhone power)
                    if (diff > 0)
                    {
                        PreciseSleepHelper.SleepUntilTimePointSingleWake(PerformanceCounter.ElapsedTicks + diff);
                    }
                }
            }
        }

        public void Compose()
        {
            lock (_lock)
            {
                // TODO: support multilayers (& multidisplay ?)
                if (RenderLayerId == 0)
                {
                    return;
                }

                Layer layer = GetLayerByIdLocked(RenderLayerId);

                long s2aA = Ryujinx.Common.S2AThreadAlloc.On ? GC.GetAllocatedBytesForCurrentThread() : 0;   // S2Arm: per-part allocation accounting (diagnostics)
                Status acquireStatus = layer.Consumer.AcquireBuffer(out BufferItem item, 0);
                if (Ryujinx.Common.S2AThreadAlloc.On) Ryujinx.Common.S2AThreadAlloc.Part("合成·取帧上屏·取帧 AcquireBuffer", GC.GetAllocatedBytesForCurrentThread() - s2aA);

                if (acquireStatus == Status.Success)
                {
                    if (_device.VSyncMode == VSyncMode.Unbounded)
                    {
                        if (_swapInterval != 0)
                        {
                            UpdateSwapInterval(0);
                            _vSyncMode = _device.VSyncMode;
                        }
                    }
                    else if (_device.VSyncMode != _vSyncMode)
                    {
                        UpdateSwapInterval(_device.VSyncMode == VSyncMode.Unbounded ? 0 : item.SwapInterval);
                        _vSyncMode = _device.VSyncMode;
                    }
                    else if (S2AEffective(item.SwapInterval) != _swapInterval || _device.TargetVSyncInterval != _targetVSyncInterval)
                    {
                        UpdateSwapInterval(item.SwapInterval);
                    }

                    if (_s2aNotified != _swapInterval && S2AFramePacing.FrameIntervalChanged is { } s2aCb)
                    {
                        _s2aNotified = _swapInterval;
                        s2aCb(_swapInterval == 0 ? 0f : (float)_swapInterval / _device.TargetVSyncInterval);
                    }

                    PostFrameBuffer(layer, item);
                }
                else if (acquireStatus is not Status.NoBufferAvailaible and not Status.InvalidOperation)
                {
                    throw new InvalidOperationException();
                }
            }
        }

        private void PostFrameBuffer(Layer layer, BufferItem item)
        {
            // S2A：直连模式下由直连图形层出图，这里取到的帧直接放回（不交 GPU 窗口），游戏照常拿得到空闲缓冲、不重复出图
            if (S2ADirect.On)
            {
                AndroidFence s2aNoFence = AndroidFence.NoFence;
                layer.Consumer.ReleaseBuffer(item, ref s2aNoFence);

                return;
            }

            long s2aP = Ryujinx.Common.S2AThreadAlloc.On ? GC.GetAllocatedBytesForCurrentThread() : 0;   // S2Arm: per-part allocation accounting (diagnostics)
            int frameBufferWidth = item.GraphicBuffer.Object.Width;
            int frameBufferHeight = item.GraphicBuffer.Object.Height;

            int nvMapHandle = item.GraphicBuffer.Object.Buffer.Surfaces[0].NvMapHandle;

            if (nvMapHandle == 0)
            {
                nvMapHandle = item.GraphicBuffer.Object.Buffer.NvMapId;
            }

            ulong bufferOffset = (ulong)item.GraphicBuffer.Object.Buffer.Surfaces[0].Offset;

            NvMapHandle map = NvMapDeviceFile.GetMapFromHandle(layer.Owner, nvMapHandle);

            ulong frameBufferAddress = map.Address + bufferOffset;

            // S2A：未知像素格式报红、这一帧放回队列不上屏（原先抛异常，合成线程上没人接，整局退出）
            if (!TryConvertColorFormat(item.GraphicBuffer.Object.Buffer.Surfaces[0].ColorFormat, out Format format))
            {
                S2AHooks.Red?.Invoke($"nvnflinger 未实现像素格式 {item.GraphicBuffer.Object.Buffer.Surfaces[0].ColorFormat}");
                AndroidFence s2aBadFormatFence = AndroidFence.NoFence;
                layer.Consumer.ReleaseBuffer(item, ref s2aBadFormatFence);

                return;
            }

            byte bytesPerPixel =
                format is Format.B5G6R5Unorm or
                Format.R4G4B4A4Unorm ? (byte)2 : (byte)4;

            int gobBlocksInY = 1 << item.GraphicBuffer.Object.Buffer.Surfaces[0].BlockHeightLog2;

            // Note: Rotation is being ignored.
            Rect cropRect = item.Crop;

            bool flipX = item.Transform.HasFlag(NativeWindowTransform.FlipX);
            bool flipY = item.Transform.HasFlag(NativeWindowTransform.FlipY);

            AspectRatio aspectRatio = _device.Configuration.AspectRatio;
            bool isStretched = aspectRatio == AspectRatio.Stretched;

            ImageCrop crop = new(
                cropRect.Left,
                cropRect.Right,
                cropRect.Top,
                cropRect.Bottom,
                flipX,
                flipY,
                isStretched,
                aspectRatio.ToFloatX(),
                aspectRatio.ToFloatY());

            TextureCallbackInformation textureCallbackInformation;

            lock (_callbackInfoPool)
            {
                textureCallbackInformation = _callbackInfoPool.Count != 0 ? _callbackInfoPool.Pop() : new TextureCallbackInformation();
            }

            textureCallbackInformation.Layer = layer;
            textureCallbackInformation.Item = item;

            if (Ryujinx.Common.S2AThreadAlloc.On) { long a = GC.GetAllocatedBytesForCurrentThread(); Ryujinx.Common.S2AThreadAlloc.Part("合成·取帧上屏·准备参数", a - s2aP); s2aP = a; }

            bool s2aQueued = _device.Gpu.Window.EnqueueFrameThreadSafe(
                layer.Owner,
                frameBufferAddress,
                frameBufferWidth,
                frameBufferHeight,
                0,
                false,
                gobBlocksInY,
                format,
                bytesPerPixel,
                crop,
                _acquireBufferCallback,
                _releaseBufferCallback,
                textureCallbackInformation);

            if (Ryujinx.Common.S2AThreadAlloc.On) { long a = GC.GetAllocatedBytesForCurrentThread(); Ryujinx.Common.S2AThreadAlloc.Part("合成·取帧上屏·交帧 EnqueueFrameThreadSafe", a - s2aP); s2aP = a; }

            if (s2aQueued)
            {
                if (item.Fence.FenceCount == 0)
                {
                    _device.Gpu.Window.SignalFrameReady();
                    _device.Gpu.GPFifo.Interrupt();
                }
                else
                {
                    item.Fence.RegisterCallback(_device.Gpu, _frameReadyCallback);
                }
            }
            else
            {
                ReleaseBuffer(textureCallbackInformation);
            }

            if (Ryujinx.Common.S2AThreadAlloc.On) Ryujinx.Common.S2AThreadAlloc.Part(item.Fence.FenceCount == 0 ? "合成·取帧上屏·发帧就绪（无围栏）" : "合成·取帧上屏·登记围栏回调", GC.GetAllocatedBytesForCurrentThread() - s2aP);
        }

        private void ReleaseBuffer(object obj)
        {
            ReleaseBuffer((TextureCallbackInformation)obj);
        }

        private void ReleaseBuffer(TextureCallbackInformation information)
        {
            AndroidFence fence = AndroidFence.NoFence;

            information.Layer.Consumer.ReleaseBuffer(information.Item, ref fence);

            information.Layer = null;
            information.Item = null;

            lock (_callbackInfoPool)
            {
                if (_callbackInfoPool.Count < BufferSlotArray.NumBufferSlots)
                {
                    _callbackInfoPool.Push(information);
                }
            }
        }

        private void AcquireBuffer(GpuContext ignored, object obj)
        {
            AcquireBuffer((TextureCallbackInformation)obj);
        }

        private void AcquireBuffer(TextureCallbackInformation information)
        {
            information.Item.Fence.WaitForever(_device.Gpu);
        }

        public static bool TryConvertColorFormat(ColorFormat colorFormat, out Format format)
        {
            (bool known, format) = colorFormat switch
            {
                ColorFormat.A8B8G8R8 => (true, Format.R8G8B8A8Unorm),
                ColorFormat.X8B8G8R8 => (true, Format.R8G8B8A8Unorm),
                ColorFormat.R5G6B5 => (true, Format.B5G6R5Unorm),
                ColorFormat.A8R8G8B8 => (true, Format.B8G8R8A8Unorm),
                ColorFormat.A4B4G4R4 => (true, Format.R4G4B4A4Unorm),
                _ => (false, default),
            };

            return known;
        }

        public void Dispose()
        {
            _isRunning = false;

            foreach (Layer layer in _layers.Values)
            {
                layer.Core.PrepareForExit();
            }
        }

        public void OnFrameAvailable(ref BufferItem item)
        {
            _device.Statistics.RecordGameFrameTime();
        }

        public void OnFrameReplaced(ref BufferItem item)
        {
            _device.Statistics.RecordGameFrameTime();
        }

        public void OnBuffersReleased() { }
    }
}
