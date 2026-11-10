using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using LibHac.FsSrv;
using LibHac.Kvdb;
using LibHac.Tools.Fs;

namespace S2A.Services;

public static partial class SaveTransfer
{
    private sealed class IndexMemory(long maximum) : MemoryResource
    {
        private readonly ArrayPoolMemoryResource inner = new();
        protected override LibHac.Mem.Buffer DoAllocate(long size, int alignment)
        {
            Require(size >= 0 && size <= maximum, T("LibHac 索引分配超过条目上限。", "The LibHac index allocation exceeds the entry limit."));
            return inner.Allocate(size, alignment);
        }
        protected override void DoDeallocate(LibHac.Mem.Buffer buffer, int alignment) => inner.Deallocate(ref buffer, alignment);
        protected override bool DoIsEqual(MemoryResource other) => ReferenceEquals(this, other);
    }
    private static List<(SaveDataAttribute Attribute, SaveDataIndexerValue Value)> ReadIndex(byte[] bytes)
    {
        // Use the pinned library's own header type for the allocation bound. The
        // complete archive is parsed and rewritten by LibHac, never by this code.
        Require(bytes.Length >= Marshal.SizeOf<KeyValueArchiveHeader>(), T("存档索引头缺失。", "The save index header is missing."));
        var header = MemoryMarshal.Read<KeyValueArchiveHeader>(bytes);
        Require(header.IsValid() && header.Reserved == 0 && header.EntryCount is >= 0 and <= 0x1080 &&
            bytes.Length == 12L + header.EntryCount * 140L, T("LibHac 索引大小或条目数量无效。", "Invalid LibHac index size or entry count."));
        using var client = new Horizon(new HorizonConfiguration()).CreatePrivilegedHorizonClient();
        using var fileSystem = new UniqueRef<IFileSystem>(new InMemoryFileSystem());
        Check(client.Fs.Register("transfer"u8, ref fileSystem.Ref), T("挂载索引内存文件系统", "Mounting the index memory file system"));
        Check(client.Fs.CreateFile("transfer:/imkvdb.arc"u8, bytes.Length), T("创建索引内存文件", "Creating the index memory file"));
        Check(client.Fs.OpenFile(out var handle, "transfer:/imkvdb.arc"u8, OpenMode.Write), T("打开索引内存文件", "Opening the index memory file"));
        try { Check(client.Fs.WriteFile(handle, 0, bytes, WriteOption.Flush), T("写入索引内存文件", "Writing the index memory file")); }
        finally { client.Fs.CloseFile(handle); }
        using var store = new FlatMapKeyValueStore<SaveDataAttribute>();
        Check(store.Initialize(client.Fs, "transfer:/"u8, 0x1080, new IndexMemory(64), new IndexMemory(MaxMetadata)), T("初始化 LibHac 索引", "Initializing the LibHac index"));
        Check(store.Load(), T("读取 LibHac 索引", "Reading the LibHac index"));
        Require(store.Count == header.EntryCount, T("LibHac 索引条目数量不符。", "The LibHac index entry count doesn’t match."));
        var result = new List<(SaveDataAttribute, SaveDataIndexerValue)>();
        var iterator = store.GetBeginIterator();
        while (!iterator.IsEnd())
        {
            var item = iterator.Get();
            Require(iterator.GetValue().Length == 64, T("LibHac 索引值大小不支持。", "The LibHac index value size isn’t supported."));
            result.Add((item.Key, MemoryMarshal.Read<SaveDataIndexerValue>(iterator.GetValue())));
            iterator.Next();
        }
        // A canonical library round trip also rejects trailing data, noncanonical
        // entry sizes, and metadata the public loader might otherwise ignore.
        Check(store.Save(), T("重验 LibHac 索引", "Re-verifying the LibHac index"));
        Check(client.Fs.OpenFile(out handle, "transfer:/imkvdb.arc"u8, OpenMode.Read), T("重读索引内存文件", "Re-reading the index memory file"));
        try
        {
            Check(client.Fs.GetFileSize(out long size, handle), T("读取索引大小", "Reading the index size"));
            Require(size == bytes.Length, T("LibHac 索引往返大小不符。", "The LibHac index round-trip size doesn’t match."));
            byte[] canonical = new byte[bytes.Length];
            Check(client.Fs.ReadFile(handle, 0, canonical), T("重读索引", "Re-reading the index"));
            Require(bytes.AsSpan().SequenceEqual(canonical), T("LibHac 索引不是受支持的规范格式。", "The LibHac index isn’t in a supported canonical format."));
        }
        finally { client.Fs.CloseFile(handle); }
        return result;
    }
    private static void Check(Result result, string operation) => Require(result.IsSuccess(), operation + T("失败。", " failed."));
}
