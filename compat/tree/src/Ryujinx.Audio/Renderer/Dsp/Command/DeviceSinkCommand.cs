using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Server.Sink;
using System;
using System.Buffers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class DeviceSinkCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.DeviceSink;

        public uint EstimatedProcessingTime { get; set; }

        public string DeviceName { get; private set; }

        public int SessionId { get; private set; }

        public uint InputCount { get; private set; }
        public ushort[] InputBufferIndices { get; private set; }

        public Memory<float> Buffers { get; private set; }

        // S2Arm (#1182 无声诊断)：交设备前（饱和转 int16 之前）混音结果里的 NaN 样本累计数。饱和把 NaN 变 0，到设备那边已分不出
        //   「渲染出 NaN」与「渲染出真 0」，只能在 float 阶段数。全渲染器共用一个计数：本命令只在音频渲染线程上跑，有 NaN 时才原子加一次；
        //   Apple 后端的 10 秒 [声] 行（S2AOutputDiag）取走清零。
        public static long S2ANaNSamples;

        private static int S2ACountNaN(ReadOnlySpan<float> buffer)
        {
            int count = 0;

            foreach (float sample in buffer)
            {
                if (float.IsNaN(sample))
                {
                    count++;
                }
            }

            return count;
        }

        public DeviceSinkCommand()
        {
            
        }

        public DeviceSinkCommand Initialize(uint bufferOffset, DeviceSink sink, int sessionId, Memory<float> buffers, int nodeId)
        {
            Enabled = true;
            NodeId = nodeId;

            // Unused and wasting time and memory, re-add if needed
            // DeviceName = Encoding.ASCII.GetString(sink.Parameter.DeviceName).TrimEnd('\0');
            
            SessionId = sessionId;
            InputCount = sink.Parameter.InputCount;
            // S2Arm: pooled command, keep the array while the input count is unchanged (was allocated every frame)
            if (InputBufferIndices == null || InputBufferIndices.Length != InputCount)
            {
                InputBufferIndices = new ushort[InputCount];
            }
            
            Span<byte> inputSpan = sink.Parameter.Input.AsSpan();

            for (int i = 0; i < Math.Min(InputCount, Constants.ChannelCountMax); i++)
            {
                InputBufferIndices[i] = (ushort)(bufferOffset + inputSpan[i]);
            }

            if (sink.UpsamplerInfo != null)
            {
                Buffers = sink.UpsamplerInfo.OutputBuffer;
            }
            else
            {
                Buffers = buffers;
            }

            return this;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private Span<float> GetBuffer(int index, int sampleCount)
        {
            return Buffers.Span.Slice(index * sampleCount, sampleCount);
        }

        // S2Arm: 5.1 交织内核的声道取数——缓冲区数不足 6（上混）的声道没有数据，给空 span（内核查零向量），
        //   与原循环先整块清零再只写前 bufferCount 个声道的行为一致。
        private ReadOnlySpan<float> BufferOrEmpty(uint bufferCount, int index, int sampleCount)
        {
            return index < (int)bufferCount ? GetBuffer(InputBufferIndices[index], sampleCount) : default;
        }

        public void Process(CommandList context)
        {
            IHardwareDevice device = context.OutputDevice;

            if (device.GetSampleRate() == Constants.TargetSampleRate)
            {
                int channelCount = (int)device.GetChannelCount();
                uint bufferCount = Math.Min(device.GetChannelCount(), InputCount);

                const int SampleCount = Constants.TargetSampleCount;

                uint inputCount;

                // In case of upmixing to 5.1, we allocate the right amount.
                if (bufferCount != channelCount && channelCount == 6)
                {
                    inputCount = (uint)channelCount;
                }
                else
                {
                    inputCount = bufferCount;
                }

                // S2Arm (#1182)：饱和前数 NaN（见 S2ANaNSamples）
                int nanSamples = 0;

                for (int i = 0; i < bufferCount; i++)
                {
                    nanSamples += S2ACountNaN(GetBuffer(InputBufferIndices[i], SampleCount));
                }

                if (nanSamples != 0)
                {
                    Interlocked.Add(ref S2ANaNSamples, nanSamples);
                }

                short[] outputBuffer = ArrayPool<short>.Shared.Rent((int)inputCount * SampleCount);

                // S2Arm: 立体声设备 + 双声道输入（最常见的设备形态）走 S2ADspMixHelper 的饱和窄化 + 交织内核；
                //   5.1（6 声道）设备走 6 声道交织内核（缓冲区数不足 6 的上混，静音声道传空 span 查零，
                //   与原循环先整块清零再只写前面的声道一致）；其余布局照原逐样本循环。
                //   各路径逐样本一致（FCVTZS+SQXTN ≡ 夹取后截断）。
                if (channelCount == 2 && bufferCount == 2)
                {
                    S2ADspMixHelper.SaturateInterleaveStereo(
                        outputBuffer,
                        GetBuffer(InputBufferIndices[0], SampleCount),
                        GetBuffer(InputBufferIndices[1], SampleCount),
                        (int)SampleCount);
                }
                else if (channelCount == 6)
                {
                    S2ADspMixHelper.SaturateInterleave6(
                        outputBuffer,
                        BufferOrEmpty(bufferCount, 0, (int)SampleCount),
                        BufferOrEmpty(bufferCount, 1, (int)SampleCount),
                        BufferOrEmpty(bufferCount, 2, (int)SampleCount),
                        BufferOrEmpty(bufferCount, 3, (int)SampleCount),
                        BufferOrEmpty(bufferCount, 4, (int)SampleCount),
                        BufferOrEmpty(bufferCount, 5, (int)SampleCount),
                        (int)SampleCount);
                }
                else
                {
                    // S2Arm: 两个 SIMD 内核逐样本覆盖全部输出帧，只有这条逐声道循环给不足 bufferCount 的声道留空位，
                    //   缺的静音声道靠清零（审计 P4-4：原先无条件整块清零，2/6 声道最常见的两条路径纯浪费）。
                    Array.Fill(outputBuffer, (short)0, 0, (int)inputCount * SampleCount);

                    for (int i = 0; i < bufferCount; i++)
                    {
                        ReadOnlySpan<float> inputBuffer = GetBuffer(InputBufferIndices[i], SampleCount);

                        for (int j = 0; j < SampleCount; j++)
                        {
                            outputBuffer[i + j * channelCount] = PcmHelper.Saturate(inputBuffer[j]);
                        }
                    }
                }

                device.AppendBuffer(outputBuffer.AsSpan(..((int)inputCount * SampleCount)), inputCount);
                
                ArrayPool<short>.Shared.Return(outputBuffer);
            }
            else
            {
                // TODO: support resampling for device only supporting something different
                throw new NotImplementedException();
            }
        }
    }
}
