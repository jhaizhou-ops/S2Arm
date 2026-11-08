using System.Diagnostics;
using System.Globalization;
using System.Runtime;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

// K02: standalone Mac NativeAOT experiment, never linked into the product.
internal static partial class Program
{
    private const int MiB = 1 << 20;
    private static byte[]? _sink;

    private readonly record struct Options(int Frames, int FrameUs, int PerFrameKB,
        int BurstEvery, int SmallMB, int LohMB, int PohMB, int RingMB, int Seed, bool Forced,
        string LargeMode);

    private struct Sample
    {
        public long Index, Before, After, Fragmented, Committed, Promoted, Pinned, Load, Threshold;
        public long G2Before, G2After, LohBefore, LohAfter, PohBefore, PohAfter;
        public int Generation;
        public bool Concurrent, Compacted;
        public double Pause0, Pause1;
    }

    private sealed class Recorder
    {
        private readonly Sample[] _samples = new Sample[16384];
        private readonly long[] _last = new long[4];
        private int _n0, _n2;
        private long _pendingBackground;
        public int Count, Overflow;
        public long ProbeAllocated;
        public long PeakCommitted;

        public void Reset()
        {
            for (int k = 1; k <= 3; k++) _last[k] = GC.GetGCMemoryInfo((GCKind)k).Index;
            _n0 = GC.CollectionCount(0);
            _n2 = GC.CollectionCount(2);
            Count = Overflow = 0;
            ProbeAllocated = 0;
        }

        // MemoryInfo allocates in NativeAOT. Poll only after collection counts advance;
        // keep polling a pending background completion until its own Index changes.
        public void Poll()
        {
            int n0 = GC.CollectionCount(0), n2 = GC.CollectionCount(2);
            if (n0 == _n0 && n2 == _n2 && _pendingBackground == 0) return;
            long a = GC.GetAllocatedBytesForCurrentThread();
            if (n2 != _n2) _pendingBackground = Stopwatch.GetTimestamp();
            _n0 = n0;
            _n2 = n2;
            for (int k = 1; k <= 3; k++)
            {
                GCMemoryInfo g = GC.GetGCMemoryInfo((GCKind)k);
                if (k == 3 && g.Index > _last[k]) _pendingBackground = 0;
                if (g.Index == 0 || g.Index <= _last[k]) continue;
                _last[k] = g.Index;
                if (Count == _samples.Length) { Overflow++; continue; }
                ref Sample s = ref _samples[Count++];
                s.Index = g.Index;
                s.Generation = g.Generation;
                s.Concurrent = g.Concurrent;
                s.Compacted = g.Compacted;
                s.Pause0 = g.PauseDurations[0].TotalMilliseconds;
                s.Pause1 = g.PauseDurations[1].TotalMilliseconds;
                foreach (GCGenerationInfo gi in g.GenerationInfo) s.Before += gi.SizeBeforeBytes;
                s.After = g.HeapSizeBytes;
                s.Fragmented = g.FragmentedBytes;
                s.Committed = g.TotalCommittedBytes;
                PeakCommitted = Math.Max(PeakCommitted, s.Committed);
                s.Promoted = g.PromotedBytes;
                s.Pinned = g.PinnedObjectsCount;
                s.Load = g.MemoryLoadBytes;
                s.Threshold = g.HighMemoryLoadThresholdBytes;
                s.G2Before = g.GenerationInfo[2].SizeBeforeBytes;
                s.G2After = g.GenerationInfo[2].SizeAfterBytes;
                s.LohBefore = g.GenerationInfo[3].SizeBeforeBytes;
                s.LohAfter = g.GenerationInfo[3].SizeAfterBytes;
                s.PohBefore = g.GenerationInfo[4].SizeBeforeBytes;
                s.PohAfter = g.GenerationInfo[4].SizeAfterBytes;
            }
            // A blocking gen2 may increment count without a background collection.
            // Bound pending polling to avoid permanent observer allocation after it.
            if (_pendingBackground != 0 &&
                Stopwatch.GetElapsedTime(_pendingBackground).TotalSeconds > 1) _pendingBackground = 0;
            ProbeAllocated += GC.GetAllocatedBytesForCurrentThread() - a;
        }

        public void Write(Utf8JsonWriter w)
        {
            w.WriteStartArray("collections");
            for (int i = 0; i < Count; i++)
            {
                ref Sample s = ref _samples[i];
                w.WriteStartObject();
                w.WriteNumber("index", s.Index);
                w.WriteNumber("generation", s.Generation);
                w.WriteBoolean("concurrent", s.Concurrent);
                w.WriteBoolean("compacted", s.Compacted);
                w.WriteNumber("pause0_ms", s.Pause0);
                w.WriteNumber("pause1_ms", s.Pause1);
                w.WriteNumber("before_bytes", s.Before);
                w.WriteNumber("after_bytes", s.After);
                w.WriteNumber("fragmented_bytes", s.Fragmented);
                w.WriteNumber("committed_bytes", s.Committed);
                w.WriteNumber("promoted_bytes", s.Promoted);
                w.WriteNumber("pinned_count", s.Pinned);
                w.WriteNumber("load_bytes", s.Load);
                w.WriteNumber("threshold_bytes", s.Threshold);
                w.WriteNumber("gen2_before_bytes", s.G2Before);
                w.WriteNumber("gen2_after_bytes", s.G2After);
                w.WriteNumber("loh_before_bytes", s.LohBefore);
                w.WriteNumber("loh_after_bytes", s.LohAfter);
                w.WriteNumber("poh_before_bytes", s.PohBefore);
                w.WriteNumber("poh_after_bytes", s.PohAfter);
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
    }

    [DllImport("/usr/lib/libSystem.B.dylib", SetLastError = true)]
    private static extern int proc_pidinfo(int pid, int flavor, ulong arg, out TaskInfo buffer, int size);

    // Darwin proc_taskinfo, libproc.h: first two fields are virtual / resident bytes.
    [StructLayout(LayoutKind.Sequential, Size = 96)]
    private struct TaskInfo { public ulong VirtualBytes, ResidentBytes; }

    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "proc_pidinfo", SetLastError = true)]
    private static extern int RegionInfo(int pid, int flavor, ulong arg, out Region buffer, int size);

    // SDK sys/proc_info.h proc_regioninfo: tag at 32, share_mode at 60,
    // address/size at 80/88. Count private untagged mappings, including PROT_NONE.
    // This includes GC reservations but is not a GC-only or low-address counter.
    [StructLayout(LayoutKind.Explicit, Size = 96)]
    private struct Region
    {
        [FieldOffset(0)] public uint Protection;
        [FieldOffset(32)] public uint Tag;
        [FieldOffset(60)] public uint ShareMode;
        [FieldOffset(80)] public ulong Address;
        [FieldOffset(88)] public ulong Size;
    }

    private readonly record struct VmSnapshot(ulong Total, ulong Accessible, ulong NoAccess);

    private static VmSnapshot PrivateMappings()
    {
        ulong address = 0, total = 0, accessible = 0, noAccess = 0;
        int regions = 0;
        while (RegionInfo(Environment.ProcessId, 7, address, out Region r, 96) == 96)
        {
            if (r.Tag == 0 && r.ShareMode is 2 or 3)
            {
                total += r.Size;
                if (r.Protection == 0) noAccess += r.Size;
                else accessible += r.Size;
            }
            if (r.Size == 0 || r.Address + r.Size <= address || ++regions > 100000)
                throw new InvalidOperationException("Invalid region enumeration");
            address = r.Address + r.Size;
        }
        if (regions == 0) throw new InvalidOperationException("No VM regions observed");
        return new(total, accessible, noAccess);
    }

    private static void Memory(ref ulong peakV, ref ulong peakR)
    {
        if (proc_pidinfo(Environment.ProcessId, 4, 0, out TaskInfo t, 96) != 96)
            throw new InvalidOperationException("proc_pidinfo(PROC_PIDTASKINFO) failed");
        peakV = Math.Max(peakV, t.VirtualBytes);
        peakR = Math.Max(peakR, t.ResidentBytes);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static byte[] Allocate(int size, bool pinned = false)
    {
        byte[] a = GC.AllocateUninitializedArray<byte>(size, pinned);
        // Touch pages so resident memory is real, including long-lived LOH and POH.
        for (int i = 0; i < a.Length; i += 4096) a[i] = 1;
        a[^1] = 1;
        return a;
    }

    private static Options Parse(string[] args)
    {
        var values = new Dictionary<string, int>();
        bool forced = false;
        string largeMode = "managed";
        string[] names = ["frames", "frame-us", "per-frame-kb", "burst-every", "small-mb",
            "loh-mb", "poh-mb", "ring-mb", "seed"];
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--forced-control") { forced = true; continue; }
            if (args[i] == "--large-mode") { largeMode = args[++i]; continue; }
            string name = args[i].StartsWith("--") ? args[i][2..] : "";
            if (!names.Contains(name) || !values.TryAdd(name, int.Parse(args[++i], CultureInfo.InvariantCulture)))
                throw new ArgumentException("Unknown or duplicate option: " + name);
        }
        int Get(string k, int d) => values.GetValueOrDefault(k, d);
        var o = new Options(Get("frames", 6000), Get("frame-us", 1000), Get("per-frame-kb", 16),
            Get("burst-every", 30), Get("small-mb", 150), Get("loh-mb", 64), Get("poh-mb", 14),
            Get("ring-mb", 24), Get("seed", 1), forced, largeMode);
        if (largeMode is not ("managed" or "transient-native" or "all-native"))
            throw new ArgumentException("Unknown large-mode");
        if (o.Frames < 1 || o.Frames > 1_000_000 || o.FrameUs < 0 || o.FrameUs > 100000 ||
            o.PerFrameKB < 0 || o.PerFrameKB > 1024 || o.BurstEvery < 1 || o.SmallMB < 0 ||
            o.LohMB < 0 || o.PohMB < 0 || o.RingMB < 0 ||
            (long)o.SmallMB + o.LohMB + o.PohMB + o.RingMB > 768)
            throw new ArgumentException("Invalid workload bounds (live payload <= 768 MiB)");
        return o;
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0] is "--reference-control" or "--reference-natural")
                return RunReferences(args);
            return Run(Parse(args));
        }
        catch (Exception e) { Console.Error.WriteLine(e.GetType().Name + ": " + e.Message); return 2; }
    }

    private static int Run(Options o)
    {
        if (!OperatingSystem.IsMacOS() || RuntimeInformation.ProcessArchitecture != Architecture.Arm64 ||
            RuntimeFeature.IsDynamicCodeSupported)
            throw new PlatformNotSupportedException("Requires macOS arm64 NativeAOT publish");
        string? latency = Environment.GetEnvironmentVariable("S2A_GCBENCH_LATENCY");
        if (latency == "sustained") GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
        else if (!string.IsNullOrEmpty(latency)) throw new ArgumentException("Unknown benchmark latency mode");
        var config = GC.GetConfigurationVariables();
        using var native = new NativeBuffers(o.LargeMode == "all-native" ? o.LohMB : 0);
        // Initialize observer, P/Invoke, timer and sink before the measured window.
        var rec = new Recorder();
        ulong startupV = 0, startupR = 0;
        Memory(ref startupV, ref startupR);
        long startupAlloc = GC.GetTotalAllocatedBytes(true);
        var live = new byte[o.SmallMB * MiB / 120][]; // 96 B payload + 24 B object header
        for (int i = 0; i < live.Length; i++) live[i] = Allocate(96);
        var loh = new byte[o.LargeMode == "all-native" ? 0 : o.LohMB][];
        for (int i = 0; i < loh.Length; i++) loh[i] = Allocate(MiB);
        var poh = new byte[o.PohMB][];
        for (int i = 0; i < poh.Length; i++) poh[i] = Allocate(MiB, true);
        var ring = new byte[o.RingMB * MiB / 536][];
        for (int i = 0; i < ring.Length; i++) ring[i] = Allocate(512);
        var pins = new GCHandle[128];
        for (int i = 0; i < pins.Length && live.Length > 0; i++)
            pins[i] = GCHandle.Alloc(live[i * (live.Length / pins.Length)], GCHandleType.Pinned);
        // One explicit promotion before measurement, excluded from all deltas.
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        GC.WaitForPendingFinalizers();
        rec.Reset();
        int c0 = GC.CollectionCount(0), c1 = GC.CollectionCount(1), c2 = GC.CollectionCount(2);
        long allocated = GC.GetTotalAllocatedBytes(true);
        double pause = GC.GetTotalPauseDuration().TotalMilliseconds;
        ulong peakV = 0, peakR = 0;
        Memory(ref peakV, ref peakR);
        ulong initialV = peakV, initialR = peakR;
        VmSnapshot initialMap = PrivateMappings();
        ulong initialPrivate = initialMap.Total, peakPrivate = initialPrivate;
        ulong peakAccessible = initialMap.Accessible, peakNoAccess = initialMap.NoAccess;
        rec.PeakCommitted = GC.GetGCMemoryInfo().TotalCommittedBytes;
        long begin = Stopwatch.GetTimestamp();
        int rp = 0, completed = 0, forced = 0;
        var random = new Random(o.Seed);
        string status = "ok";
        try
        {
            for (int frame = 0; frame < o.Frames; frame++)
            {
                // Per-frame small objects with a bounded escaping sink prevent AOT elimination.
                if (o.PerFrameKB > 0) native.ReleaseTransient();
                for (int k = 0; k < o.PerFrameKB * 1024; k += 256)
                    _sink = Allocate(232);
                if (ring.Length > 0)
                {
                    ring[rp] = Allocate(512);
                    rp = (rp + 1) % ring.Length;
                }
                rec.Poll();
                if (frame % o.BurstEvery == 0)
                {
                    // 0.5--7 MiB one-shot LOH allocation; a small subset replaces old LOH.
                    int size = (1 + random.Next(14)) * (MiB / 2);
                    if (o.LargeMode == "managed") _sink = Allocate(size);
                    else native.ReplaceTransient(size);
                    rec.Poll();
                    if (loh.Length > 0 && frame % (o.BurstEvery * 4) == 0)
                    {
                        loh[random.Next(loh.Length)] = Allocate(MiB);
                        rec.Poll();
                    }
                    if (o.LargeMode == "all-native" && o.LohMB > 0 && frame % (o.BurstEvery * 4) == 0)
                        native.Replace(random.Next(o.LohMB));
                }
                if (live.Length > 0 && frame % 64 == 0) live[random.Next(live.Length)] = Allocate(96);
                if (o.Forced && frame % 1000 == 999)
                {
                    GC.Collect(2, GCCollectionMode.Forced, true, true);
                    forced++;
                    rec.Poll();
                }
                Memory(ref peakV, ref peakR);
                if (frame % 64 == 0 || frame % o.BurstEvery == 0)
                {
                    VmSnapshot m = PrivateMappings();
                    peakPrivate = Math.Max(peakPrivate, m.Total);
                    peakAccessible = Math.Max(peakAccessible, m.Accessible);
                    peakNoAccess = Math.Max(peakNoAccess, m.NoAccess);
                }
                completed++;
                if (o.FrameUs > 0) Thread.Sleep(TimeSpan.FromMicroseconds(o.FrameUs));
            }
        }
        catch (OutOfMemoryException) { status = "oom"; }
        // Stop allocating; allow any in-flight background GC to publish completion info.
        for (int i = 0; i < 100; i++) { rec.Poll(); Thread.Sleep(10); }
        double elapsed = Stopwatch.GetElapsedTime(begin).TotalSeconds;
        int n0 = GC.CollectionCount(0) - c0, n1 = GC.CollectionCount(1) - c1, n2 = GC.CollectionCount(2) - c2;
        long measuredAlloc = GC.GetTotalAllocatedBytes(true) - allocated;
        double totalPause = GC.GetTotalPauseDuration().TotalMilliseconds - pause;
        Memory(ref peakV, ref peakR);
        VmSnapshot finalMap = PrivateMappings();
        peakPrivate = Math.Max(peakPrivate, finalMap.Total);
        peakAccessible = Math.Max(peakAccessible, finalMap.Accessible);
        peakNoAccess = Math.Max(peakNoAccess, finalMap.NoAccess);
        rec.PeakCommitted = Math.Max(rec.PeakCommitted, GC.GetGCMemoryInfo().TotalCommittedBytes);
        // Serialize only after measurement. Never allocate strings/JSON in the hot loop.
        using var w = new Utf8JsonWriter(Console.OpenStandardOutput());
        w.WriteStartObject();
        w.WriteString("schema", "s2a.gcbench.v1");
        w.WriteString("status", status);
        w.WriteString("runtime", RuntimeInformation.FrameworkDescription);
        w.WriteString("os", RuntimeInformation.OSDescription);
        w.WriteString("architecture", RuntimeInformation.ProcessArchitecture.ToString());
        w.WriteString("latency_mode", GCSettings.LatencyMode.ToString());
        w.WriteBoolean("server_gc", GCSettings.IsServerGC);
        w.WriteBoolean("native_aot", !RuntimeFeature.IsDynamicCodeSupported);
        w.WriteStartObject("workload");
        w.WriteNumber("frames", o.Frames);
        w.WriteNumber("frame_us", o.FrameUs);
        w.WriteNumber("per_frame_kib", o.PerFrameKB);
        w.WriteNumber("burst_every_frames", o.BurstEvery);
        w.WriteNumber("small_object_heap_target_mib", o.SmallMB);
        w.WriteNumber("loh_payload_mib", o.LohMB);
        w.WriteNumber("poh_payload_mib", o.PohMB);
        w.WriteNumber("medium_ring_target_mib", o.RingMB);
        w.WriteNumber("seed", o.Seed);
        w.WriteBoolean("forced_control", o.Forced);
        w.WriteString("large_mode", o.LargeMode);
        w.WriteEndObject();
        w.WriteStartObject("effective_config");
        foreach (var p in config.OrderBy(p => p.Key))
        {
            if (p.Value is bool b) w.WriteBoolean(p.Key, b);
            else if (p.Value is string s) w.WriteString(p.Key, s);
            else if (p.Value is ulong u) w.WriteNumber(p.Key, u);
            else w.WriteNumber(p.Key, Convert.ToInt64(p.Value, CultureInfo.InvariantCulture));
        }
        w.WriteEndObject();
        w.WriteNumber("completed_frames", completed);
        w.WriteNumber("forced_measured_collections", forced);
        w.WriteNumber("elapsed_s", elapsed);
        w.WriteNumber("count0", n0); w.WriteNumber("count1", n1); w.WriteNumber("count2", n2);
        w.WriteNumber("total_pause_ms", totalPause);
        w.WriteNumber("allocated_bytes", measuredAlloc);
        w.WriteNumber("observer_allocated_bytes", rec.ProbeAllocated);
        w.WriteNumber("startup_allocated_bytes", allocated - startupAlloc);
        w.WriteNumber("startup_virtual_bytes", startupV);
        w.WriteNumber("initial_virtual_bytes", initialV);
        w.WriteNumber("peak_virtual_bytes", peakV);
        w.WriteNumber("initial_resident_bytes", initialR);
        w.WriteNumber("peak_resident_bytes", peakR);
        w.WriteNumber("initial_private_untagged_bytes", initialPrivate);
        w.WriteNumber("peak_private_untagged_bytes", peakPrivate);
        w.WriteNumber("peak_private_untagged_accessible_bytes", peakAccessible);
        w.WriteNumber("peak_private_untagged_noaccess_bytes", peakNoAccess);
        w.WriteNumber("peak_gc_committed_bytes", rec.PeakCommitted);
        w.WriteNumber("native_allocated_bytes", native.Allocated);
        w.WriteNumber("peak_native_live_bytes", native.Peak);
        w.WriteNumber("record_overflow", rec.Overflow);
        rec.Write(w);
        w.WriteEndObject(); w.Flush();
        foreach (GCHandle p in pins) if (p.IsAllocated) p.Free();
        GC.KeepAlive(live); GC.KeepAlive(loh); GC.KeepAlive(poh); GC.KeepAlive(ring);
        return status == "ok" ? 0 : 3;
    }
}
