using Ryujinx.Memory;
using System;
using System.IO;

namespace S2A.Services.Tests
{
    // 共享内存创建失败不漏 fd（11-01 全量审计 P2-31）：size = ulong.MaxValue 转成 nint 是 -1，ftruncate 必回 EINVAL，CreateSharedMemory 抛异常。
    //   判法按「最小可用 fd」语义：先开一次 /dev/null 记下它拿到的号 X 再关掉；失败的创建里 shm_open 拿到的就是 X；
    //   之后再开 /dev/null 仍拿到 X = 失败路径把 fd 关了。连做 3 次，期望 3 次都抛、3 次 fd 号都回到 X。旧代码不关 → 每次号往上涨，判红
    public static partial class Program
    {
        [SoloTest("--shm-create-fail-fd")]
        private static int SharedMemoryCreateFailFd()
        {
            static long Probe() { using Microsoft.Win32.SafeHandles.SafeFileHandle h = File.OpenHandle("/dev/null"); return h.DangerousGetHandle().ToInt64(); }
            int threw = 0, same = 0;
            for (int i = 0; i < 3; i++)
            {
                long x = Probe();
                try { MemoryManagement.CreateSharedMemory(ulong.MaxValue, false); }
                catch (SystemException) { threw++; }
                if (Probe() == x) same++;
            }
            string expect = "3 / 3", actual = $"{threw} / {same}";
            bool ok = expect == actual;
            Console.WriteLine($"{(ok ? "✓" : "✗")} 共享内存创建失败（抛异常次数 / fd 号回到原位次数）：{expect} → {actual}");
            return ok ? 0 : 1;
        }
    }
}
