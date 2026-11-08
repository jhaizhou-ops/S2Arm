using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 11-01 审计 P2-40：MemoryTracking.S2AReadTouch（本线程「正在处理游戏读缺页」，GPU 层据此只回写所碰子页）在 S2AReadFlush 里置位、
    //   finally 无条件清零。回写动作里再发一次收口读（嵌套 S2AReadFlush）时，内层收尾把外层的标志一并清掉，外层余下的回写按「非读」整段回写。
    //   两个跟踪句柄 A / B：A 的动作里先记标志、对 B 发嵌套收口读、再记标志；B 的动作记标志。期望（只看调用关系即可写出）：
    //   A 进入时真、B 里真、嵌套返回后 A 仍真；外层返回后回到进入前的假。旧代码嵌套返回后为假，判红
    public static unsafe partial class Program
    {
        [SoloTest("--readtouch-nest", Booted = true)]
        private static void ReadTouchNest()
        {
            byte* g = FakeNative.Alloc(0x4000);
            ulong rbase = ((ulong)g + 0xFFF) & ~0xFFFUL;
            GuestMemory gm = new();
            Ryujinx.Memory.Tracking.RegionHandle ha = gm.BeginTracking(rbase, 0x1000, 0), hb = gm.BeginTracking(rbase + 0x1000, 0x1000, 0);
            List<string> seen = new();
            hb.RegisterAction((a, n) => seen.Add($"B 里 {Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch}"));
            ha.RegisterAction((a, n) =>
            {
                seen.Add($"A 进入 {Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch}");
                gm.Tracking.S2AReadFlush(rbase + 0x1000, 0x10);
                seen.Add($"嵌套后 {Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch}");
            });
            bool before = Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch;
            gm.Tracking.S2AReadFlush(rbase, 0x10);
            seen.Add($"外层返回 {Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch}");
            ha.Dispose();
            hb.Dispose();
            Check("读缺页标志嵌套（进入前 / A 进入 / B 里 / 嵌套后 / 外层返回）",
                "False、A 进入 True、B 里 True、嵌套后 True、外层返回 False", $"{before}、{string.Join("、", seen)}");
        }
    }
}
