using Ryujinx.Audio.Integration;

namespace Ryujinx.Audio.Common
{
    /// <summary>
    /// Represent an audio buffer that will be used by an <see cref="IHardwareDeviceSession"/>.
    /// </summary>
    public class AudioBuffer
    {
        /// <summary>
        /// Unique tag of this buffer.
        /// </summary>
        /// <remarks>Unique per session</remarks>
        public ulong BufferTag;

        /// <summary>
        /// Pointer to the user samples.
        /// </summary>
        public ulong DataPointer;

        /// <summary>
        /// Size of the user samples region.
        /// </summary>
        public ulong DataSize;

        /// <summary>
        ///  The timestamp at which the buffer was played.
        /// </summary>
        /// <remarks>Not used but useful for debugging</remarks>
        public ulong PlayedTimestamp;

        /// <summary>
        /// The user samples.
        /// </summary>
        public byte[] Data;

        // S2Arm: a registered buffer's samples stay in guest memory (no array sized by the game: DataSize can be anything) and the device
        // pulls them in bounded chunks through this session, which also applies the compat layer's downmix / format conversion.
        // Null when Data holds the samples (renderer output).
        public Backends.Common.HardwareDeviceSessionOutputBase SampleReader;
    }
}
