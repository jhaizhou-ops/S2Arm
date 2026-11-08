using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.HLE;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.Memory;
using S2A.Android.Aot;
using S2A.Services;
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using static Ryujinx.Memory.MemoryManagerUnixHelper;

internal static unsafe class SharedMemoryTests
{
    private static readonly Type Hooks = typeof(Switch).Assembly.GetType("Ryujinx.HLE.S2AHooks", true);
    private static readonly FieldInfo Factory = Hooks.GetField("CreateServiceMemory", BindingFlags.Public | BindingFlags.Static);
    private static readonly MethodInfo Allocate = typeof(Switch).GetMethod("AllocateServiceMemory", BindingFlags.NonPublic | BindingFlags.Static);

    public static void Run(Action<bool, string> check, string mode)
    {
        if (mode == "memory-composition")
        {
            Composition(check);
            return;
        }

        bool shared = mode == "memory-shared";
        bool privateControl = mode == "memory-private-control";
        if (!shared && !privateControl && mode != "memory-private-red") throw new ArgumentException(mode);
        ulong page = (ulong)Environment.SystemPageSize, size = page * 16, offset = page * 4, span = page * 4;
        int initial = AllocationCount();
        using MemoryBlock source = shared ? MemoryBlock.ReserveShared(size) : new MemoryBlock(size, MemoryAllocationFlags.Reserve);
        nint sourceAddress = source.Pointer;
        check(source.Size == size && sourceAddress != 0, "actual reserved block owns expected size/address");
        check(AllocationCount() == initial + 1, "reservation enters actual allocation owner table");
        source.Commit(0, size);
        byte* src = (byte*)source.GetPointer(offset, span);
        src[0] = 0x7a;
        src[span - 1] = 0x91;
        bool mirrorRejected = false;
        try { using MemoryBlock unexpected = source.CreateMirror(); }
        catch (NotSupportedException) { mirrorRejected = true; }
        check(mirrorRejected, "anonymous backing does not pretend to provide fd mirroring");

        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException("This fixture requires real Linux mremap; it must not silently skip aliases.");
        using (MemoryBlock target = new(span, MemoryAllocationFlags.Reserve))
        {
            nint result = mremap((nint)src, 0, span, 1 | 2, target.Pointer);
            int error = Marshal.GetLastPInvokeError();
            if (privateControl)
            {
                check(result == MAP_FAILED && error == 22, "private production backing reproduces EINVAL");
            }
            else
            {
                check(result == target.Pointer, $"real MemoryBlock alias must succeed; shared={shared} errno={error}");
                byte* alias = (byte*)target.Pointer;
                check(alias[0] == 0x7a && alias[span - 1] == 0x91, "interior alias views existing source bytes");
                source.Reprotect(offset, span, MemoryPermission.ReadAndWrite);
                target.Reprotect(0, span, MemoryPermission.Read);
                src[0] = 0xa5;
                check(alias[0] == 0xa5, "service writes remain visible through a guest read-only alias");
                target.Reprotect(0, span, MemoryPermission.ReadAndWrite);
                alias[span - 1] = 0x63;
                check(src[span - 1] == 0x63, "reverse write proves one shared backing rather than a copy");
            }
        }

        check(AllocationCount() == initial + 1, "target owner releases its actual replaced reservation");
        source.Dispose();
        check(source.Pointer == 0 && AllocationCount() == initial, "source Dispose releases pointer and actual owner entry");
        check(mprotect(sourceAddress, size, MmapProts.PROT_NONE) == -1 && Marshal.GetLastPInvokeError() == 12,
            "source address is actually unmapped after Dispose");
        source.Dispose();
        check(AllocationCount() == initial, "repeated Dispose does not free twice");
        bool failed = false;
        try { using MemoryBlock unexpected = MemoryBlock.ReserveShared(ulong.MaxValue); }
        catch (SystemException) { failed = true; }
        check(failed && AllocationCount() == initial, "real failed mmap cannot escape or register a fake block");
        failed = false;
        try { using MemoryBlock unexpected = MemoryBlock.ReserveShared(0); }
        catch (ArgumentOutOfRangeException) { failed = true; }
        check(failed && AllocationCount() == initial, "zero size is rejected without creating an owner");
    }

    private static int AllocationCount()
    {
        Type type = typeof(MemoryBlock).Assembly.GetType("Ryujinx.Memory.MemoryManagementUnix", true);
        object allocations = type.GetField("_allocations", BindingFlags.NonPublic | BindingFlags.Static).GetValue(null);
        return (int)allocations.GetType().GetProperty("Count").GetValue(allocations);
    }

    private static void Composition(Action<bool, string> check)
    {
        string root = Path.Combine(Path.GetTempPath(), "s2a-service-memory-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        ulong requested = 0;
        int calls = 0;
        var stop = new InvalidOperationException("fixture stops at the actual Switch memory creation, before GPU/services");
        Func<ulong, MemoryBlock> factory = size => { requested = size; calls++; throw stop; };
        var configuration = new HostConfiguration(Path.Combine(root, "game"), Path.Combine(root, "state"),
            SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false,
            AndroidHostUi.Create(), factory);
        var defaults = new HostConfiguration(Path.Combine(root, "game"), Path.Combine(root, "state"),
            SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, AndroidHostUi.Create());
        check(defaults.ServiceMemoryFactory == null, "existing compositions have no backing override");
        check(ReferenceEquals(configuration.ServiceMemoryFactory, factory), "typed composition retains exact factory");
        try
        {
            using var audio = new DummyHardwareDeviceDriver();
            IRenderer renderer = DispatchProxy.Create<IRenderer, NoGpuCalls>();
            bool reached = false;
            try { Host.Boot(renderer, audio, Path.Combine(root, "host"), configuration); }
            catch (InvalidOperationException error) when (ReferenceEquals(error, stop)) { reached = true; }
            check(reached && calls == 1, "actual Host.Boot to Switch constructor consumes factory exactly once");
            check(ReferenceEquals(Factory.GetValue(null), factory), "Host installed exact typed factory into production hook");
            check(Host.Device == null, "failed memory creation cannot publish a live Device");
            ulong expected = (ulong)typeof(Switch).Assembly.GetType("Ryujinx.HLE.HOS.Kernel.Common.KernelInit", true)
                .GetMethod("GetBackedDramSize", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, null);
            check(requested == expected && expected != 0, "actual constructor supplies exact kernel/service pool size");

            int initial = AllocationCount();
            MemoryBlock returned = null;
            Factory.SetValue(null, (Func<ulong, MemoryBlock>)(size => returned = MemoryBlock.ReserveShared(size)));
            using (var actual = (MemoryBlock)Allocate.Invoke(null, new object[] { MemoryAllocationFlags.Reserve }))
            {
                check(ReferenceEquals(actual, returned), "production Switch allocator retains the exact owner, without a copy");
                check(actual.Size == expected && AllocationCount() == initial + 1, "valid block remains owned until disposal");
            }
            check(AllocationCount() == initial && returned.Pointer == 0, "accepted block uses normal MemoryBlock disposal");
            Factory.SetValue(null, (Func<ulong, MemoryBlock>)(size => returned = MemoryBlock.ReserveShared((ulong)Environment.SystemPageSize)));
            check(Rejected(), "wrong-sized block is rejected at production allocation boundary");
            check(returned.Pointer == 0 && AllocationCount() == initial, "rejected returned owner is disposed");
            Factory.SetValue(null, (Func<ulong, MemoryBlock>)(_ => null));
            check(Rejected(), "null override does not silently fall back to private memory");
            Factory.SetValue(null, null);
            using var original = (MemoryBlock)Allocate.Invoke(null, new object[] { MemoryAllocationFlags.Reserve });
            check(original.Size == expected, "null hook still uses original reserve allocation");
            bool Rejected()
            {
                try { using var unexpected = (MemoryBlock)Allocate.Invoke(null, new object[] { MemoryAllocationFlags.Reserve }); }
                catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException) { return true; }
                return false;
            }
        }
        finally
        {
            Factory.SetValue(null, null);
            Directory.Delete(root, true);
        }
    }
}

// This fixture must stop before any GPU method is used; it does not simulate a ready renderer.
public class NoGpuCalls : DispatchProxy
{
    protected override object Invoke(MethodInfo method, object[] args) =>
        throw new InvalidOperationException("Unexpected GPU call in service-memory fixture: " + method.Name);
}
