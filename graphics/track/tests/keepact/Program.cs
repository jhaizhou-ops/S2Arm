// 部分回写保留回写动作单测（帧率能耗线 10-23，RegionHandle.S2AKeepAction）：贴图只回写所碰子页时，Ryujinx 的回写动作不能撤、保护不能放开，
// 否则别的线程在「撤掉 → 重新登记」之间读同段别的子页会读到旧值（陷地那一类错）。全用真件：Ryujinx MemoryTracking / RegionHandle + 产品 GuestMemory。
// 用例（期望按「每一次读都必须先经回写动作」直接定）：一个跟踪句柄覆盖两个 16 KB 页、登记回写动作；两条线程同时各发 N 次读事件（一条读页 0、一条读页 1）：
//   ① 动作里置 S2AKeepAction（部分回写）→ 动作被调 2N 次（没有一次读绕过回写）；② 反证（原版：不置）→ 只被调 1 次，之后的读全绕过（= 漏拦）。
// 用法：bash build_run.sh；退出码 0 = 全过
using Ryujinx.Memory.Tracking;
using S2A.Services;
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // GuestMemory 引用的产品原生入口与报红：单测不开确定性档、不接原生层（同产品单测「假原生层没有时退回」的路径）
#pragma warning disable CS0649
    static unsafe class Native
    {
        public static delegate* unmanaged<int> DetMode;
        public static delegate* unmanaged<ulong, void*, ulong, void> DetHostWrite;
        public static delegate*<ulong, MemInfo*, int> MemQuery;
        public static delegate*<ulong, ulong, int> MemMapped;
        public static FarDesc* Far = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));   // 远端没开（同产品 Native.Far 缺省）
    }
#pragma warning restore CS0649

    [StructLayout(LayoutKind.Sequential)]
    public struct MemInfo
    {
        public ulong Base, Size;
        public uint State, Attr, Perm, Pad;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FarDesc
    {
        public ulong Lo;
        public nint Dir;
    }

    static class Red
    {
        public static void Report(string what, string detail) => Console.WriteLine($"【红】{what} {detail}");
    }
}

static unsafe class P
{
    static int Main()
    {
        const int N = 2000;
        int fail = 0;
        foreach (bool keep in new[] { true, false })
        {
            ulong addr = (ulong)System.Runtime.InteropServices.NativeMemory.AlignedAlloc(0x10000, 0x4000);
            var gm = new GuestMemory();
            RegionHandle h = gm.BeginTracking(addr, 0x8000, 1);
            h.Reprotect();
            int calls = 0;
            h.RegisterAction((a, s) => { System.Threading.Interlocked.Increment(ref calls); if (keep) RegionHandle.S2AKeepAction = true; });
            var go = new System.Threading.ManualResetEventSlim();
            System.Threading.Thread Mk(ulong at) => new System.Threading.Thread(() => { go.Wait(); for (int i = 0; i < N; i++) gm.SignalMemoryTracking(at, 4, false); });
            var a = Mk(addr + 0x10); var b = Mk(addr + 0x4010);
            a.Start(); b.Start(); go.Set(); a.Join(); b.Join();
            int want = keep ? 2 * N : 1;
            bool ok = calls == want; fail += ok ? 0 : 1;
            Console.WriteLine($"{(keep ? "① 部分回写（置 S2AKeepAction）" : "② 反证（原版不置）")}：两线程各读 {N} 次 → 回写动作被调 期望 {want} → 真结果 {calls} {(ok ? "✓" : "✗")}");
        }
        Console.WriteLine($"keepact：2 项，失败 {fail}");
        return fail == 0 ? 0 : 1;
    }
}
