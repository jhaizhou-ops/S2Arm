// Native memory the managed VP9 decoder (Ryujinx.Graphics.Nvdec.Vp9) keeps per decoded frame.
// 11-07 GRID Autosport: the host footprint rose about 2 MB per movie frame until iOS killed it at 8 GB. Decoder.Decode took its ten per-frame buffers
//   (tile workers, mode info, segment maps, contexts, loop filter masks, motion vectors) from a 10-entry pool and gave them back only after a
//   successful decode; a frame that failed (InternalErrorException → false) left all ten marked in use, every later frame then allocated past the
//   pool, and MemoryAllocator.Free ignored pointers that were not in the pool, so those were never freed.
// Expected, from the allocator contract alone (every Allocate is matched by a Free inside one Decode call): after a warm-up frame, decoding more
//   frames, failed or not, leaves the malloc bytes in use where they were. Measured with malloc_zone_statistics; the tolerance (1 MB) is far
//   below one frame's buffers at 1920x1088 (the leak per frame the fix removes) and covers unrelated runtime allocations.
// Input: a 1920x1088 keyframe with an empty bitstream (the tile data cannot be read: "Truncated packet or corrupt tile length" → Decode false).
using System;
using System.Reflection;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Nvdec.Vp9;
using Ryujinx.Graphics.Video;

static class P
{
    [StructLayout(LayoutKind.Sequential)] struct MallocStats { public uint BlocksInUse; public nuint SizeInUse, MaxSizeInUse, SizeAllocated; }
    [DllImport("libSystem.dylib")] static extern void malloc_zone_statistics(nint zone, out MallocStats stats);
    static long InUse() { GC.Collect(); GC.WaitForPendingFinalizers(); malloc_zone_statistics(0, out var s); return (long)s.SizeInUse; }

    static int fails;
    static void Le(string what, long limit, long got) { Console.WriteLine($"{(got <= limit ? "ok  " : "FAIL")} {what}: want <= {limit}, got {got}"); if (got > limit) fails++; }
    static void Eq(string what, long want, long got) { Console.WriteLine($"{(want == got ? "ok  " : "FAIL")} {what}: want {want}, got {got}"); if (want != got) fails++; }
    const long Tol = 1 << 20;

    static int Main()
    {
        if (!OperatingSystem.IsMacOS()) { Console.WriteLine("vp9_alloc_leak: macOS only (malloc_zone_statistics)"); return 75; }

        // ① failed frames
        var dec = new Decoder();
        ISurface outp = dec.CreateSurface(1920, 1088);
        var mvs = new Vp9MvRef[(1920 / 8) * (1088 / 8)];
        bool Fail()
        {
            var info = new Vp9PictureInfo { IsKeyFrame = true, TransformMode = 0, LastReference = outp, GoldenReference = outp, AltReference = outp };
            return dec.Decode(ref info, outp, ReadOnlySpan<byte>.Empty, ReadOnlySpan<Vp9MvRef>.Empty, mvs);
        }
        Eq("empty bitstream fails to decode", 0, Fail() ? 1 : 0);
        Fail();   // warm-up: the pool holds one frame's ten buffers
        long a = InUse();
        int okCount = 0;
        for (int i = 0; i < 40; i++) okCount += Fail() ? 1 : 0;
        Eq("40 more frames all failed", 0, okCount);
        Le("① malloc bytes in use grown over 40 failed 1920x1088 frames", Tol, InUse() - a);

        // ② MemoryAllocator: 12 live allocations against its 10-entry pool, freed, 20 rounds — the 2 past the pool must be freed too
        Type t = typeof(Decoder).Assembly.GetType("Ryujinx.Graphics.Nvdec.Vp9.Common.MemoryAllocator", true)!;
        object al = Activator.CreateInstance(t, true)!;
        MethodInfo alloc = t.GetMethod("Allocate")!.MakeGenericMethod(typeof(byte)), free = t.GetMethod("Free")!.MakeGenericMethod(typeof(byte));
        void Round() { var live = new object[12]; for (int i = 0; i < 12; i++) live[i] = alloc.Invoke(al, [(1 << 20) + i * 4096])!; foreach (object p in live) free.Invoke(al, [p]); }
        Round();
        long b = InUse();
        for (int r = 0; r < 20; r++) Round();
        Le("② malloc bytes in use grown over 20 rounds of 12 x 1 MB against a 10-entry pool", Tol, InUse() - b);

        Console.WriteLine(fails == 0 ? "vp9_alloc_leak: all green" : $"vp9_alloc_leak: {fails} red");
        return fails == 0 ? 0 : 1;
    }
}
