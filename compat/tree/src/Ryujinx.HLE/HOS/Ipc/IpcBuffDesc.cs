using System.IO;

namespace Ryujinx.HLE.HOS.Ipc
{
    struct IpcBuffDesc
    {
        public ulong Position { get; private set; }
        public ulong Size { get; private set; }
        public byte Flags { get; private set; }

        // S2Arm: from the three descriptor words (zero-allocation parse, see IpcMessage.S2A.cs)
        internal IpcBuffDesc(ulong word0, ulong word1, ulong word2)
        {
            Position = word1;
            Position |= (word2 << 4) & 0x0f00000000;
            Position |= (word2 << 34) & 0x7000000000;
            Position = S2AHooks.FixIpcAddr(Position);   // S2Arm: restore bit 39 (macOS alias region above 2^39)

            Size = word0;
            Size |= (word2 << 8) & 0xf00000000;

            Flags = (byte)(word2 & 3);
        }

        public IpcBuffDesc(BinaryReader reader)
        {
            ulong word0 = reader.ReadUInt32();
            ulong word1 = reader.ReadUInt32();
            ulong word2 = reader.ReadUInt32();

            Position = word1;
            Position |= (word2 << 4) & 0x0f00000000;
            Position |= (word2 << 34) & 0x7000000000;
            Position = S2AHooks.FixIpcAddr(Position);   // S2Arm: restore bit 39 (macOS alias region above 2^39)

            Size = word0;
            Size |= (word2 << 8) & 0xf00000000;

            Flags = (byte)(word2 & 3);
        }
    }
}
