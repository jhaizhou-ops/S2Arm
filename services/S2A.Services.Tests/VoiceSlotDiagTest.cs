// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Server.Voice;
using System;
using PlayState = Ryujinx.Audio.Renderer.Server.Types.PlayState;

namespace S2A.Services.Tests
{
    // 声音槽诊断计数（S2AVoiceSlotDiag，11-05 伊苏X AcquireVoiceSlot() failed）：只读计数，不改回写。
    // 4 个槽、4 次 Update（t = 0 / 3 / 6 / 10 秒），手摆 VoiceInfo 与 CPU 侧 VoiceState，期望手算：
    //   U1 t=0：槽 0 新（IsNew，Started）、槽 1 新（IsNew，Started）→ 新分配 2
    //   U2 t=3：槽 0 Started 已消耗 3、槽 1 Stopping 已消耗 2、槽 2 新（IsNew）→ 新分配 1，已消耗 3 + 2 = 5
    //   U3 t=6：槽 0 Started 已消耗 7（+4）、槽 1 不在用（释放）、槽 2 Paused 已消耗 1（+1）、槽 3 在用但非 IsNew（算新分配）→ 释放 1、新分配 1、已消耗 5
    //   U4 t=10：槽 0 IsNew（上一持有者释放 + 新分配）、槽 2 Stopped 已消耗 1（+0）、槽 3 Started 已消耗 2（+2）、丢弃标记 1（槽 3）
    //   → 窗口 10 秒收：新分配 2+1+1+1 = 5，释放 1+1 = 2，已消耗 5+5+2 = 12，更新 4；
    //     快照：在用 3（槽 0 / 2 / 3）Started 2（0、3）Stopped 1（2）Stopping 0 Paused 0 丢弃标记 1
    //   U1–U3 不到 10 秒，不出行（返回 null）。
    static class VoiceSlotDiagTest
    {
        [SoloTest("--voice-slot-diag")]
        private static int Run()
        {
            const int n = 4;
            VoiceInfo[] voices = new VoiceInfo[n];
            VoiceState[] cpu = new VoiceState[n];
            VoiceContext ctx = new();
            ctx.Initialize(new int[n], voices, new VoiceChannelResource[n], cpu, new VoiceState[n], n);

            void Set(int i, bool inUse, bool isNew, PlayState ps, uint consumed, bool drop = false)
            {
                voices[i].InUse = inUse;
                voices[i].IsNew = isNew;
                voices[i].PlayState = ps;
                voices[i].VoiceDropFlag = drop;
                voices[i].ChannelsCount = 1;
                voices[i].ChannelResourceIds[0] = i;
                cpu[i].WaveBufferConsumed = consumed;
            }

            S2AVoiceSlotDiag d = new(n);
            int bad = 0;
            void Row(string name, string expect, string actual)
            {
                bool ok = expect == actual;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 声音槽计数 {name}：{expect} → {actual}");
            }

            Set(0, true, true, PlayState.Started, 0); Set(1, true, true, PlayState.Started, 0);
            Row("U1 t=0 不出行", "null", d.Observe(ctx, 0, 7) ?? "null");

            Set(0, true, false, PlayState.Started, 3); Set(1, true, false, PlayState.Stopping, 2); Set(2, true, true, PlayState.Started, 0);
            Row("U2 t=3 不出行", "null", d.Observe(ctx, 3, 7) ?? "null");

            Set(0, true, false, PlayState.Started, 7); Set(1, false, false, PlayState.Stopped, 2);
            Set(2, true, false, PlayState.Paused, 1); Set(3, true, false, PlayState.Started, 0);
            Row("U3 t=6 不出行", "null", d.Observe(ctx, 6, 7) ?? "null");

            Set(0, true, true, PlayState.Started, 0); Set(2, true, false, PlayState.Stopped, 1); Set(3, true, false, PlayState.Started, 2, drop: true);
            string line = d.Observe(ctx, 10, 7);
            Row("U4 t=10 出行", "[S2A 声音槽] 渲染器 7 在用 3/4 Started=2 Stopping=0 Stopped=1 Paused=0 丢弃标记=1 | 10.0 秒内 新分配=5 释放=2 缓冲已消耗=12 更新=4",
                line ?? "null");
            Row("出行后窗口清零", "0/0/0/0", $"{d.Allocated}/{d.Released}/{d.Consumed}/{d.Updates}");

            return bad == 0 ? 0 : 1;
        }
    }
}
