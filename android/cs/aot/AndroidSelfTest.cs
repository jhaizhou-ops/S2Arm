using System;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Android.Aot
{
    // Single-library build only (NativeLib=Static, linked into libs2arm_android.so):
    // the service layer's native imports bind with DirectPInvoke at link time, as on
    // iOS, instead of a main-program lookup that cannot see app libraries on Android.
    public static unsafe class AndroidSelfTest
    {
        // This composition owns the app DSO, not app_process. NativeAOT and the
        // function pointers it publishes have process lifetime; never Free it.
        private static readonly Lazy<nint> _nativeOwner = new(() => NativeLibrary.Load("libs2arm_android.so"));

        [UnmanagedCallersOnly(EntryPoint = "s2a_android_cs_selftest")]
        public static int Run(byte* buffer, int length)
        {
            string report;
            int failures = 0;
            try
            {
                S2A.Services.Native.UseLinked(_nativeOwner.Value);
                int width = S2A.Services.Native.ScreenW();   // C# -> C, value back
                byte[] mark = Encoding.UTF8.GetBytes("cs-selftest\0");
                fixed (byte* p = mark) S2A.Services.Native.BootMark(p);   // C# -> C, string in
                // The runtime's unwinder is renamed in this build (cs/build.sh); exception
                // dispatch and the GC's stack walks both go through it.
                string unwind;
                try { Throw(3); unwind = "not caught"; }
                catch (InvalidOperationException e) { unwind = e.StackTrace != null ? "caught with trace" : "caught"; }
                string nullRef;
                try { nullRef = Deref(null).ToString(); } catch (NullReferenceException) { nullRef = "caught"; }
                var keep = new object[1024];
                for (int i = 0; i < 100_000; i++) keep[i & 1023] = new byte[i & 511];
                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
                if (unwind == "not caught" || nullRef != "caught") failures++;
                string clock = S2A.Services.Native.GuestTick != null ? "present" : "absent";
                string det = S2A.Services.Native.DetMode != null ? "present" : "absent";
                string catchup = S2A.Services.Native.ClockUnseen != null ? "present" : "absent";
                report = $"runtime={RuntimeInformation.FrameworkDescription}; s2a_screen_w={width}; exceptions={unwind}; null-ref={nullRef}; gc=ok; clock={clock}; det={det}; clock-catchup={catchup}; game_ready=false";
            }
            catch (Exception e)
            {
                failures++;
                report = $"FAILED {e.GetType().Name} {e.Message}";
            }
            byte[] text = Encoding.UTF8.GetBytes(report);
            int n = Math.Min(text.Length, length - 1);
            text.AsSpan(0, n).CopyTo(new Span<byte>(buffer, length));
            buffer[n] = 0;
            return failures;
        }

        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static void Throw(int depth)
        {
            if (depth == 0) throw new InvalidOperationException("selftest");
            Throw(depth - 1);
        }

        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static int Deref(int[] a) => a[0];
    }
}
