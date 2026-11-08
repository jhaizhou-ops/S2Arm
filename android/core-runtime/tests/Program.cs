using S2A.Android.Aot;
using S2A.Services;
using Ryujinx.HLE.HOS.SystemState;
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

internal static unsafe class Program
{
    private static int _checks, _registerCalls, _renderCalls, _stopCalls;
    private static bool _registerReject;
    private static string _language = "zh-Hans-CN", _region = "CN", _zone = "UTC";
    private static int _inputFailure, _textMode, _inputMode;
    private static nint _observedHost;
    private static uint _observedMode;
    private static CsApi* _registeredApi;
#if FULL_RUNTIME
    private static bool _cancelDuringMode;
#endif
    private static readonly nint ExpectedHost = 0x1234;

    private static void Check(bool value, string message)
    {
        _checks++;
        if (!value) throw new Exception(message);
    }
    private static void Throws(Action action, string message)
    {
        _checks++;
        try { action(); }
        catch (Exception) { return; }
        throw new Exception(message);
    }
    private static void Offset<T>(string name, int offset) => Check(Marshal.OffsetOf<T>(name).ToInt32() == offset, name + " ABI offset");

    private static void Main(string[] args)
    {
        if (args.Length == 1 && args[0].StartsWith("memory-", StringComparison.Ordinal))
        {
            try
            {
                SharedMemoryTests.Run(Check, args[0]);
                Console.WriteLine($"Actual service memory {args[0]}: {_checks} assertions passed; host only");
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                Environment.ExitCode = 1;
            }
            return;
        }
        if (args.Length == 1 && args[0] == "memdiag")
        {
            long footprint = MemDiag.Footprint();
            bool apple = OperatingSystem.IsMacOS() || OperatingSystem.IsIOS();
            Check(apple ? footprint > 0 : footprint == -1, "real platform footprint or explicit unavailable");
            if (!OperatingSystem.IsIOS()) Check(MemDiag.Available() == -1, "iOS-only process budget remains unavailable elsewhere");
            string snapshot = MemDiag.Snapshot();
            Check(snapshot.Contains("GC 堆", StringComparison.Ordinal), "GC diagnostics remain present");
            Check(!snapshot.Contains("-1 MB", StringComparison.Ordinal), "unknown metric cannot look like a byte count");
            if (!OperatingSystem.IsIOS()) Check(snapshot.Contains("取不到（当前平台不提供此指标）", StringComparison.Ordinal), "missing platform metric is explicit");
            Environment.SetEnvironmentVariable("S2A_MEMPROBE", null);
            MemDiag.Startup();
            Console.WriteLine($"Actual memory diagnostics: {_checks} assertions passed; OS={RuntimeInformation.OSDescription} footprint={footprint}");
            return;
        }
        if (args.Length == 1 && args[0].StartsWith("resource-", StringComparison.Ordinal))
        {
            ResourceTests(args[0]);
            Console.WriteLine($"Actual resource consumers {args[0]}: {_checks} assertions passed; host only");
            return;
        }
#if FULL_RUNTIME
        if (args.Length == 1 && (args[0].StartsWith("shutdown-", StringComparison.Ordinal) || args[0].StartsWith("cancel-export-", StringComparison.Ordinal)))
        {
            using HostFixture host = new();
            typeof(AndroidGameRuntime).GetField("_host", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
                .SetValue(null, host.Bind());
            int expectedStops = ShutdownTests.Run(Check, args[0]);
            Check(_stopCalls == expectedStops, "actual HostApi stop notification count matches outcome");
            Console.WriteLine($"Android shutdown {args[0]}: {_checks} assertions passed; actual production UCO and cleanup, fixture excludes HLE/GPU");
            return;
        }
        if (args.Length == 2 && args[0].StartsWith("attach-", StringComparison.Ordinal))
        {
            using HostFixture host = new();
            typeof(AndroidGameRuntime).GetField("_host", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
                .SetValue(null, host.Bind());
            bool failed = AttachThreadTests.Run(Check, args[0], args[1]);
            Check(_stopCalls == (failed ? 1 : 0), "only an actual fatal attachment sends HostApi stop, once");
            Console.WriteLine($"Android thread attachment {args[0]}: {_checks} assertions passed; actual production entry, host only, not Android NativeAOT");
            return;
        }
#endif
        if (args.Length == 1 && args[0].StartsWith("horizon-", StringComparison.Ordinal))
        {
            Action<Exception> failure = null;
#if FULL_RUNTIME
            using HostFixture host = new();
            var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
            var runtime = typeof(AndroidGameRuntime);
            var state = (AndroidServiceState)runtime.GetField("State", flags).GetValue(null);
            Check(state.Begin(7) == ServiceError.Ok, "real Android runtime begins Starting");
            runtime.GetField("_host", flags).SetValue(null, host.Bind());
            failure = (Action<Exception>)runtime.GetMethod("OnServiceFailure", flags).CreateDelegate(typeof(Action<Exception>));
            if (args[0] == "horizon-late") Check(state.Complete() == ServiceError.Ok, "fixture enters late-failure boundary");
#endif
            bool failed = HorizonStartupTests.Run(Check, args[0], failure);
#if FULL_RUNTIME
            if (failed)
            {
                Check(state.Snapshot().State == (uint)ServiceState.Failed, "real async failure revokes Starting/Ready");
                Check(state.Snapshot().Error == (int)ServiceError.Initialize, "real async error retains Initialize category");
                Check(_stopCalls == 1, "async failure emits exactly one actual HostApi stop");
                failure(new InvalidOperationException("subsequent failure does not send a second stop"));
                AndroidServicesStatus status = new() { Size = 24, Version = 1 };
                delegate* unmanaged<ulong, AndroidServicesStatus*, int> stop = &AndroidGameRuntime.RequestStop;
                Check(stop(7, &status) == 0, "subsequent explicit stop accepted as request");
                Check(_stopCalls == 1, "failure plus repeated stop remains one HostApi notification");
            }
#endif
            Console.WriteLine($"Actual Horizon startup {args[0]}: {_checks} assertions passed; host only, no complete HLE/GPU initialization");
            return;
        }
        if (args.Length == 1 && args[0].StartsWith("arp", StringComparison.Ordinal))
        {
            ArpRegistrationTests.Run(Check, args[0] == "arp-issue");
            Console.WriteLine($"Actual ARP production classes: {_checks} assertions passed; host only, kernel event excluded");
            return;
        }
        if (args is ["hostui-strict-message"] or ["hostui-strict-screenshot"])
        {
            // 独立进程：FailFast 不能在主夹具进程内捕获。维护方确认严格模式保持原有行为。
            Red.Reset();
            Red.Strict = true;
            var ui = new HostUi();
            if (args[0] == "hostui-strict-message") ui.DisplayMessageDialog("标题", "内容");
            else ui.TakeScreenshot();
            throw new Exception("严格模式应在报红时终止进程");
        }
        if (args is ["hostui-nohook"])
        {
            // 负控（验收用）：绕开安卓装配直接 new HostUi() —— 软键盘挂点缺失，同一条用例必红在挂点断言
            HostUiTests.Run(Check, () => new HostUi());
            Console.WriteLine($"hostui-nohook: {_checks} assertions passed（不应到达：挂点断言应先红）");
            return;
        }
#if FULL_RUNTIME
        if (args.Length != 0)
        {
            RuntimeTests(args[0]);
            Console.WriteLine($"Android runtime {args[0]}: {_checks} assertions passed; real production consumer, failure path only");
            return;
        }
#endif
        Check(sizeof(AndroidServicesRequest) == 64, "request ABI size");
        Check(sizeof(AndroidServicesStatus) == 24, "status ABI size");
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.Session), 8);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.NativeOwner), 16);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.HostApi), 24);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.GameDataDirectory), 32);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.StateDirectory), 40);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.LeaseApi), 48);
        Offset<AndroidServicesRequest>(nameof(AndroidServicesRequest.ConsoleMode), 56);
        Offset<AndroidServicesStatus>(nameof(AndroidServicesStatus.State), 16);
        Offset<AndroidServicesStatus>(nameof(AndroidServicesStatus.Error), 20);
        Check(sizeof(AndroidHostApi.Api) == 80 && sizeof(AndroidHostApi.InputState) == 40, "HostApi prefix sizes");
        Offset<AndroidHostApi.Api>(nameof(AndroidHostApi.Api.Stop), 72);
        Offset<AndroidHostApi.InputState>(nameof(AndroidHostApi.InputState.TimestampNs), 32);
        Check((int)ServiceError.Cleanup == -9 && (uint)ServiceState.StopRequested == 4 && (uint)ServiceState.Stopped == 5, "native enum values");
        StateTests();
        HostTests();
        ServicesTests();
        using (HostFixture uiHost = new(ui: true))
            HostUiTests.Run(Check, () => AndroidHostUi.Create(uiHost.Bind()));
        Console.WriteLine($"Android services production contracts: {_checks} assertions passed; host only, no guest/GPU/Android readiness claim");
    }

    private static void StateTests()
    {
        var fresh = new AndroidServiceState();
        Check(fresh.Complete() != ServiceError.Ok, "cannot complete an unstarted session");
        Check(fresh.Begin(0) == ServiceError.Argument, "zero session");
        Check(fresh.Begin(7) == ServiceError.Ok, "begin");
        Check(fresh.Snapshot().State == (uint)ServiceState.Starting, "not ready after begin");
        Check(fresh.Begin(7) == ServiceError.AlreadyUsed && fresh.Begin(8) == ServiceError.AlreadyUsed, "no duplicate session");
        Check(fresh.RequestStop(8) == ServiceError.Argument, "wrong-session stop");
        Check(fresh.Complete() == ServiceError.Ok, "ready only after completion");
        Check(fresh.RequestStop(7) == ServiceError.Ok, "stop request");
        Check(fresh.Snapshot().State == (uint)ServiceState.StopRequested, "stop is not quiesced");
        Check(fresh.Complete() == ServiceError.StopRequested, "stop cannot be overwritten by late completion");
        fresh.Fail(ServiceError.Gpu);
        Check(fresh.Snapshot().State == (uint)ServiceState.Failed, "late GPU error revokes readiness");
        Check(fresh.RequestStop(7) == ServiceError.Ok && fresh.Snapshot().Error == (int)ServiceError.Gpu, "stop preserves fatal cause");
        for (int run = 0; run < 40; run++)
        {
            var raced = new AndroidServiceState();
            int started = 0;
            Parallel.For(0, 8, n => { if (raced.Begin((ulong)(n + 1)) == ServiceError.Ok) Interlocked.Increment(ref started); });
            Check(started == 1, "single lifecycle winner");
            Parallel.Invoke(() => raced.Complete(), () => raced.Fail(ServiceError.Initialize));
            Check(raced.Snapshot().State == (uint)ServiceState.Failed, "failure survives concurrent ready");
            Check(raced.Begin(99) == ServiceError.AlreadyUsed, "failure is terminal");
            var stopped = new AndroidServiceState(); stopped.Begin(7);
            Parallel.Invoke(() => stopped.Complete(), () => stopped.RequestStop(7));
            Check(stopped.Snapshot().State == (uint)ServiceState.StopRequested, "stop survives concurrent ready");
        }
    }

    private sealed class HostFixture : IDisposable
    {
        internal AndroidHostApi.Api* Api;
        internal HostFixture(bool ui = false)
        {
            Api = (AndroidHostApi.Api*)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.Api));
            Api->Header = H(sizeof(AndroidHostApi.Api)); Api->Capabilities = 1 | 4 | 8 | 64; Api->Host = ExpectedHost;
            Api->User = (AndroidHostApi.User*)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.User));
            *Api->User = new() { Header = H(sizeof(AndroidHostApi.User)), Language = &Language, Region = &Region, TimeZone = &Zone };
            Api->Input = (AndroidHostApi.Input*)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.Input));
            *Api->Input = new() { Header = H(sizeof(AndroidHostApi.Input)), Read = &Input };
            Api->Display = (AndroidHostApi.Display*)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.Display));
            *Api->Display = new()
            {
                Header = H(sizeof(AndroidHostApi.Display)),
                Info = (nint)(delegate* unmanaged<nint, AndroidHostApi.DisplayInfo*, int>)&ReadDisplayInfo,
                SetMode = &SetMode,
            };
            Api->Stop = (AndroidHostApi.Stop*)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.Stop));
            *Api->Stop = new() { Header = H(sizeof(AndroidHostApi.Stop)), Request = &Stop };
            if (ui)
            {
                Api->Ui = (nint)NativeMemory.AllocZeroed((nuint)sizeof(AndroidHostApi.Ui));
                *(AndroidHostApi.Ui*)Api->Ui = new()
                {
                    Header = H(sizeof(AndroidHostApi.Ui)),
                    Begin = &HostUiTests.UiBegin, Wait = &HostUiTests.UiWait, Cancel = &HostUiTests.UiCancel,
                };
                Api->Capabilities |= 16;
            }
        }
        internal AndroidHostApi Bind(uint mode = 1) => new((nint)Api, mode);
        public void Dispose()
        {
            if (Api->Ui != 0) NativeMemory.Free((void*)Api->Ui);
            NativeMemory.Free(Api->User); NativeMemory.Free(Api->Input); NativeMemory.Free(Api->Display); NativeMemory.Free(Api->Stop); NativeMemory.Free(Api);
        }
    }
    private static AndroidHostApi.Header H(int size) => new() { Size = (uint)size, Version = 1 };
    private static int Text(nint host, byte* output, nuint cap, string text)
    {
        _observedHost = host;
        if (_textMode == 1) { new Span<byte>(output, (int)cap).Fill(65); return 0; }
        if (_textMode == 2) { output[0] = 0xff; output[1] = 0; return 0; }
        if (_textMode == 3) return -3;
        byte[] bytes = Encoding.UTF8.GetBytes(text + "\0");
        if ((nuint)bytes.Length > cap) return -3;
        bytes.CopyTo(new Span<byte>(output, (int)cap)); return 0;
    }
    [UnmanagedCallersOnly] private static int Language(nint host, byte* output, nuint cap) => Text(host, output, cap, _language);
    [UnmanagedCallersOnly] private static int Region(nint host, byte* output, nuint cap) => Text(host, output, cap, _region);
    [UnmanagedCallersOnly] private static int Zone(nint host, byte* output, nuint cap) => Text(host, output, cap, _zone);
    [UnmanagedCallersOnly] private static int ReadDisplayInfo(nint host, AndroidHostApi.DisplayInfo* info)
    {
        _observedHost = host;
        *info = new()
        {
            Size = (uint)sizeof(AndroidHostApi.DisplayInfo),
            AbiVersion = 1,
            Width = 1920,
            Height = 1080,
            RefreshMilliHz = 60000,
            Rotation = 0,
            DpiX = 0,
            DpiY = 0,
        };
        return 0;
    }

    [UnmanagedCallersOnly] private static int SetMode(nint host, uint mode)
    {
        _observedHost = host; _observedMode = mode;
#if FULL_RUNTIME
        if (_cancelDuringMode)
        {
            var status = new AndroidServicesStatus { Size = 24, Version = 1 };
            delegate* unmanaged<ulong, AndroidServicesStatus*, int> stop = &AndroidGameRuntime.RequestStop;
            Check(stop(7, &status) == 0, "stop during actual HostApi callback");
        }
#endif
        return 0;
    }
    [UnmanagedCallersOnly] private static void Stop(nint host, uint reason, byte* detail) { _observedHost = host; _stopCalls++; }
    [UnmanagedCallersOnly] private static int Input(nint host, AndroidHostApi.InputState* output)
    {
        _observedHost = host;
        if (_inputFailure != 0) return _inputFailure;
        *output = new() { Size = 40, Version = 1, Buttons = 0x123, LeftX = -32768, LeftY = 32767, RightX = 7, RightY = -8, TimestampNs = 1234567 };
        if (_inputMode == 1) output->Size = 32;
        if (_inputMode == 2) output->Version = 2;
        if (_inputMode == 3) output->LeftX = -32769;
        return 0;
    }

    private static void HostTests()
    {
        Throws(() => new AndroidHostApi(0, 0), "null table");
        using var f = new HostFixture();
        AndroidHostApi host = f.Bind();
        Check(host.Language == "zh-Hans-CN" && host.Region == "CN" && host.TimeZone == "UTC", "actual frozen HostApi text");
        Check(_observedHost == ExpectedHost && _observedMode == 1, "host context and console mode");
        var input = host.ReadInput();
        Check(input.Buttons == 0x123 && input.LeftX == -32768 && input.LeftY == 32767 && input.RightX == 7 && input.RightY == -8, "real input callback values");
        Check(input.TimestampNs == 1234567, "input timestamp retained, not guest clock");
        host.RequestStop(3, "test failure"); Check(_stopCalls == 1 && _observedHost == ExpectedHost, "real stop callback");
        f.Api->Header.Size = 79; Throws(() => f.Bind(), "short table"); f.Api->Header.Size = 88;
        Check(f.Bind().Language == _language, "extended prefix accepted"); f.Api->Header.Size = 80;
        f.Api->Header.Version = 2; Throws(() => f.Bind(), "ABI version"); f.Api->Header.Version = 1;
        f.Api->Capabilities &= ~4UL; Throws(() => f.Bind(), "missing input cap"); f.Api->Capabilities |= 4;
        f.Api->Capabilities |= 128; Throws(() => f.Bind(), "unknown cap"); f.Api->Capabilities &= ~128UL;
        f.Api->User->Header.Size = 24; Throws(() => f.Bind(), "short user table"); f.Api->User->Header.Size = 32;
        f.Api->Input->Read = null; Throws(() => f.Bind(), "missing read callback"); f.Api->Input->Read = &Input;
        f.Api->Stop->Request = null; Throws(() => f.Bind(), "missing stop callback"); f.Api->Stop->Request = &Stop;
        for (_textMode = 1; _textMode <= 3; _textMode++) Throws(() => f.Bind(), "bad text rejected"); _textMode = 0;
        _region = "usa"; Throws(() => f.Bind(), "invalid country"); _region = "";
        Check(f.Bind().Region == "", "absent region allowed"); _region = "CN";
        _inputFailure = -5; Throws(() => f.Bind(), "failed first snapshot"); _inputFailure = 0;
        for (_inputMode = 1; _inputMode <= 3; _inputMode++) Throws(() => host.ReadInput(), "invalid runtime snapshot"); _inputMode = 0;
        Throws(() => f.Bind(2), "invalid console mode");
        byte[] path = Encoding.UTF8.GetBytes("/中文 空格/game\0");
        fixed (byte* p = path) Check(AndroidHostApi.ReadPath(p) == "/中文 空格/game", "UTF8 path");
    }

    private static uint HandleNew(uint kind, ulong cookie) => 1;
    private static ulong FailedEvent(uint* read, uint* write) { if (read != null) *read = 0; return 0; }
    [UnmanagedCallersOnly] private static int DetMode() => 0;
    [UnmanagedCallersOnly] private static void DetWrite(ulong address, void* bytes, ulong size) { }
    [UnmanagedCallersOnly] private static ulong GuestTick() => 1;
    private static int Register(CsApi* api)
    {
        _registerCalls++;
        _registeredApi = api;
        Check(api != null && api->Size == sizeof(CsApi), "actual CsApi size");
        Check(api->Svc != null && api->HandleClosed != null && api->ThreadExit != null && api->Shutdown != null, "actual service callbacks registered");
        return _registerReject ? -1 : 0;
    }
    private static void ResourceTests(string scenario)
    {
        string root = Path.Combine(Path.GetTempPath(), "s2a-resource-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string game = Path.Combine(root, "game"), state = Path.Combine(root, "state");
            Directory.CreateDirectory(Path.Combine(game, "exefs"));
            Directory.CreateDirectory(Path.Combine(game, "ctl"));
            Directory.CreateDirectory(Path.Combine(game, "romfs"));
            if (scenario == "resource-control")
            {
                string target = Path.Combine(root, "control-blob"), control = Path.Combine(game, "ctl/control.nacp");
                File.WriteAllBytes(Path.Combine(root, "npdm-blob"), new byte[1]);
                File.CreateSymbolicLink(Path.Combine(game, "exefs/main.npdm"), "../../npdm-blob");
                File.WriteAllBytes(target, new byte[0x4000]);
                File.CreateSymbolicLink(control, "../../control-blob");
                var configuration = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish,
                    RegionCode.USA, "UTC", false, AndroidHostUi.Create());
                Red.Strict = false; Red.Log = _ => { };
                Native.HandleNew = &HandleNew;
                Native.GuestTick = &GuestTick; Native.DetMode = &DetMode; Native.DetHostWrite = &DetWrite;
                Native.EventCreate = &FailedEvent;
                Exports.RendererFactory = () => throw new Exception("fixture must stop at native self-check");
                Exports.AfterBoot = (_, _) => { }; Exports.BeforeShutdown = () => { }; Exports.ServiceFailure = _ => { };
                string Error()
                {
                    try { Exports.Initialize(configuration); }
                    catch (Exception error) { return error.Message; }
                    throw new Exception("fixture unexpectedly initialized");
                }
                Check(Error().StartsWith("Native provider self-check failed:", StringComparison.Ordinal),
                    "valid symlink resources pass actual validation and reach the controlled native self-check");
                foreach (int length in new[] {0, 0x3fff, 0x4001})
                {
                    File.WriteAllBytes(target, new byte[length]);
                    Check(Error().Contains("complete NACP", StringComparison.Ordinal), "actual target length must remain exactly 0x4000");
                }
                File.Delete(target);
                Check(!Error().StartsWith("Native provider self-check failed:", StringComparison.Ordinal), "dangling target cannot pass validation");
                File.Delete(control); File.WriteAllBytes(control, new byte[0x4000]);
                Check(Error().StartsWith("Native provider self-check failed:", StringComparison.Ordinal), "ordinary NACP still accepted");
                return;
            }
            Check(scenario == "resource-romfs", "known resource scenario");
            string direct = Path.Combine(root, "direct"), linked = Path.Combine(root, "linked");
            Directory.CreateDirectory(direct); Directory.CreateDirectory(linked);
            byte[] data = new byte[513];
            for (int i = 0; i < data.Length; i++) data[i] = (byte)(i * 31);
            File.WriteAllBytes(Path.Combine(direct, "asset"), data);
            File.CreateSymbolicLink(Path.Combine(linked, "asset"), "../direct/asset");
            byte[] Read(LibHac.Fs.IStorage storage)
            {
                using (storage)
                {
                    LibHac.Result result = storage.GetSize(out long length);
                    Check(result.IsSuccess(), "actual RomFS size available");
                    byte[] image = new byte[checked((int)length)];
                    Check(storage.Read(0, image).IsSuccess(), "actual RomFS data read succeeds");
                    return image;
                }
            }
            Red.Strict = true;
            byte[] ordinary = Read(S2A.Services.Application.RomFsFromDirectory(direct));
            byte[] symlink = Read(S2A.Services.Application.RomFsFromDirectory(linked));
            Check(ordinary.AsSpan().SequenceEqual(symlink), "directory-built RomFS uses the exact target bytes and size");
            string directIndex = Path.Combine(root, "direct.idx"), linkedIndex = Path.Combine(root, "linked.idx");
            RomFsIndex.Write(direct, directIndex); RomFsIndex.Write(linked, linkedIndex);
            Check(File.ReadAllBytes(directIndex).AsSpan().SequenceEqual(File.ReadAllBytes(linkedIndex)), "indexed metadata is identical for symlink target");
            Check(ordinary.AsSpan().SequenceEqual(Read(RomFsIndex.Open(linked, linkedIndex))), "indexed lazy data matches whole ordinary image");
            File.Delete(Path.Combine(direct, "asset"));
            Throws(() => S2A.Services.Application.RomFsFromDirectory(linked), "dangling data rejected by directory builder");
            Throws(() => RomFsIndex.Write(linked, Path.Combine(root, "broken.idx")), "dangling data rejected by index writer");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void ServicesTests()
    {
        string root = Path.Combine(Path.GetTempPath(), "s2a-services-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string game = Path.Combine(root, "game"), state = Path.Combine(root, "state");
            Directory.CreateDirectory(Path.Combine(game, "exefs"));
            Directory.CreateDirectory(Path.Combine(game, "ctl"));
            Directory.CreateDirectory(Path.Combine(game, "romfs"));
            File.WriteAllBytes(Path.Combine(game, "exefs/main.npdm"), new byte[1]);
            File.WriteAllBytes(Path.Combine(game, "ctl/control.nacp"), new byte[0x4000]);
            var ui = AndroidHostUi.Create();
            Check(ui.DisplayInputDialog(default, out string autoText) && autoText == "Player", "zero-config keyboard auto-answer");
            Throws(() => ui.ShowPlayerSelectDialog(), "player choice without a live session must not select");
            string frozenTag = "zh-Hans-CN";
            var configuration = new HostConfiguration(game, state, SystemLanguage.SimplifiedChinese, RegionCode.China, "UTC", true, ui,
                saveDirectory: state, systemLanguageTag: () => frozenTag, memoryFootprint: () => 28672);
            Check(configuration.SaveDirectory == state && configuration.SystemLanguageTag() == "zh-Hans-CN" &&
                configuration.MemoryFootprint() == 28672, "host fields retain platform-owned path and delegates");
            Throws(() => new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui,
                saveDirectory: "relative"), "relative save root rejected");
            Throws(() => new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui,
                saveDirectory: Path.Combine(game, "saves")), "save root cannot be inside game data");
            string saveAlias = Path.Combine(root, "game-link");
            Directory.CreateSymbolicLink(saveAlias, game);
            Throws(() => new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui,
                saveDirectory: Path.Combine(saveAlias, "saves")), "save root symlink cannot lead into game data");
            Directory.CreateDirectory(state);
            string outsideAlias = Path.Combine(root, "state-link");
            Directory.CreateSymbolicLink(outsideAlias, state);
            var outsideSave = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui,
                saveDirectory: Path.Combine(outsideAlias, "saves"));
            Check(outsideSave.SaveDirectory == Path.Combine(outsideAlias, "saves"), "safe save symlink outside game remains accepted");
            Throws(() => new HostConfiguration(game + Path.DirectorySeparatorChar,
                Path.Combine(game, "state"), SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui),
                "trailing separator cannot hide state below immutable game data");
            Throws(() => new HostConfiguration(Path.GetPathRoot(game), state,
                SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui),
                "filesystem root cannot be treated as disjoint game data");
            Red.Strict = false;
            Red.Log = _ => { };
            Throws(() => Exports.Initialize(configuration), "unbound provider rejected");
            Native.HandleNew = &HandleNew;
            Throws(() => Exports.Initialize(configuration), "missing renderer/worker rejected");
            Exports.RendererFactory = () => { _renderCalls++; throw new Exception("must not create renderer"); };
            Exports.AfterBoot = (_, _) => { }; Exports.BeforeShutdown = () => { };
            Exports.ServiceFailure = _ => { };
            Throws(() => Exports.Initialize(configuration), "missing clock/det group rejected");
            Native.GuestTick = &GuestTick; Native.DetMode = &DetMode; Native.DetHostWrite = &DetWrite;
            Native.EventCreate = &FailedEvent;
            Throws(() => Exports.Initialize(configuration), "real native self-check failure propagates");
            Check(_renderCalls == 0 && Host.Device == null, "failed core does not construct renderer/HLE");
            Native.RegisterCs = &Register;
            _registerReject = true; Throws(Exports.RegisterChecked, "registration return failure propagates");
            _registerReject = false; Exports.RegisterChecked();
            Check(_registerCalls == 2, "real checked registration calls once each");
            int shutdowns = 0;
            Exports.ShutdownHandler = () => shutdowns++;
            _registeredApi->Shutdown(null);
            Check(shutdowns == 1, "native registered shutdown calls platform owner");
            Exports.ShutdownHandler = null;
            var unsupportedZone = new HostConfiguration(game, state, SystemLanguage.SimplifiedChinese, RegionCode.China, "Asia/Shanghai", true, ui);
            Environment.SetEnvironmentVariable("S2A_SYSTEM_LANGUAGE", "Japanese");
            Environment.SetEnvironmentVariable("S2A_DOCKED", "0");
            Environment.SetEnvironmentVariable("S2A_SAVE_DIR", game);
            Throws(() => Host.Boot(null, null, state, unsupportedZone), "missing locked timezone must not silently use host zone");
            Check(Host.Device == null, "timezone failure occurs before service creation");
            Check(Host.Language == SystemLanguage.SimplifiedChinese && Host.Docked, "typed HostApi values override legacy environment");
            Check(Saves.Dir() == null, "persistent session never imports/clears seed saves");
            Check(File.Exists(Path.Combine(game, "exefs/main.npdm")), "original game/seed preserved");
        }
        finally { Directory.Delete(root, true); }
    }

#if FULL_RUNTIME
    private static void RuntimeTests(string scenario)
    {
        delegate* unmanaged<AndroidServicesRequest*, AndroidServicesStatus*, int> start = &AndroidGameRuntime.Start;
        delegate* unmanaged<ulong, AndroidServicesStatus*, int> status = &AndroidGameRuntime.Status;
        delegate* unmanaged<ulong, AndroidServicesStatus*, int> stop = &AndroidGameRuntime.RequestStop;
        var result = new AndroidServicesStatus { Size = 24, Version = 1 };
        if (scenario == "arguments")
        {
            Check(start(null, null) == -1, "null output");
            Check(start(null, &result) == -1 && result.State == 0, "null request does not consume session");
            var shortRequest = new AndroidServicesRequest { Size = 63, Version = 1 };
            Check(start(&shortRequest, &result) == -1 && result.State == 0, "short request");
            shortRequest.Size = 64; shortRequest.Version = 2;
            Check(start(&shortRequest, &result) == -2 && result.State == 0, "wrong request version");
            Check(stop(7, &result) == -1 && result.State == 0, "unstarted stop");
            Check(status(7, &result) == -1 && result.State == 0, "unstarted query");
            return;
        }
        using var host = new HostFixture();
        byte[] game = Encoding.UTF8.GetBytes("/game-data\0"), state = Encoding.UTF8.GetBytes("/persistent-state\0");
        if (scenario == "path")
        {
            game = Encoding.UTF8.GetBytes("/game-data/\0");
            state = Encoding.UTF8.GetBytes("/game-data/state\0");
        }
        fixed (byte* gamePath = game, statePath = state)
        {
            var request = new AndroidServicesRequest { Size = 64, Version = 1, Session = 7,
                NativeOwner = NativeLibrary.GetMainProgramHandle(), HostApi = (nint)host.Api,
                GameDataDirectory = gamePath, StateDirectory = statePath, LeaseApi = 1, ConsoleMode = 1 };
            if (scenario == "host") host.Api->Capabilities &= ~4UL;
            else if (scenario is "cancel" or "cancel-waker")
            {
                _cancelDuringMode = true;
                if (scenario == "cancel-waker") Ryujinx.Common.S2AShutdown.OnRequest(() => throw new InvalidOperationException("injected service wake failure"));
            }
            else Check(scenario is "provider" or "path", "known scenario");
            int rc = start(&request, &result);
            Check(Exports.CancelWaitsHandler != null, "actual start installs cancellation owner before service initialization");
            int expected = scenario is "host" or "path" ? -5 : scenario == "cancel" ? -8 : scenario == "cancel-waker" ? -9 : -4;
            Check(rc == expected && result.Error == expected, "failure code remains observable");
            Check(result.State == (scenario == "cancel" ? 4U : 3U) && result.Session == 7, "failure cannot report Ready");
            Check(Host.Device == null, "failure never constructs HLE");
            Check(Native.GuestTick == null && Native.DetMode == null && Native.DetHostWrite == null,
                "missing game provider group remains absent (Native.Ready alone is not admission)");
            Check(start(&request, &result) == -3, "failed/stopped session cannot restart");
            Check(status(7, &result) == 0 && result.Error == expected, "status carries actual first outcome");
            Check(status(8, &result) == -1, "wrong-session status rejected");
            Check(stop(8, &result) == -1, "wrong-session stop rejected");
            Check(stop(7, &result) == 0 && result.Error == expected, "stop preserves original cause");
            if (scenario != "host") Check(_stopCalls == 1, "failure reaches real HostApi stop callback exactly once");
        }
    }
#endif
}
