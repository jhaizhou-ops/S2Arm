using System.Buffers.Binary;

namespace S2A.Services;

public static partial class SaveTransfer
{
    internal static byte[] Zip64Variant(byte[] archive, bool excessiveCount, bool extendedRecord, bool sentinels = false)
    {
        int endPosition = archive.Length - 22;
        int lower = Math.Max(0, archive.Length - 65557);
        while (endPosition >= lower &&
            !(archive.AsSpan(endPosition, 4).SequenceEqual("PK\u0005\u0006"u8) &&
            endPosition + 22 + BinaryPrimitives.ReadUInt16LittleEndian(archive.AsSpan(endPosition + 20)) == archive.Length)) endPosition--;
        if (endPosition < lower) throw new InvalidDataException();
        long count = BinaryPrimitives.ReadUInt16LittleEndian(archive.AsSpan(endPosition + 10));
        long size = BinaryPrimitives.ReadUInt32LittleEndian(archive.AsSpan(endPosition + 12));
        long start = BinaryPrimitives.ReadUInt32LittleEndian(archive.AsSpan(endPosition + 16));
        using var output = new MemoryStream();
        output.Write(archive.AsSpan(0, endPosition));
        using var writer = new BinaryWriter(output, System.Text.Encoding.UTF8, leaveOpen: true);
        writer.Write(0x06064b50U); writer.Write(44UL); writer.Write((ushort)45); writer.Write((ushort)45);
        writer.Write(0U); writer.Write(0U);
        writer.Write((ulong)(excessiveCount ? 20002 : count)); writer.Write((ulong)(excessiveCount ? 20002 : count));
        writer.Write((ulong)size); writer.Write((ulong)start);
        writer.Write(0x07064b50U); writer.Write(0U); writer.Write((ulong)endPosition); writer.Write(1U);
        output.Write(archive.AsSpan(endPosition));
        byte[] bytes = output.ToArray();
        if (sentinels)
        {
            int endOffset = checked((int)endPosition + 76);
            BitConverter.GetBytes(ushort.MaxValue).CopyTo(bytes, endOffset + 8);
            BitConverter.GetBytes(ushort.MaxValue).CopyTo(bytes, endOffset + 10);
            BitConverter.GetBytes(uint.MaxValue).CopyTo(bytes, endOffset + 12);
            BitConverter.GetBytes(uint.MaxValue).CopyTo(bytes, endOffset + 16);
        }
        if (extendedRecord) BitConverter.GetBytes(45UL).CopyTo(bytes, checked((int)endPosition + 4));
        return bytes;
    }
}
