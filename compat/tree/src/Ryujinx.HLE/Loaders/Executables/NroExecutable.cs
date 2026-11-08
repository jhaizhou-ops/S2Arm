using LibHac.Fs;
using LibHac.Tools.Ro;
using System;

namespace Ryujinx.HLE.Loaders.Executables
{
    class NroExecutable : Nro, IExecutable
    {
        // S2Arm: Memory<byte> so the image can be a view of the game's NRO buffer (no copy of the whole NRO)
        private readonly Memory<byte> _program;
        public Span<byte> Program => _program.Span;
        public Span<byte> Text => Program.Slice((int)TextOffset, (int)Header.NroSegments[0].Size);
        public Span<byte> Ro => Program.Slice((int)RoOffset, (int)Header.NroSegments[1].Size);
        public Span<byte> Data => Program.Slice((int)DataOffset, (int)Header.NroSegments[2].Size);

        public uint TextOffset => Header.NroSegments[0].FileOffset;
        public uint RoOffset => Header.NroSegments[1].FileOffset;
        public uint DataOffset => Header.NroSegments[2].FileOffset;
        public uint BssOffset => DataOffset + (uint)Data.Length;
        public uint BssSize => Header.BssSize;

        public uint Mod0Offset => (uint)Start.Mod0Offset;
        public uint FileSize => Header.Size;

        public ulong SourceAddress { get; private set; }
        public ulong BssAddress { get; private set; }

        public NroExecutable(IStorage inStorage, ulong sourceAddress = 0, ulong bssAddress = 0) : base(inStorage)
        {
            _program = new byte[FileSize];

            SourceAddress = sourceAddress;
            BssAddress = bssAddress;

            OpenNroSegment(NroSegmentType.Text, false).Read(0, Text);
            OpenNroSegment(NroSegmentType.Ro, false).Read(0, Ro);
            OpenNroSegment(NroSegmentType.Data, false).Read(0, Data);
        }

        // S2Arm: the whole NRO file already in memory (a view of the game buffer): segments are slices of it, nothing is read or copied
        public NroExecutable(IStorage inStorage, Memory<byte> image, ulong sourceAddress, ulong bssAddress) : base(inStorage)
        {
            _program = image;

            SourceAddress = sourceAddress;
            BssAddress = bssAddress;
        }
    }
}
