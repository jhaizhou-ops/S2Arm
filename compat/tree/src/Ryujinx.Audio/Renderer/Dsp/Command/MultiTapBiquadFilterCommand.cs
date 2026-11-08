using Ryujinx.Audio.Renderer.Dsp.State;
using Ryujinx.Audio.Renderer.Parameter;
using System;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class MultiTapBiquadFilterCommand : ICommand
    {
        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.MultiTapBiquadFilter;

        public uint EstimatedProcessingTime { get; set; }

        public BiquadFilterParameter2[] Parameters { get; private set; }
        public Memory<BiquadFilterState> BiquadFilterStates { get; private set; }
        public int InputBufferIndex { get; private set; }
        public int OutputBufferIndex { get; private set; }
        public bool[] IsInitialized { get; private set; }

        public MultiTapBiquadFilterCommand()
        {
            
        }

        // S2Arm: pooled command reinitialized every audio frame for every voice with filters; keep one array per length
        // (voices use 1 or 2 biquad filters) instead of allocating two arrays each time
        private BiquadFilterParameter2[] _parameters1, _parameters2;
        private bool[] _isInitialized1, _isInitialized2;

        public MultiTapBiquadFilterCommand Initialize(int baseIndex, ReadOnlySpan<BiquadFilterParameter2> filters, Memory<BiquadFilterState> biquadFilterStateMemory, int inputBufferOffset, int outputBufferOffset, ReadOnlySpan<bool> isInitialized, int nodeId)
        {
            Parameters = filters.Length switch
            {
                1 => _parameters1 ??= new BiquadFilterParameter2[1],
                2 => _parameters2 ??= new BiquadFilterParameter2[2],
                _ => new BiquadFilterParameter2[filters.Length],
            };
            filters.CopyTo(Parameters);
            BiquadFilterStates = biquadFilterStateMemory;
            InputBufferIndex = baseIndex + inputBufferOffset;
            OutputBufferIndex = baseIndex + outputBufferOffset;
            IsInitialized = isInitialized.Length switch
            {
                1 => _isInitialized1 ??= new bool[1],
                2 => _isInitialized2 ??= new bool[2],
                _ => new bool[isInitialized.Length],
            };
            isInitialized.CopyTo(IsInitialized);

            Enabled = true;
            NodeId = nodeId;
            
            return this;
        }

        public void Process(CommandList context)
        {
            Span<BiquadFilterState> states = BiquadFilterStates.Span;

            ReadOnlySpan<float> inputBuffer = context.GetBuffer(InputBufferIndex);
            Span<float> outputBuffer = context.GetBuffer(OutputBufferIndex);

            for (int i = 0; i < Parameters.Length; i++)
            {
                if (!IsInitialized[i])
                {
                    states[i] = new BiquadFilterState();
                }
            }

            // NOTE: Nintendo only implement single and double biquad filters but no generic path when the command definition suggests it could be done.
            // As such we currently only implement a generic path for simplicity for double biquad.
            if (Parameters.Length == 1)
            {
                BiquadFilterHelper.ProcessBiquadFilter(ref Parameters[0], ref states[0], outputBuffer, inputBuffer, context.SampleCount);
            }
            else
            {
                BiquadFilterHelper.ProcessBiquadFilter(Parameters, states, outputBuffer, inputBuffer, context.SampleCount);
            }
        }
    }
}
