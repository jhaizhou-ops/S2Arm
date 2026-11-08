// Minimal host transport and kernel seams: the account command handlers and async execution are production sources.
using System.IO;
namespace Ryujinx.Horizon.Common { enum Result { Success } }
namespace Ryujinx.Common.Logging
{
    enum LogClass { ServiceAcc }
    static class Logger { public static Log Stub => null; public static Log Warning => null; }
    class Log { public void PrintStub(LogClass c, object value = null) {} public void Print(LogClass c, string s) {} }
}
namespace Ryujinx.HLE.HOS.Kernel.Threading
{
    class KEvent
    {
        public KEvent(object context) {} public Readable ReadableEvent { get; } = new();
        public class Readable { private int signaled; public void Signal() => Interlocked.Exchange(ref signaled, 1); public bool IsSignaled() => Volatile.Read(ref signaled) != 0; public void Clear() => Interlocked.Exchange(ref signaled, 0); }
    }
}
namespace Ryujinx.HLE.HOS.Ipc { class IpcHandleDesc { public static object MakeCopy(int handle) => handle; } }
namespace Ryujinx.HLE.HOS
{
    class ServiceCtx
    {
        public object OutputObject; public BinaryWriter ResponseData = new(new MemoryStream());
        public Device Device = new(); public Process Process = new(); public Response Response = new();
    }
    class Device { public DeviceSystem System = new(); }
    class DeviceSystem { public object KernelContext = new(); public Services.Account.Acc.AccountManager AccountManager = new(); }
    class Process { public HandleTable HandleTable = new(); }
    class HandleTable { public Ryujinx.Horizon.Common.Result GenerateHandle(object o, out int handle) { handle = 1; return 0; } }
    class Response { public object HandleDesc; }
    [AttributeUsage(AttributeTargets.Method)] class CommandCmifAttribute(int id) : Attribute { public int Id = id; }
    class IpcService { protected void MakeObject(ServiceCtx c, IpcService o) => c.OutputObject = o; }
    class DisposableIpcService : IpcService { protected virtual void Dispose(bool isDisposing) {} }
}
namespace Ryujinx.HLE.HOS.Services.Account.Acc
{
    struct UserId {}
    class AccountManager { public void ApplicationOpened(UserId u) {} public void ApplicationClosed(UserId u) {} public int Stored; public void StoreOpenedUsers() { Stored++; } }
}
