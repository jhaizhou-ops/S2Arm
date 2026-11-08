using System;

namespace Ryujinx.Audio.Renderer.Dsp
{
    // S2Arm (10-23 塞尔达分层账：C# 前三热点全是音频 DSP)：ARM 上的音频 DSP 快路径开关。
    //   S2A_AUDIO_DSP_FAST=1 开（缺省关，测试机2 同包 A/B 达标后翻缺省）。快路径与原路径逐样本输出一致（同运算、同求和顺序、同舍入），
    //   只去掉 ARM 上的多余开销：重采样走标量（SSE 快路径只认 x86）、每次 32 KB 栈缓冲清零、双二阶滤波器状态逐样本经引用读写。
    internal static class S2ADspFast
    {
        public static readonly bool On = Environment.GetEnvironmentVariable("S2A_AUDIO_DSP_FAST") == "1";
    }
}
