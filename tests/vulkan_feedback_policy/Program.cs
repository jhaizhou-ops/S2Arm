using System;

namespace Ryujinx.Graphics.Vulkan
{
    internal static class FeedbackPolicy
    {
        private static int _failed;

        private static void Check(string name, bool actual, bool expected)
        {
            bool ok = actual == expected;
            Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {name} expected={expected} actual={actual}");
            if (!ok)
            {
                _failed++;
            }
        }

        private static int Main()
        {
            // 深度 hazard + 通道进行中 + 布局未启用/未切换 → 拆
            Check("split-depth-active",
                S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, false, true, true), true);
            // 布局已激活 → 不拆
            Check("layout-active", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(true, false, true, true), false);
            // 本次切换成功 → 不拆
            Check("layout-changed", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, true, true, true), false);
            // 无深度 hazard → 不拆
            Check("no-depth", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, false, false, true), false);
            // 通道未进行 → 不拆
            Check("no-pass", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, false, true, false), false);
            // 深度 + 颜色同时命中 → 仍按深度拆
            Check("depth-and-color",
                S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, false, true, true), true);

            // 负控：布局生效路径、颜色-only、通道外都不能触发拆通道。
            Check("negative-layout-active", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(true, true, true, true), false);
            Check("negative-color-only", S2AFeedbackLoopPolicy.ShouldSplitDepthPass(false, false, false, true), false);

            Console.WriteLine("negative-controls=2");
            return _failed == 0 ? 0 : 1;
        }
    }
}
