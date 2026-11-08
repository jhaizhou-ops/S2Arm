// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Audio.Renderer.Server.Voice;
using System;
using PlayState = Ryujinx.Audio.Renderer.Server.Types.PlayState;

namespace S2A.Services.Tests
{
    // 冲刷波形缓冲（VoiceInfo.FlushWaveBuffers）的「已消耗」计数，11-05 伊苏X 声音槽泄漏到 512 后 AcquireVoiceSlot() failed。
    // 游戏放槽前：GetWaveBufferCount ≥ 1 → FlushWaveBuffers → 取完已释放缓冲 → GetWaveBufferCount 为 0 才 ReleaseVoiceSlot，否则下轮再试。
    //   客户端 GetWaveBufferCount = 已追加数 − PlayedWaveBuffersCount（服务端回写 = 声道 0 的 WaveBufferConsumed）。
    // 真值：同款 sdk 内服务端 nn::audio::server::VoiceInfo::FlushWaveBuffers（sdk+0x218b04）逐个冲刷槽位 idx：
    //   IsSendToAudioProcessor = 1；每个声道：若 WaveBufferIndex == idx 则 WaveBufferIndex = (idx + 1) % 4、WaveBufferConsumed++；
    //   IsWaveBufferValid[idx] = 0。即按 DSP 当前读到的槽位判，没送过 DSP 的缓冲也算已消耗，DSP 已读完的不重复计。
    // 用例（期望按上面规则手算，不跑被测实现）：
    //   A 停止态、槽 0 已追加但没送过 DSP（有效 = 否，DSP 槽位 0，已消耗 0），冲刷 1 → 已消耗 1、槽位 1；客户端剩余 1 − 1 = 0，可放槽
    //   B 同 A 但双声道 → 两个声道都 已消耗 1、槽位 1
    //   C 播放中、槽 0 已送 DSP 且已被 DSP 读完（DSP 槽位已到 1、已消耗 1、有效 = 否），冲刷 1（从槽 0 起）→ 不重复计：已消耗 1、槽位 1
    //   D 暂停态、槽 2 已送 DSP 未读完（DSP 槽位 2、已消耗 2、有效 = 是），冲刷 2（从槽 2 起，槽 3 没送过）→ 已消耗 4、槽位 0、槽 2 有效 = 否
    static class VoiceFlushTest
    {
        [SoloTest("--voice-flush")]
        private static int Run()
        {
            int bad = 0;
            void Row(string name, string expect, string actual)
            {
                bool ok = expect == actual;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 冲刷波形缓冲 {name}：{expect} → {actual}");
            }

            // 一个声音槽：channels 个声道，各自一份 DSP 侧 VoiceState
            (VoiceInfo info, VoiceState[][] states, Memory<VoiceState>[] mem) Make(PlayState ps, int channels, uint wbIndex, byte flush)
            {
                VoiceInfo info = new();
                info.Initialize();
                info.InUse = true;
                info.PlayState = ps;
                info.PreviousPlayState = ps;
                info.ChannelsCount = (uint)channels;
                info.WaveBuffersCount = 1;
                info.WaveBuffersIndex = wbIndex;
                info.FlushWaveBufferCount = flush;
                VoiceState[][] states = new VoiceState[channels][];
                Memory<VoiceState>[] mem = new Memory<VoiceState>[channels];
                for (int c = 0; c < channels; c++)
                {
                    states[c] = new VoiceState[1];
                    mem[c] = states[c];
                }
                return (info, states, mem);
            }

            string Show(VoiceState[][] states) =>
                string.Join(" ", Array.ConvertAll(states, s => $"已消耗 {s[0].WaveBufferConsumed} 槽位 {s[0].WaveBufferIndex}"));

            // A：停止态，槽 0 已追加、没送过 DSP
            {
                var (info, states, mem) = Make(PlayState.Stopped, 1, 0, 1);
                info.UpdateParametersForCommandGeneration(mem);
                Row("A 停止态冲刷没送过 DSP 的缓冲", "已消耗 1 槽位 1", Show(states));
                Row("A 客户端剩余缓冲（已追加 1 − 回写已播）", "0", (1 - states[0][0].WaveBufferConsumed).ToString());
                Row("A 冲刷计数清零", "0", info.FlushWaveBufferCount.ToString());
            }

            // B：同 A，双声道
            {
                var (info, states, mem) = Make(PlayState.Stopped, 2, 0, 1);
                info.UpdateParametersForCommandGeneration(mem);
                Row("B 双声道", "已消耗 1 槽位 1 已消耗 1 槽位 1", Show(states));
            }

            // C：播放中，槽 0 已被 DSP 读完，冲刷不重复计
            {
                var (info, states, mem) = Make(PlayState.Started, 1, 0, 1);
                info.WaveBuffers[0].IsSendToAudioProcessor = true;
                states[0][0].WaveBufferIndex = 1;
                states[0][0].WaveBufferConsumed = 1;
                info.UpdateParametersForCommandGeneration(mem);
                Row("C DSP 已读完的不重复计", "已消耗 1 槽位 1", Show(states));
            }

            // D：暂停态，槽 2 已送 DSP 未读完、槽 3 没送过，从槽 2 冲刷 2 个
            {
                var (info, states, mem) = Make(PlayState.Paused, 1, 2, 2);
                info.WaveBuffers[2].IsSendToAudioProcessor = true;
                states[0][0].WaveBufferIndex = 2;
                states[0][0].WaveBufferConsumed = 2;
                states[0][0].IsWaveBufferValid[2] = true;
                info.UpdateParametersForCommandGeneration(mem);
                Row("D 已送未读 + 没送过", "已消耗 4 槽位 0", Show(states));
                Row("D 槽 2 有效标记清掉", "False", states[0][0].IsWaveBufferValid[2].ToString());
                Row("D 槽 2 / 3 标已送", "True True", $"{info.WaveBuffers[2].IsSendToAudioProcessor} {info.WaveBuffers[3].IsSendToAudioProcessor}");
            }

            return bad == 0 ? 0 : 1;
        }
    }
}
