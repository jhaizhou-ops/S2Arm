// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace S2A.Services.Tests
{
    // 队列时间轴跑到声音前面（QueueTimelineWatch，11-06 时之笛 iPhone 读档后永久静音）。48 kHz 双声道 16 位：每秒 192000 B，看门狗每 250 ms 一拍。
    //   期望手算（不跑被测实现）：
    //   ① 卡死态（测试机2 第 32 版读档后的交还账：每 10 秒约 445 次交还后在途为 0、交还 48 万帧）：每拍 11 次归零、交还 48000 B（= 1.00 倍实时）。
    //      第 1 拍没有上一拍可比 → 不重启；第 2 拍两拍都 ≥ 4 次、两拍合计 96000 B / 0.5 s = 1.00 ≥ 0.85 → 重启；重启后清零，第 3 拍又没有上一拍 → 不重启，第 4 拍再重启。
    //      4 拍的结论：0101
    //   ② 正常播放（读档前：每 10 秒 0–2 次归零）：每拍 0 次归零、48000 B → 4 拍 0000
    //   ③ 真供不上（游戏只交 70% 实时）：每拍 11 次归零、33600 B，两拍合计 67200 B / 0.5 s = 0.70 < 0.85 → 4 拍 0000
    //   ④ 一拍偶发欠载后恢复（Mac 上欠载后自己恢复的样子）：第 1 拍 6 次归零，之后每拍 0 次 → 4 拍 0000
    //   ⑤ 卡死态但一拍交还正好少一拉（21.3 ms = 4096 B）：两拍 43904 + 48000 B = 91904 B / 0.5 s = 0.957 ≥ 0.85 → 第 2 拍重启：01
    //   ⑥ 门槛边上：每拍 3 次归零（< 4）、1.00 倍实时 → 4 拍 0000；每拍 4 次 → 0101
    static class QueueTimelineWatchTest
    {
        private const long Bps = 192000;

        private static long Tk(long ms) => ms * Stopwatch.Frequency / 1000;

        private static string Run((int Zero, long Bytes)[] ticks)
        {
            var w = new QueueTimelineWatch(Bps);
            var s = new System.Text.StringBuilder();

            foreach (var (zero, bytes) in ticks)
            {
                s.Append(w.Tick(zero, bytes, Tk(250)) ? '1' : '0');
            }

            return s.ToString();
        }

        private static (int, long)[] Same(int n, int zero, long bytes)
        {
            var a = new (int, long)[n];

            for (int i = 0; i < n; i++)
            {
                a[i] = (zero, bytes);
            }

            return a;
        }

        [SoloTest("--audio-timeline-ahead")]
        private static int Check()
        {
            var rows = new List<(string Name, string Expect, string Actual)>
            {
                ("① 卡死态：每拍 11 次归零、1.00 倍实时，4 拍", "0101", Run(Same(4, 11, 48000))),
                ("② 正常播放：每拍 0 次归零，4 拍", "0000", Run(Same(4, 0, 48000))),
                ("③ 真供不上：每拍 11 次归零、0.70 倍实时，4 拍", "0000", Run(Same(4, 11, 33600))),
                ("④ 一拍偶发欠载后恢复：6 / 0 / 0 / 0 次归零", "0000", Run(new (int, long)[] { (6, 48000), (0, 48000), (0, 48000), (0, 48000) })),
                ("⑤ 卡死态、一拍少一拉：43904 + 48000 B", "01", Run(new (int, long)[] { (11, 48000 - 4096), (11, 48000) })),
                ("⑥a 门槛边上：每拍 3 次归零，4 拍", "0000", Run(Same(4, 3, 48000))),
                ("⑥b 门槛边上：每拍 4 次归零，4 拍", "0101", Run(Same(4, 4, 48000))),
            };

            int bad = 0;

            foreach (var (name, expect, actual) in rows)
            {
                bool ok = expect == actual;

                if (!ok)
                {
                    bad++;
                }

                Console.WriteLine($"{(ok ? "✓" : "✗")} 队列时间轴检测 {name}：{expect} → {actual}");
            }

            return bad == 0 ? 0 : 1;
        }
    }
}
