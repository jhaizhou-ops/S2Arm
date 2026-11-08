// PipelineStatePreference 单测：离线包合并「旧无状态记录 + 新有状态记录」时的取舍。
// 退出 0 = 全过；最后一行「期望 → 真结果」。
// 注意：2 / 6 是 owner 要求的负控——同客体代码但特化不同的无状态记录必须保留；
// 若影子键退化成只比客体代码（旧实现），这两项会红。
using S2A.ShBake;
using System;
using System.Collections.Generic;
using System.Linq;

namespace S2A.StateTest
{
    sealed record Item(string Guest, bool Compute, bool State, string Spec, string Name);

    static class Program
    {
        static int pass, fail;
        static void Check(bool ok, string what)
        {
            if (ok) pass++; else fail++;
            Console.WriteLine($"{(ok ? "✓" : "✗ 不通")} {what}");
        }

        static PipelineStatePreference.MergeResult<Item> Merge(params Item[] items) =>
            PipelineStatePreference.PreferStateful(
                items,
                x => x.Compute ? "c|" + x.Guest : "g|" + x.Guest,   // 客体代码 + c1（不含特化）
                x => (x.Compute ? "c|" + x.Guest : "g|" + x.Guest) + "|" + x.Spec,   // + 去掉 PipelineState 后的特化字节
                x => x.Compute,
                x => x.State);

        static void Main()
        {
            // 1. 同一客体、特化相同：旧包无状态 + 新导出有状态 → 只保留有状态那条。
            var a = Merge(
                new Item("g1", false, false, "s1", "old"),
                new Item("g1", false, true, "s1", "new"));
            Check(a.Items.Count == 1 && a.Items[0].Name == "new", "有状态记录覆盖同客体同特化的无状态影子");
            Check(a.NoStateSameGuest == 1 && a.DroppedNoState == 1 && a.NoStateSameGuest - a.DroppedNoState == 0,
                $"统计：同客体无状态 1、删 1（实得 {a.NoStateSameGuest}/{a.DroppedNoState}）");

            // 2. 负控（owner）：同客体代码、特化不同 → 无状态记录是另一个变体，必须保留。
            var b = Merge(
                new Item("g2", false, false, "spec-old", "old-different-spec"),
                new Item("g2", false, true, "spec-new", "new"));
            Check(b.Items.Count == 2 && b.Items.Any(x => x.Name == "old-different-spec") && b.Items.Any(x => x.Name == "new"),
                "负控：同客体代码、特化不同的无状态记录必须保留（去掉特化键时此项红）");
            Check(b.NoStateSameGuest == 1 && b.DroppedNoState == 0,
                $"负控统计：同客体无状态 1、删 0（实得 {b.NoStateSameGuest}/{b.DroppedNoState}）");

            // 3. 负控：只有无状态记录 → 原样保留，不得凭空补 state。
            var c = Merge(new Item("g3", false, false, "s3", "only-old"));
            Check(c.Items.Count == 1 && c.Items[0].Name == "only-old" && !c.Items[0].State,
                "has=0 负控：无状态记录保留且仍无 state");

            // 4. 不同客体 → 都保留（无状态的不因别的客体有状态而被删）。
            var d = Merge(
                new Item("g4", false, false, "s4", "g4"),
                new Item("g5", false, true, "s5", "g5"));
            Check(d.Items.Count == 2 && d.Items.Any(x => x.Name == "g4") && d.Items.Any(x => x.Name == "g5"),
                "不同客体互不影响");

            // 5. 计算程序没有 ProgramPipelineState，不能被同客体的图形有状态记录删掉。
            var e = Merge(
                new Item("c1", true, false, "s6", "compute"),
                new Item("c1", false, true, "s7", "graphics"));
            Check(e.Items.Count == 2 && e.Items.Any(x => x.Name == "compute") && e.Items.Any(x => x.Name == "graphics"),
                "计算程序保留（compute has=0 是设计）");

            // 6. 同客体：两条有状态（不同特化）都保留；只删与新记录特化完全相同的无状态影子，另一条无状态保留。
            var f = Merge(
                new Item("g6", false, false, "spec-A", "old-shadow"),
                new Item("g6", false, false, "spec-B", "old-variant"),
                new Item("g6", false, true, "spec-A", "new-A"),
                new Item("g6", false, true, "spec-C", "new-C"));
            Check(f.Items.Count == 3 && f.Items.All(x => x.Name != "old-shadow") && f.Items.Any(x => x.Name == "old-variant")
                && f.Items.Any(x => x.Name == "new-A") && f.Items.Any(x => x.Name == "new-C"),
                "同客体：只删完全相同的影子，特化不同的无状态变体保留");
            Check(f.NoStateSameGuest == 2 && f.DroppedNoState == 1,
                $"同客体统计：无状态 2、删 1、留 1（实得 {f.NoStateSameGuest}/{f.DroppedNoState}）");

            // 7. 全有状态 → 原样。
            var g = Merge(new Item("g7", false, true, "s8", "a"), new Item("g8", false, true, "s9", "b"));
            Check(g.Items.Count == 2, "全有状态不变");

            // 8. 全无状态 → 原样（整包没有 state 时不误删）。
            var h = Merge(new Item("g9", false, false, "s10", "a"), new Item("g10", false, false, "s11", "b"));
            Check(h.Items.Count == 2, "全无状态不变（has=0 整包负控）");

            Console.WriteLine($"期望 → 真结果：{pass} 通过 / {fail} 失败");
            Environment.Exit(fail == 0 ? 0 : 1);
        }
    }
}
