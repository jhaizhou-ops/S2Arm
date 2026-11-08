using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    // Android generic only. Disabled sessions never call native code per wait.
    public static class S2AFrameTrace
    {
        [DllImport("s2a_native")] private static extern int s2a_frame_log_on();
        [DllImport("s2a_native")] private static extern void s2a_frame_log_fence_wait(ulong ns);
        private static int _enabled;

        public static void InitializeAndroid() => Volatile.Write(ref _enabled, s2a_frame_log_on());
        public static void Disable() => Volatile.Write(ref _enabled, 0);
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static long Begin() => Volatile.Read(ref _enabled) != 0 ? Stopwatch.GetTimestamp() : 0;
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static ulong ElapsedNs(long started) => started == 0 ? 0 : checked((ulong)Stopwatch.GetElapsedTime(started).Ticks * 100UL);
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void EndFence(long started)
        {
            if (started != 0) s2a_frame_log_fence_wait(ElapsedNs(started));
        }
    }
}
