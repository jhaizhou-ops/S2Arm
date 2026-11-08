using System;
using System.Threading;
using Ryujinx.Graphics.Gpu.Memory;

static class Program
{
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static void Dead(S2ABufferReadScratch.Lease lease)
    {
        try { _ = lease.Span; } catch (ObjectDisposedException) { return; }
        throw new Exception("disposed/stale lease was readable");
    }

    static void Main()
    {
        Check(S2ABufferReadScratch.Enabled == (Environment.GetEnvironmentVariable("S2A_BUFFER_READ_SCRATCH") == "1"), "actual policy");
        var pool = new S2ABufferReadScratch();
        var first = pool.Rent(32);
        first.Span.Fill(17);
        var stale = first;
        using (var nested = pool.Rent(32))
        {
            nested.Span.Fill(29);
            Check(first.Span.IndexOfAnyExcept((byte)17) < 0, "nested rental overwrote outer data");
        }
        first.Dispose(); first.Dispose(); Dead(first);
        using (var next = pool.Rent(32))
        {
            next.Span.Fill(43);
            stale.Dispose(); Dead(stale);
            Check(next.Span.IndexOfAnyExcept((byte)43) < 0, "stale dispose released new rental");
        }
        var leases = new S2ABufferReadScratch.Lease[6];
        for (int i = 0; i < leases.Length; i++) { leases[i] = pool.Rent(1024); leases[i].Span.Fill((byte)i); }
        for (int i = 0; i < leases.Length; i++)
        {
            Check(leases[i].Span.IndexOfAnyExcept((byte)i) < 0, "exhausted pool aliases a live rental");
            leases[i].Dispose(); leases[i].Dispose(); Dead(leases[i]);
        }
        using (var huge = pool.Rent(1024 * 1024 + 1)) Check(huge.Span.Length == 1024 * 1024 + 1, "oversize fallback length");
        try { using var failed = pool.Rent(4096); failed.Span.Fill(1); throw new ApplicationException(); }
        catch (ApplicationException) { }
        using (var empty = pool.Rent(0)) Check(empty.Span.Length == 0, "zero length");
        bool negative = false;
        try { pool.Rent(-1); } catch (ArgumentOutOfRangeException) { negative = true; }
        Check(negative, "negative size accepted");
        using (var active = pool.Rent(64))
        {
            bool rentRejected = false, disposeRejected = false, readRejected = false;
            var thread = new Thread(() => {
                try { pool.Rent(1); } catch (InvalidOperationException) { rentRejected = true; }
                try { active.Dispose(); } catch (InvalidOperationException) { disposeRejected = true; }
                try { _ = active.Span; } catch (InvalidOperationException) { readRejected = true; }
            });
            thread.Start(); thread.Join();
            Check(rentRejected && disposeRejected && readRejected && active.Span.Length == 64, "wrong thread changed live rental");
        }
        for (int i = 0; i < 10000; i++) { using var warm = pool.Rent(256); warm.Span[0] = 1; }
        long start = GC.GetAllocatedBytesForCurrentThread();
        for (int i = 0; i < 100000; i++) { using var warm = pool.Rent(256); warm.Span[0] = 2; }
        long allocated = GC.GetAllocatedBytesForCurrentThread() - start;
        Check(allocated == 0, "warm scoped rentals allocate: " + allocated);
        Console.WriteLine($"PASS scratch lifecycle: policy={S2ABufferReadScratch.Enabled}; warm 100000 rentals={allocated} B; host JIT only");
    }
}
