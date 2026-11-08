using System;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Memory.Range;
using S2A.Services;
using GpuBuffer = Ryujinx.Graphics.Gpu.Memory.Buffer;

// 无 Vulkan 实例或 GPU 命令：分配器提供真实可读写宿主页，真正 SetData/WaitForFences/Memmove 不替换。
sealed unsafe class VulkanUpload
{
    private delegate void UploadCall(int offset, ReadOnlySpan<byte> data);
    private readonly UploadCall _upload;
    public readonly byte* Pointer;
    public readonly int Size;
    public int Calls;
    public bool SingleByte;
    public bool ThrowOnUpload;
    public Action AfterUpload;

    public VulkanUpload(int size)
    {
        Size = size;
        Pointer = (byte*)NativeMemory.AlignedAlloc((nuint)size, (nuint)Environment.SystemPageSize);
        new Span<byte>(Pointer, size).Fill(0xcd);
        Assembly assembly = typeof(VulkanRenderer).Assembly;
        Type allocationType = assembly.GetType("Ryujinx.Graphics.Vulkan.MemoryAllocation", true);
        ConstructorInfo allocator = Array.Find(allocationType.GetConstructors(), c => c.GetParameters().Length == 5);
        var allocation = allocator.Invoke(new object[] { null, default(Silk.NET.Vulkan.DeviceMemory), (nint)Pointer, 0ul, (ulong)size });
        Type holderType = assembly.GetType("Ryujinx.Graphics.Vulkan.BufferHolder", true);
        ConstructorInfo constructor = Array.Find(holderType.GetConstructors(), c => c.GetParameters().Length == 7 && c.GetParameters()[3].ParameterType == allocationType);
        Type kind = constructor.GetParameters()[5].ParameterType;
        var renderer = (VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        object holder = constructor.Invoke(new object[] { renderer, default(Silk.NET.Vulkan.Device), default(Silk.NET.Vulkan.Buffer), allocation, size, Enum.ToObject(kind, 0), Enum.ToObject(kind, 0) });
        MethodInfo setData = holderType.GetMethod("SetData");
        var invoke = new DynamicMethod("ActualBufferHolderSetData", typeof(void), new[] { typeof(object), typeof(int), typeof(ReadOnlySpan<byte>) }, typeof(VulkanUpload).Module, true);
        ILGenerator il = invoke.GetILGenerator();
        LocalBuilder cbs = il.DeclareLocal(setData.GetParameters()[2].ParameterType);
        il.Emit(OpCodes.Ldloca, cbs); il.Emit(OpCodes.Initobj, cbs.LocalType);
        il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Castclass, holderType);
        il.Emit(OpCodes.Ldarg_1); il.Emit(OpCodes.Ldarg_2); il.Emit(OpCodes.Ldloc, cbs);
        il.Emit(OpCodes.Ldnull); il.Emit(OpCodes.Ldc_I4_1); il.Emit(OpCodes.Callvirt, setData); il.Emit(OpCodes.Ret);
        _upload = (UploadCall)invoke.CreateDelegate(typeof(UploadCall), holder);
    }

    public void SetData(int offset, ReadOnlySpan<byte> source)
    {
        Calls++;
        if (offset < 0 || source.Length > Size - offset) throw new Exception("fixture catches invalid destination range before actual SetData");
        Console.WriteLine($"ENTER actual BufferHolder.SetData offset={offset:x} size={source.Length:x}");
        Console.Out.Flush();
        if (ThrowOnUpload) throw new InvalidOperationException("controlled renderer failure");
        _upload(offset, SingleByte ? source[..1] : source);
        AfterUpload?.Invoke();
    }
}

unsafe class Program
{
    [DllImport("readonly_fixture")] static extern void* fixture_create(int shared);
    [DllImport("readonly_fixture")] static extern int fixture_none();
    [DllImport("readonly_fixture")] static extern int fixture_protection(ulong address);
    [DllImport("readonly_fixture")] static extern int fixture_gpu_modified();
    [DllImport("readonly_fixture")] static extern int fixture_readonly();
    [DllImport("readonly_fixture")] static extern int s2a_android_copy_guest_readonly(ulong address, void* destination, ulong size);
    [DllImport("libc")] static extern int mprotect(void* address, nuint size, int protection);
    private static int _assertions;
    private static int _copies;
    private static int _writes;
    private static bool _copyFailure;
    static void Check(bool value, string label) { _assertions++; if (!value) throw new Exception(label); }
    static void Copy(ulong address, Memory<byte> target)
    {
        _copies++;
        if (_copyFailure) throw new InvalidOperationException("controlled copy failure");
        fixed (byte* destination = target.Span)
        {
            int error = s2a_android_copy_guest_readonly(address, destination, (ulong)target.Length);
            if (error != 0) throw new InvalidOperationException($"readonly copy failed: {error}");
        }
    }
    static void Write(ulong address, ReadOnlySpan<byte> data, bool flush)
    {
        _writes++;
        throw new Exception("read path must not write guest memory");
    }

    static int Main(string[] args)
    {
        string mode = args[0];
        byte* source = (byte*)fixture_create(1);
        Check(source != null, "real source allocation");
        var upload = new VulkanUpload(Environment.SystemPageSize);
        upload.SingleByte = mode == "one-byte-source";
        var renderer = new UploadRenderer(default) { Upload = upload };
        var context = new GpuContext(renderer, new DirtyHacks(Array.Empty<ulong>()));
        context.SetGpuThread();
        var guest = new GuestMemory();
        GuestMemory.WriteUntrackedHook = &Write;
        var memory = new PhysicalMemory(context, guest);
        bool whole = mode.StartsWith("whole", StringComparison.Ordinal);
        ulong address = (ulong)source + (whole ? 0x400ul : 0ul);
        ulong size = whole ? 0x800ul : 0x2000ul;
        var buffer = new GpuBuffer(context, memory, address, size, BufferStage.VertexBuffer, false, Array.Empty<GpuBuffer>());
        if (!whole) buffer.SignalModified(address, 0x400, BufferStage.Compute | BufferStage.StorageWrite);
        else context.AdvanceSequence();
        bool safe = mode is "safe" or "whole-safe" or "copy-failure" or "upload-failure" or "wrong-thread" or "lease" or "pure-no-signal";
        if (safe) context.S2AReadGuestMemory = Copy;
        _copyFailure = mode == "copy-failure";
        upload.ThrowOnUpload = mode == "upload-failure";
        int consumed = 0;
        upload.AfterUpload = () => consumed++;
        if (mode != "readable") Check(fixture_none() == 0, "real same-page neighbor protection");
        if (mode == "source-readable") Check(fixture_readonly() == 0, "only source access changed");
        if (mode == "destination-none")
        {
            Check(fixture_readonly() == 0, "source readable for destination control");
            Check(mprotect(upload.Pointer, (nuint)upload.Size, 0) == 0, "only destination inaccessible");
        }
        Console.WriteLine("ENTER actual Buffer.SyncAction"); Console.Out.Flush();
        Action consume = () => { if (whole) buffer.SynchronizeMemory(address, size); else buffer.SyncAction(true); };
        if (mode is "copy-failure" or "upload-failure")
        {
            bool rejected = false;
            try { consume(); } catch (InvalidOperationException) { rejected = true; }
            Check(rejected && _copies == 1 && consumed == 0, "failure cannot publish completed upload");
            Check(upload.Calls == (mode == "copy-failure" ? 0 : 1), "copy failure precedes renderer");
        }
        else if (mode == "wrong-thread")
        {
            Exception failure = null;
            var thread = new System.Threading.Thread(() => { try { consume(); } catch (Exception e) { failure = e; } });
            thread.Start(); thread.Join();
            Check(failure is InvalidOperationException && _copies == 0 && upload.Calls == 0, "wrong GPU owner rejected before copying or renderer");
        }
        else
        {
            consume();
            Check(upload.Calls != 0 && consumed == upload.Calls, "actual upload happened");
            if (!whole) Check(new ReadOnlySpan<byte>(upload.Pointer, 0x400).IndexOfAnyExcept((byte)0xcd) == -1, "GPU-owned bytes excluded from CPU upload");
            int first = whole ? 0 : 0x400, end = whole ? 0x800 : 0x1000;
            for (int i = first; i < end; i++) Check(upload.Pointer[i] == (byte)((i + (whole ? 0x400 : 0)) * 37 + 11), "remaining CPU bytes reach real destination");
            if (safe) Check(_copies == upload.Calls, "each actual upload consumes one readonly copy");
        }
        if (mode == "lease")
        {
            var bytes = memory.S2AGetBufferReadSpan(address + 0x400, 0x20, out var owner);
            Check(owner.Span.Length == 0x20 && bytes.Length == 0x20, "caller owns actual lease through use");
            owner.Dispose();
            bool disposed = false;
            try { _ = owner.Span; } catch (ObjectDisposedException) { disposed = true; }
            Check(disposed, "lease returned after consumption");
            bool overflow = false;
            try { memory.S2AGetBufferReadSpan(ulong.MaxValue - 4, 16, out _); } catch (OverflowException) { overflow = true; }
            Check(overflow, "source overflow rejected before copy");
        }
        if (mode == "pure-no-signal")
        {
            var cache = (NonOverlappingRangeList<GpuBuffer>)typeof(BufferCache)
                .GetField("_buffers", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(memory.BufferCache);
            cache.Add(buffer);
            Check(memory.BufferCache.S2AHasGpuModified(address, 0x20), "control region is genuinely GPU modified in production cache");
            int signals = 0;
            using var watcher = guest.BeginTracking(address, 0x1000, 123);
            watcher.RegisterAction((_, _) => { signals++; throw new Exception("unexpected recursive tracking signal"); });
            // 仅核 helper 的纯复制合同；实际 buffer 上传仍由上面的 ExcludeModifiedRegions 筛选。
            _ = memory.S2AGetBufferReadSpan(address, 0x20, out var owner);
            owner.Dispose();
            Check(signals == 0, "already-synchronized copy cannot emit another tracking signal");
        }
        if (safe)
        {
            Check(fixture_protection((ulong)source) == 0, "source original None remains");
            Check(fixture_gpu_modified() != 0, "neighbor native GPU dirty remains");
            if (!whole) Check(buffer.IsModified(address, 0x400), "GPU modified range remains excluded and owned");
        }
        Check(_writes == 0, "no readback or guest write side effect");
        Console.WriteLine($"PASS {mode}: {_assertions} assertions; uploads={upload.Calls}; copies={_copies}");
        return 0;
    }
}
