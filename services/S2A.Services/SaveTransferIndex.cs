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
            Require(size >= 0 && size <= maximum, "LibHac 索引分配超过条目上限。");
            return inner.Allocate(size, alignment);
        }
        protected override void DoDeallocate(LibHac.Mem.Buffer buffer, int alignment) => inner.Deallocate(ref buffer, alignment);
        protected override bool DoIsEqual(MemoryResource other) => ReferenceEquals(this, other);
    }
    private static List<(SaveDataAttribute Attribute, SaveDataIndexerValue Value)> ReadIndex(byte[] bytes)
    {
        // Use the pinned library's own header type for the allocation bound. The
        // complete archive is parsed and rewritten by LibHac, never by this code.
        Require(bytes.Length >= Marshal.SizeOf<KeyValueArchiveHeader>(), "存档索引头缺失。");
        var header = MemoryMarshal.Read<KeyValueArchiveHeader>(bytes);
        Require(header.IsValid() && header.Reserved == 0 && header.EntryCount is >= 0 and <= 0x1080 &&
            bytes.Length == 12L + header.EntryCount * 140L, "LibHac 索引大小或条目数量无效。");
        using var client = new Horizon(new HorizonConfiguration()).CreatePrivilegedHorizonClient();
        using var fileSystem = new UniqueRef<IFileSystem>(new InMemoryFileSystem());
        Check(client.Fs.Register("transfer"u8, ref fileSystem.Ref), "挂载索引内存文件系统");
        Check(client.Fs.CreateFile("transfer:/imkvdb.arc"u8, bytes.Length), "创建索引内存文件");
        Check(client.Fs.OpenFile(out var handle, "transfer:/imkvdb.arc"u8, OpenMode.Write), "打开索引内存文件");
        try { Check(client.Fs.WriteFile(handle, 0, bytes, WriteOption.Flush), "写入索引内存文件"); }
        finally { client.Fs.CloseFile(handle); }
        using var store = new FlatMapKeyValueStore<SaveDataAttribute>();
        Check(store.Initialize(client.Fs, "transfer:/"u8, 0x1080, new IndexMemory(64), new IndexMemory(MaxMetadata)), "初始化 LibHac 索引");
        Check(store.Load(), "读取 LibHac 索引");
        Require(store.Count == header.EntryCount, "LibHac 索引条目数量不符。");
        var result = new List<(SaveDataAttribute, SaveDataIndexerValue)>();
        var iterator = store.GetBeginIterator();
        while (!iterator.IsEnd())
        {
            var item = iterator.Get();
            Require(iterator.GetValue().Length == 64, "LibHac 索引值大小不支持。");
            result.Add((item.Key, MemoryMarshal.Read<SaveDataIndexerValue>(iterator.GetValue())));
            iterator.Next();
        }
        // A canonical library round trip also rejects trailing data, noncanonical
        // entry sizes, and metadata the public loader might otherwise ignore.
        Check(store.Save(), "重验 LibHac 索引");
        Check(client.Fs.OpenFile(out handle, "transfer:/imkvdb.arc"u8, OpenMode.Read), "重读索引内存文件");
        try
        {
            Check(client.Fs.GetFileSize(out long size, handle), "读取索引大小");
            Require(size == bytes.Length, "LibHac 索引往返大小不符。");
            byte[] canonical = new byte[bytes.Length];
            Check(client.Fs.ReadFile(handle, 0, canonical), "重读索引");
            Require(bytes.AsSpan().SequenceEqual(canonical), "LibHac 索引不是受支持的规范格式。");
        }
        finally { client.Fs.CloseFile(handle); }
        return result;
    }
    private static void Check(Result result, string operation) => Require(result.IsSuccess(), operation + "失败。");
}
