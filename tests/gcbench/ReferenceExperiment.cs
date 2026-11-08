using System.Diagnostics;
using System.Globalization;
using System.Runtime;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static partial class Program
{
    // A single young pointer per padded object spreads remembered-set writes
    // through the old object graph, rather than only through one LOH root array.
    [StructLayout(LayoutKind.Sequential)]
    private sealed class ReferenceNode
    {
        public byte[]? Young;
        // Physical fields matter: NativeAOT did not honor a class Size-only
        // padding request in the pilot (retained as a rejected observation).
#pragma warning disable CS0649
        public long P0, P1, P2, P3, P4, P5, P6, P7, P8, P9, P10, P11, P12;
#pragma warning restore CS0649
    }

    private readonly record struct ReferenceTrial(bool Valid, int PreparedGen1, int Targets,
        long Index, int Generation, long Promoted, long G2Before, long G2After,
        double Pause0, double Pause1, double WallMs, int Count0, int Count1, int Count2);

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static ReferenceTrial ReferenceEpoch(ReferenceNode[] old, int refs, int youngMB,
        bool control, Recorder rec)
    {
        // Clearing precedes the new batch in both modes. The local pool roots all
        // young objects, keeping live bytes constant when old->young edges vary.
        for (int i = 0; i < refs; i++) old[(int)((long)i * old.Length / refs)].Young = null;
        if (control) GC.Collect(2, GCCollectionMode.Forced, true, true);
        int a0 = GC.CollectionCount(0), a1 = GC.CollectionCount(1), a2 = GC.CollectionCount(2);
        var pool = new byte[youngMB * MiB / 4096][];
        for (int i = 0; i < pool.Length; i++)
        {
            pool[i] = Allocate(4072); // 4096 B including the array header
            if (!control) rec.Poll();
        }
        for (int i = 0; i < refs; i++)
            old[(int)((long)i * old.Length / refs)].Young = pool[i % pool.Length];
        if (!control)
        {
            rec.Poll();
            GC.KeepAlive(pool);
            return default;
        }

        // Explicit gen0 preparation and gen1 collection are diagnostics only.
        // Reject a trial if natural preparation collections already aged targets.
        bool cleanPreparation = GC.CollectionCount(0) == a0 && GC.CollectionCount(1) == a1
            && GC.CollectionCount(2) == a2;
        GC.Collect(0, GCCollectionMode.Forced, true, true);
        int prepared = 0;
        foreach (byte[] p in pool) if (GC.GetGeneration(p) == 1) prepared++;
        int n0 = GC.CollectionCount(0), n1 = GC.CollectionCount(1), n2 = GC.CollectionCount(2);
        long begin = Stopwatch.GetTimestamp();
        GC.Collect(1, GCCollectionMode.Forced, true, true);
        double wall = Stopwatch.GetElapsedTime(begin).TotalMilliseconds;
        GCMemoryInfo g = GC.GetGCMemoryInfo(GCKind.Ephemeral);
        var trial = new ReferenceTrial(cleanPreparation && prepared == pool.Length
            && g.Generation == 1 && GC.CollectionCount(2) == n2,
            prepared, pool.Length, g.Index, g.Generation, g.PromotedBytes,
            g.GenerationInfo[2].SizeBeforeBytes, g.GenerationInfo[2].SizeAfterBytes,
            g.PauseDurations[0].TotalMilliseconds, g.PauseDurations[1].TotalMilliseconds,
            wall, GC.CollectionCount(0) - n0, GC.CollectionCount(1) - n1,
            GC.CollectionCount(2) - n2);
        GC.KeepAlive(pool);
        return trial;
    }

    private static int RunReferences(string[] args)
    {
        if (!OperatingSystem.IsMacOS() || RuntimeInformation.ProcessArchitecture != Architecture.Arm64 ||
            RuntimeFeature.IsDynamicCodeSupported) throw new PlatformNotSupportedException("Mac arm64 AOT required");
        bool control = args[0] == "--reference-control";
        var values = new Dictionary<string, int>();
        for (int i = 1; i < args.Length; i++)
        {
            string name = args[i];
            if (name is not ("--old-mib" or "--young-mib" or "--references" or "--epochs") ||
                !values.TryAdd(name, int.Parse(args[++i], CultureInfo.InvariantCulture)))
                throw new ArgumentException("Unknown/duplicate reference option");
        }
        int oldMB = values.GetValueOrDefault("--old-mib", 150);
        int youngMB = values.GetValueOrDefault("--young-mib", 16);
        int refs = values.GetValueOrDefault("--references", 65536);
        int epochs = values.GetValueOrDefault("--epochs", control ? 12 : 120);
        if (oldMB < 16 || oldMB > 384 || youngMB < 1 || youngMB > 32 || refs < 0 ||
            refs > oldMB * MiB / 128 || epochs < 1 || epochs > 1000)
            throw new ArgumentException("Invalid reference workload bounds");
        var config = GC.GetConfigurationVariables();
        var rec = new Recorder();
        var trials = new ReferenceTrial[epochs];
        long alloc0 = GC.GetTotalAllocatedBytes(true);
        var old = new ReferenceNode[oldMB * MiB / 128];
        for (int i = 0; i < old.Length; i++) old[i] = new ReferenceNode();
        long oldAllocated = GC.GetTotalAllocatedBytes(true) - alloc0;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        rec.Reset();
        int c0 = GC.CollectionCount(0), c1 = GC.CollectionCount(1), c2 = GC.CollectionCount(2);
        long allocated = GC.GetTotalAllocatedBytes(true);
        double pause = GC.GetTotalPauseDuration().TotalMilliseconds;
        ulong peakV = 0, peakR = 0;
        Memory(ref peakV, ref peakR);
        ulong initialV = peakV;
        VmSnapshot m = PrivateMappings();
        ulong peakPrivate = m.Total, peakAccessible = m.Accessible, peakNoAccess = m.NoAccess;
        rec.PeakCommitted = GC.GetGCMemoryInfo().TotalCommittedBytes;
        long begin = Stopwatch.GetTimestamp();
        for (int epoch = 0; epoch < epochs; epoch++)
        {
            trials[epoch] = ReferenceEpoch(old, refs, youngMB, control, rec);
            Memory(ref peakV, ref peakR);
            m = PrivateMappings();
            peakPrivate = Math.Max(peakPrivate, m.Total);
            peakAccessible = Math.Max(peakAccessible, m.Accessible);
            peakNoAccess = Math.Max(peakNoAccess, m.NoAccess);
            if (control) rec.PeakCommitted = Math.Max(rec.PeakCommitted, GC.GetGCMemoryInfo().TotalCommittedBytes);
        }
        if (!control) for (int i = 0; i < 100; i++) { rec.Poll(); Thread.Sleep(10); }
        int n0 = GC.CollectionCount(0) - c0, n1 = GC.CollectionCount(1) - c1, n2 = GC.CollectionCount(2) - c2;
        long measuredAlloc = GC.GetTotalAllocatedBytes(true) - allocated;
        double totalPause = GC.GetTotalPauseDuration().TotalMilliseconds - pause;
        double elapsed = Stopwatch.GetElapsedTime(begin).TotalSeconds;
        using var w = new Utf8JsonWriter(Console.OpenStandardOutput());
        w.WriteStartObject();
        w.WriteString("schema", "s2a.gcbench.references.v1");
        w.WriteString("mode", control ? "forced_gen1_control" : "natural_references");
        w.WriteString("status", "ok");
        w.WriteBoolean("native_aot", !RuntimeFeature.IsDynamicCodeSupported);
        w.WriteBoolean("server_gc", GCSettings.IsServerGC);
        w.WriteNumber("old_target_mib", oldMB);
        w.WriteNumber("old_allocated_bytes", oldAllocated);
        w.WriteNumber("young_target_mib", youngMB);
        w.WriteNumber("old_to_young_references", refs);
        w.WriteNumber("epochs", epochs);
        w.WriteNumber("forced_measured_collections", control ? 3 * epochs : 0);
        w.WriteNumber("completed_frames", epochs);
        w.WriteNumber("count0", n0); w.WriteNumber("count1", n1); w.WriteNumber("count2", n2);
        w.WriteNumber("total_pause_ms", totalPause);
        w.WriteNumber("allocated_bytes", measuredAlloc);
        w.WriteNumber("observer_allocated_bytes", rec.ProbeAllocated);
        w.WriteNumber("elapsed_s", elapsed);
        w.WriteNumber("initial_virtual_bytes", initialV);
        w.WriteNumber("peak_virtual_bytes", peakV);
        w.WriteNumber("peak_resident_bytes", peakR);
        w.WriteNumber("peak_private_untagged_bytes", peakPrivate);
        w.WriteNumber("peak_private_untagged_accessible_bytes", peakAccessible);
        w.WriteNumber("peak_private_untagged_noaccess_bytes", peakNoAccess);
        w.WriteNumber("peak_gc_committed_bytes", rec.PeakCommitted);
        w.WriteNumber("record_overflow", rec.Overflow);
        w.WriteStartObject("effective_config");
        foreach (var p in config)
        {
            if (p.Value is bool b) w.WriteBoolean(p.Key, b);
            else if (p.Value is string s) w.WriteString(p.Key, s);
            else if (p.Value is ulong u) w.WriteNumber(p.Key, u);
            else w.WriteNumber(p.Key, Convert.ToInt64(p.Value, CultureInfo.InvariantCulture));
        }
        w.WriteEndObject();
        w.WriteStartArray("gen1_trials");
        if (control) foreach (ReferenceTrial t in trials)
        {
            w.WriteStartObject();
            w.WriteBoolean("valid", t.Valid);
            w.WriteNumber("targets_prepared_gen1", t.PreparedGen1);
            w.WriteNumber("targets", t.Targets);
            w.WriteNumber("index", t.Index);
            w.WriteNumber("generation", t.Generation);
            w.WriteNumber("promoted_bytes", t.Promoted);
            w.WriteNumber("gen2_before_bytes", t.G2Before);
            w.WriteNumber("gen2_after_bytes", t.G2After);
            w.WriteNumber("pause0_ms", t.Pause0); w.WriteNumber("pause1_ms", t.Pause1);
            w.WriteNumber("wall_ms", t.WallMs);
            w.WriteNumber("count0", t.Count0); w.WriteNumber("count1", t.Count1); w.WriteNumber("count2", t.Count2);
            w.WriteEndObject();
        }
        w.WriteEndArray();
        rec.Write(w);
        w.WriteEndObject(); w.Flush();
        GC.KeepAlive(old);
        return 0;
    }
}
