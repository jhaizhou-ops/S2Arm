// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace S2A.Services.Tests
{
    // 声音完成额度（PlaybackCredit，11-02 Pokopia iPhone 断续 / 杂音）。假设备同 iPhone 扬声器：每 21333 µs 拉一次 1024 帧（4096 B），只交还整块拿完的缓冲，
    //   同一次拉的交还相隔 1 µs；客人同 Pokopia 的 AudioOut：缓冲 240 帧（960 B，48 kHz 下 5 ms），始终留 4 块没放回，放回一块就补一块。
    //   时间按 50 µs 一步走（同会话的放回节拍线程：每步都问一次额度），跑 100 个周期，看第 20–99 个周期。期望手算：
    //   ① 没有提前量（上限 0 = 最早的行为）：每次拉时设备里只有 4 × 960 = 3840 B，每周期缺 4096 − 3840 = 256 B = 64 帧，80 个周期缺 5120 帧；
    //      放回只在交还那一刻，一次 4 块：任意 1 ms 内最多放回 4 块
    //   ② 有提前量：交还一串的中位数 4 块 = 960 帧 = 提前量。播放头按 48 帧 / ms 走，下限交还、上限交还 + 960 帧：每次拉之后从交还处走，
    //      20 ms 走到上限停住，等下一次拉（21.333 ms）。一次拉交还 4 块时头不跳，交还 5 块时头跳到新交还处（多放回 1 块，离上一块 1.333 ms）；
    //      其余每 5 ms 放回 1 块 → 任意 1 ms 内最多 1 块（11-02 杂音的根因：一次放回 4 块，游戏按自己 5 ms 节拍混音，第 4 块常常还没备好就交了静音）。
    //      拉之前头在交还 + 960 帧，客人又补满 4 块：设备里从交还处起有 960 + 960 = 1920 帧，减去拿了一半的那块（< 240 帧）仍 > 1024：缺 0 帧。
    //      最后一次拉之后那一刻头在新交还处，没放回的 4 块全在设备里：设备里 4 块。记为已播的永远不超过已交设备的：越界 0 次
    static class PlaybackCreditTest
    {
        private const int Bpf = 4, Block = 960, Pull = 4096, Period = 21333, Step = 50, Rate = 48000;

        private static long Tk(long us) => us * Stopwatch.Frequency / 1_000_000;

        private static (long ShortFrames, long LeadFrames, int Held, int Over, int MaxPerMs) Sim(long maxLeadBytes)
        {
            var c = new PlaybackCredit(Bpf, (long)Bpf * Rate, maxLeadBytes, Tk(2000));
            var dev = new Queue<int>();   // 设备里每块剩余字节
            var releases = new List<long>();   // 第 20 个周期起每块放回的时刻（µs）
            long submitted = 0, credited = 0, appended = 0, shortBytes = 0, released = 0;
            int over = 0;

            void Refill(long us, bool record)
            {
                credited += c.Take(submitted, Tk(us));

                if (credited > submitted)
                {
                    over++;
                }

                while (credited / Block > released)
                {
                    released++;

                    if (record)
                    {
                        releases.Add(us);
                    }
                }

                while (appended - released < 4)
                {
                    appended++;
                    submitted += Block;
                    dev.Enqueue(Block);
                }
            }

            Refill(0, false);

            for (int k = 0; k < 100; k++)
            {
                long t = (long)(k + 1) * Period;

                for (long u = (long)k * Period + Step; u < t; u += Step)
                {
                    Refill(u, k >= 20);
                }

                int need = Pull;
                long rt = t;

                while (need > 0 && dev.Count > 0)
                {
                    int head = dev.Peek();
                    int take = Math.Min(head, need);
                    need -= take;

                    if (take == head)
                    {
                        dev.Dequeue();
                        c.Returned(Block, Tk(rt++));
                    }
                    else
                    {
                        dev.Dequeue();
                        var rest = new Queue<int>();
                        rest.Enqueue(head - take);
                        foreach (int x in dev) rest.Enqueue(x);
                        dev = rest;
                    }
                }

                if (k >= 20)
                {
                    shortBytes += need;
                }

                Refill(rt, k >= 20);
            }

            int maxPerMs = 0;
            for (int i = 0, j = 0; i < releases.Count; i++)
            {
                while (releases[i] - releases[j] >= 1000) j++;
                maxPerMs = Math.Max(maxPerMs, i - j + 1);
            }

            return (shortBytes / Bpf, c.LeadBytes / Bpf, dev.Count, over, maxPerMs);
        }

        [SoloTest("--audio-playback-credit")]
        private static int Run()
        {
            var rows = new List<(string Name, string Expect, string Actual)>();

            var a = Sim(0);
            rows.Add(("① 没有提前量（最早的行为）：80 个周期缺的帧 / 越界次数 / 1 ms 内最多放回块数", "5120 / 0 / 4", $"{a.ShortFrames} / {a.Over} / {a.MaxPerMs}"));

            var b = Sim(Bpf * 4800);
            rows.Add(("② 有提前量、按播放头放回：80 个周期缺的帧 / 提前量（帧）/ 设备里的块数 / 越界次数 / 1 ms 内最多放回块数", "0 / 960 / 4 / 0 / 1", $"{b.ShortFrames} / {b.LeadFrames} / {b.Held} / {b.Over} / {b.MaxPerMs}"));

            int bad = 0;
            foreach (var (name, expect, actual) in rows)
            {
                bool ok = expect == actual;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 声音完成额度 {name}：{expect} → {actual}");
            }

            return bad == 0 ? 0 : 1;
        }
    }
}
