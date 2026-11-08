using NxGal;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using Ryujinx.Memory.Tracking;
using S2A.Services;
using S2Arm.Backends.Vulkan.Runtime;
using S2Arm.Backends.Vulkan.Wsi;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Switch = Ryujinx.HLE.Switch;

internal static unsafe class RuntimeChecks
{
    private const ulong Address = 0x10000, Source = 0x30000, Size = 0x1000;
    private static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static List<string> _events;
    private static int _workerId;
    private static int _checks;
    private static Action _admissionProbe;
    internal static void AdmissionProbe() => _admissionProbe?.Invoke();

    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new Exception(message);
    }
    private static void Set(object target, string field, object value) => target.GetType().GetField(field, Private).SetValue(target, value);
    private static void Call(AndroidVulkanRuntime runtime, string method, params object[] args)
    {
        try { typeof(AndroidVulkanRuntime).GetMethod(method, Private).Invoke(runtime, args); }
        catch (TargetInvocationException error) { throw error.InnerException; }
    }
    private static int Query(ulong address, MemInfo* info)
    {
        Check(Environment.CurrentManagedThreadId == _workerId, "VM query/flush ran off GPU owner.");
        _events.Add(address == Source ? "source" : "destination");
        *info = new MemInfo { Base = address, Size = Size, Perm = 3 };
        return 0;
    }
    public static void Run()
    {
        FailureObservationTests.Run();
        foreach (bool empty in new[] { false, true })
        foreach (bool stopping in new[] { false, true })
            Transaction(empty, stopping);
        Transaction(true, false, sleeping: true);
        Transaction(true, true, sleeping: true);
        if (Environment.GetEnvironmentVariable("S2A_TEST_ADMISSION_PROBE") == "1")
            Transaction(true, true, midPublication: true);
        RejectedAfterStop();
        SingleThreadTeardownOrder();
        PeriodicPipelineSaveThrottle();
        GpuStepWaitLifecycleBudget();
        Console.WriteLine($"PASS: {_checks} production Runtime backing handshake assertions; active GPU/native protection NOT RUN.");
    }

    // 10-27 #551：单线程收局顺序 —— 驱动管线缓存落盘必须先于停 WSI / 证明退休。真机原生兜底只有 1.5 s，
    //   9000 r8 18:02 局 GPU Run 退出 +0.670 s、Surface detached +1.029 s、1.509 s 被 _exit(124)，落盘排在 WSI 退休之后没赶上；
    //   通过局总共 1.405 s 只剩 95 ms。夹具锁住顺序：把落盘挪到 stop 之后（旧口径）必须红。
    private static void SingleThreadTeardownOrder()
    {
        foreach (int saveMs in new[] { 0, 300 })
        {
            var events = new List<string>();
            long clock = 0;
            bool retired = false;
            (bool saved, bool done) = AndroidVulkanRuntime.S2AFinishSingleThreaded(
                save: () => { events.Add("save"); clock += saveMs; return true; },
                complete: () => events.Add("complete"),
                stop: () => events.Add("stop"),
                retired: () => retired,
                poll: () => { events.Add("poll"); if (events.FindAll(e => e == "poll").Count >= 3) retired = true; },
                wait: () => clock += 100,
                deadlineMs: 1500,
                now: () => clock);
            int save = events.IndexOf("save"), stop = events.IndexOf("stop"), poll = events.IndexOf("poll");
            Check(saved && done && save >= 0 && stop > save && poll > stop,
                $"REGRESSION: pipeline cache save must precede WSI stop/retirement (save {saveMs} ms; events {string.Join(",", events)})");
        }

        // 落盘失败不能把收局停住：WSI 照停、退休照证明。
        {
            var events = new List<string>();
            long clock = 0;
            bool retired = false;
            (bool saved, bool done) = AndroidVulkanRuntime.S2AFinishSingleThreaded(
                save: () => { events.Add("save"); return false; },
                complete: () => events.Add("complete"),
                stop: () => events.Add("stop"),
                retired: () => retired,
                poll: () => { events.Add("poll"); retired = true; },
                wait: () => clock += 1,
                deadlineMs: 1500,
                now: () => clock);
            Check(!saved && done && events.Contains("stop") && events.Contains("poll"),
                $"a failed pipeline cache save must not stop WSI retirement (saved={saved} done={done} events={string.Join(",", events)})");
        }

        // 退休一直不成立：1500 ms 期限到就返回 false，不无限等（期限不放宽）。
        {
            long clock = 0;
            int polls = 0;
            (bool saved, bool done) = AndroidVulkanRuntime.S2AFinishSingleThreaded(
                save: () => true,
                complete: () => { },
                stop: () => { },
                retired: () => false,
                poll: () => polls++,
                wait: () => clock += 500,
                deadlineMs: 1500,
                now: () => clock);
            Check(saved && !done && polls == 3, $"WSI retirement deadline must stay 1500 ms (polls {polls}, done {done})");
        }
    }
    // 11-03 #1389：定期落盘节流 —— 首轮只记起点，60 s 内不重复，跨周期才写；失败不影响主循环，下周期重试。
    private static void PeriodicPipelineSaveThrottle()
    {
        var runtime = new AndroidVulkanRuntime(1, 1, error => throw error);
        long clock = 1_000_000;
        int calls = 0;
        bool fail = false;
        FieldInfo clockField = typeof(AndroidVulkanRuntime).GetField("PeriodicPipelineSaveClock", Private);
        FieldInfo saveField = typeof(AndroidVulkanRuntime).GetField("PeriodicPipelineSave", Private);
        MethodInfo periodic = typeof(AndroidVulkanRuntime).GetMethod("S2APeriodicPipelineSave", Private);
        Check(clockField != null && saveField != null && periodic != null, "periodic pipeline cache save fixture is wired");
        clockField.SetValue(runtime, (Func<long>)(() => clock));
        saveField.SetValue(runtime, (Func<Task<bool>>)(() => { calls++; return Task.FromResult(!fail); }));

        periodic.Invoke(runtime, null);
        Check(calls == 0, "periodic pipeline cache save starts its interval after session start");
        clock += 59_999;
        periodic.Invoke(runtime, null);
        Check(calls == 0, "periodic pipeline cache save does not fire inside 60 s");
        clock += 1;
        periodic.Invoke(runtime, null);
        Check(calls == 1, "periodic pipeline cache save fires at 60 s");
        clock += 59_999;
        periodic.Invoke(runtime, null);
        Check(calls == 1, "periodic pipeline cache save is throttled to one per interval");
        clock += 1;
        fail = true;
        periodic.Invoke(runtime, null);
        Check(calls == 2, "periodic pipeline cache save invokes the save on schedule even when it fails");
        fail = false;
        clock += 60_000;
        periodic.Invoke(runtime, null);
        Check(calls == 3, "periodic pipeline cache save retries at the next interval after a failed save");

        var throwing = new AndroidVulkanRuntime(1, 1, error => throw error);
        int threw = 0;
        clockField.SetValue(throwing, (Func<long>)(() => clock));
        saveField.SetValue(throwing, (Func<Task<bool>>)(() => { threw++; throw new InvalidOperationException("fixture"); }));
        typeof(AndroidVulkanRuntime).GetField("_s2aPeriodicPipelineSaveAt", Private).SetValue(throwing, clock - 60_000);
        bool escaped = false;
        try { periodic.Invoke(throwing, null); }
        catch { escaped = true; }
        Check(!escaped && threw == 1, "a periodic pipeline cache save failure never escapes the render loop");
    }
    // P1-52/P1-72：单线程换页等待的 3 s 预算必须用外壳生命周期钟，不是墙钟——Android 后台会把
    // 整个进程冻结，墙钟期限在恢复后才到期，把健康会话判死。预算只累计同一前台代元上的毫秒；
    // 后台（-1）或代元翻转即清零重计。等待期间代元必须逐次现读，不能只在进等待时取一次前台标志。
    private static void GpuStepWaitLifecycleBudget()
    {
        var runtime = new AndroidVulkanRuntime(1, 1, error => throw error);
        var ctorLifecycle = (Func<long>)typeof(AndroidVulkanRuntime).GetField("_lifecycle", Private).GetValue(runtime);
        Set(runtime, "_lifecycle", (Func<long>)AndroidVulkanSurface.Lifecycle);
        using var done = new ManualResetEventSlim();
        AndroidVulkanSurface.SetProducerForeground(true);
        Exception error = null;
        var wait = new Thread(() =>
        {
            try { Call(runtime, "WaitForGpuStep", done, "GPU step did not complete within three foreground seconds.", null, 1); }
            catch (Exception e) { error = e; }
        }) { IsBackground = true };
        try
        {
            wait.Start();
            Thread.Sleep(600);
            AndroidVulkanSurface.SetProducerForeground(false);
            Thread.Sleep(3400); // 全程后台 3.4 s：预算不得点火（冻结 32 s 亦然，这里取可接受时长）
            Check(error == null && wait.IsAlive, "background/freeze expired the single-thread GPU step budget");
            AndroidVulkanSurface.SetProducerForeground(true);
            Thread.Sleep(2700); // 新前台代元上预算须重新计满，不得继承进入等待前/冻结前已花的 600 ms
            Check(wait.IsAlive, "resumed lifecycle epoch must restart the budget, not inherit spent time");
            Check(wait.Join(2500), "foreground budget did not expire after resume");
            Check(error is TimeoutException, $"budget expiry must be TimeoutException, got {error?.GetType().Name ?? "none"}: {error?.Message}");
        }
        finally { AndroidVulkanSurface.SetProducerForeground(true); done.Set(); wait.Join(2000); }
        // 取图预算共用同一生命周期钟：宿主必须把 _lifecycle 交给 WSI surface（同一实例）。
        Check(AndroidVulkanSurface.SuppliedLifecycle != null, "runtime did not hand its lifecycle clock to the WSI surface");
        Check(ReferenceEquals(AndroidVulkanSurface.SuppliedLifecycle, ctorLifecycle),
            "surface lifecycle clock is not the runtime clock");
    }

    private static void Transaction(bool empty, bool stopping, bool sleeping = false, bool midPublication = false)
    {
        _events = new();
        var renderer = new NullRenderer(default);
        var context = new GpuContext(renderer, null);
        var fifo = context.GPFifo;
        var channel = context.CreateChannel();
        if (!empty)
            for (int i = 0; i < 64; i++) channel.PushHostCommandBuffer(Program.Barrier);
        var device = (Switch)RuntimeHelpers.GetUninitializedObject(typeof(Switch));
        Set(device, "<Gpu>k__BackingField", context);
        var runtime = new AndroidVulkanRuntime(1, 1, error => throw error, lifecycle: AndroidVulkanSurface.Lifecycle);
        var memory = new GuestMemory();
        using RegionHandle handle = memory.Tracking.BeginTracking(Address, Size, 1);
        handle.Reprotect();
        Set(runtime, "_device", device); Set(runtime, "_tracking", memory.Tracking); Set(runtime, "_renderer", renderer);
        context.HostInitalized.Set();
        GraphicsConfig.EnableMacroJit = false; GraphicsConfig.EnableSpirvCompilationOnVulkan = true;
        Native.MemQuery = &Query;
        var consume = (Action)typeof(AndroidVulkanRuntime).GetMethod("ProcessBackingChange", Private).CreateDelegate(typeof(Action), runtime);
        GPFifoDevice.S2ATrackSync = (Action)typeof(AndroidVulkanRuntime).GetMethod("DrainAndPoll", Private).CreateDelegate(typeof(Action), runtime);
        typeof(GPFifoDevice).GetProperty("S2AControlPoll")?.SetValue(fifo, consume);
        using var admissionChecked = new ManualResetEventSlim();
        using var releaseAdmission = new ManualResetEventSlim();
        if (midPublication)
            _admissionProbe = () =>
            {
                admissionChecked.Set();
                Check(releaseAdmission.Wait(2000), "Fixture admission publication not released.");
            };
        using var entryActive = new ManualResetEventSlim();
        using var releaseEntry = new ManualResetEventSlim();
        using var prepared = new ManualResetEventSlim();
        using var replaced = new ManualResetEventSlim();
        using var cpuDone = new ManualResetEventSlim();
        Exception cpuError = null, gpuError = null, stopError = null;
        Thread stopper = null;
        int commands = 0;
        NxTrack.OnDrain = () => { Check(Environment.CurrentManagedThreadId == _workerId, "Drain ran on CPU."); _events.Add("drain"); };
        AndroidVulkanSurface.OnFence = () => { Check(Environment.CurrentManagedThreadId == _workerId, "Fence ran on CPU."); _events.Add("fence"); };
        ((NullPipeline)renderer.Pipeline).OnCommandBarrier = () =>
        {
            int index = ++commands;
            if (index == 1)
            {
                entryActive.Set();
                if (!releaseEntry.Wait(2000)) throw new Exception("Fixture entry not released.");
            }
            else Check(replaced.IsSet && !handle.Unmapped && handle.Dirty, "Next entry ran before native completion/remap.");
        };
        var cpu = new Thread(() =>
        {
            try
            {
                Call(runtime, "BeginBackingChange", Address, Size, Source);
                Check(handle.Unmapped, "Prepared must unmap old tracking before CPU replacement.");
                Check(empty || commands == 1, "GPU advanced while native replacement was pending.");
                prepared.Set();
                if (!replaced.Wait(2000)) throw new Exception("Fixture replacement not released.");
                Call(runtime, "EndBackingChange", Address, Size, 1);
                Check(!handle.Unmapped && handle.Dirty, "Finished must publish new dirty backing.");
                if (!stopping)
                {
                    Call(runtime, "BeginBackingChange", Address, Size, 0UL);
                    Check(handle.Unmapped, "A new transaction after Finished did not prepare.");
                    Call(runtime, "EndBackingChange", Address, Size, 1);
                    Check(!handle.Unmapped && handle.Dirty, "The second completion was lost.");
                }
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
            finally { cpuDone.Set(); }
        });
        var gpu = new Thread(() =>
        {
            try
            {
                _workerId = Environment.CurrentManagedThreadId;
                Call(runtime, "Run");
            }
            catch (Exception error) { gpuError = error; Console.Error.WriteLine("[control] GPU thread failed: " + error); }
        });
        int polls = 0;
        AndroidVulkanSurface.OnPoll = () =>
        {
            if (empty && ++polls == 2)
            {
                entryActive.Set();
                if (!sleeping && !releaseEntry.Wait(2000)) throw new Exception("Fixture empty-loop wake not released.");
            }
        };
        Set(runtime, "_worker", gpu);
        gpu.Start();
        Check(entryActive.Wait(2000), "GPU boundary not reached.");
        if (sleeping)
            Check(SpinWait.SpinUntil(() => (gpu.ThreadState & ThreadState.WaitSleepJoin) != 0, 1000),
                "Empty production loop did not enter its FIFO event wait.");
        cpu.Start();
        if (midPublication)
        {
            Check(admissionChecked.Wait(2000), "Begin did not reach its accepted/pre-publication boundary.");
            stopper = new Thread(() => { try { runtime.Stop(); } catch (Exception error) { stopError = error; } });
            stopper.Start();
            var cancellation = (CancellationTokenSource)typeof(AndroidVulkanRuntime).GetField("_cancel", Private).GetValue(runtime);
            Check(SpinWait.SpinUntil(() => cancellation.IsCancellationRequested, 1000), "Stop did not cancel while admission held the gate.");
            releaseEntry.Set();
            try
            {
                var done = (ManualResetEventSlim)typeof(AndroidVulkanRuntime).GetField("_done", Private).GetValue(runtime);
                Check(!done.Wait(100), "REGRESSION: GPU retired after Begin accepted but before its request was published/signalled.");
            }
            finally { releaseAdmission.Set(); }
        }
        else
        {
            // Observe production request publication; no sleeps manufacture the command order.
            Check(SpinWait.SpinUntil(() => typeof(AndroidVulkanRuntime).GetField("_backingChange", Private).GetValue(runtime) != null, 1000), "CPU did not publish backing request.");
            if (stopping)
            {
                stopper = new Thread(() => { try { runtime.Stop(); } catch (Exception error) { stopError = error; } });
                stopper.Start();
                var cancellation = (CancellationTokenSource)typeof(AndroidVulkanRuntime).GetField("_cancel", Private).GetValue(runtime);
                Check(SpinWait.SpinUntil(() => cancellation.IsCancellationRequested, 1000), "Concurrent Stop did not cancel.");
            }
            releaseEntry.Set();
        }
        Check(prepared.Wait(2000), "Accepted request was not prepared at the next boundary.");
        Check(cpuError == null, "CPU preparation failed: " + cpuError);
        Check(empty || commands == 1, "GPU did not remain paused during native replacement.");
        replaced.Set();
        Check(cpu.Join(2000), "Native completion did not finish.");
        if (stopper == null) runtime.Stop(); // One native shutdown owner, no duplicate disposal request.
        Check(gpu.Join(2000), "Production GPU loop did not finish.");
        if (cpuError != null) throw cpuError;
        if (gpuError != null) throw gpuError;
        if (stopper != null)
        {
            Check(stopper.Join(2000), "Concurrent Stop did not finish.");
            if (stopError != null) throw stopError;
        }
        Check(empty || commands == 64, "Queued commands were dropped.");
        int source = _events.IndexOf("source"), destination = _events.IndexOf("destination");
        Check(source >= 0 && destination > source, "Old alias source must be flushed before destination.");
        Check(_events.GetRange(0, source).Contains("fence") && _events.GetRange(destination + 1, _events.Count - destination - 1).Contains("fence"), "Preparation must retain fences before/after old backing flush.");
        Check(typeof(AndroidVulkanRuntime).GetField("_backingChange", Private).GetValue(runtime) == null, "Finished left an active mutation.");
        _admissionProbe = null;
        Native.MemQuery = null; NxTrack.OnDrain = null; AndroidVulkanSurface.OnFence = null; AndroidVulkanSurface.OnPoll = null;
    }
    private static void RejectedAfterStop()
    {
        var runtime = new AndroidVulkanRuntime(1, 1, _ => { });
        runtime.Stop();
        bool rejected = false;
        try { Call(runtime, "BeginBackingChange", Address, Size, 0UL); }
        catch (InvalidOperationException) { rejected = true; }
        Check(rejected, "A new backing transaction was accepted after Stop.");
    }
}
