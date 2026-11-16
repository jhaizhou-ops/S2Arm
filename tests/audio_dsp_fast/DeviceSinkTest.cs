// 设备输出（DeviceSinkCommand.Process）：2 声道 / 5.1 两条 SIMD 内核逐样本覆盖全部输出帧，只有逐声道回退布局才需要整块清零。
//   判据：每次运行前把 ArrayPool 里同尺寸的缓冲填满固定垃圾值；2/6 声道输出必须仍与参考逐样本一致，
//   回退布局（2 声道设备 + 1 路输入）缺的右声道必须是 0 而不是垃圾。审计 P4-4。
using Ryujinx.Audio;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Parameter.Sink;
using Ryujinx.Audio.Renderer.Server.Sink;
using System;
using System.Buffers;

static partial class Program
{
    sealed class CaptureDevice : IHardwareDevice
    {
        private readonly uint _channelCount;

        public short[] Data;
        public uint DataChannelCount;
        public int AppendCalls;

        public CaptureDevice(uint channelCount)
        {
            _channelCount = channelCount;
        }

        public void SetVolume(float volume) { }

        public float GetVolume() => 1.0f;

        public uint GetSampleRate() => Constants.TargetSampleRate;

        public uint GetChannelCount() => _channelCount;

        public void AppendBuffer(ReadOnlySpan<short> data, uint channelCount)
        {
            Data = data.ToArray();
            DataChannelCount = channelCount;
            AppendCalls++;
        }

        public void Dispose() { }
    }

    static void PoisonShortPool(int count)
    {
        for (int i = 0; i < 16; i++)
        {
            short[] buffer = ArrayPool<short>.Shared.Rent(count);
            Array.Fill(buffer, (short)0x5A5A, 0, count);
            ArrayPool<short>.Shared.Return(buffer);
        }
    }

    static void TestDeviceSink(Random r)
    {
        const int SampleCount = Constants.TargetSampleCount;
        const int BufferCountMax = Constants.ChannelCountMax;

        (int deviceChannels, int inputCount)[] configurations =
        {
            (2, 2), // 最常见：立体声，SIMD 内核完整覆盖
            (2, 3), // 输入多于设备：bufferCount 取 2
            (6, 6), // 5.1 完整覆盖
            (6, 3), // 上混到 5.1，后三声道必须是 0
            (6, 1),
            (4, 3), // 4 声道设备缺一路：回退循环只写前 3 路，第 4 路靠清零
            (4, 4), // 其他多声道布局：回退循环写满
            (1, 1),
        };

        foreach ((int deviceChannels, int inputCount) in configurations)
        {
            int bufferCount = Math.Min(deviceChannels, inputCount);
            int outCount = (bufferCount != deviceChannels && deviceChannels == 6) ? 6 : bufferCount;

            for (int iteration = 0; iteration < 64; iteration++)
            {
                float[][] channels = new float[bufferCount][];

                for (int channel = 0; channel < bufferCount; channel++)
                {
                    channels[channel] = new float[SampleCount];

                    for (int i = 0; i < SampleCount; i++)
                    {
                        channels[channel][i] = (float)(r.NextDouble() * 80000 - 40000);
                    }

                    if (iteration % 8 == 0)
                    {
                        channels[channel][r.Next(SampleCount)] = float.NaN;
                        channels[channel][r.Next(SampleCount)] = float.PositiveInfinity;
                        channels[channel][r.Next(SampleCount)] = float.NegativeInfinity;
                    }
                }

                float[] mix = new float[BufferCountMax * SampleCount];

                for (int channel = 0; channel < bufferCount; channel++)
                {
                    channels[channel].AsSpan().CopyTo(mix.AsSpan(channel * SampleCount, SampleCount));
                }

                DeviceSink sink = new();
                sink.Parameter = new DeviceParameter { InputCount = (uint)inputCount };

                Span<byte> input = sink.Parameter.Input.AsSpan();

                for (int i = 0; i < input.Length; i++)
                {
                    input[i] = (byte)i;
                }

                Memory<float> memory = new(mix);
                CaptureDevice device = new((uint)deviceChannels);

                PoisonShortPool(outCount * SampleCount);

                using (CommandList list = new(null, memory, SampleCount, Constants.TargetSampleRate, BufferCountMax, 0))
                {
                    list.AddCommand(new DeviceSinkCommand().Initialize(0, sink, 0, memory, 1));
                    list.Process(device);
                }

                short[] expected = new short[outCount * SampleCount];

                for (int channel = 0; channel < bufferCount; channel++)
                {
                    for (int i = 0; i < SampleCount; i++)
                    {
                        int index = channel + i * deviceChannels;

                        // 回退布局的交织步长按设备声道数算；交给设备的只有前 inputCount * SampleCount 个样本。
                        if ((uint)index < (uint)expected.Length)
                        {
                            expected[index] = PcmHelper.Saturate(channels[channel][i]);
                        }
                    }
                }

                string tag = $"device sink {deviceChannels}ch input={inputCount} iter={iteration}";
                cases++;

                if (device.AppendCalls != 1)
                {
                    Fail($"{tag} append calls want 1 got {device.AppendCalls}");
                    continue;
                }

                if (device.DataChannelCount != (uint)outCount)
                {
                    Fail($"{tag} channel count want {outCount} got {device.DataChannelCount}");
                    continue;
                }

                if (!device.Data.AsSpan().SequenceEqual(expected))
                {
                    int bad = 0;

                    for (int i = 0; i < expected.Length; i++)
                    {
                        if (device.Data[i] != expected[i])
                        {
                            if (bad++ == 0)
                            {
                                Fail($"{tag} [{i}] want {expected[i]} got {device.Data[i]}");
                            }
                        }
                    }
                }
            }
        }
    }
}
