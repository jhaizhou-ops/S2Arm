// Platform-only controls: the FIFO, command decoder, backing transaction and tracking
// state are production code. No native page protection, Vulkan dispatch or device is used.
using Ryujinx.Graphics.GAL;
using Ryujinx.Memory;
using Ryujinx.Memory.Tracking;
using System;

namespace NxGal
{
    public static class NxTrack
    {
        public static Action OnDrain;
        public static void Drain(MemoryTracking tracking) => OnDrain?.Invoke();
        public static void Init(MemoryTracking tracking, Action<ulong, ulong> remap, Action<Exception> failure) { }
        public static void Reprotect(ulong address, ulong size, MemoryPermission permission, bool guest) { }
        public static void WriteUntracked(ulong address, ReadOnlySpan<byte> data, bool flush) { }
        public static void Write(ulong address, ulong size) { }
        public static void WriteQuiet(ulong address, ulong size) { }
        public static bool GpuModified(ulong address, ulong size) => false;
    }
}

namespace S2Arm.Backends.Vulkan.Wsi
{
    public sealed class AndroidVulkanSurface
    {
        public string RetirementSummary => "idleRetirements=7 fenceGraceFallbacks=3 revokeImmediateRetirements=1 deferredSemaphores=2 deferredFences=5";
        public static Action OnFence;
        public static Action OnPoll;
        // 实际宿主会把 _lifecycle（外壳代元钟）一并交给 surface → 窗口的取图预算；夹具记下接线。
        public static Func<long> SuppliedLifecycle;
        public AndroidVulkanSurface(nint leaseApi, ulong session, bool transferFullClears, Func<long> lifecycle) => SuppliedLifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
        public IRenderer CreateRenderer() => throw new NotSupportedException("No Vulkan device in host contract tests.");
        // 租约 owner 线程 Poll 时才把外壳的生命周期抄进 Foreground（同 NativeLease）；渲染线程卡在长命令里时它就停在旧值。
        public void Poll() { ForegroundValue = ProducerForeground; OnPoll?.Invoke(); }
        public void PollIfReady() => Poll();
        public static Action WaitPump;   // 接线检查：运行时装上的驱动等待泵
        public void SetWaitPump(Action pump) => WaitPump = pump;
        public void SetPipelineCachePath(string path) { }
        public void CompletePendingCommands(int milliseconds) => OnFence?.Invoke();
        public void Wake() { }
        public static Action OnStop;   // threaded stop order: observed on the thread that stops WSI
        public void Stop() => OnStop?.Invoke();
        public bool Retired => true;
        // Backing tests model a running foreground owner that is not stopping. The threaded checks flip these
        // (lease stopping, backgrounded process) and restore the defaults before the next case.
        public static volatile bool StoppingValue;
        public static volatile bool ForegroundValue = true;
        // 外壳生命周期（租约生产方，任意线程可读）：拆线程卡住判据与换页等待的生命周期钟（≥ 0 前台，值 = 转换次数；-1 后台）。
        public static volatile bool ProducerForeground = true;
        private static long _lifecycleChanges;
        public static Action<bool> OnProducerForeground;
        public static void SetProducerForeground(bool value)
        {
            if (ProducerForeground == value) return;
            OnProducerForeground?.Invoke(value);
            ProducerForeground = value;
            System.Threading.Interlocked.Increment(ref _lifecycleChanges);
        }
        public static long Lifecycle() => ProducerForeground ? System.Threading.Interlocked.Read(ref _lifecycleChanges) : -1;
        public bool Stopping => StoppingValue;
        public bool Foreground => ForegroundValue;
        // The backing-control tests never present; the threaded present check advances the queued-present count
        // on the presenting thread, as the real window does after a successful QueuePresent.
        public static ulong Presents;
        public ulong QueuedGamePresents => Presents;
    }
}
