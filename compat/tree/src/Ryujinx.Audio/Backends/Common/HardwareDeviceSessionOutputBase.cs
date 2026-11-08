using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Audio.Backends.Common
{
    public abstract class HardwareDeviceSessionOutputBase : IHardwareDeviceSession
    {
        public IVirtualMemoryManager MemoryManager { get; }
        public SampleFormat RequestedSampleFormat { get; }
        public uint RequestedSampleRate { get; }
        public uint RequestedChannelCount { get; }

        public HardwareDeviceSessionOutputBase(IVirtualMemoryManager memoryManager, SampleFormat requestedSampleFormat, uint requestedSampleRate, uint requestedChannelCount)
        {
            MemoryManager = memoryManager;
            RequestedSampleFormat = requestedSampleFormat;
            RequestedSampleRate = requestedSampleRate;
            RequestedChannelCount = requestedChannelCount;
        }

        protected ulong GetSampleCount(AudioBuffer buffer)
        {
            return GetSampleCount((int)buffer.DataSize);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        protected ulong GetSampleCount(int dataSize)
        {
            return (ulong)BackendHelper.GetSampleCount(RequestedSampleFormat, (int)RequestedChannelCount, dataSize);
        }

        public abstract void Dispose();
        public abstract void PrepareToClose();
        public abstract void QueueBuffer(AudioBuffer buffer);
        public abstract void SetVolume(float volume);
        public abstract float GetVolume();
        public abstract void Start();
        public abstract void Stop();
        public abstract ulong GetPlayedSampleCount();
        public abstract bool WasBufferFullyConsumed(AudioBuffer buffer);
        // S2Arm: registering no longer copies the samples into a new byte[DataSize] (a managed array as large as the game asks, on every
        // append): they stay in guest memory, where they are owned by the audio system until released, and the device pulls them through
        // ReadSamples in bounded chunks (AudioSampleQueue). A wrapping session (compat layer) sets SampleReader to itself first.
        public virtual bool RegisterBuffer(AudioBuffer buffer)
        {
            if (buffer.DataPointer == 0)
            {
                return false;
            }

            buffer.SampleReader ??= this;

            return true;
        }

        /// <summary>
        /// Copy the samples of a registered buffer, in this session's format, from byte offset into destination.
        /// </summary>
        public virtual void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
        {
            MemoryManager.Read(buffer.DataPointer + offset, destination);
        }

        public virtual void UnregisterBuffer(AudioBuffer buffer) { }
    }
}
