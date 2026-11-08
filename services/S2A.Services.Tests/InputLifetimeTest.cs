using System;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void InputLifetimeTest(bool selfOnly = false)
        {
            int calls = 0;
            using var called = new ManualResetEventSlim(false);
            InputPump.TouchHook = _ => { Interlocked.Increment(ref calls); called.Set(); };
            try
            {
                if (!selfOnly)
                {
                InputPump.Start(Host.Device);
                bool first = called.Wait(2000);
                InputPump.Stop();
                int before = Volatile.Read(ref calls);
                called.Reset();
                InputPump.Start(Host.Device);
                bool second = called.Wait(2000) && Volatile.Read(ref calls) > before;
                InputPump.Stop();
                Check("输入泵停止后重启：两次均收到真实采样回调", "True / True", $"{first} / {second}");
                }

                bool rejected = false;
                called.Reset();
                InputPump.TouchHook = _ =>
                {
                    try { InputPump.Stop(); }
                    catch (InvalidOperationException) { rejected = true; }
                    called.Set();
                };
                InputPump.Start(Host.Device);
                bool entered = called.Wait(2000);
                InputPump.Stop();
                Check("输入泵采样回调内不能自停后释放会话", "True / True", $"{entered} / {rejected}");
            }
            finally
            {
                InputPump.Stop();
                InputPump.TouchHook = null;
            }
        }
    }
}
