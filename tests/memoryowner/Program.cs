// 真实 MemoryOwner API：等长/跨线程/跨大小复用，以及实际后备字节和份数边界。
using Ryujinx.Common.Memory;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

const int Count = 24;
const int Size = 1024 * 1024;
Console.WriteLine($"runtime={Environment.Version} processors={Environment.ProcessorCount} serverGC={System.Runtime.GCSettings.IsServerGC}");
if (args.Length != 0)
{
    switch (args[0])
    {
        case "bounds-byte": CheckBounds<byte>(i => Size, 32 * (long)Size); break;
        case "bounds-ushort": CheckBounds<ushort>(i => Size / 2 + i % 4, 60 * (long)Size); break;
        case "oversize": CheckOversize<byte>(64 * Size + 1); CheckOversize<ushort>(32 * Size + 1); break;
        case "accounting": CheckBudgetAccounting(); break;
        case "skip-accounting": CheckSkipAccounting(); break;
        default: throw new ArgumentException($"未知测试：{args[0]}");
    }
    return;
}
MemoryOwner<byte>[] owners = new MemoryOwner<byte>[Count];

void RentAndCheck(int[] sizes)
{
    for (int i = 0; i < owners.Length; i++)
    {
        int size = sizes[i % sizes.Length];
        owners[i] = MemoryOwner<byte>.Rent(size);
        if (owners[i].Length != size || owners[i].Span.Length != size || owners[i].Memory.Length != size)
        {
            throw new InvalidOperationException("租借长度不符");
        }
        owners[i].Span.Fill((byte)(i + 1));
    }
    CheckContents();
}

void CheckContents()
{
    for (int i = 0; i < owners.Length; i++)
    {
        if (owners[i].Span.IndexOfAnyExcept((byte)(i + 1)) >= 0)
        {
            throw new InvalidOperationException("仍在使用的缓冲被另一租借覆盖");
        }
    }
}

void ReturnAll()
{
    foreach (MemoryOwner<byte> owner in owners)
    {
        owner.Dispose();
        owner.Dispose(); // 重复归还不能让两个后续租借共用同一块数组。
    }
    Array.Clear(owners);
}

void CheckAllocation(string name, int[] sizes)
{
    long before = GC.GetAllocatedBytesForCurrentThread();
    RentAndCheck(sizes);
    long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
    ReturnAll();
    Console.WriteLine($"{name}：再次同时持有 {Count} 块分配 {allocated} B");
    if (allocated >= Size)
    {
        throw new InvalidOperationException("已归还的缓冲未复用，重复分配大数组");
    }
}

int[] equal = { Size };
RentAndCheck(equal);
ReturnAll();
CheckAllocation("同线程 1 MiB", equal);

using (AutoResetEvent ready = new(false))
using (AutoResetEvent done = new(false))
{
    Thread returner = new(() =>
    {
        for (int round = 0; round < 3; round++)
        {
            ready.WaitOne();
            CheckContents();
            ReturnAll();
            done.Set();
        }
    });
    returner.Start();
    for (int round = 0; round < 3; round++)
    {
        long before = GC.GetAllocatedBytesForCurrentThread();
        RentAndCheck(equal);
        long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        ready.Set();
        done.WaitOne();
        Console.WriteLine($"跨线程归还轮次 {round + 1}：租借线程分配 {allocated} B");
        if (round == 2 && allocated >= Size)
        {
            throw new InvalidOperationException("跨线程归还后的缓冲没有复用");
        }
    }
    returner.Join();
}

int[] mixed = { 0, 1, 17, 4097, 65537, Size, Size + 1, 2 * Size + 1 };
RentAndCheck(mixed);
ReturnAll();
CheckAllocation("混合尺寸", mixed);
using (MemoryOwner<byte> cleared = MemoryOwner<byte>.RentCleared(Size + 1))
{
    if (cleared.Span.IndexOfAnyExcept((byte)0) >= 0)
    {
        throw new InvalidOperationException("RentCleared 没有清除已用缓冲");
    }
}
MemoryOwner<byte> disposed = MemoryOwner<byte>.Rent(1);
disposed.Dispose();
try
{
    _ = disposed.Memory;
    throw new InvalidOperationException("已归还的 Memory 仍可访问");
}
catch (ObjectDisposedException) { }

using (MemoryOwner<byte> copy = MemoryOwner<byte>.RentCopy(new byte[] { 1, 2, 3 }))
{
    if (!copy.Span.SequenceEqual(new byte[] { 1, 2, 3 }))
    {
        throw new InvalidOperationException("RentCopy 内容不符");
    }
}
WeakReference<byte[]>[] buffers = CaptureReturnedBuffers();
FullCollection();
long retained = RetainedBytes(buffers), heapBefore = GC.GetTotalMemory(false);
RentAndCheck(equal);
ReturnAll();
FullCollection();
heapBefore = GC.GetTotalMemory(false);
long repeatsBefore = GC.GetAllocatedBytesForCurrentThread();
for (int repeat = 0; repeat < 100; repeat++)
{
    RentAndCheck(equal);
    ReturnAll();
}
long repeatsAllocated = GC.GetAllocatedBytesForCurrentThread() - repeatsBefore;
FullCollection();
long heapAfter = GC.GetTotalMemory(false), retainedAfter = RetainedBytes(buffers);
Console.WriteLine($"100 批等长负载：分配 {repeatsAllocated} B，活堆 {heapBefore} → {heapAfter} B，所观察的归还数组 {retained} → {retainedAfter} B");
if (repeatsAllocated >= Size || heapAfter - heapBefore >= Size || retainedAfter != retained)
{
    throw new InvalidOperationException("预热后的重复负载仍分配大数组或驻留未平台化");
}
CheckAllocation("多次 Gen2 后复用", equal);
CheckCrossSizeReuse();

[MethodImpl(MethodImplOptions.NoInlining)]
static void CheckCrossSizeReuse()
{
    // 请求 5 MiB，归还后请求 3 MiB：继续用原先可覆盖请求的较大数组，不按桶重新分配。
    MemoryOwner<byte> larger = MemoryOwner<byte>.Rent(5 * Size);
    if (!MemoryMarshal.TryGetArray((ReadOnlyMemory<byte>)larger.Memory, out ArraySegment<byte> original))
    {
        throw new InvalidOperationException("Memory 没有数组存储");
    }
    larger.Dispose();
    long before = GC.GetAllocatedBytesForCurrentThread();
    using MemoryOwner<byte> smaller = MemoryOwner<byte>.Rent(3 * Size);
    long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
    if (!MemoryMarshal.TryGetArray((ReadOnlyMemory<byte>)smaller.Memory, out ArraySegment<byte> reused) || !ReferenceEquals(original.Array, reused.Array))
    {
        throw new InvalidOperationException("没有复用可覆盖请求的跨尺寸缓冲");
    }
    Console.WriteLine($"跨大小复用：5 MiB 归还后租 3 MiB，后备 {reused.Array!.Length} B，分配 {allocated} B");
}

[MethodImpl(MethodImplOptions.NoInlining)]
static WeakReference<byte[]>[] CaptureReturnedBuffers()
{
    MemoryOwner<byte>[] rented = new MemoryOwner<byte>[Count];
    WeakReference<byte[]>[] buffers = new WeakReference<byte[]>[Count];
    long requested = 0, capacity = 0;
    for (int i = 0; i < rented.Length; i++)
    {
        // 请求相邻长度，量出原池跨大小复用时的真实容量。
        int size = i % 2 == 0 ? Size : Size + 1;
        rented[i] = MemoryOwner<byte>.Rent(size);
        rented[i].Span.Fill((byte)i);
        if (!MemoryMarshal.TryGetArray((ReadOnlyMemory<byte>)rented[i].Memory, out ArraySegment<byte> segment))
        {
            throw new InvalidOperationException("Memory 没有数组存储");
        }
        buffers[i] = new WeakReference<byte[]>(segment.Array!);
        requested += size;
        capacity += segment.Array!.Length;
    }
    foreach (MemoryOwner<byte> owner in rented) owner.Dispose();
    Console.WriteLine($"混合大数组请求 {requested} B，真实后备数组 {capacity} B（倍率 {(double)capacity / requested:F3}）");
    return buffers;
}

[MethodImpl(MethodImplOptions.NoInlining)]
static long RetainedBytes(WeakReference<byte[]>[] buffers)
{
    long bytes = 0;
    foreach (WeakReference<byte[]> buffer in buffers)
    {
        if (buffer.TryGetTarget(out byte[]? array)) bytes += array.Length;
    }
    return bytes;
}

static void FullCollection()
{
    // 仅独立测试进程触发完整收集，以量真实存活数组；生产路径不主动 GC。
    GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
    GC.WaitForPendingFinalizers();
    GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
    GC.WaitForPendingFinalizers();
}

[MethodImpl(MethodImplOptions.NoInlining)]
static WeakReference<T[]>[] CaptureBoundsBurst<T>(int count, Func<int, int> length)
{
    MemoryOwner<T>[] rentals = new MemoryOwner<T>[count];
    WeakReference<T[]>[] buffers = new WeakReference<T[]>[count];
    for (int i = 0; i < count; i++)
    {
        rentals[i] = MemoryOwner<T>.Rent(length(i));
        rentals[i].Span.Clear();
        if (!MemoryMarshal.TryGetArray((ReadOnlyMemory<T>)rentals[i].Memory, out ArraySegment<T> segment))
        {
            throw new InvalidOperationException("Memory 没有数组存储");
        }
        buffers[i] = new WeakReference<T[]>(segment.Array!);
    }
    foreach (MemoryOwner<T> owner in rentals)
    {
        owner.Dispose();
        owner.Dispose();
    }
    return buffers;
}

[MethodImpl(MethodImplOptions.NoInlining)]
static (long Bytes, int Count, int MaxSameLength) RetainedBounds<T>(WeakReference<T[]>[] buffers)
{
    long bytes = 0;
    int count = 0, maxSameLength = 0;
    Dictionary<int, int> lengths = new();
    foreach (WeakReference<T[]> buffer in buffers)
    {
        if (buffer.TryGetTarget(out T[]? array))
        {
            bytes += (long)array.Length * Unsafe.SizeOf<T>();
            count++;
            lengths.TryGetValue(array.Length, out int sameLength);
            lengths[array.Length] = ++sameLength;
            maxSameLength = Math.Max(maxSameLength, sameLength);
        }
    }
    return (bytes, count, maxSameLength);
}

static void CheckBounds<T>(Func<int, int> length, long minimumRetainedBytes)
{
    WeakReference<T[]>[] buffers = CaptureBoundsBurst<T>(200, length);
    FullCollection();
    var retained = RetainedBounds(buffers);
    Console.WriteLine($"{typeof(T).Name} 200 块归还：存活 {retained.Count} 块、实际后备 {retained.Bytes} B、同长最多 {retained.MaxSameLength} 块");
    if (retained.Bytes > 64L * Size || retained.MaxSameLength > 32 || retained.Bytes < minimumRetainedBytes)
    {
        throw new InvalidOperationException("池未遵守实际字节/同长份数限制，或拒绝了预算内的可复用数组");
    }
}

static void CheckOversize<T>(int length)
{
    for (int round = 0; round < 2; round++)
    {
        WeakReference<T[]>[] buffers = CaptureBoundsBurst<T>(1, _ => length);
        FullCollection();
        var retained = RetainedBounds(buffers);
        Console.WriteLine($"{typeof(T).Name} 超预算单块第 {round + 1} 轮：请求 {(long)length * Unsafe.SizeOf<T>()} B，归还后存活 {retained.Bytes} B");
        if (retained.Count != 0)
        {
            throw new InvalidOperationException("超预算单块仍被池保留");
        }
    }
}

static void CheckBudgetAccounting()
{
    // UInt32 单独的池：16 × 4 MiB 正好用满预算，不受 byte/ushort 用例影响。
    WeakReference<uint[]>[] buffers = CaptureBoundsBurst<uint>(16, _ => Size);
    FullCollection();
    long before = GC.GetAllocatedBytesForCurrentThread();
    for (int round = 0; round < 50; round++)
    {
        MemoryOwner<uint>[] rentals = new MemoryOwner<uint>[16];
        for (int i = 0; i < rentals.Length; i++) rentals[i] = MemoryOwner<uint>.Rent(Size);
        foreach (MemoryOwner<uint> owner in rentals) owner.Dispose();
    }
    long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
    FullCollection();
    var retained = RetainedBounds(buffers);
    Console.WriteLine($"UInt32 满预算反复租还 50 轮：分配 {allocated} B，原后备存活 {retained.Bytes} B / {retained.Count} 块");
    if (allocated >= Size || retained.Bytes != 64L * Size || retained.Count != 16)
    {
        throw new InvalidOperationException("Get/Return 预算扣减错误，导致预算内数组丢失或重复分配");
    }
}

static void CheckSkipAccounting()
{
    // 先达到原淘汰检查阈值，再用较大请求使部分旧数组累积 SkipCount，补足条目触发原淘汰。
    WeakReference<long[]>[] old = CaptureBoundsBurst<long>(50, i => 65536 + i);
    WeakReference<long[]>[] large = CaptureBoundsBurst<long>(1, _ => 7 * Size / sizeof(long));
    for (int i = 0; i < 128; i++)
    {
        using MemoryOwner<long> owner = MemoryOwner<long>.Rent(7 * Size / sizeof(long));
    }
    WeakReference<long[]>[] small = CaptureBoundsBurst<long>(49, i => 16 + i);
    WeakReference<long[]>[] all = new WeakReference<long[]>[old.Length + large.Length + small.Length];
    old.CopyTo(all, 0);
    large.CopyTo(all, old.Length);
    small.CopyTo(all, old.Length + large.Length);
    FullCollection();
    var survivingOld = RetainedBounds(old);
    var retained = RetainedBounds(all);
    if (survivingOld.Count >= old.Length || survivingOld.Count == 0)
    {
        throw new InvalidOperationException("没有通过真实租还触发既有 SkipCount 淘汰");
    }

    int remainingElements = checked((int)((64L * Size - retained.Bytes) / sizeof(long)));
    WeakReference<long[]>[] fill = CaptureBoundsBurst<long>(1, _ => remainingElements);
    FullCollection();
    var filled = RetainedBounds(fill);
    Console.WriteLine($"SkipCount 淘汰后：旧数组剩 {survivingOld.Count}/{old.Length}，存活 {retained.Bytes} B；补入 {filled.Bytes} B");
    if (filled.Count != 1 || retained.Bytes + filled.Bytes != 64L * Size)
    {
        throw new InvalidOperationException("SkipCount 淘汰后未正确释放字节预算");
    }
    WeakReference<long[]>[] extra = CaptureBoundsBurst<long>(1, _ => remainingElements + 1);
    FullCollection();
    if (RetainedBounds(extra).Count != 0 || RetainedBounds(all).Bytes + RetainedBounds(fill).Bytes > 64L * Size)
    {
        throw new InvalidOperationException("淘汰后的字节账允许超预算驻留");
    }
}
