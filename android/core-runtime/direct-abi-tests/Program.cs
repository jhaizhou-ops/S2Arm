// C0：direct ABI 的托管端布局/校验向量；输出与 C 探针同 schema，由
// android/tests/direct_abi_compare.py 对拍，禁止只测单端。
using System;
using System.Runtime.InteropServices;
using System.Text;
using S2A.Android.Aot;

static unsafe class Program
{
    static int checks;
    static void Check(bool ok, string what)
    {
        checks++;
        if (!ok) throw new Exception("check " + checks + " failed: " + what);
    }
    static int Off<T>(string field) where T : struct => Marshal.OffsetOf<T>(field).ToInt32();

    static string LayoutJson()
    {
        var sb = new StringBuilder();
        sb.Append("{\"schema\":\"s2a-direct-abi-v1\",\"ptr\":").Append(IntPtr.Size);
        sb.Append(",\"sizes\":{\"status\":").Append(Marshal.SizeOf<DirectStatusV1>())
          .Append(",\"table\":").Append(Marshal.SizeOf<DirectApiV1>())
          .Append(",\"services_request\":").Append(DirectAbi.ServicesRequestV2Size - 16)
          .Append(",\"services_request_v2\":").Append(Marshal.SizeOf<DirectServicesRequestV2>())
          .Append(",\"runtime_status\":24")
          .Append(",\"runtime_request_v2\":").Append(Marshal.SizeOf<DirectRuntimeRequestV2>()).Append('}');
        sb.Append(",\"offsets\":{");
        sb.Append("\"status.state\":").Append(Off<DirectStatusV1>(nameof(DirectStatusV1.State)))
          .Append(",\"status.blockers\":").Append(Off<DirectStatusV1>(nameof(DirectStatusV1.Blockers)))
          .Append(",\"status.error\":").Append(Off<DirectStatusV1>(nameof(DirectStatusV1.Error)))
          .Append(",\"status.reserved\":").Append(Off<DirectStatusV1>(nameof(DirectStatusV1.Reserved)))
          .Append(",\"table.session\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Session)))
          .Append(",\"table.context\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Context)))
          .Append(",\"table.activate\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Activate)))
          .Append(",\"table.request_stop\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.RequestStop)))
          .Append(",\"table.query\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Query)))
          .Append(",\"table.poll\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Poll)))
          .Append(",\"table.destroy\":").Append(Off<DirectApiV1>(nameof(DirectApiV1.Destroy)))
          .Append(",\"services_v2.graphics\":").Append(Off<DirectServicesRequestV2>(nameof(DirectServicesRequestV2.Graphics)))
          .Append(",\"services_v2.graphics_mode\":").Append(Off<DirectServicesRequestV2>(nameof(DirectServicesRequestV2.GraphicsMode)))
          .Append(",\"services_v2.flags\":").Append(Off<DirectServicesRequestV2>(nameof(DirectServicesRequestV2.Flags)))
          .Append(",\"runtime_v2.services\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.Services)))
          .Append(",\"runtime_v2.module_dir\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.ModuleDir)))
          .Append(",\"runtime_v2.module_names\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.ModuleNames)))
          .Append(",\"runtime_v2.module_count\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.ModuleCount)))
          .Append(",\"runtime_v2.program_id\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.ProgramId)))
          .Append(",\"runtime_v2.module_source\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.ModuleSource)))
          .Append(",\"runtime_v2.npdm_path\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.NpdmPath)))
          .Append(",\"runtime_v2.graphics\":").Append(Off<DirectRuntimeRequestV2>(nameof(DirectRuntimeRequestV2.Graphics))).Append("}}");
        return sb.ToString();
    }

    static void Validation()
    {
        var s = default(DirectStatusV1);
        Check(DirectAbi.StatusInit(ref s) == DirectAbi.Ok && s.Size == 24 && s.Version == 1, "status init");
        Check(DirectAbi.StatusCheck(s) == DirectAbi.Ok, "status ok");
        s.Version = 2; Check(DirectAbi.StatusCheck(s) == DirectAbi.VersionMismatch, "version"); s.Version = 1;
        s.Size = 16; Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "short"); s.Size = 24;
        s.Blockers = 64; Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "blocker"); s.Blockers = 0;
        s.State = (uint)DirectState.Stopped; s.Blockers = (uint)DirectBlocker.Present;
        Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "stopped blockers"); s.Blockers = 0;
        s.State = (uint)DirectState.Failed;
        Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "failed no cause");
        s.Error = DirectAbi.Driver; Check(DirectAbi.StatusCheck(s) == DirectAbi.Ok, "failed cause");
        s.Error = 7; Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "positive error");
        s = default; DirectAbi.StatusInit(ref s); s.Reserved = 1;
        Check(DirectAbi.StatusCheck(s) == DirectAbi.Argument, "reserved");

        var t = default(DirectApiV1);
        Check(DirectAbi.TableCheck(t) == DirectAbi.Argument, "empty table");
        t.Size = 64; t.Version = 1; t.Session = 0xabc; t.Context = 1;
        t.Activate = t.RequestStop = t.Query = t.Poll = t.Destroy = 1;
        Check(DirectAbi.TableCheck(t) == DirectAbi.Ok, "table ok");
        t.Version = 2; Check(DirectAbi.TableCheck(t) == DirectAbi.VersionMismatch, "table version"); t.Version = 1;
        t.Session = 0; Check(DirectAbi.TableCheck(t) == DirectAbi.Argument, "table session"); t.Session = 0xabc;
        t.Destroy = 0; Check(DirectAbi.TableCheck(t) == DirectAbi.Argument, "table entry"); t.Destroy = 1;
        // 定长/偏移必须与契约一致，不能只信 Marshal 的当次结果。
        Check(Marshal.SizeOf<DirectStatusV1>() == 24 && Marshal.SizeOf<DirectApiV1>() == 64, "fixed sizes");
        Check(Marshal.SizeOf<DirectServicesRequestV2>() == 80 && Marshal.SizeOf<DirectRuntimeRequestV2>() == 160, "request sizes");
    }

    // ---- direct 会话生命周期（bind → activate → stop → destroy）：用假 native 表验证顺序与错误映射 ----
    static int activateCalls, stopCalls, destroyCalls, activateResult = DirectAbi.Ok;
    static int pollCalls, pollResult, pollDelayMs;
    static uint lastPollBudget;
    static bool fakeSessionStopped;

    [UnmanagedCallersOnly]
    static int FakeActivate(nint context) { activateCalls++; return activateResult; }
    [UnmanagedCallersOnly]
    static int FakeStop(nint context) { stopCalls++; return 0; }
    [UnmanagedCallersOnly]
    static int FakeDestroy(nint context) { destroyCalls++; return 0; }
    [UnmanagedCallersOnly]
    static int FakePoll(nint context, uint budget)
    {
        pollCalls++;
        lastPollBudget = budget;
        if (pollDelayMs > 0) System.Threading.Thread.Sleep(pollDelayMs);
        return fakeSessionStopped ? DirectAbi.Stopped : pollResult;
    }
    [UnmanagedCallersOnly]
    static int FakeQuery(nint context, DirectStatusV1* status)
    {
        status->State = (uint)DirectState.Active;
        status->Blockers = 0;
        status->Error = 0;
        status->Reserved = 0;
        return 0;
    }

    static unsafe DirectApiV1 FakeTable()
    {
        var t = default(DirectApiV1);
        t.Size = DirectAbi.TableSize;
        t.Version = DirectAbi.Version;
        t.Session = 0x1234;
        t.Context = 0x5678;
        t.Activate = (nint)(delegate* unmanaged<nint, int>)&FakeActivate;
        t.RequestStop = (nint)(delegate* unmanaged<nint, int>)&FakeStop;
        t.Query = (nint)(delegate* unmanaged<nint, DirectStatusV1*, int>)&FakeQuery;
        t.Poll = (nint)(delegate* unmanaged<nint, uint, int>)&FakePoll;
        t.Destroy = (nint)(delegate* unmanaged<nint, int>)&FakeDestroy;
        return t;
    }

    static void Session()
    {
        activateCalls = stopCalls = destroyCalls = 0;
        activateResult = DirectAbi.Ok;

        var invalid = default(DirectApiV1);
        bool threw = false;
        try { _ = new DirectSession(in invalid); } catch (ArgumentException) { threw = true; }
        Check(threw, "session rejects an invalid table");

        // 没 bind 就 activate：参数错误，而且不能碰到 native 的 activate。
        var table = FakeTable();
        var session = new DirectSession(in table);
        Check(session.Activate() == DirectAbi.Argument && activateCalls == 0, "activate before bind");

        // 编译入口为 0：参数错误。
        Check(session.BindCompiler(0) == DirectAbi.Argument && !session.Bound, "bind without compile entry");

        // binder 失败（例如没有这条 native 符号）：不发布 Bound，Activate 仍然被拒。
        Check(session.BindCompiler(1, (nint ctx, nint compile) => DirectAbi.Unsupported) == DirectAbi.Unsupported
              && !session.Bound, "bind failure");
        Check(session.Activate() == DirectAbi.Argument && activateCalls == 0, "activate after failed bind");

        // 正常路径。
        Check(session.BindCompiler(1, (nint ctx, nint compile) => ctx == 0x5678 && compile == 1 ? DirectAbi.Ok : DirectAbi.Argument)
              == DirectAbi.Ok && session.Bound, "bind ok");
        Check(session.Activate() == DirectAbi.Ok && session.Activated && activateCalls == 1, "activate ok");
        Check(session.Activate() == DirectAbi.Argument && activateCalls == 1, "activate twice");
        Check(session.Query(out var status) == DirectAbi.Ok && status.State == (uint)DirectState.Active, "query active");
        Check(session.RequestStop() == DirectAbi.Ok && session.Stopped && stopCalls == 1, "stop ok");
        Check(session.RequestStop() == DirectAbi.Stopped, "stop twice");
        Check(session.Destroy() == DirectAbi.Ok && session.Destroyed && destroyCalls == 1, "destroy ok");
        Check(session.Destroy() == DirectAbi.Ok && destroyCalls == 1, "destroy twice is idempotent");
        Check(session.Activate() == DirectAbi.Stopped && activateCalls == 1, "activate after destroy");

        // activate 失败（驱动错误）：负码不当成功，也不发布 Activated。
        activateCalls = 0;
        activateResult = DirectAbi.Driver;
        var failing = FakeTable();
        var failSession = new DirectSession(in failing);
        Check(failSession.BindCompiler(1, (nint ctx, nint compile) => DirectAbi.Ok) == DirectAbi.Ok, "bind for failure path");
        Check(failSession.Activate() == DirectAbi.Driver && !failSession.Activated && failSession.LastError == DirectAbi.Driver,
              "activate failure is not success");
        activateResult = DirectAbi.Ok;
    }

    static DirectSession ActivatedSession()
    {
        var table = FakeTable();
        var session = new DirectSession(in table);
        Check(session.BindCompiler(1, (nint ctx, nint compile) => DirectAbi.Ok) == DirectAbi.Ok, "owner bind");
        Check(session.Activate() == DirectAbi.Ok, "owner activate");
        return session;
    }

    static bool WaitUntil(Func<bool> condition, int timeoutMs)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (!condition() && sw.ElapsedMilliseconds < timeoutMs) System.Threading.Thread.Sleep(5);
        return condition();
    }

    // ---- F4.4 owner 控制：DirectSession.Poll + DirectOwnerLoop 的真实调用/拒绝/有界收尾 ----
    static void Owner()
    {
        pollCalls = 0; pollResult = 0; pollDelayMs = 0; fakeSessionStopped = false; lastPollBudget = 0;

        // 未 Activate 的会话不能 poll（不能把控制片打到未就绪的 native context）。
        var idleTable = FakeTable();
        var idle = new DirectSession(in idleTable);
        Check(idle.Poll() == DirectAbi.Argument && pollCalls == 0, "poll before activate is refused");

        var session = ActivatedSession();
        pollCalls = 0;
        pollResult = DirectAbi.Ok;
        Check(session.Poll(25) == DirectAbi.Ok && lastPollBudget == 10,
              "owner poll clamps the budget to 10 ms and accepts OK");
        Check(pollCalls == 1, "owner poll actually calls the native entry");
        pollResult = DirectAbi.Pending;
        Check(session.Poll() == DirectAbi.Pending && session.LastError == DirectAbi.Ok,
              "PENDING is an in-flight obligation, not a failure");
        pollResult = DirectAbi.Driver;
        Check(session.Poll() == DirectAbi.Driver && session.LastError == DirectAbi.Driver,
              "a negative poll result is retained as the first error");
        pollResult = 0;

        // 正常循环：持续 poll；Stop 请求后由 native 的 STOPPED 收尾，循环在预算内退出。
        pollResult = DirectAbi.Pending;
        var loop = new DirectOwnerLoop();
        Check(loop.Start(session, (rc, why) => { }) == DirectAbi.Ok, "owner loop starts");
        Check(loop.Start(session) == DirectAbi.Stopped, "second owner loop is refused while the first runs");
        Check(WaitUntil(() => loop.Slices >= 4, 2000), "owner loop keeps polling");
        Check(loop.PendingSlices >= 1 && loop.Running, "owner loop records PENDING slices");
        fakeSessionStopped = true;
        Check(session.RequestStop() == DirectAbi.Ok, "request stop");
        Check(loop.Stop(1500), "owner loop exits within the bounded stop budget");
        Check(!loop.Running, "owner loop is not running after Stop");
        Check(loop.StopReason.Contains("session stopped"), "STOPPED is the normal owner-loop terminal state");

        // poll 失败：只通知一次、保留负码，循环不能把失败当成继续工作。
        fakeSessionStopped = false;
        pollResult = DirectAbi.Retirement;
        int notified = 0, notifiedCode = 0;
        var failingSession = ActivatedSession();
        var failing = new DirectOwnerLoop();
        Check(failing.Start(failingSession, (rc, why) => { notified++; notifiedCode = rc; }) == DirectAbi.Ok,
              "failing owner loop starts");
        Check(WaitUntil(() => !failing.Running, 2000), "a poll failure exits the owner loop");
        Check(notified == 1 && notifiedCode == DirectAbi.Retirement,
              "poll failure reaches the owner failure callback exactly once");
        Check(failing.LastError == DirectAbi.Retirement, "first poll error retained");
        Check(failing.Stop(1000), "failed loop joins without a timeout");

        // 有界 Stop：轮询卡在驱动调用时，第一次 Stop 必须如实返回 false；线程退出后第二次回收。
        pollResult = 0;
        pollDelayMs = 250;
        var slowSession = ActivatedSession();
        var slow = new DirectOwnerLoop();
        Check(slow.Start(slowSession, (rc, why) => { }) == DirectAbi.Ok, "slow owner loop starts");
        Check(WaitUntil(() => slow.Slices >= 1, 2000), "slow loop entered a poll");
        Check(!slow.Stop(50), "a blocked poll must not be joined past the stop budget");
        Check(WaitUntil(() => !slow.Running, 3000), "the blocked poll eventually returns and observes the deadline");
        Check(slow.TimedOut, "stop budget exhaustion is recorded");
        Check(slow.Stop(1000), "a later stop reclaims the exited loop");
        pollDelayMs = 0;

        Check(session.Destroy() == DirectAbi.Ok, "owner session destroy");
        Check(session.Poll() == DirectAbi.Stopped && session.LastError == DirectAbi.Stopped,
              "poll after destroy is a terminal Stopped, not a native call");
    }

    static int Main()
    {
        Console.WriteLine(LayoutJson());
        Validation();
        Session();
        Owner();
        Console.WriteLine("direct-abi-cs: ok (" + checks + " checks)");
        return 0;
    }
}
