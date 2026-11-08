using System;
using System.Reflection;
using System.Threading;
using Ryujinx.Horizon;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Real Host.Boot and registered Horizon managers; the shutdown caller is
        // a fresh managed thread with no HorizonStatic registration.
        private static int AppleShutdownThreadTest()
        {
            if (!WaitFor(() => HorizonHost.Services.Length > 0, 10000))
                throw new InvalidOperationException("Horizon ports did not register");
            int ports = HorizonHost.Services.Length;
            nint shutdown = typeof(Exports).GetMethod("Shutdown", BindingFlags.NonPublic | BindingFlags.Static).MethodHandle.GetFunctionPointer();
            bool initiallyUnregistered = false, returned = false;
            var thread = new Thread(() =>
            {
                initiallyUnregistered = HorizonStatic.Syscall == null;
                ((delegate* unmanaged<byte*, void>)shutdown)(null);
                returned = true;
            }) { IsBackground = true };
            thread.Start();
            bool joined = thread.Join(15000);
            var threads = (System.Collections.Generic.List<Thread>)typeof(HorizonHost).GetField("_threads", BindingFlags.NonPublic | BindingFlags.Static).GetValue(null);
            bool allStopped = joined && threads.TrueForAll(t => !t.IsAlive);
            bool ok = initiallyUnregistered && returned && allStopped;
            Console.WriteLine($"Apple 新线程真实 Shutdown：端口={ports}，起始无 Syscall={initiallyUnregistered}，返回={returned}，服务线程全退出={allStopped} {(ok ? "✓" : "✗")}");
            return ok ? 0 : 1;
        }
    }
}
