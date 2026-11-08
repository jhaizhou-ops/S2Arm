using Ryujinx.Cpu;
using System;

namespace S2A.Services
{
    // Ryujinx 的计数器改用游戏读到的同一个（原生层 s2a_guest_tick，Switch 19.2 MHz / Switch 2 31.25 MHz，频率 s2a_guest_tick_hz）：时间服务把稳态时钟基准按它写进共享内存，
    // 游戏用自己的计数器减基准算当前时间——两者零点不同（宿主开机 vs 进程启动）就差出整段宿主开机时长（对拍查出动森时间晚 10 小时）。
    // 计数器从宿主开机起算，所以「自创建起」的耗时也按它算；不支持变速与暂停（S2Arm 不暂停游戏），被调到报红。
    sealed unsafe class NativeTickSource : ITickSource
    {
        private static readonly ulong Hz = Native.GuestTickHz != null ? Native.GuestTickHz() : 19_200_000;
        private static readonly object CatchUpGate = new();
        private static bool _catchUpActive;

        public static bool Available => Native.GuestTick != null;

        public ulong Frequency => Hz;

        public ulong Counter => Native.GuestTick();

        public TimeSpan ElapsedTime => TimeSpan.FromTicks((long)((UInt128)Counter * 10_000_000 / Hz));   // 计数 → 100 ns 单位

        public double ElapsedSeconds => Counter / (double)Hz;

        private long _scalar = ITickSource.RealityTickScalar;

        public long TickScalar
        {
            get => _scalar;
            set
            {
                if (value != ITickSource.RealityTickScalar)
                {
                    Red.Report("Ryujinx 要求时钟变速（S2Arm 未支持，原生计数器不变速）", value.ToString());
                }

                _scalar = value;
            }
        }

        public void Suspend() => Red.Report("Ryujinx 要求暂停时钟（S2Arm 未支持）");

        public void Resume()
        {
        }

        // 游戏计数器没看到的宿主时长（接口 v2.14，runtime/src/os.c s2a_clock_unseen_ns）：后台冻结与宿主睡眠期间在长。
        //   Ryujinx 稳态时钟要补它的增量（真机睡眠时系统计数器停、RTC 起的稳态时钟照走），否则游戏日历落后后台时长（#863）
        public static bool UnseenAvailable => Native.ClockUnseen != null;

        public static long UnseenNs() => Native.ClockUnseen();

        // 把补时入口登记给原生层（Host 设好 S2AHooks.TickUnseenNs 后调；Native 只绑导出、不引用本类，单独收 Native.cs 的工程照样能编）
        public static void BindCatchUp()
        {
            lock (CatchUpGate)
            {
                _catchUpActive = true;
                if (Native.ClockRegisterCatchup != null) Native.ClockRegisterCatchup(&CatchUp);
            }
        }

        // The native caller can already have copied the function pointer. The
        // same gate drains that callback before the old shared clock is retired.
        internal static void StopCatchUp()
        {
            lock (CatchUpGate)
            {
                _catchUpActive = false;
                if (Native.ClockRegisterCatchup != null) Native.ClockRegisterCatchup(null);
                Ryujinx.HLE.S2AHooks.TickUnseenNs = null;
            }
        }

        // 补时入口：登记给原生层（s2a_clock_register_catchup），App 壳回前台 / Mac 唤醒时经 s2a_clock_catchup 同步调到这里
        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        public static void CatchUp()
        {
            lock (CatchUpGate)
                if (_catchUpActive) Ryujinx.HLE.S2AHooks.SteadyClockCatchUp();
        }
    }
}
