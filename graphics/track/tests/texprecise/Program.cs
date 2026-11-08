// 贴图精确访问不相交即跳过单测（帧率能耗线 10-23，RegionHandle.S2AOutsideReal + TextureGroup.GenerateHandle 的精确动作）：
// 跟踪按页登记，贴图真实字节只占子页一段；游戏写同子页里贴图旁边的数据（写跟踪排空发精确写事件）时，原版照样整张回写并标脏。
// 全用真件：Ryujinx MemoryTracking / RegionHandle + 产品 GuestMemory。贴图真实区间 = 页内 [0x1100, 0x1200)。
// 期望按「访问字节与 [0x1100, 0x1200) 有无交集」直接定（不跑被测实现）：
//   ① 0x1400 起 16 B（同页、不相交）→ 回写动作 0 次、不标脏；② 0x10F0 起 16 B（正好止于起点）→ 0 次；③ 0x11F0 起 32 B（跨终点）→ 1 次、标脏；
//   ④ 0x1200 起 16 B（正好始于终点）→ 0 次；⑤ 反证（原版：不登记精确动作）0x1400 起 16 B → 1 次、标脏（＝假共享整张回写）
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
        int fail = 0, n = 0;
        void Case(string name, ulong off, ulong len, bool precise, int wantCalls, bool wantDirty)
        {
            ulong addr = (ulong)System.Runtime.InteropServices.NativeMemory.AlignedAlloc(0x10000, 0x4000);
            var gm = new GuestMemory();
            RegionHandle h = gm.BeginTracking(addr + 0x1100, 0x100, 1);
            h.Reprotect();
            int calls = 0;
            h.RegisterAction((a, s) => calls++);
            if (precise) h.RegisterPreciseAction((a, s, w) => RegionHandle.S2AOutsideReal(h, a, s));
            gm.SignalMemoryTracking(addr + off, len, true, precise: true);
            bool ok = calls == wantCalls && h.Dirty == wantDirty; n++; fail += ok ? 0 : 1;
            Console.WriteLine($"{name}：回写动作 期望 {wantCalls} → 真结果 {calls}；标脏 期望 {wantDirty} → 真结果 {h.Dirty} {(ok ? "✓" : "✗")}");
        }
        Case("① 同页不相交", 0x1400, 16, true, 0, false);
        Case("② 止于起点", 0x10F0, 16, true, 0, false);
        Case("③ 跨终点", 0x11F0, 32, true, 1, true);
        Case("④ 始于终点", 0x1200, 16, true, 0, false);
        Case("⑤ 反证（原版不登记）", 0x1400, 16, false, 1, true);
        Console.WriteLine($"texprecise：{n} 项，失败 {fail}");
        return fail == 0 ? 0 : 1;
    }
}
