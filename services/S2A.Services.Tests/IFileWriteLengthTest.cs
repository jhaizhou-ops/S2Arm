using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using LibHac.Common;
using LibHac.Fs;
using LibHac.FsSrv.Impl;
using LibHac.Sf;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using HleFile = Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy.IFile;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // 不启动 Host/音频/图形；真实 HLE IFile -> 锁定 LibHac FileInterfaceAdapter -> MemoryStorage。
        // 描述符长度是假的，客体内存和文件都仅 16 字节。期望结果独立取 LibHac 的公开 InvalidSize。
        private static int IFileWriteLengthTest()
        {
            int failed = 0;
            void Run(string name, ulong bufferSize, long size, bool reject)
            {
                try
                {
                    byte[] contents = new byte[16];
                    var memory = new IFileLengthMemory();
                    var storage = new MemoryStorage(contents);
                    using var raw = new UniqueRef<LibHac.Fs.Fsa.IFile>(new LibHac.FsSystem.StorageFile(storage, OpenMode.ReadWrite));
                    using var parent = new SharedRef<FileSystemInterfaceAdapter>();
                    using var file = new SharedRef<LibHac.FsSrv.Sf.IFile>(new FileInterfaceAdapter(ref raw.Ref, ref parent.Ref, false));
                    using var service = new HleFile(ref file.Ref);
                    var request = new IpcMessage();
                    request.SendBuff.Add(new IpcBuffDesc(bufferSize & uint.MaxValue, 0, (bufferSize >> 32) << 24));
                    using var data = new MemoryStream();
                    using var writer = new BinaryWriter(data);
                    writer.Write(0u); writer.Write(0u); writer.Write(0L); writer.Write(size); data.Position = 0;
                    using var reader = new BinaryReader(data);
                    using var response = new MemoryStream();
                    using var responseWriter = new BinaryWriter(response);
                    var context = new ServiceCtx(null, null, memory, null, request, new IpcMessage(), reader, responseWriter);
                    uint result = (uint)service.Write(context);
                    uint expected = reject ? ResultFs.InvalidSize.Value.Value : 0;
                    byte[] readBack = new byte[16];
                    var readResult = storage.Read(0, readBack);
                    bool equal = readResult.IsSuccess();
                    for (int i = 0; i < contents.Length; i++)
                    {
                        byte expectedByte = reject ? (byte)0 : (byte)(i * 13 + 7);
                        equal &= readBack[i] == expectedByte;
                    }
                    bool ok = result == expected && equal && memory.Reads == (reject ? 0 : 1);
                    Console.WriteLine($"IFile.Write {name}：期望 0x{expected:X}/字节一致/读取次数 {(reject ? 0 : 1)} → 实测 0x{result:X}/{equal}/{memory.Reads} {(ok ? "✓" : "✗")}");
                    if (!ok) failed++;
                }
                catch (Exception ex)
                {
                    failed++;
                    Console.WriteLine($"IFile.Write {name}：期望 不抛异常 → 实测 {ex.GetType().Name} ✗");
                }
            }
            Run("SendBuff > int.MaxValue", (ulong)int.MaxValue + 1, 16, true);
            // 2^32 在旧 LibHac 的 int 转换后变成 0，必须防止假成功（普通 17 > 16 由 LibHac 已能拒绝）。
            Run("size=2^32 > SendBuff=16", 16, (long)uint.MaxValue + 1, true);
            Run("正常写入逐字节读回", 16, 16, false);
            Console.WriteLine($"IFile.Write 长度专项：共 3 例，失败 {failed}");
            return failed == 0 ? 0 : 1;
        }

        // 只提供本测试需要的 GetSpan。拒绝路径若碰客体内存即失败；没有替换生产服务或 LibHac 算法。
        private sealed class IFileLengthMemory : IVirtualMemoryManager
        {
            private readonly byte[] _data = [7, 20, 33, 46, 59, 72, 85, 98, 111, 124, 137, 150, 163, 176, 189, 202];
            public int Reads;
            public bool UsesPrivateAllocations => false;
            public ReadOnlySpan<byte> GetSpan(ulong va, int size, bool tracked = false) { Reads++; return _data.AsSpan(checked((int)va), size); }
            public void Map(ulong va, ulong pa, ulong size, MemoryMapFlags flags) => throw new NotSupportedException();
            public void MapForeign(ulong va, nuint hostPointer, ulong size) => throw new NotSupportedException();
            public void Unmap(ulong va, ulong size) => throw new NotSupportedException();
            public T Read<T>(ulong va) where T : unmanaged => throw new NotSupportedException();
            public void Read(ulong va, Span<byte> data) => throw new NotSupportedException();
            public bool TryReadUnsafe(ulong va, int length, out Span<byte> data) => throw new NotSupportedException();
            public void Write<T>(ulong va, T value) where T : unmanaged => throw new NotSupportedException();
            public void Write(ulong va, ReadOnlySpan<byte> data) => throw new NotSupportedException();
            public bool WriteWithRedundancyCheck(ulong va, ReadOnlySpan<byte> data) => throw new NotSupportedException();
            public ReadOnlySequence<byte> GetReadOnlySequence(ulong va, int size, bool tracked = false) => throw new NotSupportedException();
            public WritableRegion GetWritableRegion(ulong va, int size, bool tracked = false) => throw new NotSupportedException();
            public ref T GetRef<T>(ulong va) where T : unmanaged => throw new NotSupportedException();
            public IEnumerable<HostMemoryRange> GetHostRegions(ulong va, ulong size) => throw new NotSupportedException();
            public IEnumerable<MemoryRange> GetPhysicalRegions(ulong va, ulong size) => throw new NotSupportedException();
            public bool IsMapped(ulong va) => throw new NotSupportedException();
            public bool IsRangeMapped(ulong va, ulong size) => throw new NotSupportedException();
            public void SignalMemoryTracking(ulong va, ulong size, bool write, bool precise = false, int? exemptId = null) => throw new NotSupportedException();
            public void Reprotect(ulong va, ulong size, MemoryPermission protection) => throw new NotSupportedException();
            public void TrackingReprotect(ulong va, ulong size, MemoryPermission protection, bool guest) => throw new NotSupportedException();
        }
    }
}
