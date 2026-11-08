using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace S2A.Services.Tests
{
    // ro LoadNro 的托管分配判据（同 #1302 截图那条的拆法）。要防的是「整段 NRO 拷成托管数组」（10-20 普查高风险：new byte[nroSize] + NroExecutable.Program）。
    //   原判据的假映射回 5（本环境不支持）→ S2AMapNro 走 default 分支打红：Convert.ToHexString + 格式化串 + Red.Report 首次入日志队列，
    //   这些分配与拷不拷 NRO 无关，却和日志队列积压程度一起落进 64 KB（10-30 20:00 列车门禁 93 KB 红）。
    //   改为假映射回 3（已加载）：S2AMapNro 不打红、直接转 AlreadyLoaded，被量的只剩服务路径（ParseNro 原地哈希 / 解析 + 映射分派）；
    //   结果码必须是 AlreadyLoaded，证明解析阶段真跑完、走到了映射（解析中途早退的读数小得没意义）。
    public static unsafe partial class Program
    {
        static int NroMapAlreadyLoaded(byte* sha256, ulong size, ulong bss, ulong* mapped) => 3;

        private const int RoNroSz = 32 << 20, RoWarmSz = 0x3000;

        // 按 NRO 头的段布局造一支：.text 到 size - 0x2000，.ro / .data 各 0x1000
        private static byte* RoBuildNro(int size, out byte[] hash)
        {
            byte* nro = FakeNative.Alloc(size);
            new Span<byte>(nro, size).Clear();
            *(uint*)(nro + 0x10) = 0x304F524E; *(uint*)(nro + 0x18) = (uint)size;
            *(uint*)(nro + 0x20) = 0; *(uint*)(nro + 0x24) = (uint)size - 0x2000;
            *(uint*)(nro + 0x28) = (uint)size - 0x2000; *(uint*)(nro + 0x2C) = 0x1000;
            *(uint*)(nro + 0x30) = (uint)size - 0x1000; *(uint*)(nro + 0x34) = 0x1000;
            hash = System.Security.Cryptography.SHA256.HashData(new ReadOnlySpan<byte>(nro, size));
            return nro;
        }

        // ldr:ro 初始化 + 登记一份含两支 NRO 哈希的 NRR；返回会话、32 MB 与预热用 12 KB 两支 NRO
        private static (uint Ros, uint InitResult, uint NrrResult, ulong Nro, ulong Warm) RoSetup(uint sm)
        {
            Reply gro = Call(sm, Msg.Cmif(1, Name8("ldr:ro")));
            uint ros = gro.Move.Count == 1 ? gro.Move[0] : 0;
            Msg rin = Msg.Cmif(4, Bytes(0UL)); rin.SendPid = true; rin.Copy.Add(0xFFFF8001);
            Reply rinr = Call(ros, rin);
            byte* nro = RoBuildNro(RoNroSz, out byte[] nroHash);
            byte* warm = RoBuildNro(RoWarmSz, out byte[] warmHash);
            byte* nrr = FakeNative.Alloc(0x1000);
            new Span<byte>(nrr, 0x1000).Clear();
            *(uint*)nrr = 0x3052524E; *(uint*)(nrr + 0x338) = 0x1000; *(uint*)(nrr + 0x340) = 0x350; *(uint*)(nrr + 0x344) = 2;
            nroHash.CopyTo(new Span<byte>(nrr + 0x350, 0x20));
            warmHash.CopyTo(new Span<byte>(nrr + 0x370, 0x20));
            Msg lnrr = Msg.Cmif(2, Bytes(0UL, (ulong)nrr, 0x1000UL)); lnrr.SendPid = true;
            Reply lnrrr = Call(ros, lnrr);
            return (ros, rinr.Result, lnrrr.Result, (ulong)nro, (ulong)warm);
        }

        // 一次 LoadNro 的本线程托管分配（映射阶段换成回 3 的假实现，NRO 不进已加载表，可重复调）
        private static (long Alloc, uint Result) RoLoadNroAlloc(uint ros, ulong nro, int size)
        {
            delegate*<byte*, ulong, ulong, ulong*, int> was = Ryujinx.HLE.S2AHooks.NroMap;
            Ryujinx.HLE.S2AHooks.NroMap = &NroMapAlreadyLoaded;
            try
            {
                Msg m = Msg.Cmif(0, Bytes(0UL, nro, (ulong)size, 0UL, 0UL)); m.SendPid = true;
                long c0 = GC.GetAllocatedBytesForCurrentThread();
                Reply r = Call(ros, m);
                return (GC.GetAllocatedBytesForCurrentThread() - c0, r.Result);
            }
            finally { Ryujinx.HLE.S2AHooks.NroMap = was; }
        }

        private const uint RoAlreadyLoaded = (3 << 9) | 22;

        // 守卫兼诊断：同一调用连跑 50 次，逐次判「结果 AlreadyLoaded、服务路径 < 64 KB」，并打分布
        [SoloTest("--ro-alloc-probe", Booted = true)]
        private static void RoAllocProbe()
        {
            const int N = 50;
            Host.Device.System.ServiceTable.WaitServicesReady();
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            (uint ros, uint ir, uint nr, ulong nro, ulong warm) = RoSetup(sm);
            RoLoadNroAlloc(ros, warm, RoWarmSz);
            List<long> a = new();
            int bad = 0;
            for (int k = 0; k < N; k++)
            {
                (long n, uint res) = RoLoadNroAlloc(ros, nro, RoNroSz);
                a.Add(n);
                if (res != RoAlreadyLoaded) bad++;
            }
            Console.WriteLine($"ro 探针 {N} 次：LoadNro 32 MB 服务路径 最小 {a.Min()} B 最大 {a.Max()} B（首次 {a[0]} B）");
            Check($"ro LoadNro 32 MB 连跑 {N} 次：初始化、登记 NRR、结果非 AlreadyLoaded 次数、每次服务路径 < 64 KB",
                "0、0、0、是", $"{ir}、{nr}、{bad}、{(a.Max() < 65536 ? "是" : "否")}");
        }
    }
}
