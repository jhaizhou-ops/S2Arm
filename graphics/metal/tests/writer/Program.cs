// Real cached guest code, specialization and host metadata; real background
// writer and files. Like production shbake, shared-only writes need no GPU host
// program. Optional host-binary writes use a real NxRenderer/GpuContext; neither
// mode constructs a guest or replacement host.
using System.Numerics;
using System.Reflection;
using NxGal;
using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;

static class Program
{
    const int Jobs = 2048;
    sealed record Snapshot(GuestCodeAndCbData?[] Guests, ShaderSpecializationState State);
    sealed record CachedRecord(CachedShaderProgram Program, byte[] HostCode);

    static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    static byte[] StateBytes(ShaderSpecializationState state)
    {
        using MemoryStream bytes = new();
        BinarySerializer writer = new(bytes); state.Write(ref writer);
        return bytes.ToArray();
    }

    // The on-disk shared/guest reader follows production shbake's ReadCache.
    static Snapshot ReadRecord(string directory, int index)
    {
        DiskCacheGuestStorage guest = new(directory);
        using FileStream toc = File.OpenRead(Path.Combine(directory, "shared.toc"));
        using FileStream data = File.OpenRead(Path.Combine(directory, "shared.data"));
        using Stream gtoc = guest.OpenTocFileStream(), gdata = guest.OpenDataFileStream();
        toc.Position = 32L + 8L * index;
        BinarySerializer tr = new(toc), dr = new(data);
        ulong offset = 0; tr.Read(ref offset);
        Require(offset < (ulong)data.Length, "shared offset outside real data");
        data.Position = (long)offset; dr.BeginCompression();
        uint mask = 0; dr.Read(ref mask);
        Require((mask & ~0x3fu) == 0, "invalid stage mask");
        GuestCodeAndCbData?[] stages = new GuestCodeAndCbData?[mask == 0 ? 1 : 6];
        if (mask == 0) mask = 1;
        while (mask != 0)
        {
            int stage = BitOperations.TrailingZeroCount(mask), guestIndex = 0;
            dr.Read(ref guestIndex); stages[stage] = guest.LoadShader(gtoc, gdata, guestIndex);
            mask &= mask - 1;
        }
        ShaderSpecializationState state = ShaderSpecializationState.Read(ref dr);
        dr.EndCompression();
        return new(stages, state);
    }

    static CachedRecord ReadProgram(string directory, string hostPrefix, int index)
    {
        Snapshot record = ReadRecord(directory, index);
        using FileStream toc = File.OpenRead(Path.Combine(directory, hostPrefix + ".toc"));
        using FileStream data = File.OpenRead(Path.Combine(directory, hostPrefix + ".data"));
        toc.Position = 32L + 16L * index;
        BinarySerializer tr = new(toc), dr = new(data);
        ulong offset = 0; uint uncompressed = 0, compressed = 0;
        tr.Read(ref offset); tr.Read(ref uncompressed); tr.Read(ref compressed);
        Require(uncompressed > 0 && compressed > 0 && offset + compressed < (ulong)data.Length, "real host metadata missing");
        data.Position = (long)offset;
        byte[] hostCode = new byte[uncompressed]; BinarySerializer.ReadCompressed(data, hostCode);
        // Read actual metadata with the production deserializer, with no invented info.
        data.Position = checked((long)(offset + compressed)); dr.BeginCompression();
        CachedShaderStage[] stages = new CachedShaderStage[record.Guests.Length];
        for (int stage = 0; stage < stages.Length; stage++)
        {
            if (record.Guests[stage] is not GuestCodeAndCbData guest) continue;
            var info = stage == 0 && stages.Length != 1 ? null : DiskCacheHostStorage.S2AReadShaderProgramInfo(ref dr);
            stages[stage] = new(info, guest.Code, guest.Cb1Data);
        }
        dr.EndCompression();
        return new(new CachedShaderProgram(null, record.State, stages), hostCode);
    }

    static int Pending(BackgroundDiskCacheWriter writer)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        object queue = typeof(BackgroundDiskCacheWriter).GetField("_fileWriterWorkerQueue", flags).GetValue(writer);
        object collection = queue.GetType().GetField("_queue", flags).GetValue(queue);
        return (int)collection.GetType().GetProperty("Count").GetValue(collection);
    }

    static int Main(string[] args)
    {
        Require(args.Length == 3 || args.Length == 4 && args[3] == "--with-host-binary",
            "Writer <real-current-cache> <host-prefix-without-extension> <new-output-directory> [--with-host-binary]");
        string input = Path.GetFullPath(args[0]), output = Path.GetFullPath(args[2]);
        Require(!Directory.Exists(output) && !File.Exists(output), "output must be a new isolated directory");
        Require(DiskCacheHostStorage.S2AReadCodeGenVersion(input) == DiskCacheHostStorage.CodeGenVersion,
            "input must use current production translator version");
        Require(new DiskCacheHostStorage(input).GetProgramCount() >= 16, "at least 16 real input programs required");
        CachedRecord[] programs = Enumerable.Range(0, 16).Select(i => ReadProgram(input, args[1], i)).ToArray();
        // Full host-binary serialization uses a real initialized production
        // renderer/context for its capabilities. CPU-only mode covers shared
        // and guest records, the same valid write mode as production shbake.
        NxRenderer renderer = null;
        GpuContext context = null;
        if (args.Length == 4)
        {
            renderer = new(); renderer.Initialize(GraphicsDebugLevel.None);
            context = new(renderer, new DirtyHacks(Array.Empty<EnabledDirtyHack>())); context.SetGpuThread();
        }
        DiskCacheHostStorage destination = new(Path.Combine(output, "drain"));
        int initial = destination.GetProgramCount();
        Require(initial == 0 && Directory.GetFiles(Path.Combine(output, "drain")).Length == 0,
            "destination must contain no pre-existing records or guest files");
        BackgroundDiskCacheWriter writer = new(context, destination);
        for (int i = 0; i < Jobs; i++)
        {
            CachedRecord entry = programs[i % programs.Length];
            writer.AddShader(entry.Program, context == null ? null : entry.HostCode);
        }
        int pending = Pending(writer);
        Require(pending > 0, "writer already empty; this run cannot prove pending-work drain");
        writer.Dispose();
        Require(destination.GetProgramCount() == Jobs, "Dispose returned before the last real cache record was written");
        Snapshot last = ReadRecord(Path.Combine(output, "drain"), Jobs - 1);
        CachedShaderProgram expected = programs[(Jobs - 1) % programs.Length].Program;
        Require(StateBytes(last.State).AsSpan().SequenceEqual(StateBytes(expected.SpecializationState)), "last specialization bytes differ");
        for (int i = 0; i < expected.Shaders.Length; i++)
        {
            CachedShaderStage stage = expected.Shaders[i];
            Require((stage == null) == !last.Guests[i].HasValue, "last stage presence differs");
            if (stage == null) continue;
            Require(stage.Code.AsSpan().SequenceEqual(last.Guests[i].Value.Code), "last guest code differs");
            Require(stage.Cb1Data.AsSpan().SequenceEqual(last.Guests[i].Value.Cb1Data), "last constant buffer differs");
        }
        if (context != null)
        {
            string hostPrefix = Path.GetFileNameWithoutExtension(Directory.GetFiles(Path.Combine(output, "drain"), "*_bin.toc").Single());
            CachedRecord finalHost = ReadProgram(Path.Combine(output, "drain"), hostPrefix, Jobs - 1);
            Require(finalHost.HostCode.AsSpan().SequenceEqual(programs[(Jobs - 1) % programs.Length].HostCode), "last appended host binary differs");
            Console.WriteLine("PASS writer host binary: last appended production host code and metadata read back");
        }
        foreach (string path in Directory.GetFiles(Path.Combine(output, "drain")))
            using (FileStream exclusive = new(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                Require(exclusive.Length > 0, "empty output cache file");
        Console.WriteLine($"PASS writer drain: initial {initial} records/0 files; {pending} tasks pending before Dispose; final {Jobs} new records; last appended guest/spec bytes identical");

        DiskCacheHostStorage failed = new(Path.Combine(output, "write-failure"));
        // A genuine file sharing conflict, not a replacement writer or fake I/O.
        using FileStream held = new(Path.Combine(output, "write-failure", "shared.toc"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        BackgroundDiskCacheWriter blocked = new(context, failed);
        blocked.AddShader(programs[0].Program, null);
        bool propagated = false;
        try { blocked.Dispose(); }
        catch (IOException e) { propagated = e.InnerException is DiskCacheLoadException { Result: DiskCacheLoadResult.NoAccess }; }
        Require(propagated, "real write failure was hidden by retirement");
        Console.WriteLine("PASS writer failure: real file-sharing NoAccess propagated as IOException after worker exit");
        context?.Dispose();
        return 0;
    }
}
