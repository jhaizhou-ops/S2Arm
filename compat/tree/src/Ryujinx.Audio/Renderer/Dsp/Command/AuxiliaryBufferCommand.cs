using Ryujinx.Audio.Renderer.Common;
using Ryujinx.Memory;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Ryujinx.Audio.Renderer.Dsp.State.AuxiliaryBufferHeader;
using CpuAddress = System.UInt64;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class AuxiliaryBufferCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.AuxiliaryBuffer;

        public uint EstimatedProcessingTime { get; set; }

        public uint InputBufferIndex { get; private set; }
        public uint OutputBufferIndex { get; private set; }

        public AuxiliaryBufferAddresses BufferInfo { get; private set; }

        public CpuAddress InputBuffer { get; private set; }
        public CpuAddress OutputBuffer { get; private set; }
        public uint CountMax { get; private set; }
        public uint UpdateCount { get; private set; }
        public uint WriteOffset { get; private set; }

        public bool IsEffectEnabled { get; private set; }

        public AuxiliaryBufferCommand()
        {
            
        }
        
        public AuxiliaryBufferCommand Initialize(
            uint bufferOffset,
            byte inputBufferOffset,
            byte outputBufferOffset,
            ref AuxiliaryBufferAddresses sendBufferInfo,
            bool isEnabled,
            uint countMax,
            CpuAddress outputBuffer,
            CpuAddress inputBuffer,
            uint updateCount,
            uint writeOffset,
            int nodeId)
        {
            Enabled = true;
            NodeId = nodeId;
            InputBufferIndex = bufferOffset + inputBufferOffset;
            OutputBufferIndex = bufferOffset + outputBufferOffset;
            BufferInfo = sendBufferInfo;
            InputBuffer = inputBuffer;
            OutputBuffer = outputBuffer;
            CountMax = countMax;
            UpdateCount = updateCount;
            WriteOffset = writeOffset;
            IsEffectEnabled = isEnabled;
            
            return this;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private uint Read(IVirtualMemoryManager memoryManager, ulong bufferAddress, uint countMax, Span<int> outBuffer, uint count, uint readOffset, uint updateCount)
        {
            if (countMax == 0 || bufferAddress == 0)
            {
                return 0;
            }

            uint targetReadOffset = readOffset + AuxiliaryBufferInfo.GetReadOffset(memoryManager, BufferInfo.ReturnBufferInfo);

            if (targetReadOffset > countMax)
            {
                return 0;
            }

            uint remaining = count;

            uint outBufferOffset = 0;

            while (remaining != 0)
            {
                uint countToWrite = Math.Min(countMax - targetReadOffset, remaining);

                memoryManager.Read(bufferAddress + targetReadOffset * sizeof(int), MemoryMarshal.Cast<int, byte>(outBuffer.Slice((int)outBufferOffset, (int)countToWrite)));

                targetReadOffset = (targetReadOffset + countToWrite) % countMax;
                remaining -= countToWrite;
                outBufferOffset += countToWrite;
            }

            if (updateCount != 0)
            {
                uint newReadOffset = (AuxiliaryBufferInfo.GetReadOffset(memoryManager, BufferInfo.ReturnBufferInfo) + updateCount) % countMax;

                AuxiliaryBufferInfo.SetReadOffset(memoryManager, BufferInfo.ReturnBufferInfo, newReadOffset);
            }

            return count;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private uint Write(IVirtualMemoryManager memoryManager, ulong outBufferAddress, uint countMax, ReadOnlySpan<int> buffer, uint count, uint writeOffset, uint updateCount)
        {
            if (countMax == 0 || outBufferAddress == 0)
            {
                return 0;
            }

            uint targetWriteOffset = writeOffset + AuxiliaryBufferInfo.GetWriteOffset(memoryManager, BufferInfo.SendBufferInfo);

            if (targetWriteOffset > countMax)
            {
                return 0;
            }

            uint remaining = count;

            uint inBufferOffset = 0;

            while (remaining != 0)
            {
                uint countToWrite = Math.Min(countMax - targetWriteOffset, remaining);

                memoryManager.Write(outBufferAddress + targetWriteOffset * sizeof(int), MemoryMarshal.Cast<int, byte>(buffer.Slice((int)inBufferOffset, (int)countToWrite)));

                targetWriteOffset = (targetWriteOffset + countToWrite) % countMax;
                remaining -= countToWrite;
                inBufferOffset += countToWrite;
            }

            if (updateCount != 0)
            {
                uint newWriteOffset = (AuxiliaryBufferInfo.GetWriteOffset(memoryManager, BufferInfo.SendBufferInfo) + updateCount) % countMax;

                AuxiliaryBufferInfo.SetWriteOffset(memoryManager, BufferInfo.SendBufferInfo, newWriteOffset);
            }

            return count;
        }

        // S2Arm 诊断（S2A_AUX_DIAG=1 开，缺省关）：游戏混响回调用 ReadAuxSendBuffer 读回的样本数做两个检查
        //   （不是「声道数 × 每帧样本」整数倍、读到帧数超过缓冲帧数 → abort）。每个送出缓冲在最后一个声道的命令（UpdateCount ≠ 0）处记：
        //   CPU / DSP 两份信息头的读写偏移、丢样本数、总样本数，环形上限 CountMax，实际声道数 = UpdateCount / SampleCount。
        //   首见 / 参数变时打一行；游戏读偏移一动就核这次读量 d 与上次读偏移变动以来 DSP 写入量，d 不是 UpdateCount 整数倍、或写入量超过 CountMax（游戏一圈没读、DSP 套圈）打一行（上限 400 行）；每 2000 次打汇总
        private static readonly bool s_auxDiag = Environment.GetEnvironmentVariable("S2A_AUX_DIAG") == "1";
        private sealed class AuxDiagState
        {
            public uint CountMax, UpdateCount, SampleCount, CpuR, WrittenSinceRead, Calls, Reads, ReadMin = uint.MaxValue, ReadMax, PendingMax, Odd, Laps;
        }
        private static readonly System.Collections.Generic.Dictionary<ulong, AuxDiagState> s_auxDiagStates = new();
        private static int s_auxDiagLines;

        private void AuxDiag(CommandList context)
        {
            IVirtualMemoryManager mm = context.MemoryManager;
            ulong dsp = BufferInfo.SendBufferInfo, cpu = dsp - 0x40, rdsp = BufferInfo.ReturnBufferInfo;
            uint cR = mm.Read<uint>(cpu), cW = mm.Read<uint>(cpu + 4), cLost = mm.Read<uint>(cpu + 8), cTotal = mm.Read<uint>(cpu + 12);
            uint dR = mm.Read<uint>(dsp), dW = mm.Read<uint>(dsp + 4), dLost = mm.Read<uint>(dsp + 8), dTotal = mm.Read<uint>(dsp + 12);
            uint rR = rdsp != 0 ? mm.Read<uint>(rdsp) : 0, rW = rdsp != 0 ? mm.Read<uint>(rdsp + 4) : 0;
            string Head() => $"CountMax={CountMax} 声道={(context.SampleCount != 0 ? UpdateCount / context.SampleCount : 0)}（UpdateCount={UpdateCount} SampleCount={context.SampleCount}） " +
                             $"送出 CPU 读 {cR} 写 {cW} 丢 {cLost} 总 {cTotal}｜DSP 读 {dR} 写 {dW} 丢 {dLost} 总 {dTotal}｜回送 DSP 读 {rR} 写 {rW}";

            lock (s_auxDiagStates)
            {
                if (!s_auxDiagStates.TryGetValue(dsp, out AuxDiagState st) || st.CountMax != CountMax || st.UpdateCount != UpdateCount || st.SampleCount != context.SampleCount)
                {
                    s_auxDiagStates[dsp] = st = new AuxDiagState { CountMax = CountMax, UpdateCount = UpdateCount, SampleCount = context.SampleCount, CpuR = cR };
                    Console.Error.WriteLine($"[辅缓诊] 送出 0x{dsp:x} 首见 / 参数变：{Head()}");
                }

                st.Calls++;
                if (cR != st.CpuR && CountMax != 0)
                {
                    uint d = (cR + CountMax - st.CpuR) % CountMax;
                    st.Reads++;
                    st.ReadMin = Math.Min(st.ReadMin, d);
                    st.ReadMax = Math.Max(st.ReadMax, d);
                    bool odd = UpdateCount != 0 && d % UpdateCount != 0;
                    bool lap = st.WrittenSinceRead > CountMax;
                    if (odd) st.Odd++;
                    if (lap) st.Laps++;
                    if ((odd || lap) && s_auxDiagLines < 400)
                    {
                        s_auxDiagLines++;
                        Console.Error.WriteLine($"[辅缓诊] 送出 0x{dsp:x} 第 {st.Calls} 次：游戏读 {d}（上次读偏移 {st.CpuR}），上次读偏移变动以来 DSP 写入 {st.WrittenSinceRead}{(odd ? "，不是整数倍" : "")}{(lap ? "，DSP 已套圈" : "")}；{Head()}");
                    }
                    st.WrittenSinceRead = 0;
                    st.CpuR = cR;
                }

                st.WrittenSinceRead += UpdateCount;   // 本次 Write 推进的量
                st.PendingMax = Math.Max(st.PendingMax, st.WrittenSinceRead);
                if (st.Calls % 2000 == 0)
                {
                    Console.Error.WriteLine($"[辅缓诊] 送出 0x{dsp:x} 汇总 {st.Calls} 次：游戏读 {st.Reads} 次（每次 {(st.Reads != 0 ? st.ReadMin : 0)}–{st.ReadMax}），两次读之间写入最多 {st.PendingMax}，不是整数倍 {st.Odd} 次，套圈 {st.Laps} 次；{Head()}");
                }
            }
        }

        public void Process(CommandList context)
        {
            Span<float> inputBuffer = context.GetBuffer((int)InputBufferIndex);
            Span<float> outputBuffer = context.GetBuffer((int)OutputBufferIndex);

            if (IsEffectEnabled)
            {
                Span<int> inputBufferInt = MemoryMarshal.Cast<float, int>(inputBuffer);
                Span<int> outputBufferInt = MemoryMarshal.Cast<float, int>(outputBuffer);

                // Convert input data to the target format for user (int)
                DataSourceHelper.ToInt(inputBufferInt, inputBuffer, inputBuffer.Length);

                if (s_auxDiag && UpdateCount != 0)
                {
                    AuxDiag(context);
                }

                // Send the input to the user
                Write(context.MemoryManager, OutputBuffer, CountMax, inputBufferInt, context.SampleCount, WriteOffset, UpdateCount);

                // Convert back to float just in case it's reused
                DataSourceHelper.ToFloat(inputBuffer, inputBufferInt, inputBuffer.Length);

                // Retrieve the input from user
                uint readResult = Read(context.MemoryManager, InputBuffer, CountMax, outputBufferInt, context.SampleCount, WriteOffset, UpdateCount);

                // Convert the outputBuffer back to the target format of the renderer (float)
                DataSourceHelper.ToFloat(outputBuffer, outputBufferInt, outputBuffer.Length);

                if (readResult != context.SampleCount)
                {
                    outputBuffer[(int)readResult..(int)context.SampleCount].Clear();
                }
            }
            else
            {
                AuxiliaryBufferInfo.Reset(context.MemoryManager, BufferInfo.SendBufferInfo);
                AuxiliaryBufferInfo.Reset(context.MemoryManager, BufferInfo.ReturnBufferInfo);

                if (InputBufferIndex != OutputBufferIndex)
                {
                    inputBuffer.CopyTo(outputBuffer);
                }
            }
        }
    }
}
