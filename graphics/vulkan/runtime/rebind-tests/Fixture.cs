using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;

internal static class Proof
{
    private const int ExpectedChecks = 1468;
    private const int WarmupIterations = 30000;
    private const int Iterations = 100000;
    private static int _checks;
    private static readonly Type UpdaterType = typeof(DescriptorSetUpdater);

    private static FieldInfo Field(string name) =>
        UpdaterType.GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("Production field changed: " + name);

    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new Exception(message);
    }

    private static T Get<T>(DescriptorSetUpdater updater, string name) => (T)Field(name).GetValue(updater)!;
    private static void Put(DescriptorSetUpdater updater, string name, object value) => Field(name).SetValue(updater, value);

    // Setup only: Rebind consumes these real fields, without constructing a Vulkan device.
    private static DescriptorSetUpdater Create(bool program = true)
    {
        var updater = (DescriptorSetUpdater)RuntimeHelpers.GetUninitializedObject(UpdaterType);
        Type references = Field("_uniformBufferRefs").FieldType.GetElementType()!;
        Put(updater, "_uniformBufferRefs", Array.CreateInstance(references, Constants.MaxUniformBufferBindings));
        Put(updater, "_storageBufferRefs", Array.CreateInstance(references, Constants.MaxStorageBufferBindings));
        Put(updater, "_uniformBuffers", new DescriptorBufferInfo[Constants.MaxUniformBufferBindings]);
        Put(updater, "_storageBuffers", new DescriptorBufferInfo[Constants.MaxStorageBufferBindings]);
        Put(updater, "_uniformSetPd", Enumerable.Repeat(37, Constants.MaxUniformBufferBindings).ToArray());
        if (program) Put(updater, "_program", RuntimeHelpers.GetUninitializedObject(typeof(ShaderCollection)));
        return updater;
    }

    private static Auto<DisposableBuffer> Buffer() => new(default);

    private static void Bind(DescriptorSetUpdater updater, bool storage, int bit,
        Auto<DisposableBuffer> buffer, int offset, int length, bool set, bool mirrored)
    {
        string kind = storage ? "_storage" : "_uniform";
        Array references = Get<Array>(updater, kind + "BufferRefs");
        Type referenceType = references.GetType().GetElementType()!;
        object reference = Activator.CreateInstance(referenceType)!;
        referenceType.GetField("Buffer")!.SetValue(reference, buffer);
        referenceType.GetField("Offset")!.SetValue(reference, offset);
        references.SetValue(reference, bit);
        // Intentionally different: overlap must use BufferRef.Offset, not this Offset.
        Get<DescriptorBufferInfo[]>(updater, kind + "Buffers")[bit] = new() { Offset = 999, Range = (ulong)length };
        var bindings = Get<BitMapStruct<Array2<long>>>(updater, kind + "Set");
        if (set) bindings.Set(bit);
        Put(updater, kind + "Set", bindings);
        var mirrors = Get<BitMapStruct<Array2<long>>>(updater, kind + "Mirrored");
        if (mirrored) mirrors.Set(bit);
        Put(updater, kind + "Mirrored", mirrors);
    }

    private static int Dirty(DescriptorSetUpdater updater) => Convert.ToInt32(Field("_dirty").GetValue(updater));
    private static bool IsSet(DescriptorSetUpdater updater, bool storage, int bit, bool mirrored = false) =>
        Get<BitMapStruct<Array2<long>>>(updater,
            (storage ? "_storage" : "_uniform") + (mirrored ? "Mirrored" : "Set")).IsSet(bit);

    private static void Semantics()
    {
        var buffer = Buffer();
        var other = Buffer();
        var none = Create(false);
        Bind(none, false, 64, buffer, 100, 20, true, true);
        none.Rebind(buffer, 100, 20);
        Check(IsSet(none, false, 64) && Dirty(none) == 0, "null program mutated bindings");
        var empty = Create();
        empty.Rebind(buffer, 100, 20);
        Check(Dirty(empty) == 0, "empty dirty");

        foreach (bool storage in new[] { false, true })
        foreach (int bit in new[] { 0, 1, 63, 64, storage ? Constants.MaxStorageBufferBindings - 1 : Constants.MaxUniformBufferBindings - 1 })
        foreach (var masks in new[] { (true, false), (false, true), (true, true) })
        foreach (var range in new[] { (99, 2, true), (100, 20, true), (119, 1, true), (120, 1, false), (90, 10, false), (200, 10, false) })
        foreach (bool sameBuffer in new[] { false, true })
        {
            var updater = Create();
            Bind(updater, storage, bit, sameBuffer ? buffer : other, 100, 20, masks.Item1, masks.Item2);
            updater.Rebind(buffer, range.Item1, range.Item2);
            bool invalid = sameBuffer && range.Item3;
            Check(IsSet(updater, storage, bit) == (masks.Item1 && !invalid), "set/overlap semantics");
            Check(IsSet(updater, storage, bit, true) == masks.Item2, "mirrored bitmap must not be cleared");
            Check(Dirty(updater) == (invalid ? (storage ? 2 : 1) : 0), "dirty category/return semantics");
            Check(Get<int[]>(updater, "_uniformSetPd")[bit] == (!storage && invalid ? 0 : 37), "uniform push descriptor generation");
        }

        var combined = Create();
        foreach (int bit in new[] { 0, 1, 63, 64, 79 })
        {
            Bind(combined, false, bit, buffer, 100, 20, true, true);
            Bind(combined, true, bit, buffer, 100, 20, true, true);
        }
        combined.Rebind(buffer, 100, 20);
        Check(Dirty(combined) == 3, "combined dirty flags");
        foreach (int bit in new[] { 0, 1, 63, 64, 79 })
        {
            Check(!IsSet(combined, false, bit) && !IsSet(combined, true, bit), "snapshot skipped binding after clear");
            Check(IsSet(combined, false, bit, true) && IsSet(combined, true, bit, true), "mirror source mutated");
        }

        var bitmap = new BitMap(128);
        foreach (int bit in new[] { 0, 63, 64, 127 }) Check(bitmap.Set(bit), "BitMap initial set");
        foreach (int bit in new[] { 0, 63, 64, 127 })
        {
            Check(!bitmap.Set(bit) && bitmap.IsSet(bit), "BitMap duplicate");
            bitmap.Clear(bit);
        }
        Check(!bitmap.AnySet(), "BitMap clear");
        SnapshotSemantics();
    }

    private struct ClearingListener : IBitMapListener
    {
        public BitMapStruct<Array2<long>> Left, Right;
        public List<(int, int)> Calls;
        public void BitMapSignal(int index, int count)
        {
            Calls.Add((index, count));
            Left.Clear();
            Right.Clear();
        }
    }

    private static void SnapshotSemantics()
    {
        var listener = new ClearingListener { Calls = new() };
        foreach (int bit in new[] { 0, 63, 127 }) listener.Left.Set(bit);
        foreach (int bit in new[] { 63, 64 }) listener.Right.Set(bit);
        var snapshot = listener.Left.Union(listener.Right);
#if VALUE_LISTENER
        snapshot.SignalSet(ref listener);
#else
        snapshot.SignalSet((index, count) => listener.BitMapSignal(index, count));
#endif
        Check(listener.Calls.SequenceEqual(new[] { (0, 1), (63, 1), (64, 1), (127, 1) }), "Union snapshot, duplicate or traversal order changed");
        Check(!listener.Left.AnySet() && !listener.Right.AnySet(), "callback must mutate original source bitmaps");
        foreach (int bit in new[] { 0, 63, 64, 127 }) Check(snapshot.IsSet(bit), "SignalSet mutated snapshot");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static long Measure(DescriptorSetUpdater updater, Auto<DisposableBuffer> buffer, int iterations)
    {
        long before = GC.GetAllocatedBytesForCurrentThread();
        for (int i = 0; i < iterations; i++) updater.Rebind(buffer, 100, 20);
        return GC.GetAllocatedBytesForCurrentThread() - before;
    }

    private static int Main()
    {
        try
        {
            Semantics();
            if (_checks != ExpectedChecks) throw new InvalidOperationException("Semantic assertion count changed: " + _checks);
            var buffer = Buffer();
            var empty = Create();
            var mirrored = Create();
            var noProgram = Create(false);
            Bind(mirrored, false, 64, buffer, 100, 20, true, true);
            Bind(mirrored, true, 64, buffer, 100, 20, true, true);
            foreach (var updater in new[] { empty, mirrored, noProgram }) Measure(updater, buffer, WarmupIterations);
            long emptyBytes = Measure(empty, buffer, Iterations);
            long mirroredBytes = Measure(mirrored, buffer, Iterations);
            long nullBytes = Measure(noProgram, buffer, Iterations);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                semantics_checks = _checks, iterations = Iterations, warmup_iterations = WarmupIterations,
                empty_bytes = emptyBytes, mirrored_bytes = mirroredBytes, null_program_bytes = nullBytes,
                runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
                architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            }));
            if (emptyBytes != 0 || mirroredBytes != 0 || nullBytes != 0)
            {
                Console.Error.WriteLine("FAIL: Rebind steady-state allocated managed bytes");
                return 1;
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { semantics_checks = _checks, failure = error.Message }));
            Console.Error.WriteLine(error);
            return 2;
        }
    }
}
