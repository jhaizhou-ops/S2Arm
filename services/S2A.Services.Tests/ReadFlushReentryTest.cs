using Ryujinx.Memory;
using Ryujinx.Memory.Tracking;
using System;
using System.Collections.Generic;
using System.Linq;

namespace S2A.Services.Tests
{
    // #1397（8E nx-84 宿主栈溢出）：回写动作内部经不跟踪 GetWritableRegion / GetSpan 取目标区，目标段还脏
    //   （act 要等回写完成 reprotect 才清）→ ReadFlushIfGpuModified → 嵌套 S2AReadFlush → 同一 FlushAction
    //   又被同步触发——每级 12 帧约 0x640 字节无界叠栈，8 MiB 宿主栈吃满（确定性 SIGSEGV/SEGV_ACCERR）。
    //   修法（RegionHandle 级在信号闸，等价原生 t_in_touch 上移一层）：信号命中正在执行动作的句柄自身时
    //   跳过（在跑的那次调用本身就是这次信号要的回写，不重发不延后），同段别名句柄照常同步——
    //   保「读之前先回写」顺序语义（owner 审 1427 口径）。全真件：产品 GuestMemory + MemoryTracking /
    //   RegionHandle；脏位用两个槽模拟 act。
    //   ① 正控：动作里取同段可写区（仍脏）→ 嵌套信号跳过自身——深度 = 1、动作只调 1 次、内存 = 回写值、
    //      S2AReadTouch 复位。关闸（S2AReadFlushNoGuard）同一用例深度 > 1（负控）。
    //   ② 跨段出路：A 的动作里对不重叠的脏段 B 收口 → B 同步回写（顺序语义保留）。
    //   ③ 别名双句柄：同段两个句柄，A 动作内嵌套收口命中同段 → A 自身跳过（总 1 次）、B 同步跑（读前回写）。
    public static unsafe partial class Program
    {
        private static (ulong va, ulong end, bool set) _gm1, _gm2;
        private static bool GpuModReentry(ulong va, ulong size)
            => (_gm1.set && va < _gm1.end && _gm1.va < va + size) || (_gm2.set && va < _gm2.end && _gm2.va < va + size);
        private static void ClearGm(ulong va)
        {
            if (_gm1.set && va >= _gm1.va && va < _gm1.end) _gm1.set = false;
            if (_gm2.set && va >= _gm2.va && va < _gm2.end) _gm2.set = false;
        }

        // ReprotectHook 记账（复用 Program.cs 的 _reprot / RecordReprotect）：断言只看「保护域 = guest 且权限非 None
        //   覆盖受测段」——它等价原生层 s2a_track_reprotect(非 None) 把 act 退掉；修前宿主域消费动作后 guest 域一条都收不到。
        private static bool GuestOpened(ulong va, ulong end)
            => _reprot.Any(r => r.Guest && r.Perm != MemoryPermission.None && r.Va < end && va < r.Va + r.Size);

        [SoloTest("--readflush-reentry", Booted = true)]
        private static void ReadFlushReentry()
        {
            delegate*<ulong, ulong, bool> gmWas = GuestMemory.GpuModifiedHook;
            byte* g = FakeNative.Alloc(0x4000);
            ulong rb = ((ulong)g + 0xFFF) & ~0xFFFUL;
            GuestMemory.GpuModifiedHook = &GpuModReentry;
            try
            {
                // ① 同段嵌套：有闸深度 = 1、动作 1 次；关闸（负控）深度 > 1
                foreach (bool noGuard in new[] { false, true })
                {
                    GuestMemory gm = new();
                    RegionHandle h = gm.BeginTracking(rb, 0x1000, 0);
                    int depth = 0, maxDepth = 0, calls = 0, budget = 8, armed = 4;
                    new Span<byte>((void*)rb, 0x1000).Fill(0x11);
                    _gm1 = (rb, rb + 0x1000, true); _gm2 = (0, 0, false);
                    RegionSignal act = null;
                    act = (a, n) =>
                    {
                        calls++;
                        RegionHandle.S2AKeepAction = armed-- > 0;   // 同生产句柄：保动作登记（否则跑完就撤）
                        depth++; if (depth > maxDepth) maxDepth = depth;
                        // 回写动作内部取同段可写区：段仍脏 → 嵌套收口读（有闸跳过自身 / 无闸同步重入）
                        if (budget-- > 0)
                        {
                            using WritableRegion w = gm.GetWritableRegion(a, (int)n);
                            w.Memory.Span.Fill(0x5A);
                        }
                        ClearGm(a);
                        depth--;
                    };
                    h.RegisterAction(act);
                    MemoryTracking.S2AReadFlushNoGuard = noGuard;
                    gm.Tracking.S2AReadFlush(rb, 0x100);
                    MemoryTracking.S2AReadFlushNoGuard = false;
                    bool flagBack = !MemoryTracking.S2AReadTouch;
                    bool dataOk = ((byte*)rb)[0] == 0x5A && ((byte*)rb)[0xFFF] == 0x11;
                    h.Dispose();
                    if (noGuard)
                        Check("① 负控（关闸）：同段嵌套深度 > 1", "是", maxDepth > 1 ? "是" : $"否（{maxDepth}）");
                    else
                        Check($"① 正控：同段嵌套深度=1、动作只 1 次、数据正确、标志复位",
                            "深 1、调 1、数据对、标志复位",
                            $"深 {maxDepth}、调 {calls}、{(dataOk ? "数据对" : "数据错")}、{(flagBack ? "标志复位" : "标志未复位")}");
                }

                // ② 跨段出路：A 的动作里对不重叠的脏段 B 收口 → B 的动作同步跑（顺序：B 先于 A 收尾）
                {
                    GuestMemory gm = new();
                    RegionHandle ha = gm.BeginTracking(rb, 0x1000, 0), hb = gm.BeginTracking(rb + 0x1000, 0x1000, 0);
                    List<string> seq = new();
                    new Span<byte>((void*)rb, 0x2000).Fill(0x11);
                    _gm1 = (rb, rb + 0x1000, true); _gm2 = (rb + 0x1000, rb + 0x2000, true);
                    hb.RegisterAction((a, n) => { seq.Add("B 回写"); new Span<byte>((void*)a, 0x10).Fill(0x5B); ClearGm(a); });
                    ha.RegisterAction((a, n) =>
                    {
                        seq.Add("A 进入");
                        gm.Tracking.S2AReadFlush(rb + 0x1000, 0x10);
                        seq.Add("A 收尾"); new Span<byte>((void*)a, 0x10).Fill(0x5A); ClearGm(a);
                    });
                    gm.Tracking.S2AReadFlush(rb, 0x10);
                    bool dataOk = ((byte*)rb)[0] == 0x5A && ((byte*)rb)[0x1000] == 0x5B;
                    ha.Dispose(); hb.Dispose();
                    Check("② 跨段嵌套照旧同步：B 在 A 收尾前回写、两段数据都正确",
                        "A 进入、B 回写、A 收尾、数据对",
                        $"{string.Join("、", seq)}、{(dataOk ? "数据对" : "数据错")}");
                }

                // ③ 别名双句柄：同段 A、B 两句柄——A 动作内嵌套收口命中同段，A 自身跳过、B 同步跑
                {
                    GuestMemory gm = new();
                    RegionHandle ha = gm.BeginTracking(rb, 0x1000, 0), hb = gm.BeginTracking(rb, 0x1000, 0);
                    List<string> seq = new();
                    new Span<byte>((void*)rb, 0x1000).Fill(0x11);
                    _gm1 = (rb, rb + 0x1000, true); _gm2 = (0, 0, false);
                    int aCalls = 0;
                    hb.RegisterAction((a, n) => { seq.Add("B 回写"); ((byte*)a)[0x10] = 0x5B; });
                    ha.RegisterAction((a, n) =>
                    {
                        aCalls++;
                        RegionHandle.S2AKeepAction = aCalls < 4;
                        seq.Add("A 进入");
                        // 同段仍脏 → 嵌套收口：A 在信号栈上跳过自身，B 同步执行（读前回写顺序保留）
                        using WritableRegion w = gm.GetWritableRegion(a, (int)n);
                        w.Memory.Span.Fill(0x5A);
                        seq.Add("A 收尾"); ClearGm(a);
                    });
                    gm.Tracking.S2AReadFlush(rb, 0x10);
                    bool dataOk = ((byte*)rb)[0] == 0x5A && ((byte*)rb)[0x10] == 0x5B;
                    ha.Dispose(); hb.Dispose();
                    Check("③ 别名句柄：A 自触发跳过（总 1 次）、B 在 A 收尾前同步回写、数据正确",
                        "1 次、A 进入、B 回写、A 收尾、数据对",
                        $"{aCalls} 次、{string.Join("、", seq)}、{(dataOk ? "数据对" : "数据错")}");
                }
            }
            finally
            {
                MemoryTracking.S2AReadFlushNoGuard = false;
                GuestMemory.GpuModifiedHook = gmWas;
                _gm1 = _gm2 = default;
                FakeNative.Free(g);
            }
        }

        // #1427 回归（r4 8E 歧路旅人 II DmaClass.Copy<T> AccessViolation）：闸让动作可由宿主域信号
        //   （GetSpan(tracked:true) 等托管读 → VirtualMemoryEvent guest:false）跑完——动作内嵌套收口被跳过、
        //   _preAction 清在外层宿主域信号里，本域 UpdateProtection 只更新自己，guest 域仍停在「动作挂着」的
        //   None 记账——等价原生 act/want 不再退，排空时把页设回不可读，之后同段托管借用读直接缺页。
        //   本用例：宿主域 GetSpan(tracked:true) 消费动作（动作内同段真实写 gm.Write 命中同句柄写信号跳过 +
        //   GetWritableRegion 触发嵌套收口跳过）后，guest 域必须收到一次非 None 保护（act 退掉）；修前收不到。
        [SoloTest("--readflush-reprotect", Booted = true)]
        private static void ReadFlushReprotectOnConsume()
        {
            delegate*<ulong, ulong, bool> gmWas = GuestMemory.GpuModifiedHook;
            delegate*<ulong, ulong, MemoryPermission, bool, void> rpWas = GuestMemory.ReprotectHook;
            byte* g = FakeNative.Alloc(0x4000);
            ulong rb = ((ulong)g + 0xFFF) & ~0xFFFUL;
            GuestMemory.GpuModifiedHook = &GpuModReentry;
            GuestMemory.ReprotectHook = &RecordReprotect;
            try
            {
                GuestMemory gm = new();
                RegionHandle h = gm.BeginTracking(rb, 0x1000, 0);
                new Span<byte>((void*)rb, 0x1000).Fill(0x11);
                _gm1 = (rb, rb + 0x1000, true); _gm2 = (0, 0, false);
                int calls = 0;
                h.RegisterAction((a, n) =>
                {
                    calls++;
                    // 动作内嵌套收口（同段还脏→跳过自身）+ 真实写（gm.Write→guest 域写信号→同句柄跳过、Dirty 照记）
                    using WritableRegion w = gm.GetWritableRegion(a, (int)n);
                    w.Memory.Span.Fill(0x5A);
                    gm.Write(a, new byte[] { 0x5B, 0x5C, 0x5D, 0x5E });
                    ClearGm(a);
                });
                _reprot.Clear();
                ReadOnlySpan<byte> s = gm.GetSpan(rb, 0x100, tracked: true);
                bool dataOk = s[0] == 0x5B && s[4] == 0x5A;
                bool dirty = h.Dirty;
                bool opened = GuestOpened(rb, rb + 0x1000);
                h.Dispose();
                Check("④ 宿主域消费动作后 guest 域收到非 None 保护（act 退掉）",
                    "调 1、数据对、已记脏、guest 收到非 None",
                    $"调 {calls}、{(dataOk ? "数据对" : "数据错")}、{(dirty ? "已记脏" : "没记脏")}、guest {(opened ? "收到非 None" : "没收到非 None")}");
            }
            finally
            {
                GuestMemory.GpuModifiedHook = gmWas;
                GuestMemory.ReprotectHook = rpWas;
                _gm1 = _gm2 = default;
                _reprot.Clear();
                FakeNative.Free(g);
            }
        }
    }
}
