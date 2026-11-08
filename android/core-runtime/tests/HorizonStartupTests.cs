using Ryujinx.Horizon;
using S2A.Services;
using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

internal static class HorizonStartupTests
{
    private const BindingFlags Static = BindingFlags.NonPublic | BindingFlags.Static;
    private static readonly Type Host = typeof(Exports).Assembly.GetType("S2A.Services.HorizonHost", true);

    private static object Invoke(string method, params object[] args)
    {
        try { return Host.GetMethod(method, Static).Invoke(null, args); }
        catch (TargetInvocationException error)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error.InnerException).Throw();
            throw;
        }
    }

    private static Exception Capture(Action action)
    {
        try { action(); return null; }
        catch (Exception error) { return error; }
    }

    private static void Start(ServiceTable table, Action<ServiceTable> body)
    {
        var entry = (ServiceEntry)Activator.CreateInstance(typeof(ServiceEntry), BindingFlags.NonPublic | BindingFlags.Instance,
            null, new object[] { body, table, default(HorizonOptions), "StartupFailureFixture" }, null);
        Invoke("Start", entry);
    }

    internal static bool Run(Action<bool, string> check, string scenario, Action<Exception> androidFailure)
    {
        // The actual service-thread wrapper, TLS setup and ServiceEntry.Start run.
        // Only unrelated Dispatcher kernel construction is excluded: the injected
        // entry throws before making a syscall or touching guest memory.
        var dispatcher = (Dispatcher)RuntimeHelpers.GetUninitializedObject(typeof(Dispatcher));
        typeof(Dispatcher).GetField("<Memory>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance)
            .SetValue(dispatcher, new GuestMemory());
        typeof(Dispatcher).GetProperty("Instance").SetValue(null, dispatcher);
        Red.Strict = false;
        using var reached = new ManualResetEventSlim();
        using var notified = new ManualResetEventSlim();
        var table = new ServiceTable();
        int total = table.GetServices(default).Count();
        var signal = typeof(ServiceTable).GetMethod("SignalServiceReady", BindingFlags.NonPublic | BindingFlags.Instance);
        void ReadyTable() { for (int i = 0; i < total; i++) signal.Invoke(table, null); }
        void Wait() => Invoke("WaitServicesReady", table, TimeSpan.FromSeconds(3));
        var sentinel = new InvalidOperationException("original asynchronous service initialization failure");
        Exception observed = null;
        int callbacks = 0;
        if (scenario != "horizon-legacy")
        {
            Invoke("ObserveFailures", (Action<Exception>)(error =>
            {
                Interlocked.Increment(ref callbacks);
                observed = error;
                androidFailure?.Invoke(error);
                notified.Set();
            }));
        }

        if (scenario == "horizon-timeout")
        {
            var clock = Stopwatch.StartNew();
            Exception error = Capture(() => Invoke("WaitServicesReady", table, TimeSpan.FromMilliseconds(20)));
            check(error is TimeoutException, "unready actual ServiceTable produces a deadline failure");
            check(clock.Elapsed < TimeSpan.FromSeconds(2), "deadline is bounded");
            check(callbacks == 0, "a timed wait does not invent a service-thread exception");
            return false;
        }
        if (scenario is "horizon-cancel" or "horizon-ready-cancel")
        {
            if (scenario == "horizon-ready-cancel")
            {
                ReadyTable();
                Ryujinx.Common.S2AShutdown.Request();
                check(Capture(Wait) is OperationCanceledException, "shutdown wins even when readiness is signaled");
            }
            else
            {
                Task<Exception> waiting = Task.Run(() => Capture(Wait));
                check(!waiting.Wait(50), "unready checked startup is actually waiting");
                Ryujinx.Common.S2AShutdown.Request();
                check(waiting.Wait(1000), "shutdown wakes the pending actual waiter");
                check(waiting.Result is OperationCanceledException, "actual shutdown produces cancellation");
            }
            check(callbacks == 0, "ordinary stop is not a service failure");
            return false;
        }
        if (scenario == "horizon-before-ready")
        {
            Start(table, _ => reached.Set());
            Ryujinx.Common.S2AShutdown.Request();
            Invoke("Ready");
            check(!reached.Wait(100), "stop before dispatcher readiness never enters the service body");
            check(Capture(Wait) is OperationCanceledException, "canceled initial threads cannot publish ready");
            check(callbacks == 0, "canceled setup is not reported as a new failure");
            return false;
        }

        Invoke("Ready");
        if (scenario == "horizon-late")
        {
            ReadyTable();
            check(Capture(Wait) == null, "all actual readiness signals satisfy checked wait before late failure");
        }
        if (scenario == "horizon-legacy")
        {
            var legacyWait = Task.Run(table.WaitServicesReady);
            Start(table, _ => { reached.Set(); throw sentinel; });
            check(reached.Wait(3000), "legacy actual service body reached");
            check(!legacyWait.Wait(100), "legacy no-argument failure behavior stays unchanged");
            ReadyTable();
            check(legacyWait.Wait(3000), "legacy wait still completes from readiness");
            return false;
        }
        if (scenario == "horizon-two-failures")
        {
            using var entered = new CountdownEvent(2);
            using var completed = new CountdownEvent(2);
            using var release = new ManualResetEventSlim();
            Start(table, _ => { try { entered.Signal(); release.Wait(); throw sentinel; } finally { completed.Signal(); } });
            Start(table, _ => { try { entered.Signal(); release.Wait(); throw new ArgumentException("second racing failure"); } finally { completed.Signal(); } });
            check(entered.Wait(3000), "both actual service entries are running before either fails");
            release.Set();
            check(completed.Wait(3000), "both actual service bodies left the release barrier");
        }
        else
        {
            Start(table, _ => { reached.Set(); throw sentinel; });
            check(reached.Wait(3000), "actual service entry reached");
        }
        check(notified.Wait(3000), "original async failure reaches owner callback");
        if (scenario == "horizon-ready-failure") ReadyTable();
        Exception caught = Capture(Wait);
        check(ReferenceEquals(caught, observed), "wait rethrows the exact original asynchronous exception");
        check(caught.StackTrace.Contains("ServiceEntry.Start", StringComparison.Ordinal), "original service stack survives wait boundary");
        check(callbacks == 1, "one asynchronous failure owner notification");
        check(ReferenceEquals(Capture(Wait), observed), "later readiness/waits never erase the first failure");
        return true;
    }
}
