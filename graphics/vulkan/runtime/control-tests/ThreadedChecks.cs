// 拆线程（S2A_ANDROID_THREADED_RENDERER=1）的受控反证：真实 ThreadedRenderer（套空渲染器）、真实 GpuContext / GPFIFO / MemoryTracking、
// 真实 RunThreaded / RenderMain / 换页事务 / Stop，生产上限（ConfigureThreadedBounds）。只替换 surface、native tracker 与 MemQuery；
// 没有 Vulkan 设备、Android 租约、页保护或游戏，所以通过不代表真机无死锁，只证明下面这些线程分工、上限与顺序在生产代码里成立。
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using Ryujinx.Memory.Tracking;
using S2A.Services;
using S2Arm.Backends.Vulkan.Runtime;
using System.Threading.Tasks;
using System.IO;
using System.IO.MemoryMappedFiles;
using S2Arm.Backends.Vulkan.Wsi;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using Switch = Ryujinx.HLE.Switch;

internal static unsafe class ThreadedChecks
{
    private const ulong Address = 0x10000, Source = 0x30000, Size = 0x1000;
    private const string RenderName = "S2A.GPU.Vk";
    private const string SwitchVariable = "S2A_ANDROID_THREADED_RENDERER";
    private static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly BindingFlags PrivateStatic = BindingFlags.Static | BindingFlags.NonPublic;
    private static readonly object Gate = new();
    private static int _checks;
    private static Thread _sim;
    private static List<string> _events, _violations;

    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new Exception("FAIL threaded: " + message);
    }

    private static void Set(object target, string field, object value) => target.GetType().GetField(field, Private).SetValue(target, value);
    private static T Get<T>(object target, string field) => (T)target.GetType().GetField(field, Private).GetValue(target);
    private static T Const<T>(Type type, string name) => (T)type.GetField(name, PrivateStatic | BindingFlags.Public).GetRawConstantValue();

    private static void Call(AndroidVulkanRuntime runtime, string method, params object[] args)
    {
        try
        {
            MethodInfo target = typeof(AndroidVulkanRuntime).GetMethod(method, Private);
            ParameterInfo[] parameters = target.GetParameters();
            object[] values = new object[parameters.Length];
            for (int i = 0; i < values.Length; ++i) values[i] = i < args.Length ? args[i] : parameters[i].DefaultValue;
            target.Invoke(runtime, values);
        }
        catch (TargetInvocationException error) { throw error.InnerException; }
    }

    private static bool OnRender => Thread.CurrentThread.Name == RenderName;
    private static bool OnSim => Thread.CurrentThread == _sim;

    private static void Note(string value) { lock (Gate) _events.Add(value); }
    private static void Violation(string value) { lock (Gate) _violations.Add(value); }
    private static int Count(string value) { lock (Gate) return _events.FindAll(e => e == value).Count; }
    private static double Ms(long since) => (Stopwatch.GetTimestamp() - since) * 1000.0 / Stopwatch.Frequency;

    private static int Query(ulong address, MemInfo* info)
    {
        if (!OnSim) Violation("VM query/flush ran off the GPU emulation thread");
        Note(address == Source ? "source" : "destination");
        *info = new MemInfo { Base = address, Size = Size, Perm = 3 };
        return 0;
    }

    private sealed class Session
    {
        public AndroidVulkanRuntime Runtime;
        public ThreadedRenderer Threaded;
        public GpuContext Context;
        public GpuChannel Channel;
        public RegionHandle Handle;
        public Thread Render;
        public ITexture Texture;
        public int HostThreaded, BackingProgress;
        public ulong BackingOwner, BackingGeneration;
        public nint Authority;
        public readonly object BackingLock = new();
        public Exception Fatal;
        public Action<int> Barrier;
        public int Barriers;
    }

    // S2A_THREADED_CHECK=<用例名>：只跑这一个（负控定位用）；缺省全跑。
    public static void Run()
    {
        (string Name, Action Body)[] cases =
        [
            (nameof(ThreadedSwitch), ThreadedSwitch),
            (nameof(AutoPolicy), AutoPolicy),
            (nameof(AutoRuntimeWiring), AutoRuntimeWiring),
            (nameof(AutoRequestedRate), AutoRequestedRate),
            (nameof(Backing), Backing),
            (nameof(BackingUnderBackpressure), BackingUnderBackpressure),
            (nameof(QueueBackpressure), QueueBackpressure),
            (nameof(PayloadBackpressure), PayloadBackpressure),
            (nameof(Presents), Presents),
            (nameof(BackgroundActionOnEmulationThread), BackgroundActionOnEmulationThread),
            (nameof(SyncWakeLatency), SyncWakeLatency),
            (nameof(StallDuringBacking), StallDuringBacking),
            (nameof(SlowDrainBacking), SlowDrainBacking),
            (nameof(BackingWithoutSource), BackingWithoutSource),
            (nameof(BackingNativeLifecycle), BackingNativeLifecycle),
            (nameof(BackingPublicationHandoff), BackingPublicationHandoff),
            (nameof(BackingPublicationModel), BackingPublicationModel),
            (nameof(PublicationClockOrigin), PublicationClockOrigin),
            (nameof(PublicationFailureBoundary), PublicationFailureBoundary),
            (nameof(PublicationLifecycleSnapshot), PublicationLifecycleSnapshot),
            (nameof(DelayedResumeObservation), DelayedResumeObservation),
            (nameof(BackingDecisionWiring), BackingDecisionWiring),
            (nameof(PresentThrottleStall), PresentThrottleStall),
            (nameof(CounterWaitTick), CounterWaitTick),
            (nameof(NonGpuWaitsBounded), NonGpuWaitsBounded),
            (nameof(BackgroundPausesWatchdog), BackgroundPausesWatchdog),
            (nameof(ThawAfterLongCommand), ThawAfterLongCommand),
            (nameof(LeaseStoppingOrder), LeaseStoppingOrder),
            (nameof(SlowDisposeShutdown), SlowDisposeShutdown),
            (nameof(ExitFastTeardown), ExitFastTeardown),
            (nameof(HostShutdownSequence), HostShutdownSequence),
            (nameof(ShutdownRequestNonBlocking), ShutdownRequestNonBlocking),
            (nameof(PipelineSaveOrder), PipelineSaveOrder),
            (nameof(PipelineSaveAwait), PipelineSaveAwait),
            (nameof(RenderFailure), RenderFailure),
        ];
        string only = Environment.GetEnvironmentVariable("S2A_THREADED_CHECK");
        if (only != null && Array.FindIndex(cases, c => c.Name == only) < 0) throw new Exception("FAIL threaded: unknown S2A_THREADED_CHECK " + only);
        foreach ((string name, Action body) in cases)
            if (only == null || only == name) body();
        Console.WriteLine($"PASS: {_checks} threaded-renderer assertions (real ThreadedRenderer + RunThreaded/RenderMain over NullRenderer, production bounds{(only == null ? "" : ", only " + only)}); Vulkan/Android/GPU NOT RUN.");
    }

    private static ulong Publish(Session session, ulong owner, int advance)
    {
        lock (session.BackingLock)
        {
            ulong result = BackingAuthority.test_publish(session.Authority, owner, advance);
            if (result != 0) {
                session.BackingOwner = advance != 0 ? result : 0;
                session.BackingGeneration = result;
                session.BackingProgress++;
            }
            return result;
        }
    }

    private static Session Open(int maxQueued = 0, long maxPayload = 0)
    {
        _events = new();
        _violations = new();
        AndroidVulkanSurface.ForegroundValue = true;
        AndroidVulkanSurface.SetProducerForeground(true);
        AndroidVulkanSurface.StoppingValue = false;
        AndroidVulkanSurface.Presents = 0;
        var session = new Session { Authority = BackingAuthority.test_create() };
        Check(session.Authority != 0, "native test lease created");
        AndroidVulkanSurface.OnProducerForeground = fg => BackingAuthority.test_lifecycle(session.Authority, fg ? 1 : 0);
        var baseRenderer = new NullRenderer(default);
        session.Runtime = new AndroidVulkanRuntime(1, 1, error => session.Fatal ??= error, lifecycle: AndroidVulkanSurface.Lifecycle);
        // 生产接线：CreateRenderer 的拆线程分支同一个 ComposeThreaded（套层、上限与判据、收局请求登记、等待泵）；这里下层是空渲染器
        Set(session.Runtime, "_renderer", baseRenderer);
        AndroidVulkanSurface.WaitPump = null;
        Set(session.Runtime, "HostThreaded", (Action<int>)(on => session.HostThreaded = on));
        Set(session.Runtime, "BackingProgress", (Func<ulong, int, ulong>)((owner, idle) => Publish(session, owner, idle)));
        Set(session.Runtime, "BackingDecision", (Func<ulong, int>)(owner => BackingAuthority.test_decision(session.Authority, owner)));
        Call(session.Runtime, "ComposeThreaded");
        Check(session.HostThreaded == 1, "ComposeThreaded must tell the native host the threaded renderer is on");
        session.Threaded = Get<ThreadedRenderer>(session.Runtime, "_threaded");
        Check(ReferenceEquals(Get<IRenderer>(session.Runtime, "_renderer"), session.Threaded) && session.Threaded.BaseRenderer == baseRenderer,
            "ComposeThreaded must hand HLE the threaded wrapper over the same backend");
        Check(AndroidVulkanSurface.WaitPump?.Method.Name == "RenderWaitPump", "ComposeThreaded must install the render-thread wait pump");
        session.Threaded.S2ACollectStats = true;
        if (maxQueued != 0 || maxPayload != 0)
        {
            var fail = (Action<Exception>)typeof(AndroidVulkanRuntime).GetMethod("Fail", Private).CreateDelegate(typeof(Action<Exception>), session.Runtime);
            session.Threaded.S2AConfigureBounds(maxQueued != 0 ? maxQueued : ThreadedRenderer.S2AQueueCapacity,
                maxPayload != 0 ? maxPayload : Const<long>(typeof(AndroidVulkanRuntime), "ThreadedPayloadBytes"),
                Const<int>(typeof(AndroidVulkanRuntime), "RenderStallMilliseconds"),
                Const<int>(typeof(AndroidVulkanRuntime), "RenderStallGraceMilliseconds"),
                AndroidVulkanSurface.Lifecycle, fail);
        }
        session.Context = new GpuContext(session.Threaded, null);
        session.Channel = session.Context.CreateChannel();
        var device = (Switch)RuntimeHelpers.GetUninitializedObject(typeof(Switch));
        Set(device, "<Gpu>k__BackingField", session.Context);
        var memory = new GuestMemory();
        session.Handle = memory.Tracking.BeginTracking(Address, Size, 1);
        session.Handle.Reprotect();
        Set(session.Runtime, "_device", device);
        Set(session.Runtime, "_tracking", memory.Tracking);
        session.Context.HostInitalized.Set();
        GraphicsConfig.EnableMacroJit = false;
        GraphicsConfig.EnableSpirvCompilationOnVulkan = true;
        Native.MemQuery = &Query;
        var consume = (Action)typeof(AndroidVulkanRuntime).GetMethod("ProcessBackingChange", Private).CreateDelegate(typeof(Action), session.Runtime);
        typeof(GPFifoDevice).GetProperty("S2AControlPoll").SetValue(session.Context.GPFifo, consume);
        GPFifoDevice.S2ATrackSync = (Action)typeof(AndroidVulkanRuntime).GetMethod("DrainThreaded", Private).CreateDelegate(typeof(Action), session.Runtime);
        NxTrack.OnDrain = () => { if (!OnSim) Violation("write-tracking drain ran off the GPU emulation thread"); };
        AndroidVulkanSurface.OnFence = () => { if (!OnRender) Violation("queue marker ran off the render thread"); Note("fence"); };
        AndroidVulkanSurface.OnPoll = () => { if (!OnRender) Violation("WSI poll ran off the render thread"); };
        AndroidVulkanSurface.OnStop = () => { if (!OnRender) Violation("WSI stop ran off the render thread"); Note("wsi-stop"); };
        NullRenderer.OnDispose = () => { if (!OnRender) Violation("backend dispose ran off the render thread"); Note("dispose"); };
        ((NullPipeline)baseRenderer.Pipeline).OnCommandBarrier = () =>
        {
            if (!OnRender) Violation("a GAL command executed off the render thread");
            int index = Interlocked.Increment(ref session.Barriers);
            Note("barrier");
            session.Barrier?.Invoke(index);
        };
        _sim = new Thread(() => Call(session.Runtime, "RunThreaded")) { Name = "S2A.GPU", IsBackground = true };
        Set(session.Runtime, "_worker", _sim);
        _sim.Start();
        Check(Get<ManualResetEventSlim>(session.Runtime, "_ready").Wait(5000), "two-thread startup did not become ready");
        Check(session.Fatal == null, "startup failed: " + session.Fatal);
        session.Render = Get<Thread>(session.Runtime, "_render");
        Check(session.Render != null && session.Render.Name == RenderName && session.Render.IsAlive, "render thread S2A.GPU.Vk is not running");
        return session;
    }

    private static void Push(Session session, int entries)
    {
        for (int i = 0; i < entries; i++) session.Channel.PushHostCommandBuffer(Program.Barrier);
        session.Context.GPFifo.SignalNewEntries();
    }

    private static int Queued(Session session) => Get<int>(session.Threaded, "_commandCount");

    private static void Close(Session session)
    {
        session.Handle.Dispose();
        Native.MemQuery = null;
        NxTrack.OnDrain = null;
        AndroidVulkanSurface.OnFence = null;
        AndroidVulkanSurface.OnPoll = null;
        AndroidVulkanSurface.OnStop = null;
        AndroidVulkanSurface.ForegroundValue = true;
        AndroidVulkanSurface.SetProducerForeground(true);
        AndroidVulkanSurface.StoppingValue = false;
        AndroidVulkanSurface.OnProducerForeground = null;
        BackingAuthority.test_destroy(session.Authority);
        NullRenderer.OnDispose = null;
        NullRenderer.OnSetBufferData = null;
        GPFifoDevice.S2ATrackSync = null;
    }

    private static void NoViolations()
    {
        lock (Gate) Check(_violations.Count == 0, "thread-ownership violations: " + string.Join("; ", _violations));
    }

    // 关 = 单线程基线：未设 / 0 不套 ThreadedRenderer，1 套，auto 按本游戏上局记录（要状态目录），其他值抛错（不按关处理）；
    // 生产上限之间的关系（判据有余量）。
    private static bool Requested(AndroidVulkanRuntime runtime)
    {
        try { return (bool)typeof(AndroidVulkanRuntime).GetMethod("ThreadedRequested", Private).Invoke(runtime, null); }
        catch (TargetInvocationException error) { throw error.InnerException; }
    }

    private static string TempDirectory()
    {
        string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "s2a-threaded-auto-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(path);
        return path;
    }

    private static void ThreadedSwitch()
    {
        string saved = Environment.GetEnvironmentVariable(SwitchVariable);
        string state = TempDirectory();
        try
        {
            Environment.SetEnvironmentVariable(SwitchVariable, null);
            Check(!Requested(new AndroidVulkanRuntime(1, 1, _ => { })), "an unset switch must keep the single-thread baseline");
            Environment.SetEnvironmentVariable(SwitchVariable, "0");
            Check(!Requested(new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: state)), "0 must keep the single-thread baseline");
            Environment.SetEnvironmentVariable(SwitchVariable, "1");
            Check(Requested(new AndroidVulkanRuntime(1, 1, _ => { })), "1 must select the threaded renderer");
            var explicitRuntime = new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: state);
            Requested(explicitRuntime);
            Check(Get<ThreadedAuto>(explicitRuntime, "_auto") == null, "an explicit 0/1 must not read or write the auto record");
            Check(!explicitRuntime.WantsFrameInterval, "REGRESSION: an explicit 0/1 must not ask for the frame-interval hook (baseline wiring)");
            Environment.SetEnvironmentVariable(SwitchVariable, "auto");
            bool noState = false;
            try { Requested(new AndroidVulkanRuntime(1, 1, _ => { })); }
            catch (InvalidOperationException) { noState = true; }
            Check(noState, "auto without a state directory must be rejected, not treated as off");
            var auto = new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: state);
            Check(!Requested(auto) && Get<ThreadedAuto>(auto, "_auto") is { Threaded: false }, "auto without a record must start single-threaded and measure");
            Check(auto.WantsFrameInterval, "auto needs the requested frame interval");
            bool rejected = false;
            Environment.SetEnvironmentVariable(SwitchVariable, "true");
            try { Requested(new AndroidVulkanRuntime(1, 1, _ => { })); }
            catch (InvalidOperationException) { rejected = true; }
            Check(rejected, "an unrecognised switch value must be rejected, not treated as off");
        }
        finally
        {
            Environment.SetEnvironmentVariable(SwitchVariable, saved);
            System.IO.Directory.Delete(state, true);
        }

        int stall = Const<int>(typeof(AndroidVulkanRuntime), "RenderStallMilliseconds");
        int grace = Const<int>(typeof(AndroidVulkanRuntime), "RenderStallGraceMilliseconds");
        int slice = Const<int>(typeof(ThreadedRenderer), "S2AWaitSliceMs");
        // 渲染线程上有期限但不泵的单步：换页 marker 的 fence（1000 ms）与 acquire（1000 ms）；换页回调前台预算 3000 ms。
        Check(stall > 1000, "the stall limit must exceed the bounded non-pumping render-thread steps (1000 ms)");
        Check(stall + grace + slice <= 2500, "a stall must be diagnosed with at least 500 ms left of the 3 s backing budget");
        Check(ThreadedRenderer.S2AQueueCapacity == 9999, "queue capacity changed; re-derive the documented bound");
        Console.WriteLine($"PASS: threaded switch — unset/0 keep the single-thread baseline, 1 selects ThreadedRenderer, auto needs a state directory and starts single without a record, other values rejected; stall {stall}+{grace}+{slice} ms < 3000 ms budget.");
    }

    private static ThreadedAuto.Record Feed(ThreadedAuto auto, int windows, double busy, double hz, double requestedHz)
    {
        ThreadedAuto.Record last = null;
        for (int i = 0; i < windows; i++) last = auto.Window(busy, hz, requestedHz) ?? last;
        Check(auto.WaitWritten(3000), "auto record writes did not drain");
        return last;
    }

    private static string RecordPath(string state) => System.IO.Path.Combine(state, ThreadedAuto.FileName);

    private static ThreadedAuto.Record OnDisk(string state) => ThreadedAuto.Record.Parse(System.IO.File.ReadAllText(RecordPath(state)));

    private static void WriteRecord(string state, ThreadedAuto.Record record) => System.IO.File.WriteAllText(RecordPath(state), record.Format());

    private static ThreadedAuto.Record ThreadedRecord(double singleHz, int noGain = 0) =>
        new("threaded", noGain, 0, singleHz, 0.98, 0, 60, "fixture");

    // auto 判据（下局生效，评估覆盖整局）：
    // - 9000 真机形：前 70 s 标题 / 菜单（忙 0.83、44.1 Hz）不饱和，之后持续饱和（忙 0.98、37.7 Hz）→ 必须记拆线程；
    //   菜单 200 s 先记单线程，之后出现饱和段改写为拆线程；全程菜单的短局（100 s）不写记录。
    // - 拆线程一局只比饱和段：前面菜单窗不拉偏；有收益保持；第 1 次没收益只记单线程下局重测，连续 2 次才固定；固定 10 局后自动重新评估。
    // - 8E 形（忙 0.63、59.6 Hz）180 s 后记单线程，不到 180 s 不写；30 帧游戏跑满 30 帧不切；请求不限只看忙。
    // - 只有卡住判定固定；收局开始后不评估不固定；记录数值 / 长度 / 版本校验。
    private static void AutoPolicy()
    {
        var directories = new List<string>();
        string Dir() { string d = TempDirectory(); directories.Add(d); return d; }
        try
        {
            string g710 = Dir();
            ThreadedAuto first = ThreadedAuto.Load(g710);
            Check(!first.Threaded && first.Basis.Contains("无记录"), "the first auto launch must run the single-thread baseline");
            Check(Feed(first, 14, 0.83, 44.1, 60) == null && !System.IO.File.Exists(RecordPath(g710)),
                "REGRESSION: 70 s of title/menu windows must not settle a verdict");
            Check(first.Window(0.99, 2, 60) == null, "a loading window decides nothing");
            Check(Feed(first, 5, 0.98, 37.7, 60) == null, "five saturated windows are not a segment");
            Check(first.Window(0.99, 2, 60) == null && Feed(first, 5, 0.98, 37.7, 60) == null, "REGRESSION: a loading window must break the saturated streak");
            ThreadedAuto.Record verdict = Feed(first, 1, 0.98, 37.7, 60);
            Check(verdict is { Verdict: "threaded", NoGain: 0, Pinned: false } && Math.Abs(verdict.SingleHz - 37.7) < 0.01,
                "REGRESSION: menu-then-saturated (9000 shape) must record threaded: " + verdict);
            Check(OnDisk(g710) == verdict && Feed(first, 6, 0.98, 37.7, 60) == null, "the threaded verdict must be written once per session");

            string longMenu = Dir();
            ThreadedAuto menu = ThreadedAuto.Load(longMenu);
            ThreadedAuto.Record settled = Feed(menu, 40, 0.83, 44.1, 60);
            Check(settled is { Verdict: "single" } && OnDisk(longMenu).Verdict == "single", "180 s without a saturated segment must record single");
            Check(Feed(menu, 6, 0.98, 37.7, 60) is { Verdict: "threaded" } && OnDisk(longMenu).Verdict == "threaded",
                "a saturated segment after the single verdict must still switch the record to threaded");

            string shortMenu = Dir();
            Check(Feed(ThreadedAuto.Load(shortMenu), 20, 0.83, 44.1, 60) == null && !System.IO.File.Exists(RecordPath(shortMenu)),
                "REGRESSION: a short menu-only session must not write a record");

            string keep = Dir();
            WriteRecord(keep, ThreadedRecord(37.7));
            ThreadedAuto threaded = ThreadedAuto.Load(keep);
            Check(threaded.Threaded && Feed(threaded, 14, 0.5, 60, 60) == null, "menu windows in a threaded session decide nothing");
            ThreadedAuto.Record kept = Feed(threaded, 6, 0.9, 52.1, 60);
            Check(kept is { Verdict: "threaded", NoGain: 0 } && Math.Abs(kept.ThreadedHz - 52.1) < 0.01,
                "a threaded saturated segment faster than 1.05x the single segment must keep threaded (menus must not bias it): " + kept);

            string noGain = Dir();
            WriteRecord(noGain, ThreadedRecord(37.7));
            ThreadedAuto.Record miss = Feed(ThreadedAuto.Load(noGain), 6, 0.9, 38, 60);
            Check(miss is { Verdict: "single", NoGain: 1, Pinned: false }, "REGRESSION: one session without gain must not pin single: " + miss);
            ThreadedAuto retry = ThreadedAuto.Load(noGain);
            Check(!retry.Threaded && Feed(retry, 6, 0.98, 37.7, 60) is { Verdict: "threaded", NoGain: 1 }, "after one miss the next single session re-measures");
            ThreadedAuto.Record pin = Feed(ThreadedAuto.Load(noGain), 6, 0.9, 38, 60);
            Check(pin is { Verdict: "single", Pinned: true, PinnedLeft: ThreadedAuto.PinSessions }, "two consecutive sessions without gain must pin single: " + pin);
            for (int session = 0; session < ThreadedAuto.PinSessions; session++)
            {
                ThreadedAuto pinned = ThreadedAuto.Load(noGain);
                Check(!pinned.Threaded && pinned.Basis.Contains("固定") && Feed(pinned, 40, 0.98, 37.7, 60) == null, "a pinned record must not be evaluated");
                Check(OnDisk(noGain).PinnedLeft == ThreadedAuto.PinSessions - session - 1, "each pinned session must use up one session");
            }
            Check(Feed(ThreadedAuto.Load(noGain), 6, 0.98, 37.7, 60) is { Verdict: "threaded" }, "an expired pin must be re-evaluated");

            // 复审第 2 轮 P1-B：拆线程后瓶颈移到渲染线程 / GPU，模拟线程不忙（0.6）但呈现仍 ≈ 单线程值，必须记一次没收益，不能「保持」
            string shifted = Dir();
            WriteRecord(shifted, ThreadedRecord(37.7));
            ThreadedAuto.Record shiftedMiss = Feed(ThreadedAuto.Load(shifted), 6, 0.6, 37.7, 60);
            Check(shiftedMiss is { Verdict: "single", NoGain: 1 },
                "REGRESSION: a threaded session whose bottleneck moved off the emulation thread (busy 0.6, rate = single) must count as no gain: " + shiftedMiss);

            string reached = Dir();
            WriteRecord(reached, ThreadedRecord(37.7));
            Check(Feed(ThreadedAuto.Load(reached), 36, 0.7, 59.5, 60) is { Verdict: "threaded", NoGain: 0 }, "a threaded session that meets the request for 180 s keeps threaded");

            string adreno = Dir();
            ThreadedAuto adrenoAuto = ThreadedAuto.Load(adreno);
            Check(Feed(adrenoAuto, 35, 0.63, 59.6, 60) == null && !System.IO.File.Exists(RecordPath(adreno)), "under 180 s the 8E shape must not write");
            Check(Feed(adrenoAuto, 1, 0.63, 59.6, 60) is { Verdict: "single" }, "the 8E shape must record single after 180 s");
            Check(Feed(ThreadedAuto.Load(Dir()), 36, 0.9, 29.9, 30) is { Verdict: "single" }, "REGRESSION: a game meeting its own 30 fps request must not switch to threaded however busy");
            Check(Feed(ThreadedAuto.Load(Dir()), 6, 0.9, 70, double.PositiveInfinity) is { Verdict: "threaded" }, "an unbounded request must switch on saturation alone");

            string stalled = Dir();
            WriteRecord(stalled, ThreadedRecord(37.7));
            ThreadedAuto crashing = ThreadedAuto.Load(stalled);
            ThreadedAuto.Record stallPin = crashing.Stalled(new TimeoutException("fixture stall"));
            Check(crashing.WaitWritten(3000) && stallPin is { Verdict: "single", PinnedLeft: ThreadedAuto.PinSessions } && OnDisk(stalled) == stallPin,
                "a render-thread stall in a threaded session must pin single: " + stallPin);
            Check(Feed(crashing, 40, 0.9, 52, 60) == null && OnDisk(stalled) == stallPin, "nothing may overwrite the stall record in the same session");
            Check(ThreadedAuto.Load(adreno).Stalled(new TimeoutException()) == null, "a single-thread session never pins on a stall");
            string ending = Dir();
            WriteRecord(ending, ThreadedRecord(37.7));
            ThreadedAuto closing = ThreadedAuto.Load(ending);
            closing.EndSession();
            Check(closing.Stalled(new TimeoutException()) == null && Feed(closing, 6, 0.9, 38, 60) == null && OnDisk(ending).Verdict == "threaded",
                "after EndSession (shutdown) nothing may be evaluated or pinned");

            foreach ((string text, string why) in new[]
            {
                ("version=7\nverdict=threaded\n", "unknown version"),
                ("version=2\nverdict=threaded\nno_gain=0\npinned_left=0\nsingle_hz=NaN\nsingle_busy=0.9\nthreaded_hz=0\nrequested_hz=60\nreason=x\n", "NaN rate"),
                ("version=2\nverdict=single\nno_gain=5\npinned_left=0\nsingle_hz=30\nsingle_busy=0.9\nthreaded_hz=0\nrequested_hz=60\nreason=x\n", "no_gain out of range"),
                ("version=2\nverdict=single\nno_gain=0\npinned_left=0\nsingle_hz=30\nsingle_busy=0.9\nthreaded_hz=0\nrequested_hz=60\nreason=" + new string('x', 400) + "\n", "reason too long"),
                ("version=2\nverdict=threaded\nno_gain=0\npinned_left=3\nsingle_hz=30\nsingle_busy=0.9\nthreaded_hz=0\nrequested_hz=60\nreason=x\n", "pinned threaded"),
            })
            {
                string bad = Dir();
                System.IO.File.WriteAllText(RecordPath(bad), text);
                ThreadedAuto recovered = ThreadedAuto.Load(bad);
                Check(!recovered.Threaded && recovered.Basis.Contains("读不了"), "an invalid record (" + why + ") must fall back to the measured single-thread baseline");
            }
            string old = Dir();
            System.IO.File.WriteAllText(RecordPath(old), "version=1\nverdict=threaded\nsticky=0\nsingle_hz=37\nsingle_busy=0.9\nthreaded_hz=0\nrequested_hz=60\nreason=x\n");
            ThreadedAuto upgraded = ThreadedAuto.Load(old);
            Check(!upgraded.Threaded && upgraded.Basis.Contains("v1") && Feed(upgraded, 6, 0.98, 37.7, 60) is { Verdict: "threaded" } && OnDisk(old).Verdict == "threaded",
                "a v1 record must be re-measured and replaced by a v2 record");
        }
        finally
        {
            foreach (string directory in directories) System.IO.Directory.Delete(directory, true);
        }
        Console.WriteLine("PASS: threaded auto policy — whole-session evaluation (menu-then-saturated → threaded, short menu session writes nothing), same-kind threaded comparison, two misses to pin, pins expire after 10 sessions, only stalls pin, shutdown evaluates nothing, invalid records re-measured.");
    }

    // auto 的运行时接线：生产 S2AReportLoop 的 5 s 窗口用 S2A.GPU 线程 CPU / 墙钟算忙（FIFO 空等为 0 也只按 CPU 算）、出图次数 / 墙钟算呈现，
    // 加上游戏请求的出图间隔，写进记录；只有卡住判定（ThreadedStalled）固定单线程，普通 Fail 不写记录。
    private static void AutoRuntimeWiring()
    {
        string saved = Environment.GetEnvironmentVariable(SwitchVariable);
        string measure = TempDirectory(), failing = TempDirectory();
        try
        {
            Environment.SetEnvironmentVariable(SwitchVariable, "auto");
            var runtime = new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: measure);
            Check(!Requested(runtime), "auto without a record must start single-threaded");
            runtime.ObserveFrameInterval(1f / 60);
            long cpu = 0, wall = 1;
            runtime.AutoCpuNanoseconds = () => cpu;
            runtime.AutoWallTicks = () => wall;
            for (int i = 0; i <= ThreadedAuto.SaturatedStreak; i++)
            {
                Set(runtime, "_s2aLoopReported", 0L);
                Set(runtime, "_s2aLoopFrame", Stopwatch.Frequency * 5);   // 主循环 5 s 都不在 FIFO 空等：按 FIFO 口径会是忙 1.0
                Set(runtime, "_s2aLoopPresents", 185L);                    // 5 s 里 185 帧：37 Hz
                typeof(AndroidVulkanRuntime).GetMethod("S2AReportLoop", Private).Invoke(runtime, null);
                cpu += 4_900_000_000;                                      // 线程 CPU 4.9 s / 5 s：忙 0.98
                wall += Stopwatch.Frequency * 5;
            }
            ThreadedAuto auto = Get<ThreadedAuto>(runtime, "_auto");
            Check(auto.WaitWritten(3000), "auto record write did not drain");
            ThreadedAuto.Record measured = OnDisk(measure);
            Check(measured.Verdict == "threaded" && Math.Abs(measured.SingleBusy - 0.98) < 0.001 && Math.Abs(measured.SingleHz - 37) < 0.01
                && Math.Abs(measured.RequestedHz - 60) < 0.01, "the runtime must feed CPU-time busy, present rate and the requested interval: " + measured);

            WriteRecord(failing, ThreadedRecord(37));
            var threaded = new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: failing);
            Check(Requested(threaded), "auto with a threaded record must select the threaded renderer");
            Call(threaded, "Fail", new InvalidOperationException("fixture failure unrelated to threading (device lost, cancel)"));
            Check(Get<ThreadedAuto>(threaded, "_auto").WaitWritten(3000) && OnDisk(failing).Verdict == "threaded",
                "REGRESSION: a failure not caused by threading must not pin single");
            var stalling = new AndroidVulkanRuntime(1, 1, _ => { }, stateDirectory: failing);
            Check(Requested(stalling), "fixture: still threaded");
            Call(stalling, "ThreadedStalled", new TimeoutException("fixture render-thread stall"));
            Check(Get<ThreadedAuto>(stalling, "_auto").WaitWritten(3000) && OnDisk(failing) is { Verdict: "single", Pinned: true },
                "a render-thread stall in an auto-threaded session must pin single after fatal");
        }
        finally
        {
            Environment.SetEnvironmentVariable(SwitchVariable, saved);
            System.IO.Directory.Delete(measure, true);
            System.IO.Directory.Delete(failing, true);
        }
        Console.WriteLine("PASS: threaded auto wiring — CPU-time busy 0.98 (FIFO wait 0), 37 Hz, request 60 Hz reach the record; an unrelated failure leaves it, a stall pins single.");
    }

    // 换页两阶段 + 排空 GAL 队列 + 停止顺序。
    private static void Backing()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        using var replaced = new ManualResetEventSlim();
        bool beginRejected = false, readRejected = false;
        session.Barrier = index =>
        {
            if (index == 1)
            {
                renderBlocked.Set();
                if (!releaseRender.Wait(5000)) Violation("fixture render release timed out");
            }
            else if (index > 8)
            {
                if (session.Handle.Unmapped || !session.Handle.Dirty) Violation("a command decoded after the transaction ran before remap/dirty");
                if (index == 9)
                {
                    try { Call(session.Runtime, "BeginBackingChange", Address, Size, 0UL); }
                    catch (InvalidOperationException error) when (error.Message.Contains("render thread")) { beginRejected = true; }
                    try { Call(session.Runtime, "CopyGuestMemoryOffRenderThread", Address, new Memory<byte>(new byte[16])); }
                    catch (InvalidOperationException error) when (error.Message.Contains("render thread")) { readRejected = true; }
                }
            }
        };

        // 8 条在事务之前已解码入队的 GAL 命令；渲染线程卡在第 1 条上。
        Push(session, 8);
        Check(renderBlocked.Wait(2000), "render thread did not execute the first queued command");
        Check(SpinWait.SpinUntil(() => Queued(session) >= 8, 2000),
            "GPU emulation thread did not decode the queued entries while the render thread was busy");

        Exception cpuError = null;
        using var prepared = new ManualResetEventSlim();
        var cpu = new Thread(() =>
        {
            try
            {
                Call(session.Runtime, "BeginBackingChange", Address, Size, Source);
                prepared.Set();
                if (!replaced.Wait(5000)) throw new Exception("fixture replacement not released");
                Call(session.Runtime, "EndBackingChange", Address, Size, 1);
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
        });
        cpu.Start();
        object change = null;
        Check(SpinWait.SpinUntil(() => (change = typeof(AndroidVulkanRuntime).GetField("_backingChange", Private).GetValue(session.Runtime)) != null, 2000),
            "CPU did not publish the backing request");
        Check(!prepared.Wait(300), "REGRESSION: prepare finished while earlier GAL commands were still unexecuted");
        Check((string)change.GetType().GetField("Phase").GetValue(change) == "queue-marker-before-old-backing-flush",
            "the GPU emulation thread must be waiting at the first queue marker");
        Check(Count("fence") == 0, "queue marker ran before the earlier GAL commands drained");

        releaseRender.Set();
        Check(prepared.Wait(3000), "prepare did not finish after the render thread drained");
        Check(cpuError == null, "CPU preparation failed: " + cpuError);
        Check(session.Handle.Unmapped, "prepare must unmap old tracking");
        int barriersAtPrepare = session.Barriers;
        Check(barriersAtPrepare == 8, $"all earlier commands must execute before prepare completes (saw {barriersAtPrepare})");
        Check(Queued(session) == 0, "the queue markers must leave the GAL queue empty while the transaction is open");

        // 事务期间：新推进来的条目不得被解码，渲染线程没有新命令。
        Push(session, 4);
        Thread.Sleep(150);
        Check(session.Barriers == 8, "REGRESSION: GAL work ran between prepare and native completion");
        replaced.Set();
        Check(cpu.Join(3000), "native completion did not finish");
        Check(cpuError == null, "CPU completion failed: " + cpuError);
        Check(SpinWait.SpinUntil(() => session.Barriers == 12, 3000), "commands after completion were not executed");
        Check(beginRejected, "a backing change started on the render thread was not rejected");
        Check(readRejected, "a guest-memory read on the render thread was not rejected");

        List<string> order;
        lock (Gate) order = new List<string>(_events);
        int firstFence = order.IndexOf("fence"), source = order.IndexOf("source");
        Check(firstFence > 0 && order.GetRange(0, firstFence).FindAll(e => e == "barrier").Count == 8,
            "the first queue marker must follow every GAL command queued before the transaction");
        Check(source > firstFence, "the old alias source flush must follow the first marker");
        Check(order.LastIndexOf("fence") > source, "a second marker must follow the old-backing flush");

        var stats = session.Threaded.S2AReadCounters(false);
        Check(stats.InvokeAction >= 2 && stats.QueueDepthMax >= 8, "threaded counters did not record the markers/queue depth");

        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed"), "Stop returned without GPU retirement");
        Check(Get<bool>(session.Runtime, "_renderWsiClosed"), "WSI retirement was not proven on the render thread");
        Check(session.Render.Join(2000), "render thread did not exit after disposal");
        Check(Count("fence") == 3, "stop must drain the GAL queue with one marker on the render thread");
        Check(session.Fatal == null, "unexpected fatal: " + session.Fatal);
        NoViolations();
        Check(typeof(AndroidVulkanRuntime).GetField("_backingChange", Private).GetValue(session.Runtime) == null, "finished left an active mutation");
        Close(session);
        Console.WriteLine("PASS: threaded backing — prepare drains earlier GAL work before the render-thread marker, no GAL work between prepare and completion, render-thread VM/guest reads rejected, stop drains/retires/disposes on the render thread.");
    }

    // 换页遇上条数背压：模拟线程卡在条数上限时换页请求等着；渲染线程前进后，marker 把背压期间排进的命令全部排空，事务期间不再有命令。
    private static void BackingUnderBackpressure()
    {
        const int cap = 4, entries = 12;
        Session session = Open(maxQueued: cap);
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        using var replaced = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            if (!releaseRender.Wait(5000)) Violation("fixture render release timed out");
        };
        Push(session, entries);
        Check(renderBlocked.Wait(2000), "render thread did not execute the first queued command");
        Check(SpinWait.SpinUntil(() => Queued(session) == cap, 2000), "the GPU emulation thread did not fill the queue to its cap");

        Exception cpuError = null;
        using var prepared = new ManualResetEventSlim();
        var cpu = new Thread(() =>
        {
            try
            {
                Call(session.Runtime, "BeginBackingChange", Address, Size, Source);
                prepared.Set();
                if (!replaced.Wait(5000)) throw new Exception("fixture replacement not released");
                Call(session.Runtime, "EndBackingChange", Address, Size, 1);
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
        });
        cpu.Start();
        Check(!prepared.Wait(300), "prepare finished while the GPU emulation thread was still held by backpressure");
        Check(Queued(session) <= cap, "REGRESSION: queue depth exceeded the cap while a backing change was pending");
        releaseRender.Set();
        Check(prepared.Wait(3000), "REGRESSION: backing change did not complete after backpressure released (deadlock)");
        Check(cpuError == null, "CPU preparation failed: " + cpuError);
        int atPrepare = session.Barriers;
        Check(Queued(session) == 0, "the markers must drain everything queued under backpressure before prepare completes");
        Check(atPrepare >= cap && atPrepare < entries, $"prepare must land between entries (barriers {atPrepare})");
        Thread.Sleep(150);
        Check(session.Barriers == atPrepare, "REGRESSION: GAL work ran between prepare and native completion");
        replaced.Set();
        Check(cpu.Join(3000) && cpuError == null, "native completion did not finish: " + cpuError);
        Check(SpinWait.SpinUntil(() => session.Barriers == entries, 3000), "entries after the transaction were not executed");
        var stats = session.Threaded.S2AReadCounters(false);
        Check(stats.QueueWaitCount >= 1 && stats.QueueDepthMax <= cap, $"backpressure counters wrong (waits {stats.QueueWaitCount}, depth max {stats.QueueDepthMax})");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop after backpressure failed: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded backing under backpressure — the request waits while the queue is at its cap, then markers drain all queued work; no GAL work inside the transaction; no deadlock.");
    }

    // 条数上限：渲染线程卡住时模拟线程在上限处背压等（不无界增长），放开后全部按序执行。
    private static void QueueBackpressure()
    {
        const int cap = 16, entries = 40;
        Session session = Open(maxQueued: cap);
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            if (!releaseRender.Wait(5000)) Violation("fixture render release timed out");
        };
        Push(session, entries);
        Check(renderBlocked.Wait(2000), "render thread did not execute the first queued command");
        Check(SpinWait.SpinUntil(() => Queued(session) >= cap, 2000), "the GPU emulation thread did not fill the queue to its cap");
        Thread.Sleep(300);
        int depth = Queued(session);
        Check(depth == cap, $"REGRESSION: queue depth {depth} exceeded the configured cap {cap} (no backpressure)");
        Check(session.Barriers == 1 && session.Fatal == null, "a 300 ms render-thread pause must neither run more commands nor fail the session");
        releaseRender.Set();
        Check(SpinWait.SpinUntil(() => session.Barriers == entries, 3000), "queued commands after backpressure were not all executed");
        var stats = session.Threaded.S2AReadCounters(false);
        Check(stats.QueueWaitCount >= 1 && stats.QueueWaitTicks > 0, "backpressure waits were not counted");
        Check(stats.QueueDepthMax <= cap, $"queue depth peak {stats.QueueDepthMax} exceeded the cap {cap}");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop after backpressure failed: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine($"PASS: threaded queue bound — depth held at {cap} while the render thread was busy (backpressure counted), all {entries} commands then executed in order.");
    }

    // 在途载荷上限：环形池放不下的上传（新分配）与贴图 SetData 数据计入在途字节；超上限时生产线程等渲染线程消费；
    // 单块比上限大时在已发布的在途载荷清零后放行（不会永远等）；全部消费完在途归零。测试线程在模拟线程空闲时充当唯一生产者。
    private static void PayloadBackpressure()
    {
        const long cap = 4L << 20;
        const int big = 9 << 20, texture = 3 << 20;
        Session session = Open(maxPayload: cap);
        var info = new TextureCreateInfo(64, 64, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
        ITexture tex = session.Threaded.CreateTexture(info);   // 非 GPU 线程：直接在渲染线程锁内建好（渲染线程卡住之前建）
        BufferHandle buffer = session.Threaded.CreateBuffer(16, BufferAccess.Default);
        var uploads = new List<(string Thread, int Length)>();
        NullRenderer.OnSetBufferData = length => { lock (Gate) uploads.Add((Thread.CurrentThread.Name, length)); };
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            if (!releaseRender.Wait(5000)) Violation("fixture render release timed out");
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not execute the blocking command");

        int stage = 0;
        Exception producerError = null;
        var producer = new Thread(() =>
        {
            try
            {
                session.Threaded.SetBufferData(buffer, 0, new byte[big]);   // 比环形池大：新分配；比上限大但没有已发布的在途 → 放行
                Volatile.Write(ref stage, 1);
                session.Threaded.SetBufferData(buffer, 0, new byte[big]);   // 已发布的在途 9 MiB，再计入 9 MiB 超 4 MiB → 等第一块被消费
                Volatile.Write(ref stage, 2);
                tex.SetData(MemoryOwner<byte>.Rent(texture));               // 贴图数据同样计入
                Volatile.Write(ref stage, 3);
            }
            catch (Exception error) { producerError = error; }
        }) { IsBackground = true };
        producer.Start();
        Check(SpinWait.SpinUntil(() => Volatile.Read(ref stage) >= 1, 2000), "an oversize payload must be admitted when nothing else is in flight");
        Thread.Sleep(300);
        Check(Volatile.Read(ref stage) == 1, "REGRESSION: a payload over the in-flight cap was queued without backpressure");
        Check(session.Threaded.S2APayloadInFlight == big, $"in-flight bytes {session.Threaded.S2APayloadInFlight} must equal the one admitted payload");
        releaseRender.Set();
        Check(producer.Join(3000) && producerError == null, "payload producer did not finish after the render thread drained: " + producerError);
        Check(SpinWait.SpinUntil(() => Queued(session) == 0, 2000), "payload commands did not execute");
        Check(session.Threaded.S2APayloadInFlight == 0, $"in-flight bytes must return to 0 after consumption (left {session.Threaded.S2APayloadInFlight})");
        var stats = session.Threaded.S2AReadCounters(false);
        Check(stats.PayloadWaitCount >= 1, $"payload backpressure waits were not counted ({stats.PayloadWaitCount})");
        Check(stats.PayloadInFlightMax == big, $"in-flight peak {stats.PayloadInFlightMax} must not exceed max(cap, largest payload)");
        Check(stats.PayloadBytes == 2L * big + texture, $"admitted payload bytes {stats.PayloadBytes} do not match the uploads");
        Check(stats.UploadSpills == 2 && stats.UploadBytes == 2L * big, "spilled uploads were not counted");
        lock (Gate)
        {
            Check(uploads.Count == 2 && uploads.TrueForAll(u => u.Thread == RenderName && u.Length == big), "spilled uploads must reach the backend on the render thread intact");
        }
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop after payload backpressure failed: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded payload bound — spilled uploads and texture data count as in-flight bytes, producer waits over the cap, an oversize payload passes alone, in-flight returns to 0.");
    }

    // GPU 层的后台动作（TextureGroup 回写走的 BackgroundContextAction，复审 P1-4）在 GPU 模拟线程上发起时就在模拟线程上执行，
    // 渲染线程不进 GPU 层 / 写跟踪；动作里的读回照常排成同步命令由渲染线程执行。宿主的 marker 仍走 S2AOnRenderThread 在渲染线程上。
    private static void BackgroundActionOnEmulationThread()
    {
        Session session = Open();
        BufferHandle buffer = session.Threaded.CreateBuffer(16, BufferAccess.Default);
        int armed = 1;
        string actionThread = null;
        Exception actionError = null;
        using var ran = new ManualResetEventSlim();
        NxTrack.OnDrain = () =>
        {
            if (!OnSim) Violation("write-tracking drain ran off the GPU emulation thread");
            if (Interlocked.Exchange(ref armed, 0) == 0) return;
            try
            {
                session.Threaded.BackgroundContextAction(() =>
                {
                    actionThread = Thread.CurrentThread.Name;
                    session.Threaded.GetBufferData(buffer, 0, 16);   // GPU 模拟线程上 → 同步命令，渲染线程执行读回
                });
            }
            catch (Exception error) { actionError = error; }
            ran.Set();
        };
        Push(session, 1);
        Check(ran.Wait(3000) && actionError == null, "the background action did not complete: " + actionError);
        Check(actionThread == "S2A.GPU", $"REGRESSION: a GPU-layer background action must run on the GPU emulation thread, not {actionThread ?? "nowhere"}");
        Check(session.Threaded.S2AReadCounters(false).ReadbackBuffer >= 1, "the readback inside the action must still go through the render thread");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop failed: " + session.Fatal);
        Check(Count("fence") == 1, "the stop marker must still run on the render thread");
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded background action — GPU-layer actions run inline on S2A.GPU (readback still via the render thread); host markers stay on the render thread.");
    }

    // 同步命令的唤醒（9000 正式版报「同步命令单次 max 58.7 / 80.6 ms」，怀疑有界等待按 50 ms 一片超时醒）：渲染线程空闲时，模拟线程上
    // 300 次缓冲读回（同步命令）每次都应被渲染线程执行完的事件立即唤醒，往返远小于一片；按片超时醒的话每次 ≥ 50 ms。
    private static void SyncWakeLatency()
    {
        Session session = Open();
        BufferHandle buffer = session.Threaded.CreateBuffer(16, BufferAccess.Default);
        const int rounds = 300;
        var took = new double[rounds];
        Exception error = null;
        int armed = 1;
        using var ran = new ManualResetEventSlim();
        NxTrack.OnDrain = () =>
        {
            if (Interlocked.Exchange(ref armed, 0) == 0) return;
            try
            {
                for (int i = 0; i < rounds; i++)
                {
                    long start = Stopwatch.GetTimestamp();
                    session.Threaded.GetBufferData(buffer, 0, 16);
                    took[i] = Ms(start);
                }
            }
            catch (Exception caught) { error = caught; }
            ran.Set();
        };
        Push(session, 1);
        Check(ran.Wait(30000) && error == null, "the readbacks did not complete: " + error);
        Array.Sort(took);
        double p50 = took[rounds / 2], p99 = took[rounds * 99 / 100], max = took[^1];
        ThreadedRenderer.S2ACounters counters = session.Threaded.S2AReadCounters(false);
        double counted = counters.InvokeMaxTicks * 1000.0 / Stopwatch.Frequency;
        Check(counters.ReadbackBuffer >= rounds, "the readbacks must be sync commands executed by the render thread");
        Check(p50 < 2 && max < 25,
            $"REGRESSION: a sync command on an idle render thread must be woken by its completion event, not a 50 ms slice timeout (p50 {p50:F2} / p99 {p99:F2} / max {max:F2} ms)");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop failed: " + session.Fatal);
        Close(session);
        Console.WriteLine($"PASS: threaded sync wake — {rounds} readbacks on an idle render thread: p50 {p50:F3} / p99 {p99:F3} / max {max:F3} ms (counter max {counted:F3} ms), event-driven, not slice-bound.");
    }

    // 出图计数 / FramePresented 归渲染线程：真实 ThreadedWindow.Present 入队、渲染线程执行出图命令后经 S2AAfterPresent 取计数。
    // 计数不变（下层没有成功排队）不回调；每 60 帧读数窗口照常结算。测试线程在模拟线程空闲（无 FIFO 条目）时充当唯一生产者。
    private static void Presents()
    {
        Session session = Open();
        var seen = new List<(string Thread, ulong Count)>();
        session.Runtime.FramePresented = count => { lock (Gate) seen.Add((Thread.CurrentThread.Name, count)); };
        const int frames = 130;
        int counted = 1;
        NullWindow.OnPresent = () =>
        {
            if (!OnRender) Violation("present executed off the render thread");
            if (Volatile.Read(ref counted) != 0) AndroidVulkanSurface.Presents++;   // 真实窗口成功排队后才加计数
        };
        for (int i = 0; i < frames; i++) session.Threaded.Window.Present(null, default, null);
        Check(SpinWait.SpinUntil(() => Get<ulong>(session.Runtime, "_renderPresentsSeen") == frames, 2000), "render thread did not execute the queued presents");
        Volatile.Write(ref counted, 0);
        session.Threaded.Window.Present(null, default, null); // 下层没有成功排队（计数不变）：不算一帧
        Check(SpinWait.SpinUntil(() => session.Threaded.S2AReadCounters(false).FrameWaitCount == frames + 1, 2000), "the uncounted present was not queued");
        Thread.Sleep(50);
        NullWindow.OnPresent = null;
        lock (Gate)
        {
            Check(seen.Count == frames, $"FramePresented must fire once per counted present (saw {seen.Count})");
            Check(seen.TrueForAll(s => s.Thread == RenderName), "FramePresented must run on the render thread");
            bool ordered = true;
            for (int i = 0; i < seen.Count; i++) ordered &= seen[i].Count == (ulong)(i + 1);
            Check(ordered, "FramePresented counts must follow the queued order");
        }
        object split = typeof(AndroidVulkanRuntime).GetField("_split", Private).GetValue(session.Runtime);
        Check(Get<long>(split, "_windowFrames") == 120, "two 60-frame windows must settle after the baseline present");
        session.Runtime.FramePresented = null;
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed"), "Stop returned without GPU retirement");
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded presents — FramePresented runs on the render thread once per counted present, in order; 60-frame windows settle.");
    }

    // 换页时渲染线程卡住：模拟线程在第一个 marker（同步命令）里有界等，生产判据到了按失败处理（TimeoutException 进 fatal，首个失败锁存），
    // 并且在 guest 的前台 3 s 换页预算到期之前报出；Stop 在宿主 3 s 停机期限内返回同一个异常；对象保留。
    private static void StallDuringBacking()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            releaseRender.Wait(15000);
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not enter the stuck command");
        Exception guestError = null;
        var guest = new Thread(() =>
        {
            try { Call(session.Runtime, "BeginBackingChange", Address, Size, Source); }
            catch (Exception error) { guestError = error; }
        }) { IsBackground = true };
        long requested = Stopwatch.GetTimestamp();
        guest.Start();
        Check(SpinWait.SpinUntil(() => Volatile.Read(ref session.Fatal) != null, 3000),
            "REGRESSION: a render-thread stall during a backing change was not diagnosed within the 3 s foreground budget");
        double diagnosed = Ms(requested);
        Exception fatal = session.Fatal;
        Check(fatal is TimeoutException && fatal.Message.Contains("拆线程") && fatal.Message.Contains("同步命令") && fatal.Message.Contains("CommandBufferBarrier"),
            "the diagnosis must name the stalled render thread, the waiting operation and the running command: " + fatal);
        Check(diagnosed >= 2000 && diagnosed <= 2600, $"stall diagnosed at {diagnosed:F0} ms; expected 2000 ms without progress + 250 ms grace (+ one 50 ms slice)");
        Console.WriteLine("  diagnosis: " + fatal.Message);
        long stopping = Stopwatch.GetTimestamp();
        Exception stopError = null;
        try { session.Runtime.Stop(); } catch (Exception error) { stopError = error; }
        Check(ReferenceEquals(stopError, fatal) && Ms(stopping) < 3000, "Stop must return the latched stall diagnosis within the host stop deadline: " + stopError);
        Check(guest.Join(3000) && guestError is TimeoutException, "the guest's own 3 s backing wait must expire after the diagnosis: " + guestError);
        Check(ReferenceEquals(session.Fatal, fatal), "the later guest timeout must not replace the first failure");
        Check(!Get<bool>(session.Runtime, "_gpuDisposed"), "a failed session must retain GPU objects");
        releaseRender.Set();
        Check(session.Render.Join(3000), "the render thread did not leave after the session failed");
        Close(session);
        Console.WriteLine($"PASS: threaded stall during backing — diagnosed at {diagnosed:F0} ms (< 3000 ms budget), fatal/Stop carry the same TimeoutException, objects retained.");
    }

    // 换页遇上「慢但在前进」的排空（复审 P1-1）：100 条事务前的命令每条在渲染线程上跑 50 ms（共约 5 s，模拟加载期一串现编），
    // guest 的换页等待不得按 3 s 判死（渲染侧一直在干活就续期，总上限 30 s），模拟线程也不得判卡住；事务完成后照常继续。
    private static void SlowDrainBacking()
    {
        const int entries = 100;
        Session session = Open();
        using var replaced = new ManualResetEventSlim();
        session.Barrier = _ => Thread.Sleep(50);
        Push(session, entries);
        Check(SpinWait.SpinUntil(() => session.Barriers >= 2, 2000), "render thread did not start the slow backlog");
        Exception cpuError = null;
        using var prepared = new ManualResetEventSlim();
        long requested = Stopwatch.GetTimestamp();
        var cpu = new Thread(() =>
        {
            try
            {
                Call(session.Runtime, "BeginBackingChange", Address, Size, Source);
                prepared.Set();
                if (!replaced.Wait(5000)) throw new Exception("fixture replacement not released");
                Call(session.Runtime, "EndBackingChange", Address, Size, 1);
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
        }) { IsBackground = true };
        cpu.Start();
        Check(prepared.Wait(10_000), "prepare did not finish after the slow backlog");
        double took = Ms(requested);
        Check(cpuError == null, "REGRESSION: a slow but progressing drain must not time out the guest backing wait: " + cpuError);
        Check(took >= 3000, $"fixture: the backlog must outlast the 3 s budget to prove the extension (took {took:F0} ms)");
        Check(session.Barriers == entries && Queued(session) == 0, "prepare must follow the whole backlog");
        Check(session.BackingProgress >= 10,
            $"REGRESSION: guest must report native progress while draining ({session.BackingProgress} publications)");
        Check(session.Fatal == null, "a progressing render thread must not be judged stalled: " + session.Fatal);
        replaced.Set();
        Check(cpu.Join(3000) && cpuError == null, "native completion did not finish: " + cpuError);
        session.Barrier = null;
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop after the slow drain failed: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine($"PASS: threaded slow drain — a {entries} × 50 ms backlog delayed prepare to {took:F0} ms without a guest timeout or stall verdict.");
    }

    // 换页没有旧 backing 回写源（Source == 0，冷启时多数换页）：拆线程只发第一条 marker（排空 + fence），第二条省掉（中间没有新的 GAL 命令）；
    // 有回写源时两条照发（Backing 用例）。事务语义不变：prepare 前队列已排空、remap / dirty 照常。
    // 可选 Linux ARM64 联合夹具：真实 native writer admission 与实际托管换页等待同时进行。
    // 共享页仅替换跨进程 host 发布边界，未替换 native serial/epoch/gate 或托管等待算法。
    private static void BackingNativeLifecycle()
    {
        using var probe = NativeBackingProbe.Open();
        if (probe == null) return;
        Session session = Open();
        using var done = new ManualResetEventSlim();
        Set(session.Runtime, "BackingProgress", (Func<ulong, int, ulong>)((owner, advance) => {
            ulong result = Publish(session, owner, advance);
            if (result != 0) probe.Publish(advance);
            return result;
        }));
        Set(session.Runtime, "BackingDecision", (Func<ulong, int>)probe.Decision);
        Task wait = Task.Run(() => Call(session.Runtime, "WaitForGpuStepThreaded", done, "joint lifecycle wait"));
        try {
            probe.WaitReady();
            AndroidVulkanSurface.SetProducerForeground(false); probe.Lifecycle(false);
            Thread.Sleep(32000);
            Check(!probe.Exited && !wait.IsCompleted, "REGRESSION: background/freeze expired native or managed budget");
            AndroidVulkanSurface.SetProducerForeground(true); probe.Lifecycle(true);
            for (int i=0; i<12; i++) { session.Threaded.S2ANoteAlive(); Thread.Sleep(100); }
            Check(!probe.Exited && !wait.IsCompleted, "REGRESSION: resume must reset idle and total budgets");
            probe.Release(); done.Set(); Check(wait.Wait(1000), "managed wait did not finish");
            Check(session.BackingOwner == 0, "managed local wait must close publication");
            Console.WriteLine("PASS joint runtime/managed backing: freeze32s, resume/progress, actual gate completes");
        } finally {
            done.Set(); try { wait.Wait(2000); } catch (AggregateException) { }
            session.Runtime.Stop(); Close(session);
        }
    }

    // 强制实际 Begin/Process/End 的 Prepared→Replaced 交接：旧 finally 晚于新等待发布。
    // 可选 Linux ARM64 再连真实 native 准入，后台 4.2 s、恢复后 350 ms 无新工作才放 writer。
    // 仅替换 host 发布/生命周期边界。binary 内仍为实际 serial/epoch/gate/VM/roster。
    private sealed class NativeBackingProbe : IDisposable
    {
        private readonly string _path = Path.Combine(Path.GetTempPath(), "s2a-handoff-" + Guid.NewGuid().ToString("N"));
        private readonly FileStream _file;
        private readonly MemoryMappedFile _map;
        private readonly MemoryMappedViewAccessor _view;
        private readonly Process _native;
        private byte* _bytes;
        public bool Exited => _native.HasExited;
        public string ExitDiagnostic => Exited ? $"exit={_native.ExitCode}; {_native.StandardError.ReadToEnd()}" : "alive";
        public int Decision(ulong owner) => BackingAuthority.test_shared_decision((nint)_bytes, owner);
        private long* Shared => (long*)_bytes;
        public static NativeBackingProbe Open() => Environment.GetEnvironmentVariable("S2A_NATIVE_WRITERS") is string binary ? new(binary) : null;
        private NativeBackingProbe(string binary)
        {
            _file = new FileStream(_path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.ReadWrite);
            _file.SetLength(256);
            _map = MemoryMappedFile.CreateFromFile(_file, null, 256, MemoryMappedFileAccess.ReadWrite, HandleInheritability.None, true);
            _view = _map.CreateViewAccessor();
            _view.SafeMemoryMappedViewHandle.AcquirePointer(ref _bytes);
            Volatile.Write(ref Shared[3], 1);
            var start = new ProcessStartInfo(binary, "external-published") { RedirectStandardOutput = true, RedirectStandardError = true };
            start.Environment["S2A_BACKING_SHARED"] = _path;
            _native = Process.Start(start);
        }
        private ulong _owner;
        public void Publish(int advance)
        {
            ulong result = BackingAuthority.test_shared_publish((nint)_bytes, _owner, advance);
            if (result != 0) _owner = result;
        }
        public void Lifecycle(bool foreground) => BackingAuthority.test_shared_lifecycle((nint)_bytes, foreground ? 1 : 0);
        public void WaitReady() => Check(SpinWait.SpinUntil(() => Volatile.Read(ref Shared[5]) == 1 || Exited, 3000) && !Exited,
            "native handoff contender did not reach actual admission");
        public void Release()
        {
            Volatile.Write(ref Shared[6], 1);
            Check(_native.WaitForExit(3000), "native handoff writer did not finish after release");
            Check(_native.ExitCode == 0, "native handoff writer failed: " + _native.StandardError.ReadToEnd());
            Console.WriteLine("PASS joint actual native admission: released writer, contender completed through epoch barrier");
        }
        public void Dispose()
        {
            if (!_native.HasExited) { _native.Kill(); _native.WaitForExit(); }
            _native.Dispose();
            _view.SafeMemoryMappedViewHandle.ReleasePointer();
            _view.Dispose(); _map.Dispose(); _file.Dispose(); File.Delete(_path);
        }
    }

    private static void PublicationClockOrigin()
    {
        Session session = Open();
        using var native = NativeBackingProbe.Open();
        using var firstPublished = new ManualResetEventSlim();
        if (native != null) Set(session.Runtime, "BackingDecision", (Func<ulong, int>)native.Decision);
        const int entries = 400;
        long publishedAt = 0, failedAt = 0;
        Set(session.Runtime, "BackingProgress", (Func<ulong,int,ulong>)((owner,idle) => {
            ulong accepted = Publish(session, owner, idle);
            if (accepted != 0) native?.Publish(idle);
            if (owner == 0 && idle > 0) { publishedAt=Environment.TickCount64; firstPublished.Set(); }
            return accepted;
        }));
        session.Barrier = index => {
            if (!firstPublished.Wait(5000)) throw new Exception("publication not registered");
            long target = publishedAt + index * 31500L / entries;
            while (Environment.TickCount64 < target) Thread.Sleep(1);
        };
        Push(session, entries);
        Check(SpinWait.SpinUntil(() => Queued(session) >= entries-1,2000),"backlog not queued");
        Exception cpuError = null;
        Thread cpu = null;
        int reads = 0;
        Set(session.Runtime,"BackingDecision",(Func<ulong,int>)(owner => {
            if (Thread.CurrentThread == cpu && Interlocked.Increment(ref reads)==1) Thread.Sleep(2500);
            return native != null ? native.Decision(owner) : BackingAuthority.test_decision(session.Authority,owner);
        }));
        cpu = new Thread(() => {
            try { Call(session.Runtime,"BeginBackingChange",Address,Size,Source); Call(session.Runtime,"EndBackingChange",Address,Size,1); }
            catch (Exception error) { cpuError=error; failedAt=Environment.TickCount64; }
        }) { IsBackground=true };
        cpu.Start();
        Check(firstPublished.Wait(3000),"no initial publication");
        native?.WaitReady();
        while (Environment.TickCount64 < publishedAt+30600) Thread.Sleep(10);
        if (cpuError is TimeoutException && !cpu.IsAlive) native?.Release();
        else
        {
            while (Environment.TickCount64 < publishedAt+31100) Thread.Sleep(10);
            Console.WriteLine($"OBSERVE clock split: publishedAgeMs={Environment.TickCount64-publishedAt} cpuWaiting={cpu.IsAlive} failure={cpuError?.GetType().Name ?? "none"} native={native?.ExitDiagnostic ?? "not attached"}");
        }
        bool timedOut = cpuError is TimeoutException && !cpu.IsAlive && session.BackingOwner == 0;
        Check(cpu.Join(4000), "clock regression guest did not exit");
        Check(timedOut, "REGRESSION: native 31s admission expires while delayed first managed wait remains legal; total must start at publication");
        Check(cpuError.Message.Contains("30000 ms"), "common total clock must produce managed total-budget diagnosis: " + cpuError);
        Check(SpinWait.SpinUntil(() => Queued(session) == 0, 3000), "progressing backlog did not finish");
        Console.WriteLine($"PASS common publication clock: delayed first read=2500ms, render backlog=31500ms, managed timeout before native cap; nativeAttached={native != null} timeoutAgeMs={failedAt-publishedAt}");
        try { session.Runtime.Stop(); }
        catch (Exception error) { Check(ReferenceEquals(error, session.Fatal), "Stop must preserve the first backing failure"); }
        Close(session);
    }

    // A lifecycle snapshot can be stale when the subsequent shared-clock read sees
    // the new foreground generation. Its idle interval must not include the pause.
    private static void PublicationLifecycleSnapshot()
    {
        Session session = Open();
        long stale = AndroidVulkanSurface.Lifecycle();
        using var done = new ManualResetEventSlim();
        using var published = new ManualResetEventSlim();
        Set(session.Runtime, "_lifecycle", (Func<long>)(() => stale));
        Set(session.Runtime, "BackingProgress", (Func<ulong, int, ulong>)((owner, idle) =>
        {
            ulong accepted = Publish(session, owner, idle);
            if (accepted != 0 && idle > 0) published.Set();
            return accepted;
        }));
        AndroidVulkanSurface.SetProducerForeground(false);
        Task wait = Task.Run(() => Call(session.Runtime, "WaitForGpuStepThreaded", done, "stale lifecycle snapshot"));
        try
        {
            Check(published.Wait(2000), "stale-snapshot waiter did not publish");
            Thread.Sleep(3500);
            Check(!wait.IsCompleted, "shared clock must pause despite an older foreground snapshot");
            AndroidVulkanSurface.SetProducerForeground(true);
            Thread.Sleep(500);
            Check(!wait.IsCompleted, "REGRESSION: idle timer included background time when shared clock observed resume before lifecycle snapshot");
        }
        finally
        {
            AndroidVulkanSurface.SetProducerForeground(true);
            done.Set();
            try { wait.Wait(2000); } catch (AggregateException) { }
            session.Runtime.Stop(); Close(session);
        }
        Check(wait.IsCompletedSuccessfully, "stale lifecycle snapshot poisoned the backing wait");
        Console.WriteLine("PASS shared clock reset bounds idle across a stale lifecycle snapshot: background3500ms, foreground500ms, no work pulses");
    }

    // R7-P1-1: late resume observation cannot grant another idle interval.
    // Replay both reader orders; only the native lifecycle callback owns the clock.
    private static void DelayedResumeObservation()
    {
        foreach (bool managedFirst in new[]{false,true}) {
            Session session=Open(); using var probe=NativeBackingProbe.Open();
            using var done=new ManualResetEventSlim();using var entered=new ManualResetEventSlim();
            using var releaseRead=new ManualResetEventSlim();Exception failure=null;
            int reads=0;long failedAt=0;
            AndroidVulkanSurface.SetProducerForeground(false);probe?.Lifecycle(false);
            Set(session.Runtime,"BackingProgress",(Func<ulong,int,ulong>)((owner,advance)=>{
                ulong result=Publish(session,owner,advance);if(result!=0)probe?.Publish(advance);return result;
            }));
            Func<ulong,int> decision=owner=>probe!=null?probe.Decision(owner):BackingAuthority.test_decision(session.Authority,owner);
            Set(session.Runtime,"BackingDecision",(Func<ulong,int>)(owner=>{
                int result=decision(owner);
                if(Interlocked.Increment(ref reads)==1){entered.Set();releaseRead.Wait();}
                return result;
            }));
            var waiter=new Thread(()=>{try{Call(session.Runtime,"WaitForGpuStepThreaded",done,"resume observation");}
                catch(Exception e){failure=e;failedAt=Environment.TickCount64;}}){IsBackground=true};
            waiter.Start();Check(entered.Wait(2000),"background decision reached");probe?.WaitReady();
            // Optional observer before resume; it has no authority to start a timer.
            if(managedFirst)Check(decision(session.BackingOwner)==0,"managed background verdict");
            AndroidVulkanSurface.SetProducerForeground(true);probe?.Lifecycle(true);long resumedAt=Environment.TickCount64;
            if(managedFirst)Check(decision(session.BackingOwner)==0,"managed resume first verdict");
            Thread.Sleep(2500);releaseRead.Set();
            Check(waiter.Join(1250),"REGRESSION: delayed resume observer reset idle; native admission can expire first");
            Check(failure is TimeoutException && failedAt-resumedAt>=3200 && failedAt-resumedAt<3900,
                "REGRESSION: late observer must use callback resume origin, got "+failure+" age="+(failedAt-resumedAt));
            Check(probe==null||!probe.Exited,"native admission expired before managed verdict");probe?.Release();
            session.Runtime.Stop();Close(session);
            Console.WriteLine($"PASS R7 late resume: managedFirst={managedFirst}, delayed2500ms, timeoutAge={failedAt-resumedAt}ms");
        }
    }

    private static void BackingDecisionWiring()
    {
        foreach(int verdict in new[]{0,1,2,3}) {
            Session session=Open();using var done=new ManualResetEventSlim();int reads=0;Exception failure=null;
            Set(session.Runtime,"_lifecycle",(Func<long>)(()=>throw new Exception("REGRESSION: backing wait read managed lifecycle")));
            Set(session.Runtime,"BackingDecision",(Func<ulong,int>)(owner=>{reads++;if(verdict==0||reads>1)done.Set();return verdict;}));
            try{Call(session.Runtime,"WaitForGpuStepThreaded",done,"native decision");}catch(Exception e){failure=e;}
            Check(reads==1,"REGRESSION: native verdict must be acted on immediately");
            Check(verdict==0?failure==null:verdict==3?failure is InvalidOperationException:failure is TimeoutException,
                "REGRESSION: managed action differs from native verdict "+verdict);
            if(verdict==2)Check(failure.Message.Contains("30000 ms"),"REGRESSION: total verdict diagnosis");
            session.Runtime.Stop();Close(session);
        }
        Console.WriteLine("PASS native decision wiring: continue/idle/total/revoked, no managed lifecycle read");
    }

    private static void PublicationFailureBoundary()
    {
        Session session = Open();
        using var probe = NativeBackingProbe.Open();
        if (probe != null)
        {
            Set(session.Runtime, "BackingProgress", (Func<ulong, int, ulong>)((owner, idle) =>
            {
                ulong accepted = Publish(session, owner, idle);
                if (accepted != 0) probe.Publish(idle);
                return accepted;
            }));
            Set(session.Runtime, "BackingDecision", (Func<ulong, int>)probe.Decision);
        }
        var error = new InvalidOperationException("probe prepare marker failed");
        AndroidVulkanSurface.SetProducerForeground(false);
        AndroidVulkanSurface.OnFence = () => throw error;
        Exception cpuError = null;
        var cpu = new Thread(() => {
            try { Call(session.Runtime, "BeginBackingChange", Address, Size, Source); }
            catch (Exception value) { cpuError = value; }
        }) { IsBackground = true };
        cpu.Start();
        Check(SpinWait.SpinUntil(() => session.Fatal != null, 2000), "prepare failure did not reach Fail");
        Check(ReferenceEquals(session.Fatal, error), "wrong first failure");
        Check(_sim.Join(1000) && session.Render.Join(1000), "failed GPU workers did not exit");
        Console.WriteLine($"OBSERVE prepare failure latched: activeOwner={session.BackingOwner} cpuWaiting={cpu.IsAlive} gpuDisposed={Get<bool>(session.Runtime, "_gpuDisposed")}");
        Check(session.BackingOwner != 0 && cpu.IsAlive, "observed terminal state changed; inspect semantics");
        probe?.WaitReady();
        Exception stopError = null;
        try { session.Runtime.Stop(); } catch (Exception value) { stopError = value; }
        Check(ReferenceEquals(stopError, error), "Stop after failure must return the first failure without completing mapping");
        Check(session.BackingOwner != 0 && !Get<bool>(session.Runtime, "_gpuDisposed"), "Stop must retain the failed transaction and GPU ownership");
        if (probe != null)
        {
            probe.Lifecycle(false);
            Thread.Sleep(4200);
            Check(!probe.Exited && cpu.IsAlive, "REGRESSION: failed/Stop retained owner must keep admission paused in background");
        }
        AndroidVulkanSurface.SetProducerForeground(true);
        probe?.Lifecycle(true);
        Check(cpu.Join(4500), "guest backing wait did not finish on foreground timeout");
        Console.WriteLine($"OBSERVE after guest timeout: activeOwner={session.BackingOwner} cpuError={cpuError?.GetType().Name} firstFailureRetained={ReferenceEquals(session.Fatal,error)}");
        Check(session.BackingOwner == 0, "foreground wait failure did not close publication");
        Check(ReferenceEquals(session.Fatal, error), "foreground timeout must not overwrite first failure");
        probe?.Release();
        Console.WriteLine("PASS failed retention + Stop + lifecycle renewal: only the foreground waiter timeout closes publication; first failure retained");
        Close(session);
    }

    private static void BackingPublicationModel()
    {
        Type type = typeof(AndroidVulkanRuntime).GetNestedType("BackingPublication", BindingFlags.NonPublic);
        int[] word = new int[6]; long traces=0, transitions=0;
        void Replay() {
            int calls=0, expected=0, stage=0, verdict=0;
            bool closed=false, allocated=false; ulong active=0;
            var publish=(Func<ulong,int,ulong>)((owner, advance) => {
                calls++; if (owner==0) { active=1; return 1; }
                if (owner!=active) throw new Exception("REGRESSION: stale owner published");
                if (advance==0) active=0; return owner;
            });
            object value=Activator.CreateInstance(type,publish,(Func<ulong,int>)(owner=>verdict));
            Action<int> enter=type.GetMethod("Enter").CreateDelegate<Action<int>>(value);
            Action<int> pulse=type.GetMethod("Pulse").CreateDelegate<Action<int>>(value);
            Action close=type.GetMethod("Close").CreateDelegate<Action>(value);
            Func<int> decision=type.GetMethod("Decision").CreateDelegate<Func<int>>(value);
            foreach(int e in word) {
                if(e<3) { int next=e+1;
                    if(!closed && next>stage) { stage=next; if(allocated||next==1){expected++;allocated=true;} }
                    enter(next);
                } else if(e<6) { if(!closed&&allocated&&e-2==stage)expected++;pulse(e-2); }
                else if(e==6) { if(!closed&&allocated)expected++;closed=true;close(); }
                else verdict=e-7; // all four native decisions, including revoked
                if(decision()!=verdict || calls!=expected || active!=(allocated&&!closed?1UL:0UL))
                    throw new Exception("REGRESSION publication model: "+string.Join(",",word));
                transitions++;
            } traces++;
        }
        void Walk(int depth) { if(depth==word.Length){Replay();return;} for(int e=0;e<11;e++){word[depth]=e;Walk(depth+1);} }
        Walk(0);
        Check(traces==1771561 && transitions==10629366,"managed observation enumeration complete");
        Console.WriteLine($"PASS publication model: depth6 alphabet11 traces={traces} transitions={transitions}; managed ownership and opaque native decisions only");
    }

    private static void BackingPublicationHandoff()
    {
        RunBackingPublicationHandoff(false);
        RunBackingPublicationHandoff(true);
    }

    private static void RunBackingPublicationHandoff(bool lateReplaced)
    {
        Session session = Open();
        using var probe = lateReplaced ? null : NativeBackingProbe.Open();
        if (probe != null) Set(session.Runtime, "BackingDecision", (Func<ulong, int>)probe.Decision);
        using var nextPublished = new ManualResetEventSlim();
        using var prepared = new ManualResetEventSlim();
        using var replace = new ManualResetEventSlim();
        Exception cpuError = null;
        Thread cpu = null;
        ulong firstOwner = 0;
        int allocations = 0, withdrawals = 0;
        // Delay the old phase's first native decision until the next phase publishes.
        Set(session.Runtime, "BackingDecision", (Func<ulong,int>)(owner => {
            if ((!lateReplaced && Thread.CurrentThread==cpu && !prepared.IsSet) ||
                (lateReplaced && Thread.CurrentThread!=cpu && !nextPublished.IsSet))
                if (!nextPublished.Wait(2000)) throw new Exception("next phase did not publish");
            return probe != null ? probe.Decision(owner) : BackingAuthority.test_decision(session.Authority,owner);
        }));
        Set(session.Runtime, "BackingProgress", (Func<ulong, int, ulong>)((owner, idle) =>
        {
            ulong accepted;
            lock (session.BackingLock)
            {
                accepted = Publish(session, owner, idle);
                if (accepted != 0) probe?.Publish(idle);
                if (owner == 0 && idle > 0) { allocations++; firstOwner = accepted; }
                if (idle == 0) withdrawals++;
            }
            if (idle > 0 && (lateReplaced ? Thread.CurrentThread == cpu && owner != 0 : Thread.CurrentThread != cpu)) nextPublished.Set();
            return accepted;
        }));
        cpu = new Thread(() =>
        {
            try
            {
                Call(session.Runtime, "BeginBackingChange", Address, Size, Source);
                prepared.Set();
                if (!replace.Wait(15_000)) throw new Exception("replacement not released");
                Call(session.Runtime, "EndBackingChange", Address, Size, 1);
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
        }) { IsBackground = true, Name = "late-Prepared" };
        cpu.Start();
        try
        {
            Check(prepared.Wait(3000) && cpuError == null, "Prepared handoff failed: " + cpuError);
            if (!lateReplaced) Check(nextPublished.IsSet, "fixture must delay Prepared until Replaced publishes");
            lock (session.BackingLock)
                Check(session.BackingOwner != 0 && session.BackingOwner == firstOwner && allocations == 1 && withdrawals == 0,
                    "REGRESSION: late first Prepared publication replaced/revoked the live transaction owner");
            if (probe != null)
            {
                probe.WaitReady();
                AndroidVulkanSurface.SetProducerForeground(false);
                probe.Lifecycle(false);
                Thread.Sleep(4200);
                Check(!probe.Exited && cpuError == null, "REGRESSION: real Prepared/Replaced handoff lost native admission in background");
                AndroidVulkanSurface.SetProducerForeground(true);
                probe.Lifecycle(true);
                Thread.Sleep(350); // 不发 S2ANoteAlive / 新 GAL 工作，不能靠重新发布掩盖撤销。
                Check(!probe.Exited, "REGRESSION: native admission expired before writer release after handoff/resume");
                probe.Release();
            }
        }
        finally { AndroidVulkanSurface.SetProducerForeground(true); replace.Set(); cpu.Join(3000); }
        Check(cpuError == null, "Finished handoff failed: " + cpuError);
        Check(nextPublished.IsSet, "late Prepared/Replaced schedule must reach the next phase publication");
        Check(session.BackingOwner == 0 && allocations == 1 && withdrawals == 1, "Finished closes exactly the transaction owner");
        session.Runtime.Stop();
        Check(session.Fatal == null && Get<bool>(session.Runtime, "_gpuDisposed"), "handoff stop failed: " + session.Fatal);
        NoViolations();
        Close(session);
    }

    private static void BackingWithoutSource()
    {
        Session session = Open();
        Push(session, 3);
        Check(SpinWait.SpinUntil(() => session.Barriers == 3 && Queued(session) == 0, 2000), "entries before the change were not executed");
        Exception cpuError = null;
        using var prepared = new ManualResetEventSlim();
        using var replaced = new ManualResetEventSlim();
        var cpu = new Thread(() =>
        {
            try
            {
                Call(session.Runtime, "BeginBackingChange", Address, Size, 0UL);
                prepared.Set();
                if (!replaced.Wait(5000)) throw new Exception("fixture replacement not released");
                Call(session.Runtime, "EndBackingChange", Address, Size, 1);
            }
            catch (Exception error) { cpuError = error; prepared.Set(); }
        }) { IsBackground = true };
        cpu.Start();
        Check(prepared.Wait(3000) && cpuError == null, "prepare without a source did not finish: " + cpuError);
        Check(Count("fence") == 1, $"REGRESSION: a source-less backing change must send only the first marker on the threaded path ({Count("fence")} fences)");
        Check(Get<long>(session.Runtime, "_s2aBcSkippedMarkers") == 1, "the skipped marker must be counted for the backing line");
        replaced.Set();
        Check(cpu.Join(3000) && cpuError == null, "native completion did not finish: " + cpuError);
        Check(!session.Handle.Unmapped && session.Handle.Dirty, "the new mapping must be adopted and dirtied");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null && Count("fence") == 2, "clean stop failed: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded source-less backing — one render-thread marker instead of two, mapping adopted, clean stop.");
    }

    // 出图节流里渲染线程卡住：第二帧的 Present 有界等，生产判据到了抛 TimeoutException，同一个异常进 fatal（宿主失败入口），Stop 返回它。
    private static void PresentThrottleStall()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            releaseRender.Wait(15000);
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not enter the stuck command");
        session.Threaded.Window.Present(null, default, null);   // 没有上一帧：过节流，排在卡住的命令后面
        Exception throttleError = null;
        long started = Stopwatch.GetTimestamp();
        try { session.Threaded.Window.Present(null, default, null); }
        catch (Exception error) { throttleError = error; }
        double waited = Ms(started);
        Check(throttleError is TimeoutException && throttleError.Message.Contains("出图节流"),
            "REGRESSION: the present throttle must time out with a render-stall diagnosis: " + throttleError);
        Check(waited >= 2000 && waited <= 2600, $"throttle stall diagnosed at {waited:F0} ms");
        Check(ReferenceEquals(session.Fatal, throttleError), "the stall must reach the host failure entry as the first failure");
        Exception stopError = null;
        try { session.Runtime.Stop(); } catch (Exception error) { stopError = error; }
        Check(ReferenceEquals(stopError, throttleError), "Stop must return the latched stall diagnosis: " + stopError);
        releaseRender.Set();
        Check(session.Render.Join(3000), "the render thread did not leave after the session failed");
        Close(session);
        Console.WriteLine($"PASS: threaded throttle stall — second present timed out at {waited:F0} ms with the diagnosis; fatal and Stop carry it.");
    }

    // 下层渲染器里的等待（Vulkan 计数队列 FlushTo 每 1 ms 醒一次调 S2AWaitCheck → S2AWaitTick，复审 P1-5）：渲染线程卡住时
    // 按生产判据判失败（不再无界自旋），同一个异常进 fatal；之后再调立刻按失败闩抛。
    private static void CounterWaitTick()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            releaseRender.Wait(15000);
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not enter the stuck command");
        Exception tickError = null;
        long started = Stopwatch.GetTimestamp();
        while (Ms(started) < 4000)
        {
            try { session.Threaded.S2AWaitTick("Vulkan 计数队列结果（夹具）"); }
            catch (Exception error) { tickError = error; break; }
            Thread.Sleep(1);
        }
        double waited = Ms(started);
        Check(tickError is TimeoutException && tickError.Message.Contains("计数队列"),
            "REGRESSION: a counter wait inside the backend must be bounded while the render thread is stuck: " + tickError);
        Check(waited >= 2000 && waited <= 2700 && ReferenceEquals(session.Fatal, tickError), $"counter wait diagnosed at {waited:F0} ms and must reach fatal");
        bool latched = false;
        try { session.Threaded.S2AWaitTick("again"); }
        catch (TimeoutException error) when (ReferenceEquals(error, tickError)) { latched = true; }
        Check(latched, "after the failure every backend wait tick must rethrow the latched exception");
        try { session.Runtime.Stop(); } catch (TimeoutException) { }
        releaseRender.Set();
        Check(session.Render.Join(3000), "the render thread did not leave after the session failed");
        Close(session);
        Console.WriteLine($"PASS: threaded counter wait — backend wait ticks diagnosed the stuck render thread at {waited:F0} ms; later ticks rethrow the latch.");
    }

    // 非 GPU 线程（写跟踪回调、计数线程等）等渲染线程的五处（复审测试缺口 1）：等缓冲建好（MapBufferBlocking）、等贴图视图建好
    // （SpinUntilNonNull）、等渲染线程锁（S2AEnterBase）、中断（Interrupt）、同步号登记（WaitSync）。每一处单独等（没有别的等待方帮它判），
    // 渲染线程卡住时都必须自己按生产判据判失败、抛进 fatal 的同一个异常，3.5 s 内返回。
    private static void NonGpuWaitsBounded()
    {
        var info = new TextureCreateInfo(64, 64, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
        MethodInfo interrupt = typeof(ThreadedRenderer).GetMethod("Interrupt", Private);
        var waits = new (string Name, Func<Session, Action> Prepare)[]
        {
            ("MapBufferBlocking", s =>
            {
                BufferHandle buffer = s.Threaded.CreateBuffer(16, BufferAccess.Default);   // 渲染线程卡着：缓冲建不好
                return () => s.Threaded.GetBufferData(buffer, 0, 16);
            }),
            ("SpinUntilNonNull", s =>
            {
                ITexture view = s.Texture.CreateView(info, 0, 0);
                return () => view.GetData();
            }),
            ("S2AEnterBase", s => () => s.Threaded.CreateTexture(info)),
            ("Interrupt", s => () =>
            {
                try { interrupt.Invoke(s.Threaded, new object[] { (Action)(() => { }) }); }
                catch (TargetInvocationException error) { throw error.InnerException; }
            }),
            ("WaitSync", s =>
            {
                s.Threaded.CreateSync(77, false);
                return () => s.Threaded.WaitSync(77);
            }),
        };
        foreach ((string name, Func<Session, Action> prepare) in waits)
        {
            Session session = Open();
            session.Texture = session.Threaded.CreateTexture(info);   // 非 GPU 线程：渲染线程卡住之前直接建好
            using var renderBlocked = new ManualResetEventSlim();
            using var releaseRender = new ManualResetEventSlim();
            session.Barrier = index =>
            {
                if (index != 1) return;
                renderBlocked.Set();
                releaseRender.Wait(15000);
            };
            Push(session, 1);
            Check(renderBlocked.Wait(2000), "render thread did not enter the stuck command");
            Action wait = prepare(session);
            Exception error = null;
            var waiter = new Thread(() =>
            {
                try { wait(); }
                catch (Exception caught) { error = caught; }
            }) { Name = "non-gpu-" + name, IsBackground = true };
            long started = Stopwatch.GetTimestamp();
            waiter.Start();
            Check(waiter.Join(3500), $"REGRESSION: the non-GPU wait in {name} is unbounded while the render thread is stuck");
            Check(error is TimeoutException && ReferenceEquals(error, session.Fatal), $"{name} must end with its own stall diagnosis in fatal, got: {error}");
            Check(Ms(started) >= 2000, $"{name} was diagnosed before 2000 ms without progress");
            try { session.Runtime.Stop(); } catch (TimeoutException) { }
            releaseRender.Set();
            Check(session.Render.Join(3000), "the render thread did not leave after the session failed");
            Close(session);
        }
        Console.WriteLine("PASS: threaded non-GPU waits — buffer map, texture view spin, render lock, interrupt and sync wait each diagnose a stuck render thread on their own.");
    }

    // 后台（Android 可能冻结整个进程）不计时：渲染线程卡住、节流在等，外壳切后台 3 s 不判失败——渲染线程卡着不 Poll，surface 的
    // Foreground 停在 true（复审 P1-2），判据必须看外壳的生命周期钟；回前台后重新计时，满判据才失败。
    private static void BackgroundPausesWatchdog()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            releaseRender.Wait(15000);
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not enter the stuck command");
        AndroidVulkanSurface.SetProducerForeground(false);
        session.Threaded.Window.Present(null, default, null);
        Exception throttleError = null;
        var presenter = new Thread(() =>
        {
            try { session.Threaded.Window.Present(null, default, null); }
            catch (Exception error) { throttleError = error; }
        }) { IsBackground = true };
        presenter.Start();
        Check(!presenter.Join(3000), "REGRESSION: the render-stall watchdog fired while the session was in the background");
        Check(session.Fatal == null, "a backgrounded wait must not fail the session: " + session.Fatal);
        Check(AndroidVulkanSurface.ForegroundValue, "fixture: the stuck render thread never polled, so the surface still says foreground");
        long resumed = Stopwatch.GetTimestamp();
        AndroidVulkanSurface.SetProducerForeground(true);
        Check(presenter.Join(3500), "the watchdog did not resume after returning to the foreground");
        double waited = Ms(resumed);
        Check(throttleError is TimeoutException && ReferenceEquals(session.Fatal, throttleError), "foreground stall must fail with the diagnosis: " + throttleError);
        Check(waited >= 2000, $"the foreground window must restart on resume (diagnosed {waited:F0} ms after it)");
        try { session.Runtime.Stop(); } catch (TimeoutException) { }
        releaseRender.Set();
        Check(session.Render.Join(3000), "the render thread did not leave after the session failed");
        Close(session);
        Console.WriteLine($"PASS: threaded background — no stall verdict during 3 s in the background; after resume diagnosed at {waited:F0} ms.");
    }

    // 渲染线程卡在长命令里时切后台（进程可能被冻结），3 s 后回前台、渲染线程随即走完（复审 P1-2「解冻后不误判」）：
    // 回前台换了生命周期纪元，卡住判据重新计时，不得把后台那段算进去；节流里等的出图正常返回、会话不失败。
    private static void ThawAfterLongCommand()
    {
        Session session = Open();
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            releaseRender.Wait(15000);
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not enter the long command");
        session.Threaded.Window.Present(null, default, null);
        Exception throttleError = null;
        var presenter = new Thread(() =>
        {
            try { session.Threaded.Window.Present(null, default, null); }
            catch (Exception error) { throttleError = error; }
        }) { IsBackground = true };
        presenter.Start();
        Thread.Sleep(500);
        AndroidVulkanSurface.SetProducerForeground(false);
        Thread.Sleep(3000);
        AndroidVulkanSurface.SetProducerForeground(true);
        Thread.Sleep(100);
        releaseRender.Set();
        Check(presenter.Join(3000), "the throttled present did not return after the render thread finished");
        Check(throttleError == null && session.Fatal == null,
            "REGRESSION: a long command across a background/foreground cycle must not be judged stalled: " + (throttleError ?? session.Fatal));
        session.Barrier = null;
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop after the thaw failed: " + session.Fatal);
        Close(session);
        Console.WriteLine("PASS: threaded thaw — 3.6 s in a long render command across background/foreground, released 100 ms after resume: no stall verdict.");
    }

    // 租约停止（宿主收回窗口，不经 Stop）：模拟线程自己退出主循环，按 排空 FIFO → 渲染线程 marker → 收局累计 → 渲染线程停 WSI / 证明退休
    // → 渲染线程释放下层 → 渲染线程退出 的顺序收局。之后不再调 Stop：单线程基线自退休后 Stop 同样会向已释放的 GPFIFO 事件发信号
    // （既有行为，两种模式相同，不在本改动范围）。
    private static void LeaseStoppingOrder()
    {
        Session session = Open();
        Push(session, 3);
        Check(SpinWait.SpinUntil(() => session.Barriers == 3, 2000), "entries before the lease stop were not executed");
        AndroidVulkanSurface.StoppingValue = true;
        session.Context.GPFifo.SignalNewEntries();
        Check(Get<ManualResetEventSlim>(session.Runtime, "_done").Wait(3000), "lease stopping did not end the GPU emulation loop");
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && Get<bool>(session.Runtime, "_renderWsiClosed"), "lease stop must retire WSI and dispose the GPU");
        Check(session.Render.Join(2000), "render thread did not exit after the lease stop");
        List<string> order;
        lock (Gate) order = _events.FindAll(e => e is "barrier" or "fence" or "wsi-stop" or "dispose");
        Check(string.Join(",", order) == "barrier,barrier,barrier,fence,wsi-stop,dispose",
            "stop order must be: queued work, render-thread marker, WSI stop, backend dispose (saw " + string.Join(",", order) + ")");
        Check(session.Fatal == null, "unexpected fatal: " + session.Fatal);
        NoViolations();
        Close(session);
        Console.WriteLine("PASS: threaded lease stop — the emulation loop exits on its own; marker, WSI stop and backend dispose run in order on the render thread.");
    }

    // 收局释放下层慢（复审 P1-6：编译通道 Join、管线缓存落盘、Vulkan 释放都在渲染线程的一条命令里，不泵不报活）：2400 ms 的释放
    // 超过 2000 + 250 ms 卡住判据，但收局阶段只受宿主停机期限（Stop 3000 ms）约束，不得判卡住、不得把 auto 记录固定成单线程。
    private static void SlowDisposeShutdown()
    {
        string state = TempDirectory();
        try
        {
            WriteRecord(state, ThreadedRecord(37.7));
            Session session = Open();
            Set(session.Runtime, "_auto", ThreadedAuto.Load(state));
            Push(session, 3);
            Check(SpinWait.SpinUntil(() => session.Barriers == 3, 2000), "entries before the stop were not executed");
            // 进程收局时渲染线程上的下层收尾（补存驱动管线缓存）慢 2400 ms
            Set(session.Runtime, "ExitPipelineSave", (Func<Task<bool>>)(() => { Note("exit-release"); Thread.Sleep(2400); return Task.FromResult(true); }));
            long stopping = Stopwatch.GetTimestamp();
            Exception stopError = null;
            try { session.Runtime.Stop(); } catch (Exception error) { stopError = error; }
            double took = Ms(stopping);
            Check(stopError == null && session.Fatal == null,
                "REGRESSION: a slow backend release during shutdown must not be judged a render-thread stall: " + (stopError ?? session.Fatal));
            Check(took >= 2400 && took < 3000 && Get<bool>(session.Runtime, "_gpuDisposed"), $"slow shutdown must still finish within the host stop deadline (took {took:F0} ms)");
            Check(Get<ThreadedAuto>(session.Runtime, "_auto").WaitWritten(3000) && OnDisk(state).Verdict == "threaded", "a slow shutdown must not pin the auto record");
            NoViolations();
            Close(session);
            Console.WriteLine($"PASS: threaded slow shutdown — a 2400 ms backend release finished in {took:F0} ms without a stall verdict or auto pin.");
        }
        finally { System.IO.Directory.Delete(state, true); }
    }

    // 宿主收局顺序（真机 9000 s2arm.finish：外壳先 onPause / Surface detached，原生收局线程再发 S2AShutdown 请求，之后才 Stop）：
    // 请求一到就停用卡住判据、打收局请求行；之后每 250 ms 一行进度（Stop 是否已到、模拟线程在哪一步 / 主循环转不转、渲染线程在执行什么、
    // 多久没执行完新命令、等渲染线程已满 50 ms 的每个线程等什么已等多久——含 guest 线程）；1200 ms 起报红，赶在原生 1500 ms 兜底之前
    // （不得静默丢缓存）；收完打用时；收得快就不报红。
    private static void HostShutdownSequence()
    {
        var info = new TextureCreateInfo(16, 16, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
        foreach (bool slow in new[] { false, true })
        {
            Session session = Open();
            Push(session, 2);
            Check(SpinWait.SpinUntil(() => session.Barriers == 2, 2000), "entries before the stop were not executed");
            using var disposing = new ManualResetEventSlim();
            if (slow) Set(session.Runtime, "ExitPipelineSave", (Func<Task<bool>>)(() => { Note("exit-release"); disposing.Set(); Thread.Sleep(1500); return Task.FromResult(true); }));
            // guest 线程（写跟踪回调形）在下层释放时进下层：等渲染线程锁，应出现在进度行里
            Thread writer = slow ? new Thread(() =>
            {
                disposing.Wait(5000);
                try { session.Threaded.CreateTexture(info); }
                catch (Exception error) when (error is ObjectDisposedException or InvalidOperationException) { }
            }) { Name = "guest-writer", IsBackground = true } : null;
            writer?.Start();
            var captured = new System.Text.StringBuilder();
            System.IO.TextWriter saved = Console.Error;
            Console.SetError(System.IO.TextWriter.Synchronized(new System.IO.StringWriter(captured)));
            long requested;
            try
            {
                AndroidVulkanSurface.SetProducerForeground(false);   // onPause / Surface detached 先到
                var native = new Thread(() => Call(session.Runtime, "OnHostShutdownRequested")) { Name = "native-shutdown" };
                requested = Stopwatch.GetTimestamp();
                native.Start();
                Check(native.Join(500), "the shutdown request callback must not block the native shutdown thread");
                Thread.Sleep(50);
                session.Runtime.Stop();
                Check(Get<ManualResetEventSlim>(session.Runtime, "_done").IsSet && Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null,
                    "the threaded shutdown did not complete after the host request: " + session.Fatal);
                if (slow) Thread.Sleep(Math.Max(0, 1400 - (int)Ms(requested)));
            }
            finally { Console.SetError(saved); }
            writer?.Join(3000);
            string log = captured.ToString();
            Check(log.Contains("拆线程收局请求") && log.Contains("卡住判据停用"), "the shutdown request must be logged at once: " + log);
            Check(log.Contains("拆线程收局完成：宿主收局请求后"), "the shutdown must log how long it took after the host request: " + log);
            if (slow)
            {
                Check(log.Contains("【黄】拆线程收局") && log.Contains("还没完成") && log.Contains("Stop 已到") && log.Contains("释放 GPU"),
                    "REGRESSION: a shutdown still running at 1200 ms must be reported yellow with its phase before the native 1500 ms backstop: " + log);
                Check(!log.Contains("【红】") && log.Contains("【黄】拆线程收局完成"), "a slow but successful shutdown must not be red, and must end with its yellow completion time: " + log);
                var ticks = System.Text.RegularExpressions.Regex.Matches(log, "拆线程收局 (\\d+) ms");
                Check(ticks.Count >= 4 && int.Parse(ticks[0].Groups[1].Value) <= 400,
                    $"REGRESSION: shutdown progress must be logged every 250 ms from the request ({ticks.Count} lines): " + log);
                Check(log.Contains("S2A.GPU 等") && log.Contains("guest-writer 等") && log.Contains("渲染线程正在执行") && log.Contains("没执行完新命令")
                    && log.Contains("主循环第"),
                    "progress lines must name what the emulation thread, the render thread and waiting guest threads are doing: " + log);
            }
            else
            {
                Check(!log.Contains("【红】") && Ms(requested) < 1000, "a fast shutdown must finish quietly well before 1000 ms: " + log);
            }
            Close(session);
        }
        Console.WriteLine("PASS: threaded host shutdown — request logged and stall verdicts off at once; progress every 250 ms names both threads and waiting guest threads; a 1500 ms release is red from 1200 ms with Stop and phase; a fast one stays quiet; completion time logged.");
    }

    // 宿主收局（Stop，进程马上 _exit）：GPU 层照常释放，下层不逐个释放、不销毁设备（S2ADiscardFrees + S2AExitRelease），渲染线程上只补存驱动管线缓存；
    // 收完打完成行与各步用时。真机 9000 01a3af10 逐个释放让「释放 GPU」一段超过 1 s、完成行一局都没打出来。租约 Stopping（进程不退出）照原样全量释放（LeaseStoppingOrder）。
    private static void ExitFastTeardown()
    {
        Session session = Open();
        BufferHandle buffer = session.Threaded.CreateBuffer(16, BufferAccess.Default);
        Push(session, 2);
        Check(SpinWait.SpinUntil(() => session.Barriers == 2 && Queued(session) == 0, 2000), "entries before the stop were not executed");
        int exitSaves = 0;
        Set(session.Runtime, "ExitPipelineSave", (Func<Task<bool>>)(() => { if (!OnRender) Violation("exit release ran off the render thread"); Interlocked.Increment(ref exitSaves); return Task.FromResult(true); }));
        var captured = new System.Text.StringBuilder();
        System.IO.TextWriter saved = Console.Error;
        Console.SetError(System.IO.TextWriter.Synchronized(new System.IO.StringWriter(captured)));
        long stopping = Stopwatch.GetTimestamp();
        try { session.Runtime.Stop(); }
        finally { Console.SetError(saved); }
        double took = Ms(stopping);
        string log = captured.ToString();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null && session.Render.Join(2000), "clean exit teardown failed: " + session.Fatal);
        Check(Count("dispose") == 0 && exitSaves == 1, $"REGRESSION: a process-exit teardown must not destroy the backend object by object ({Count("dispose")} backend disposes, {exitSaves} exit releases)");
        Check(session.Threaded.S2ADiscardFrees, "the exit teardown must stop queueing backend frees");
        long produced = session.Threaded.S2AProducedCommands;
        session.Threaded.DeleteBuffer(buffer);
        Check(session.Threaded.S2AProducedCommands == produced, "a backend free after the exit teardown began must not be queued");
        Check(log.Contains("拆线程收局完成") && log.Contains("WSI 退休") && log.Contains("GPU 层释放") && log.Contains("下层渲染器不逐个释放") && log.Contains("idleRetirements=7 fenceGraceFallbacks=3 revokeImmediateRetirements=1 deferredSemaphores=2 deferredFences=5"),
            "the exit teardown must log its completion with per-step times: " + log);
        NoViolations();
        Close(session);
        Console.WriteLine($"PASS: threaded exit teardown — GPU layer released, backend not destroyed object by object, pipeline cache topped up on the render thread, done in {took:F0} ms with step times.");
    }

    // auto 的请求速率 = 本局声明过的最小交换间隔（最高速率），与局后判读 score.py 同口径（formal4 9000：Wonder 跟不上时间隔 1 / 2 交替，
    // 按当前值取成了 30 Hz，把 52 Hz 判成「低于请求」）。只声明过间隔 2 的游戏仍是 30；不限（0）是无穷；没声明过 60。
    private static double RequestedAfter(params float[] intervals)
    {
        var runtime = new AndroidVulkanRuntime(1, 1, _ => { });
        foreach (float interval in intervals) runtime.ObserveFrameInterval(interval);
        return (double)typeof(AndroidVulkanRuntime).GetProperty("AutoRequestedHz", Private).GetValue(runtime);
    }

    private static void AutoRequestedRate()
    {
        Check(Math.Abs(RequestedAfter() - 60) < 0.01, "no declared interval must mean 60 Hz");
        Check(Math.Abs(RequestedAfter(1 / 60f, 2 / 60f, 1 / 60f, 2 / 60f) - 60) < 0.01,
            "REGRESSION: a game toggling swap interval 1 / 2 (adaptive fallback) still requests 60 Hz: " + RequestedAfter(1 / 60f, 2 / 60f, 1 / 60f, 2 / 60f));
        Check(Math.Abs(RequestedAfter(1 / 60f, 2 / 60f) - 60) < 0.01, "REGRESSION: ending on interval 2 must not lower the request to 30 Hz");
        Check(Math.Abs(RequestedAfter(2 / 60f) - 30) < 0.01, "a game that only declares interval 2 requests 30 Hz");
        Check(double.IsPositiveInfinity(RequestedAfter(1 / 60f, 0)), "an unbounded interval requests no limit");
        Check(Math.Abs(RequestedAfter(1 / 60f, float.NaN, -1) - 60) < 0.01, "invalid intervals are ignored");
        Console.WriteLine("PASS: threaded auto request — the smallest declared swap interval (score.py rule): 1/2 toggling = 60 Hz, only 2 = 30 Hz, 0 = unbounded.");
    }

    // 收局请求回调跑在原生收局线程的 S2A_CancelWaits 里：stderr 管道满（写日志阻塞）时也必须马上返回，日志交线程池写（复审第 2 轮 P2-B）。
    private static void ShutdownRequestNonBlocking()
    {
        Session session = Open();
        Push(session, 1);
        Check(SpinWait.SpinUntil(() => session.Barriers == 1, 2000), "entries before the stop were not executed");
        using var release = new ManualResetEventSlim();
        System.IO.TextWriter saved = Console.Error;
        var blocked = new BlockingWriter(release);
        Console.SetError(blocked);
        bool returned;
        try
        {
            var native = new Thread(() => Call(session.Runtime, "OnHostShutdownRequested")) { Name = "native-shutdown", IsBackground = true };
            native.Start();
            returned = native.Join(500);
            Check(SpinWait.SpinUntil(() => blocked.Writers > 0, 2000), "fixture: the request line must still be written (off the native thread)");
        }
        finally
        {
            release.Set();
            Console.SetError(saved);
        }
        Check(returned, "REGRESSION: the shutdown request callback must not write the log synchronously on the native shutdown thread");
        session.Runtime.Stop();
        Check(Get<bool>(session.Runtime, "_gpuDisposed") && session.Fatal == null, "clean stop failed: " + session.Fatal);
        Close(session);
        Console.WriteLine("PASS: threaded shutdown request — returns at once even when stderr blocks; the request line is written off the native thread.");
    }

    private sealed class BlockingWriter(ManualResetEventSlim release) : System.IO.TextWriter
    {
        public int Writers;
        public override System.Text.Encoding Encoding => System.Text.Encoding.UTF8;
        public override void Write(char value) { Interlocked.Increment(ref Writers); release.Wait(10_000); }
        public override void Write(string value) { Interlocked.Increment(ref Writers); release.Wait(10_000); }
        public override void WriteLine(string value) { Interlocked.Increment(ref Writers); release.Wait(10_000); }
    }

    // 驱动管线缓存落盘的先后（复审第 2 轮 P2-C）：提前落盘的后台写还没完时 Dispose 再存——两次写盘串行，旧快照不覆盖新快照。
    private static void PipelineSaveOrder()
    {
        var saves = new Ryujinx.Graphics.Vulkan.S2AVersionedSave();
        long early = saves.Take(), late = saves.Take();
        int inside = 0, overlap = 0;
        var order = new List<long>();
        bool Writer(long version, int ms)
        {
            if (Interlocked.Increment(ref inside) > 1) Interlocked.Increment(ref overlap);
            Thread.Sleep(ms);
            lock (order) order.Add(version);
            Interlocked.Decrement(ref inside);
            return true;
        }
        bool earlySkipped = false, lateSkipped = false;
        var first = new Thread(() => saves.Write(early, () => Writer(early, 300), out earlySkipped));
        first.Start();
        Thread.Sleep(50);
        var second = new Thread(() => saves.Write(late, () => Writer(late, 10), out lateSkipped));
        second.Start();
        Check(first.Join(3000) && second.Join(3000), "the saves did not finish");
        Check(overlap == 0, "REGRESSION: two pipeline cache writes must not run concurrently");
        Check(!earlySkipped && !lateSkipped && order.Count == 2 && order[0] == early && order[1] == late && saves.Written == late,
            $"the later snapshot must be the one left on disk (order {string.Join(",", order)}, written {saves.Written})");
        Check(saves.Write(early, () => Writer(early, 1), out bool staleSkipped) && staleSkipped && order.Count == 2 && saves.Written == late,
            "REGRESSION: an older snapshot written after a newer one must be skipped");
        Console.WriteLine("PASS: pipeline cache saves — serialized, the newer snapshot wins, an older one arriving late is skipped.");
    }

    // 定期落盘的写盘回执（#1423 复审）：定期在编译通道上不能为退出期限等写盘——bounded=false 立即返回、写盘继续在后台；
    // 收局路径 bounded 到点交后台（旧文件保留）、写成 / 写失败 / 写异常如实回报。
    private static void PipelineSaveAwait()
    {
        using var started = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        Task<bool> blocked = Task.Run(() => { started.Set(); release.Wait(5000); return true; });
        Check(started.Wait(2000), "fixture: the blocked cache write did not start");
        long began = Environment.TickCount64;
        Check(Ryujinx.Graphics.Vulkan.S2AVersionedSave.AwaitReceipt(blocked, 300, "（定期）", bounded: false) &&
            Environment.TickCount64 - began < 300 && !blocked.IsCompleted,
            "REGRESSION: a periodic pipeline cache save must not wait for the write on the compile lane");
        Check(!Ryujinx.Graphics.Vulkan.S2AVersionedSave.AwaitReceipt(blocked, 300, "（收局）", bounded: true) &&
            !blocked.IsCompleted,
            "the bounded exit-path wait must expire and leave the write running in the background");
        release.Set();
        Check(blocked.Wait(2000) && blocked.Result, "fixture: the blocked write did not finish");
        Check(Ryujinx.Graphics.Vulkan.S2AVersionedSave.AwaitReceipt(Task.FromResult(true), 300, "", bounded: true),
            "a completed cache write reports success");
        Check(!Ryujinx.Graphics.Vulkan.S2AVersionedSave.AwaitReceipt(Task.FromResult(false), 300, "", bounded: true),
            "a failed cache write reports failure");
        Check(!Ryujinx.Graphics.Vulkan.S2AVersionedSave.AwaitReceipt(
            Task.FromException<bool>(new InvalidOperationException("fixture")), 300, "", bounded: true),
            "a faulted cache write reports failure");
        Console.WriteLine("PASS: pipeline cache save receipt — periodic never waits for the write on the compile lane; the bounded exit wait expires into background.");
    }

    // 渲染线程执行命令抛错：模拟线程正在同步命令里等它，必须按原异常醒来，Stop 不挂死、对象保留。
    private static void RenderFailure()
    {
        Session session = Open();
        var failure = new InvalidOperationException("fixture render-thread failure");
        using var renderBlocked = new ManualResetEventSlim();
        using var releaseRender = new ManualResetEventSlim();
        session.Barrier = index =>
        {
            if (index != 1) return;
            renderBlocked.Set();
            if (!releaseRender.Wait(5000)) Violation("fixture render release timed out");
            throw failure;
        };
        Push(session, 1);
        Check(renderBlocked.Wait(2000), "render thread did not execute the failing command");

        Exception stopError = null;
        var stopper = new Thread(() =>
        {
            try { session.Runtime.Stop(); }
            catch (Exception error) { stopError = error; }
        });
        stopper.Start();
        var cancellation = Get<CancellationTokenSource>(session.Runtime, "_cancel");
        Check(SpinWait.SpinUntil(() => cancellation.IsCancellationRequested, 1000), "Stop did not cancel");
        Check(!stopper.Join(200), "Stop finished before the render thread released the GPU emulation thread");
        var failureLog = new System.Text.StringBuilder();
        System.IO.TextWriter savedError = Console.Error;
        Console.SetError(System.IO.TextWriter.Synchronized(new System.IO.StringWriter(failureLog)));
        releaseRender.Set();
        // 1000 ms < 渲染线程卡住判据（2000 ms）：放开靠失败闩当场唤醒，不是等卡住判据兜底。
        Check(stopper.Join(1000), "REGRESSION: render-thread failure did not promptly release the waiting GPU emulation thread (failure latch)");
        Check(ReferenceEquals(stopError, failure), "Stop must report the original render-thread exception, got: " + stopError);
        Check(ReferenceEquals(session.Fatal, failure), "fatal must receive the original render-thread exception");
        Check(session.Render.Join(2000), "failed render thread did not exit");
        Console.SetError(savedError);
        Check(failureLog.ToString().Contains("GPU Run 退出后") && failureLog.ToString().Contains("idleRetirements=7 fenceGraceFallbacks=3 revokeImmediateRetirements=1 deferredSemaphores=2 deferredFences=5"), "fatal exit must report WSI counters: " + failureLog);
        Check(!Get<bool>(session.Runtime, "_gpuDisposed"), "a failed session must retain GPU objects");
        Close(session);
        Console.WriteLine("PASS: threaded failure — render-thread exception releases the waiting GPU emulation thread with the original exception; Stop returns, objects retained.");
    }
}
