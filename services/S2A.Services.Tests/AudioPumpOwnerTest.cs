// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 苹果音频泵（审计 P1-26 / P1-27；11-02 补垫按设备播放时钟），假设备、不碰声卡。几何同苹果会话：48 kHz 立体声 PCM16 每帧 4 B，槽 50 ms = 9600 B、32 个，
    //   预充下限 64 ms = 12288 B，垫 = min(下限, 槽长) = 9600 B；容差 5 ms = 240 帧。假设备的播放时钟同 AudioQueue（11-02 Mac 实测）：缓冲首尾相接排在时间线上，
    //   交还一块时播放时钟 = 这块末尾 − 700 帧（Mac 实测 620–750）。期望全部按语义手算：
    // ① 单缓冲客人（等这块播完才交下一块，交还后立刻交）：起播 1 块，之后 12 轮「设备交还 → 再交 1 块」，设备上应只有 13 块 4096 B 真实样本、静音 0 块
    // ② 提前供数的流（正对照，马车8 那种）：连交 10 块 → 全部交还 → 生产方卡 120 ms（播放时钟走 5760 帧）→ 再交 1 块：先 9600 B 静音再 4096 B
    // ③ 停设备期间只留一个交缓冲的：5 块在途时 Restart，停的过程中游戏线程交 2 块并 Pump、设备按 AudioQueueStop 文档逐块回调交还（回调里照常 Pump）；
    //    停时交的缓冲留在设备里（停之后才入队）。期望：同一块缓冲在设备里时被再交 0 次；停完收回 0 B（缓冲都经回调交还了）；
    //    停完时间线从头算、交还相位要重新学，不补垫：真实 2 块、静音 0 块（样本 6、7、8 共 12288 B 按槽长切成 9600 + 2688）
    // ④ 停设备失败（rc ≠ 0，缓冲还在设备里）：不收回，设备仍持有的 5 块不被再交
    // ⑤ 双缓冲按完成节奏供数的客人（太鼓：2 块 256 帧，交还一块马上补一块；每个设备周期两块一起交还、在途归零）：20 轮，静音 0 块
    //    （旧规则：两块都是「在途还有样本时交的」= 提前供数，每轮归零后补 9600 B 静音，20 轮 19 块静音）
    static class AudioPumpOwnerTest
    {
        private const int Bpf = 4, Slot = 9600, Floor = 12288, Block = 4096;

        private sealed class DevicePump : DeviceBufferPump
        {
            private readonly byte[][] _mem;
            public readonly bool[] InDevice;
            public readonly Queue<int> Device = new();
            public readonly List<(int Slot, int Bytes, bool Silent)> Submits = new();
            public int Doubles;
            // 假设备时间线：已交帧数之和 = 末尾；每块的末尾；播放时钟（交还时 = 这块末尾 − Lead）
            private const long Lead = 700;
            private long _end;
            private readonly long[] _ends = new long[32];
            public long Clock = long.MinValue;

            protected override long DeviceClock() => Clock;

            public DevicePump() : base(32, Slot, Bpf, 1 << 20, Floor, 240)
            {
                _mem = new byte[32][];
                InDevice = new bool[32];

                for (int i = 0; i < 32; i++)
                {
                    _mem[i] = new byte[Slot];
                }
            }

            protected override Span<byte> SlotData(int slot) => _mem[slot];

            protected override void Submit(int slot, int bytes)
            {
                if (InDevice[slot])
                {
                    Doubles++;
                }

                InDevice[slot] = true;
                _end += bytes / Bpf;
                _ends[slot] = _end;
                Device.Enqueue(slot);
                Submits.Add((slot, bytes, _mem[slot].AsSpan(0, bytes).IndexOfAnyExcept((byte)0) < 0));
            }

            // 设备交还最早的一块（AudioQueue 回调）：先交还，再像 OutputCallback 一样 Pump
            public void Callback()
            {
                int slot = Device.Dequeue();
                InDevice[slot] = false;
                Clock = _ends[slot] - Lead;
                Returned(slot);
                Pump();
            }

            // 停设备（AudioQueueStop）：时间线从 0 重来
            public void ResetTimeline()
            {
                _end = 0;
                Clock = -Lead;
            }

            public void Queue(int seed, int block = Block)
            {
                byte[] d = new byte[block];

                for (int i = 0; i < d.Length; i++)
                {
                    d[i] = (byte)(i * 7 + seed | 1);   // 非零：交出的缓冲全零 = 垫
                }

                Samples.Enqueue(new AudioBuffer { DataPointer = (ulong)seed, Data = d, DataSize = (ulong)block });
            }
        }

        private static string Shape(List<(int Slot, int Bytes, bool Silent)> s, int from = 0)
        {
            int silent = 0, data = 0;
            var sizes = new List<string>();

            for (int i = from; i < s.Count; i++)
            {
                if (s[i].Silent) silent++; else data++;
                sizes.Add(s[i].Silent ? $"静音 {s[i].Bytes}" : $"{s[i].Bytes}");
            }

            return $"真实 {data} 块、静音 {silent} 块（{string.Join(" ", sizes)}）";
        }

        [SoloTest("--audio-pump-owner")]
        private static int Run()
        {
            var rows = new List<(string Name, string Expect, string Actual)>();

            // ①
            {
                var p = new DevicePump();
                p.Queue(1); p.Pump(); p.ForcePrimed();   // 凑不够预充下限：看门狗兜底开播（S2APrimeFallback）

                for (int k = 2; k <= 13; k++)
                {
                    while (p.Device.Count > 0) p.Callback();   // 这块播完交还（在途归零）
                    p.Queue(k); p.Pump();                      // 客人这才交下一块
                }

                rows.Add(("① 单缓冲客人：起播 1 块 + 12 轮交还后再交（P1-26）", "真实 13 块、静音 0 块（" + string.Join(" ", System.Linq.Enumerable.Repeat("4096", 13)) + "）", Shape(p.Submits)));
            }

            // ②
            {
                var p = new DevicePump();
                for (int k = 1; k <= 10; k++) { p.Queue(k); p.Pump(); }
                while (p.Device.Count > 0) p.Callback();
                p.Clock += 5760;   // 生产方卡 120 ms：设备播完了已交的、播放时钟照走
                int mark = p.Submits.Count;
                p.Queue(11); p.Pump();
                rows.Add(("② 提前供数的流卡顿 120 ms 设备真断后再交 1 块（正对照）", "真实 1 块、静音 1 块（静音 9600 4096）", Shape(p.Submits, mark)));
            }

            // ③
            {
                var p = new DevicePump();
                for (int k = 1; k <= 5; k++) { p.Queue(k); p.Pump(); }
                p.ForcePrimed();
                int reclaimed = p.Restart(() =>
                {
                    int held = p.Device.Count;
                    p.Queue(6); p.Queue(7); p.Pump();   // 游戏线程照常送声音（QueueBuffer 不拿会话锁）
                    for (int i = 0; i < held; i++) p.Callback();   // 同步停：停之前入队的缓冲逐块回调交还（回调里照常 Pump）
                    p.ResetTimeline();
                    return 0;
                });
                int mark = p.Submits.Count;
                p.Queue(8); p.Pump();   // S2ARecover 停完再交，游戏随后再送一块
                // 停完：时间线从头算、交还相位重新学 → 不补垫；样本 6、7、8 共 12288 B 按槽长切成 9600 + 2688
                rows.Add(("③ 停设备期间：缓冲在设备里又被交的次数 / 收回的样本 / 停完交出的（P1-27）", "0 / 0 B / 真实 2 块、静音 0 块（9600 2688）",
                    $"{p.Doubles} / {reclaimed} B / {Shape(p.Submits, mark)}"));
            }

            // ④
            {
                var p = new DevicePump();
                for (int k = 1; k <= 5; k++) { p.Queue(k); p.Pump(); }
                int reclaimed = p.Restart(() => -1);
                p.Queue(6); p.Pump();
                rows.Add(("④ 停设备失败：收回的样本 / 设备仍持有的缓冲被再交的次数 / 在途块数", "0 B / 0 / 6", $"{reclaimed} B / {p.Doubles} / {p.Device.Count}"));
            }

            // ⑤
            {
                var p = new DevicePump();
                p.Queue(1, 1024); p.Pump(); p.Queue(2, 1024); p.Pump(); p.ForcePrimed();

                for (int k = 0; k < 20; k++)
                {
                    p.Callback(); p.Callback();                           // 同一个设备周期两块一起交还：在途归零
                    p.Queue(100 + k * 2, 1024); p.Pump();                 // 0 ms 后补回两块：第二块交时第一块还在途（旧规则的「提前供数」）
                    p.Queue(101 + k * 2, 1024); p.Pump();
                }

                int silent = 0;
                foreach (var x in p.Submits) if (x.Silent) silent++;
                rows.Add(("⑤ 双缓冲按完成节奏供数（太鼓 11-02）：20 轮的静音块数", "0", $"{silent}"));
            }

            int bad = 0;
            foreach (var (name, expect, actual) in rows)
            {
                bool ok = expect == actual;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 音频泵 {name}：{expect} → {actual}");
            }

            return bad == 0 ? 0 : 1;
        }
    }
}
