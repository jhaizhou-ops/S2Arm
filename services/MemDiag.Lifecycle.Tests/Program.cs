using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using Ryujinx.Common;
using S2A.Services;

internal static class Program
{
    private static int Main()
    {
        Environment.SetEnvironmentVariable("S2A_HEAP_AUDIT", null);
        Environment.SetEnvironmentVariable("S2A_MEMPROBE", null);
        S2AThreadAlloc.On = true;
        FieldInfo monitor = typeof(MemDiag).GetField("_monitorThread", BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("找不到实际监视线程");
        List<Thread> previous = new();
        try
        {
            for (int round = 1; round <= 20; round++)
            {
                S2AShutdown.Reset();
                MemDiag.Startup();
                Thread first = (Thread)monitor.GetValue(null);
                if (first == null || !first.IsAlive) throw new InvalidOperationException("监视线程没有实际启动");

                // A repeated startup must join its predecessor even without a shutdown request.
                MemDiag.Startup();
                Thread second = (Thread)monitor.GetValue(null);
                if (first.IsAlive || second == null || !second.IsAlive || ReferenceEquals(first, second))
                    throw new InvalidOperationException("重复 Startup 没有完成旧线程退出与新线程启动");

                Stopwatch watch = Stopwatch.StartNew();
                S2AShutdown.Request();
                MemDiag.Stop();
                MemDiag.Stop();
                if (second.IsAlive || monitor.GetValue(null) != null)
                    throw new InvalidOperationException("Stop 返回后仍有旧监视线程存活");
                if (watch.ElapsedMilliseconds >= 3000)
                    throw new InvalidOperationException("关停未及时唤醒 30 秒诊断等待");

                previous.Add(first);
                previous.Add(second);
                foreach (Thread thread in previous)
                    if (thread.IsAlive) throw new InvalidOperationException("前一轮监视线程重新存活");
                Console.WriteLine($"PASS {round}/20：两次实际启动、可取消等待、有界退出 {watch.ElapsedMilliseconds} ms");
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
        finally { MemDiag.Stop(); }
    }
}
