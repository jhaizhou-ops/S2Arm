using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace S2A.Services;

public static partial class SaveTransfer
{
    // PKWARE APPNOTE 4.3, 4.4 and 4.5.3. Bound the on-disk directory before
    // public ZipArchive allocates entries. S2ArmSave accepts single-volume ZIP,
    // without executable prefixes, signatures or ZIP64 extensible records.
    private sealed record ZipEntryBounds(string Name, byte[] NameBytes, ushort Version, ushort Flags,
        ushort Method, uint Crc, ulong Compressed, ulong Size, ulong Offset, uint Attributes, bool Zip64Sizes);
    private static ushort Z16(ReadOnlySpan<byte> data, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(data[offset..]);
    private static uint Z32(ReadOnlySpan<byte> data, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(data[offset..]);
    private static ulong Z64(ReadOnlySpan<byte> data, int offset) => BinaryPrimitives.ReadUInt64LittleEndian(data[offset..]);
    private static byte[] ZipRead(Stream stream, ulong offset, int length, ulong limit)
    {
        Require(offset <= limit && (ulong)length <= limit - offset, T("ZIP 记录超出范围。", "A ZIP record is out of range."));
        stream.Position = checked((long)offset);
        var bytes = new byte[length];
        stream.ReadExactly(bytes);
        return bytes;
    }
    private static bool ZipField(ulong value, ulong sentinel, ulong actual) => value == sentinel || value == actual;
    private static ReadOnlySpan<byte> Zip64Extra(ReadOnlySpan<byte> extra)
    {
        ReadOnlySpan<byte> zip64 = default;
        bool found = false;
        while (!extra.IsEmpty)
        {
            Require(extra.Length >= 4 && Z16(extra, 2) <= extra.Length - 4, T("ZIP 扩展字段截断。", "A ZIP extra field is truncated."));
            int size = Z16(extra, 2);
            if (Z16(extra, 0) == 1)
            {
                Require(!found, T("ZIP64 扩展字段重复。", "Duplicate ZIP64 extra field."));
                found = true;
                zip64 = extra.Slice(4, size);
            }
            extra = extra[(4 + size)..];
        }
        return zip64;
    }
    private static ulong Zip64Value(ref ReadOnlySpan<byte> extra, ulong value, ulong sentinel, bool disk = false)
    {
        if (value != sentinel) return value;
        int width = disk ? 4 : 8;
        Require(extra.Length >= width, T("ZIP64 缺少占位字段对应的值。", "ZIP64 is missing values for its placeholder fields."));
        ulong actual = disk ? Z32(extra, 0) : Z64(extra, 0);
        extra = extra[width..];
        return actual;
    }
    private static List<ZipEntryBounds> ZipBounds(Stream stream)
    {
        Require(stream.Length >= 22, T("ZIP 文件头尾缺失。", "The ZIP header or trailer is missing."));
        ulong length = (ulong)stream.Length;
        int tailSize = (int)Math.Min(length, 65557UL);
        byte[] tail = ZipRead(stream, length - (ulong)tailSize, tailSize, length);
        int end = tail.AsSpan().LastIndexOf("PK\u0005\u0006"u8);
        Require(end >= 0 && tail.Length - end >= 22, T("ZIP 中央目录缺失。", "The ZIP central directory is missing."));
        ReadOnlySpan<byte> eocd = tail.AsSpan(end);
        Require(eocd.Length == 22 + Z16(eocd, 20), T("ZIP 尾随数据或注释长度无效。", "Invalid ZIP trailing data or comment length."));
        ulong endOffset = length - (ulong)eocd.Length;
        ulong disk = Z16(eocd, 4), centralDisk = Z16(eocd, 6), onDisk = Z16(eocd, 8), count = Z16(eocd, 10);
        ulong size = Z32(eocd, 12), start = Z32(eocd, 16), directoryEnd = endOffset;
        bool locator = endOffset >= 20 && Z32(ZipRead(stream, endOffset - 20, 4, length), 0) == 0x07064b50;
        if (locator)
        {
            byte[] loc = ZipRead(stream, endOffset - 20, 20, length);
            ulong recordOffset = Z64(loc, 8);
            Require(endOffset >= 76 && Z32(loc, 4) == 0 && Z32(loc, 16) == 1 && recordOffset == endOffset - 76,
                T("ZIP64 locator 非标准或包含扩展数据。", "The ZIP64 locator is non-standard or contains extra data."));
            byte[] record = ZipRead(stream, recordOffset, 56, endOffset - 20);
            Require(Z32(record, 0) == 0x06064b50 && Z64(record, 4) == 44 && Z32(record, 16) == 0 &&
                Z32(record, 20) == 0 && Z64(record, 24) == Z64(record, 32), T("ZIP64 分卷或扩展记录无效。", "Invalid ZIP64 volume or extended record."));
            Require(ZipField(disk, ushort.MaxValue, 0) && ZipField(centralDisk, ushort.MaxValue, 0) &&
                ZipField(onDisk, ushort.MaxValue, Z64(record, 24)) && ZipField(count, ushort.MaxValue, Z64(record, 32)) &&
                ZipField(size, uint.MaxValue, Z64(record, 40)) && ZipField(start, uint.MaxValue, Z64(record, 48)),
                T("ZIP32 与 ZIP64 目录字段不一致。", "ZIP32 and ZIP64 directory fields don’t match."));
            count = Z64(record, 32); size = Z64(record, 40); start = Z64(record, 48);
            directoryEnd = recordOffset;
        }
        else
            Require(disk == 0 && centralDisk == 0 && onDisk == count && count != ushort.MaxValue &&
                size != uint.MaxValue && start != uint.MaxValue, T("ZIP 分卷或 ZIP64 占位字段无效。", "Invalid ZIP volume or ZIP64 placeholder field."));
        Require(count is > 0 and <= MaxFiles + 1 && size <= (32UL << 20) && start <= directoryEnd &&
            size == directoryEnd - start && count <= size / 46, T("ZIP 中央目录数量、大小或范围不符。", "The ZIP central directory count, size or range doesn’t match."));

        var entries = new List<ZipEntryBounds>((int)count);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        ulong position = start, total = 0;
        var utf8 = new UTF8Encoding(false, true);
        for (ulong i = 0; i < count; i++)
        {
            byte[] header = ZipRead(stream, position, 46, directoryEnd);
            Require(Z32(header, 0) == 0x02014b50, T("ZIP 中央目录条目无效。", "Invalid ZIP central directory entry."));
            ushort nameSize = Z16(header, 28), extraSize = Z16(header, 30), commentSize = Z16(header, 32);
            Require(nameSize is > 0 and <= 1024, T("ZIP 路径长度无效。", "Invalid ZIP path length."));
            byte[] nameBytes = ZipRead(stream, position + 46, nameSize, directoryEnd);
            string name = utf8.GetString(nameBytes);
            Name(name);
            ushort flags = Z16(header, 8), method = Z16(header, 10);
            uint attributes = Z32(header, 38);
            int type = (int)(attributes >> 16) & 0xf000;
            // APPNOTE 4.4.4 leaves bits 1/2 undefined for stored entries. .NET
            // retains its deflate options when it stores an empty entry.
            Require(names.Add(name) && (flags & ~0x080e) == 0 && method is 0 or 8 &&
                type is 0 or 0x8000 &&
                (attributes & (uint)FileAttributes.Directory) == 0, T("ZIP 含重复路径、链接、目录、加密或特殊条目。", "The ZIP contains duplicate paths, links, folders, encrypted or special entries."));
            ReadOnlySpan<byte> extra = Zip64Extra(ZipRead(stream, position + 46 + nameSize, extraSize, directoryEnd));
            ulong uncompressed = Zip64Value(ref extra, Z32(header, 24), uint.MaxValue);
            ulong compressed = Zip64Value(ref extra, Z32(header, 20), uint.MaxValue);
            ulong offset = Zip64Value(ref extra, Z32(header, 42), uint.MaxValue);
            ulong entryDisk = Zip64Value(ref extra, Z16(header, 34), ushort.MaxValue, disk: true);
            Require(extra.IsEmpty && entryDisk == 0 && offset < start && compressed <= start &&
                uncompressed <= (ulong)MaxBytes + MaxMetadata && total <= (ulong)MaxBytes + MaxMetadata - uncompressed &&
                (method != 0 || compressed == uncompressed), T("ZIP 条目大小、ZIP64 字段或分卷无效。", "Invalid ZIP entry size, ZIP64 field or volume."));
            total += uncompressed;
            entries.Add(new(name, nameBytes, Z16(header, 6), flags, method, Z32(header, 16), compressed, uncompressed, offset, attributes,
                Z32(header, 20) == uint.MaxValue || Z32(header, 24) == uint.MaxValue));
            position += 46UL + nameSize + extraSize + commentSize;
            Require(position <= directoryEnd, T("ZIP 中央目录条目超出范围。", "A ZIP central directory entry is out of range."));
        }
        Require(position == directoryEnd, T("ZIP 中央目录数量不符或有额外数据。", "The ZIP central directory count doesn’t match or has extra data."));

        var localOrder = entries.OrderBy(e => e.Offset).ToArray();
        ulong next = 0;
        for (int i = 0; i < localOrder.Length; i++)
        {
            var entry = localOrder[i];
            Require(entry.Offset == next, T("ZIP 不允许前置、重叠或未登记数据。", "The ZIP has leading, overlapping or unlisted data, which isn’t allowed."));
            ulong limit = i + 1 < localOrder.Length ? localOrder[i + 1].Offset : start;
            next = ZipLocalBounds(stream, entry, limit);
        }
        Require(next == start, T("ZIP 数据区与中央目录不相接。", "The ZIP data area doesn’t meet the central directory."));
        stream.Position = 0;
        return entries;
    }
    private static ulong ZipLocalBounds(Stream stream, ZipEntryBounds entry, ulong limit)
    {
        byte[] header = ZipRead(stream, entry.Offset, 30, limit);
        ushort nameSize = Z16(header, 26), extraSize = Z16(header, 28);
        Require(Z32(header, 0) == 0x04034b50 && Z16(header, 4) == entry.Version && Z16(header, 6) == entry.Flags &&
            Z16(header, 8) == entry.Method && nameSize == entry.NameBytes.Length, T("ZIP 本地头与目录不一致。", "A ZIP local header doesn’t match the directory."));
        byte[] name = ZipRead(stream, entry.Offset + 30, nameSize, limit);
        Require(name.AsSpan().SequenceEqual(entry.NameBytes), T("ZIP 本地路径与目录不一致。", "A ZIP local path doesn’t match the directory."));
        ReadOnlySpan<byte> extra = Zip64Extra(ZipRead(stream, entry.Offset + 30 + nameSize, extraSize, limit));
        bool zip64 = Z32(header, 18) == uint.MaxValue || Z32(header, 22) == uint.MaxValue;
        if (zip64)
            Require(Z32(header, 18) == uint.MaxValue && Z32(header, 22) == uint.MaxValue, T("ZIP64 本地头必须包含两个大小。", "A ZIP64 local header must contain both sizes."));
        ulong uncompressed = Zip64Value(ref extra, Z32(header, 22), uint.MaxValue);
        ulong compressed = Zip64Value(ref extra, Z32(header, 18), uint.MaxValue);
        uint crc = Z32(header, 14);
        bool descriptor = (entry.Flags & 8) != 0;
        Require(extra.IsEmpty && (descriptor ? (crc == 0 || crc == entry.Crc) &&
            (uncompressed == 0 || uncompressed == entry.Size) && (compressed == 0 || compressed == entry.Compressed) :
            crc == entry.Crc && uncompressed == entry.Size && compressed == entry.Compressed), T("ZIP 本地 CRC 或大小与目录不一致。", "A ZIP local CRC or size doesn’t match the directory."));
        ulong data = entry.Offset + 30UL + nameSize + extraSize;
        Require(data <= limit && entry.Compressed <= limit - data, T("ZIP 压缩数据越界。", "ZIP compressed data is out of bounds."));
        ulong dataEnd = data + entry.Compressed;
        if (!descriptor)
        {
            Require(dataEnd == limit, T("ZIP 数据后有额外记录。", "There are extra records after the ZIP data."));
            return dataEnd;
        }
        // Infer the optional signature from the exact gap: a CRC equal to
        // 0x08074b50 must not be mistaken for a descriptor signature.
        bool wideDescriptor = zip64 || entry.Zip64Sizes;
        int payload = wideDescriptor ? 20 : 12;
        ulong gap = limit - dataEnd;
        Require(gap == (ulong)payload || gap == (ulong)payload + 4, T("ZIP 数据描述符长度无效。", "Invalid ZIP data descriptor length."));
        byte[] desc = ZipRead(stream, dataEnd, (int)gap, limit);
        int prefix = (int)gap - payload;
        Require(prefix == 0 || Z32(desc, 0) == 0x08074b50, T("ZIP 数据描述符签名无效。", "Invalid ZIP data descriptor signature."));
        Require(Z32(desc, prefix) == entry.Crc &&
            (wideDescriptor ? Z64(desc, prefix + 4) : Z32(desc, prefix + 4)) == entry.Compressed &&
            (wideDescriptor ? Z64(desc, prefix + 12) : Z32(desc, prefix + 8)) == entry.Size, T("ZIP 数据描述符与目录不一致。", "A ZIP data descriptor doesn’t match the directory."));
        return limit;
    }
}
