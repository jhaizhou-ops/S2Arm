#if FULL_RUNTIME
using S2A.Android.Aot;
using System;
using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

internal static unsafe class AttachThreadTests
{
    private const BindingFlags Static = BindingFlags.NonPublic | BindingFlags.Static;
    private static readonly FieldInfo AttachedSession = typeof(AndroidGameRuntime).GetField("_attachedSession", Static);
    private static readonly FieldInfo AttachedThread = typeof(AndroidGameRuntime).GetField("_attachedThreadId", Static);
    private static readonly ConcurrentDictionary<int, byte> ObservedThreads = new();
    private static int _caller;

    [StructLayout(LayoutKind.Sequential)]
    private struct Result
    {
        public int First, Repeated, Observation, Reserved;
        public AndroidServicesStatus FirstStatus, RepeatedStatus;
    }

    [UnmanagedCallersOnly]
    private static int Observe(ulong session, int error)
    {
        try
        {
            int actualThread = Thread.CurrentThread.ManagedThreadId;
            ulong attached = (ulong)AttachedSession.GetValue(null);
            int attachedThread = (int)AttachedThread.GetValue(null);
            if (actualThread == _caller || !ObservedThreads.TryAdd(actualThread, 0)) return -1;
            if (error == 0) return attached == session && attachedThread == actualThread ? 0 : -2;
            return attached == 0 && attachedThread == 0 ? 0 : -3;
        }
        catch { return -4; } // Test callback records failure; never crosses native.
    }

    internal static bool Run(Action<bool, string> check, string scenario, string library)
    {
        delegate* unmanaged<ulong, AndroidServicesStatus*, int> attach = &AndroidGameRuntime.AttachThread;
        var state = (AndroidServiceState)typeof(AndroidGameRuntime).GetField("State", Static).GetValue(null);
        AndroidServicesStatus status = new() { Size = 24, Version = 1 };
        check(attach(7, null) == -1, "null attachment output rejected");
        check(attach(7, &status) == -1 && status.State == 0, "unstarted attachment never claims readiness");
        check(state.Begin(7) == ServiceError.Ok, "explicit service-state fixture starts");
        check(attach(7, &status) == -6 && status.State == 1, "Starting is not accepted as Ready");
        check(state.Complete() == ServiceError.Ok, "fixture prepares service-state boundary only");
        status.Version = 2;
        check(attach(7, &status) == -1, "invalid status prefix rejected");
        status.Version = 1;
        check(attach(8, &status) == -1 && status.Session == 7 && status.State == 2, "foreign session does not poison owner");
        _caller = Thread.CurrentThread.ManagedThreadId;
        if (scenario == "attach-owner-failure")
        {
            // Force the actual production ownership exception on this managed
            // thread; native-pthread attachment is independently covered below.
            AttachedSession.SetValue(null, 99UL);
            AttachedThread.SetValue(null, _caller);
            check(attach(7, &status) == -6, "actual per-thread ownership exception returns Initialize failure");
            check(status.State == 3 && status.Error == -6, "actual attachment exception revokes Ready");
            check(attach(7, &status) == -6, "a failed attachment cannot retry into Ready");
            return true;
        }
        int expected = 0;
        ulong session = 7;
        if (scenario == "attach-stop") { state.RequestStop(7); expected = -8; }
        else if (scenario == "attach-failed") { state.Fail(ServiceError.Gpu); expected = -7; }
        else if (scenario == "attach-foreign") { session = 8; expected = -1; }
        else if (scenario != "attach-ready") throw new ArgumentException("Unknown attachment scenario");

        // State is a fixture; the first managed entry on each C-created pthread
        // is the actual production export. No managed wrapper runs before it.
        nint native = NativeLibrary.Load(library);
        try
        {
            var run = (delegate* unmanaged<delegate* unmanaged<ulong, AndroidServicesStatus*, int>,
                delegate* unmanaged<ulong, int, int>, ulong, Result*, uint, int>)
                NativeLibrary.GetExport(native, "s2a_test_attach_pthreads");
            Result* results = stackalloc Result[8];
            check(sizeof(Result) == 64, "native fixture result ABI");
            check(run(attach, &Observe, session, results, 8) == 0, "eight actual native pthreads started and joined");
            check(ObservedThreads.Count == 8, "each native pthread has a distinct real managed thread identity");
            for (int i = 0; i < 8; i++)
            {
                check(results[i].First == expected && results[i].Repeated == expected, "first and repeat result consume current service state");
                check(results[i].Observation == 0, "real per-thread session/thread binding observed only after actual attachment");
                check(results[i].FirstStatus.Session == 7 && results[i].RepeatedStatus.Session == 7, "attachment returns actual owner session");
                check(results[i].FirstStatus.State == state.Snapshot().State && results[i].RepeatedStatus.State == state.Snapshot().State,
                    "attachment does not overwrite real service state");
            }
            check((ulong)AttachedSession.GetValue(null) == 0, "guest native thread binding does not leak into calling managed thread");
        }
        finally { NativeLibrary.Free(native); }
        return false;
    }
}
#endif
