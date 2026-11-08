#if FULL_RUNTIME
using S2A.Android.Aot;
using S2A.Services;
using System;
using System.Reflection;
using System.Threading;
using Ryujinx.Horizon;

internal static unsafe class ShutdownTests
{
    private sealed class AudioOwner : IDisposable
    {
        public int Calls;
        public void Dispose() => Interlocked.Increment(ref Calls);
    }

    internal static int Run(Action<bool, string> check, string scenario)
    {
        const BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Static;
        Type runtime = typeof(AndroidGameRuntime);
        var state = (AndroidServiceState)runtime.GetField("State", flags).GetValue(null);
        var cleanupDone = runtime.GetField("_cleanupDone", flags);
        var cancel = (delegate* unmanaged<void>)typeof(Exports).GetMethod("CancelWaits", flags).MethodHandle.GetFunctionPointer();
        var shutdown = (delegate* unmanaged<byte*, void>)typeof(Exports).GetMethod("Shutdown", flags).MethodHandle.GetFunctionPointer();
        delegate* unmanaged<ulong, AndroidServicesStatus*, int> stop = &AndroidGameRuntime.RequestStop;
        AndroidServicesStatus status = new() { Size = 24, Version = 1 };
        int wakes = 0;
        if (scenario.StartsWith("cancel-export-legacy", StringComparison.Ordinal))
        {
            check(Exports.CancelWaitsHandler == null, "legacy path has no Android cancellation owner");
            Ryujinx.Common.S2AShutdown.OnRequest(() =>
            {
                wakes++;
                if (scenario == "cancel-export-legacy-throw") throw new InvalidOperationException("legacy callback exception remains visible");
            });
            cancel();
            check(wakes == 1 && Ryujinx.Common.S2AShutdown.Requested, "legacy actual UCO still executes original cancellation");
            check(state.Snapshot().State == 0, "legacy cancellation does not create an Android session");
            return 0;
        }
        Exports.CancelWaitsHandler = (Action)runtime.GetMethod("RequestServiceCancellation", flags).CreateDelegate(typeof(Action));
        Exports.ShutdownHandler = (Action)runtime.GetMethod("ShutdownFromNative", flags).CreateDelegate(typeof(Action));
        check(state.Begin(7) == ServiceError.Ok && state.Complete() == ServiceError.Ok, "explicit fixture prepares service state, not HLE/GPU");
        Ryujinx.Common.S2AShutdown.OnRequest(() =>
        {
            wakes++;
            if (scenario == "cancel-export-failure") throw new InvalidOperationException("actual Android CancelWaits callback failure");
        });
        if (scenario == "shutdown-failed-root") state.Fail(ServiceError.Initialize);
        cancel(); // Actual production UCO, not a direct call to the managed helper.
        check(wakes == 1 && Ryujinx.Common.S2AShutdown.Requested, "actual cancellation callback executed");
        check(!(bool)cleanupDone.GetValue(null), "cancel is not cleanup completion");
        if (scenario == "cancel-export-failure")
        {
            check(state.Snapshot().State == 3 && state.Snapshot().Error == -9, "wake exception returns from UCO as Failed/Cleanup");
            cancel();
            shutdown(null);
            check(state.Snapshot().State == 3 && state.Snapshot().Error == -9, "repeated cancel/shutdown preserves original failure");
            check(!(bool)cleanupDone.GetValue(null), "failed actual cleanup cannot publish Stopped");
            return 1;
        }
        if (scenario == "shutdown-new-thread-parked")
        {
            // The native park boundary is represented by a blocked host thread;
            // this checks managed cleanup, not native park or Android NativeAOT.
            Type horizon = typeof(Exports).Assembly.GetType("S2A.Services.HorizonHost", true);
            horizon.GetMethod("ObserveFailures", flags).Invoke(null, new object[] { (Action<Exception>)(_ => { }) });
            var owner = new AudioOwner();
            var hooks = typeof(HorizonStatic).Assembly.GetType("Ryujinx.Horizon.S2AHorizonHooks", true);
            ((Action<IDisposable>)hooks.GetField("AudioCreated", BindingFlags.Public | BindingFlags.Static).GetValue(null))(owner);
            using var parked = new ManualResetEventSlim();
            using var release = new ManualResetEventSlim();
            var parkedThread = new Thread(() => { parked.Set(); release.Wait(); }) { IsBackground = true };
            parkedThread.Start();
            check(parked.Wait(3000), "controlled park boundary entered");
            check(stop(7, &status) == 0 && status.State == 4, "stop requested before shutdown");
            nint entry = (nint)shutdown;
            bool unregistered = false, returned = false;
            var caller = new Thread(() =>
            {
                unregistered = HorizonStatic.Syscall == null;
                ((delegate* unmanaged<byte*, void>)entry)(null);
                returned = true;
            }) { IsBackground = true };
            try
            {
                caller.Start();
                bool joined = caller.Join(5000);
                check(joined && returned && unregistered, "actual Android shutdown returns on fresh unregistered thread");
                check((bool)cleanupDone.GetValue(null) && state.Snapshot().State == 5, "actual Cleanup completed before Stopped");
                check(owner.Calls == 1, "actual Cleanup disposed registered audio owner exactly once");
                check(parkedThread.IsAlive && !(bool)horizon.GetField("_stopping", flags).GetValue(null), "controlled parked thread remains parked; Cleanup does not call HorizonHost.Stop");
            }
            finally { release.Set(); parkedThread.Join(3000); }
            return 1;
        }
        if (scenario == "shutdown-failed-root")
        {
            shutdown(null);
            check((bool)cleanupDone.GetValue(null), "actual empty-resource cleanup completed");
            check(state.Snapshot().State == 3 && state.Snapshot().Error == -6, "cleanup after startup failure does not turn it into success");
            return 0;
        }
        check(scenario is "shutdown-success" or "shutdown-missing", "known shutdown scenario");
        check(stop(7, &status) == 0 && status.State == 4 && status.Error == -8, "actual stop request is still only StopRequested");
        check(!(bool)cleanupDone.GetValue(null), "missing shutdown callback has no completion acknowledgement");
        if (scenario == "shutdown-missing") return 1;
        shutdown(null);
        check((bool)cleanupDone.GetValue(null), "actual Cleanup completed before acknowledgement");
        check(state.Snapshot().State == 5 && state.Snapshot().Error == 0, "actual shutdown publishes Stopped/error0");
        int completedWakes = wakes;
        check(stop(7, &status) == 0 && status.State == 5 && status.Error == 0, "stop cannot move Stopped backwards");
        cancel();
        shutdown(null);
        check(wakes == completedWakes && state.Snapshot().State == 5, "completed owner is not canceled or cleaned a second time");
        return 1;
    }
}
#endif
