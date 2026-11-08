using System;
using System.Runtime.InteropServices;
using NxGal;
using Ryujinx.Memory.Tracking;

namespace Ryujinx.Memory {
    public enum MemoryPermission { None, Read, ReadAndWrite }
    public class InvalidMemoryRegionException : Exception { }
}
namespace Ryujinx.Memory.Tracking {
    // Only the tracking callback is a fixture; NxTrack and the native tracker
    // are the actual production implementations.
    public unsafe class MemoryTracking {
        public static bool S2ABufferNone, S2AReadTouch;
        public static Action<ulong, ulong> S2AMarkReadFlush;
        public static delegate*<ulong, byte*, int, void> S2AReadUntracked;
        public static delegate*<ulong, ulong, int, void> S2AReprotect;
        public static delegate*<ulong, ulong, void> S2AModSet, S2AModClear;
        public static delegate*<ulong, ulong> S2ATrackPageInfo;
        public int PreciseEvents;
        public void S2AReadFlush(ulong va, ulong size) {
            S2AReadTouch = true;
            try { VirtualMemoryEvent(va, size, false, false, null, true); }
            finally { S2AReadTouch = false; }
        }
        public void VirtualMemoryEvent(ulong va, ulong size, bool write, bool precise, int? exemptId, bool guest) {
            if (write && precise && guest && size > 0) {
                PreciseEvents++;
                if (Program.Clobber && Program.fixture_clobber_precise() != 0)
                    throw new InvalidOperationException("clobber opened the protected guest page");
            }
        }
    }
}
static class Program {
#if S2A_ANDROID
    const string Consumer = "Android";
#else
    const string Consumer = "Apple";
#endif
    public static bool Clobber;
    [DllImport("s2a_native")] public static extern int fixture_clobber_precise();
    [DllImport("s2a_native")] static extern int fixture_read_precise();
    [DllImport("s2a_native")] static extern ulong fixture_prepare();
    [DllImport("s2a_native")] static extern int fixture_protection();
    static int Main(string[] args) {
        Clobber = args.Length == 1 && args[0] == "clobber";
        if (fixture_prepare() == 0) return 2;
        var tracking = new MemoryTracking();
        NxTrack.Drain(tracking);
        if (tracking.PreciseEvents == 0) { Console.Error.WriteLine("no precise snapshot processed"); return 3; }
        if (fixture_protection() != 0) { Console.Error.WriteLine("READFLUSH protection was weakened"); return 4; }
        if (fixture_read_precise() != 0x5a) { Console.Error.WriteLine("CPU byte was not preserved"); return 6; }
        Console.WriteLine($"PASS actual {Consumer} NxTrack.Drain precise events={tracking.PreciseEvents}; clobber={Clobber}");
        return 0;
    }
}
