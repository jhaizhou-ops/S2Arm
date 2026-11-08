using System;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private sealed class BlockingService : IpcService, IDisposable
        {
            internal readonly ManualResetEventSlim Entered = new(false);
            internal readonly ManualResetEventSlim Release = new(false);
            internal int Disposals;
            internal bool DisposedWhileExecuting;

            [CommandCmif(0)]
            public ResultCode Execute(ServiceCtx ctx)
            {
                Entered.Set();
                if (!Release.Wait(5000)) throw new TimeoutException("受控请求未释放");
                DisposedWhileExecuting = Volatile.Read(ref Disposals) != 0;
                return ResultCode.Success;
            }

            public void Dispose() => Interlocked.Increment(ref Disposals);
        }

        private static void InflightCloseTest()
        {
            foreach (bool cloned in new[] { false, true })
            {
                var service = new BlockingService();
                var target = new HleTarget(service);
                uint original = Dispatcher.Instance.NewSessionHandle(target);
                uint handle = cloned ? Dispatcher.Instance.NewSessionHandle(target.Clone()) : original;
                Task<Reply> request = Task.Run(() => CallTlr(_tlr2, handle, Msg.Cmif(0)));
                bool entered = service.Entered.Wait(2000);
                Task<bool> closing = null;
                bool closed = false, aliveDuring = false, completed = false;
                uint result = uint.MaxValue;
                try
                {
                    if (entered)
                    {
                        closing = Task.Run(() =>
                        {
                            bool first = FakeNative.HandleClose(original) == 1;
                            return first && (!cloned || FakeNative.HandleClose(handle) == 1);
                        });
                        closed = closing.Wait(2000) && closing.Result;
                        aliveDuring = Volatile.Read(ref service.Disposals) == 0;
                    }
                }
                finally
                {
                    service.Release.Set();
                    completed = request.Wait(5000);
                    if (completed) result = request.Result.Result;
                    if (closing != null) closing.Wait(5000);
                }
                Check($"{(cloned ? "原件与 clone" : "最后句柄")}关闭与真实 IPC 并发：请求完成前不销毁，完成后恰好一次", "True / True / True / True / 0 / False / 1",
                    $"{entered} / {closed} / {aliveDuring} / {completed} / {result} / {service.DisposedWhileExecuting} / {service.Disposals}");
            }
        }
    }
}
