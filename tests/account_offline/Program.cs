using System.Reflection;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Account;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Account.Acc.AccountService;
using Ryujinx.HLE.HOS.Services.Account.Acc.AsyncContext;

static class Program
{
    static readonly ResultCode Offline = (ResultCode)((200 << 9) | 124);
    static int checks;
    static void Check(bool condition, string name) { checks++; if (!condition) throw new Exception("FAIL " + name); Console.WriteLine("PASS " + name); }
    // Dispatch by the production CMIF command attributes; only transport/objects are simulated.
    static ResultCode Call(object obj, int command, ServiceCtx ctx)
    {
        var method = obj.GetType().GetMethods().Single(m => m.GetCustomAttribute<CommandCmifAttribute>()?.Id == command);
        return (ResultCode)method.Invoke(obj, new object[] { ctx });
    }
    static void NoOutput(ServiceCtx c, string name) => Check(c.ResponseData.BaseStream.Length == 0 && c.OutputObject == null, name);
    static void Async(object obj, int command)
    {
        var c = new ServiceCtx();
        Check(Call(obj, command, c) == ResultCode.Success && c.OutputObject != null, $"{command} synchronous object success");
        var child = c.OutputObject; var wait = new ServiceCtx();
        Check(SpinWait.SpinUntil(() => { var t = new ServiceCtx(); Call(child, 2, t); return ((MemoryStream)t.ResponseData.BaseStream).ToArray()[0] != 0; }, 5000), $"{command} finishes");
        Check(Call(child, 3, wait) == Offline, $"{command} GetResult offline error");
        var execution = (AsyncExecution)typeof(IAsyncContext).GetField("AsyncExecution", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(child)!;
        Check(SpinWait.SpinUntil(() => execution.SystemEvent.ReadableEvent.IsSignaled(), 5000), $"{command} completion event");
        execution.SystemEvent.ReadableEvent.Clear();
        Check(Call(child, 3, new ServiceCtx()) == Offline, $"{command} offline error survives event clear");
        if (command == 170) { var value = new ServiceCtx(); Check(Call(child, 100, value) == Offline, "170 value error"); NoOutput(value, "170 no fake license"); }
    }
    static void Main()
    {
        Check((int)Offline == 102524, "124-200 numeric encoding");
        object app = new IManagerForApplication(new UserId(), new AccountManager());
        object sys = new IManagerForSystemService(new UserId());
        foreach (var (obj, cmds) in new[] { (app, new[] {0, 1, 3, 4, 130}), (sys, new[] {0, 1, 3, 4}) })
            foreach (int id in cmds) { var c = new ServiceCtx(); Check(Call(obj, id, c) == Offline, $"{obj.GetType().Name}/{id} offline"); NoOutput(c, $"{id} no fake output"); }
        Async(app, 2); Async(sys, 2); Async(app, 170);
        var store = new ServiceCtx(); Check(Call(app, 160, store) == ResultCode.Success && store.Device.System.AccountManager.Stored == 1, "160 stores opened users");
        // Positive and pre-completion controls on the real async object, including event auto-clear.
        var ev = new KEvent(null); var ex = new AsyncExecution(ev); var a = new IAsyncContext(ex);
        Check(Call(a, 3, new ServiceCtx()) == ResultCode.AsyncExecutionNotInitialized, "uninitialized error");
        var release = new TaskCompletionSource(); ex.Initialize(5000, _ => release.Task);
        Check(Call(a, 3, new ServiceCtx()) == ResultCode.Unknown41, "pending error");
        release.SetResult(); Check(SpinWait.SpinUntil(() => ex.IsDone && ev.ReadableEvent.IsSignaled(), 5000), "success signals");
        ev.ReadableEvent.Clear(); Check(Call(a, 3, new ServiceCtx()) == ResultCode.Success, "success survives event clear");
        Console.WriteLine($"PASS all {checks} checks");
    }
}
