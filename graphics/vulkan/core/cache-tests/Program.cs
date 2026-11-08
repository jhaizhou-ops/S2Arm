using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

class RejectedProgram : IProgram, IProgramBinaryLoadFailure
{
    public string ProgramBinaryLoadFailure => "TEST: rejected host record";
    public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Failure;
    public byte[] GetBinary() => null;
    public void Dispose() { }
}

class Recorder : DispatchProxy
{
    public static readonly List<byte[]> Loaded = new();
    public static readonly System.Threading.ManualResetEventSlim ProgramDisposed = new(false);
    public static bool RejectLoads;
    protected override object Invoke(MethodInfo method, object[] args)
    {
        if (method.Name == nameof(IRenderer.LoadProgramBinary))
        {
            Loaded.Add((byte[])args[0]);
            return RejectLoads ? new RejectedProgram() : Create<IProgram, Recorder>();
        }
        if (method.Name == nameof(IProgram.CheckProgramLink)) return ProgramLinkStatus.Success;
        if (method.Name == nameof(IDisposable.Dispose)) ProgramDisposed.Set();
        return method.ReturnType.IsValueType && method.ReturnType != typeof(void)
            ? Activator.CreateInstance(method.ReturnType) : null;
    }
}

class GuestBytes : Ryujinx.Graphics.Gpu.Shader.HashTable.IDataAccessor
{
    readonly byte[] _bytes;
    public GuestBytes(byte[] bytes) => _bytes = bytes;
    public ReadOnlySpan<byte> GetSpan(int offset, int length) => _bytes.AsSpan(offset, Math.Max(0, Math.Min(length, _bytes.Length - offset)));
}

class WarmCompletionWriter : TextWriter
{
    readonly TextWriter _inner;
    public readonly System.Threading.ManualResetEventSlim Completed = new(false);
    public WarmCompletionWriter(TextWriter inner) => _inner = inner;
    public override System.Text.Encoding Encoding => _inner.Encoding;
    public override void WriteLine(string value)
    {
        _inner.WriteLine(value);
        if (value?.StartsWith("[gal] 提前热程序：", StringComparison.Ordinal) == true) Completed.Set();
    }
}

class Program
{
    static readonly List<object> Results = new();
    static int Failed;
    static readonly string Root = Path.Combine(Path.GetTempPath(), "s2a-cache-admission-" + Environment.ProcessId);
    static readonly byte[] GuestA = Bytes(1), GuestB = Bytes(2), HostA = Bytes(41), HostB = Bytes(42);

    static byte[] Bytes(int seed) { byte[] data = new byte[256]; new Random(seed).NextBytes(data); return data; }
    static void Check(string name, bool pass, object evidence)
    {
        if (!pass) Failed++;
        Results.Add(new { name, pass, evidence });
        Console.WriteLine($"{(pass ? "PASS" : "RED")} {name}: {JsonSerializer.Serialize(evidence)}");
    }
    static GpuContext Context(string change = null, object value = null)
    {
        object caps = default(Capabilities);
        typeof(Capabilities).GetField(nameof(Capabilities.Api)).SetValue(caps, TargetApi.Vulkan);
        typeof(Capabilities).GetField(nameof(Capabilities.VendorName)).SetValue(caps, "cache-admission-fixture");
        if (change != null) typeof(Capabilities).GetField(change).SetValue(caps, value);
        var context = new GpuContext(DispatchProxy.Create<IRenderer, Recorder>(), new DirtyHacks(Array.Empty<ulong>()));
        context.Capabilities = (Capabilities)caps;
        return context;
    }
    static CachedShaderProgram ProgramFor(byte[] code, bool unalignedStorage = false)
    {
        var info = new ShaderProgramInfo(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(),
            Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(),
            ShaderStage.Compute, 0, 0, 0, false, false, false, false, 0, 0);
        var compute = new GpuChannelComputeState(8, 8, 1, 0, 0, unalignedStorage);
        return new CachedShaderProgram(DispatchProxy.Create<IProgram, Recorder>(), new ShaderSpecializationState(ref compute),
            new CachedShaderStage(info, code, Array.Empty<byte>()));
    }
    static string NewDir(string suffix) { string dir = Path.Combine(Root, suffix); Directory.CreateDirectory(dir); return dir; }
    static S2ALazyProgram Lazy(DiskCacheHostStorage storage, GpuContext context, string dir, int index, byte[] guest)
    {
        byte[] toc = File.ReadAllBytes(Path.Combine(dir, "shared.toc"));
        ulong timestamp = BitConverter.ToUInt64(toc, 16), offset = BitConverter.ToUInt64(toc, 32 + index * 8);
        S2AStageIndices stages = storage.S2ARegisterGuests(new GuestCodeAndCbData?[] { new GuestCodeAndCbData(guest, Array.Empty<byte>()) });
        return new S2ALazyProgram(storage, context, index, offset, timestamp, true, stages);
    }
    static Dictionary<string, string> OriginalHashes(string dir) => Directory.GetFiles(dir)
        .Where(p => Path.GetFileName(p).StartsWith("shared.") || Path.GetFileName(p).StartsWith("guest."))
        .ToDictionary(Path.GetFileName, p => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))));
    static bool SameHashes(Dictionary<string, string> a, Dictionary<string, string> b) =>
        a.Count == b.Count && a.All(pair => b.TryGetValue(pair.Key, out string value) && value == pair.Value);
    static void Close(DiskCacheHostStorage storage)
    {
        foreach (string name in new[] { "_lazySharedData", "_lazyHostToc", "_lazyHostData" })
            (typeof(DiskCacheHostStorage).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).GetValue(storage) as Stream)?.Dispose();
    }

    static void RejectedProgramCase()
    {
        string dir = NewDir("rejected-host");
        var writer = new DiskCacheHostStorage(dir);
        writer.AddShader(Context(), ProgramFor(GuestA), HostA);
        var reader = new DiskCacheHostStorage(dir);
        Recorder.Loaded.Clear();
        Recorder.RejectLoads = true;
        try
        {
            var program = Lazy(reader, Context(), dir, 0, GuestA).Materialize();
            Check("rejected host record becomes an on-demand miss before binding",
                program == null && Recorder.Loaded.Count == 1,
                new { materialized = program != null, rendererLoads = Recorder.Loaded.Count });
        }
        finally
        {
            Recorder.RejectLoads = false;
            Close(reader);
        }
    }

    static void CapabilityCase(string field, object value, bool same = false)
    {
        string dir = NewDir((field ?? "same-caps") + (same ? "-same" : ""));
        var writer = new DiskCacheHostStorage(dir);
        writer.AddShader(same ? Context(field, value) : Context(), ProgramFor(GuestA), HostA);
        var before = OriginalHashes(dir);
        var reader = new DiskCacheHostStorage(dir);
        Recorder.Loaded.Clear();
        var program = Lazy(reader, Context(field, value), dir, 0, GuestA).Materialize();
        bool expectedHit = field == null || same;
        Check(expectedHit ? "same effective caps reuse host bytes: " + field : "changed " + field + " rejects old host bytes",
            (expectedHit ? program != null && Recorder.Loaded.Single().SequenceEqual(HostA) : program == null && Recorder.Loaded.Count == 0) && SameHashes(before, OriginalHashes(dir)),
            new { materialized = program != null, rendererLoads = Recorder.Loaded.Count, originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
        Close(reader);
    }

    static void LanguageCase(bool writeSpirv, bool readSpirv)
    {
        bool previous = GraphicsConfig.EnableSpirvCompilationOnVulkan;
        try
        {
            string dir = NewDir($"language-{writeSpirv}-{readSpirv}");
            GraphicsConfig.EnableSpirvCompilationOnVulkan = writeSpirv;
            var writer = new DiskCacheHostStorage(dir);
            writer.AddShader(Context(nameof(Capabilities.RequiresLinkedVaryingInterface), true), ProgramFor(GuestA), HostA);
            var before = OriginalHashes(dir);
            GraphicsConfig.EnableSpirvCompilationOnVulkan = readSpirv;
            var reader = new DiskCacheHostStorage(dir);
            Recorder.Loaded.Clear();
            var program = Lazy(reader, Context(nameof(Capabilities.RequiresLinkedVaryingInterface), true), dir, 0, GuestA).Materialize();
            bool hit = writeSpirv == readSpirv;
            Check($"actual language {writeSpirv}->{readSpirv} controls host admission",
                (hit ? program != null && Recorder.Loaded.Single().SequenceEqual(HostA) : program == null && Recorder.Loaded.Count == 0) && SameHashes(before, OriginalHashes(dir)),
                new { materialized = program != null, rendererLoads = Recorder.Loaded.Count, originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
            Close(reader);
        }
        finally { GraphicsConfig.EnableSpirvCompilationOnVulkan = previous; }
    }

    static void AlignmentCase(bool firstEmpty)
    {
        string dir = NewDir(firstEmpty ? "first-empty" : "host-cleared");
        var context = Context();
        var storage = new DiskCacheHostStorage(dir);
        storage.AddShader(context, ProgramFor(GuestA), firstEmpty ? Array.Empty<byte>() : HostA);
        var before = OriginalHashes(dir);
        if (!firstEmpty) storage.ClearHostCache(context);
        Check((firstEmpty ? "empty" : "cleared") + " host keeps guest/shared bytes",
            SameHashes(before, OriginalHashes(dir)), new { originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
        // ClearHostCache leaves zero-byte files; reading them spins at EOF. A separately
        // bounded process covers that case so it cannot hang this run.
        if (firstEmpty)
        {
            var emptyReader = new DiskCacheHostStorage(dir);
            Recorder.Loaded.Clear();
            var absent = Lazy(emptyReader, context, dir, 0, GuestA).Materialize();
            Check("missing host files fall back without renderer calls", absent == null && Recorder.Loaded.Count == 0,
                new { absent = absent == null, rendererLoads = Recorder.Loaded.Count });
            Close(emptyReader);
        }
        storage.AddShader(context, ProgramFor(GuestB), HostB);
        var reader = new DiskCacheHostStorage(dir);
        Recorder.Loaded.Clear();
        var oldProgram = Lazy(reader, context, dir, 0, GuestA).Materialize();
        bool oldLoadedNew = Recorder.Loaded.Any(bytes => bytes.SequenceEqual(HostB));
        var newProgram = Lazy(reader, context, dir, 1, GuestB).Materialize();
        Check((firstEmpty ? "empty host write" : "host-only clear") + " keeps host/shared program index aligned",
            oldProgram == null && newProgram != null && !oldLoadedNew,
            new { sharedPrograms = storage.GetProgramCount(), oldProgramLoaded = oldProgram != null, oldLoadedNewBinary = oldLoadedNew, newProgramLoaded = newProgram != null });
        Close(reader);
    }

    static void TimestampCase()
    {
        string dir = NewDir("stale-timestamp");
        var storage = new DiskCacheHostStorage(dir); var context = Context();
        storage.AddShader(context, ProgramFor(GuestA), HostA);
        var lazy = Lazy(storage, context, dir, 0, GuestA);
        object[] args = { context, null, null, lazy.GuestShaders, 0, lazy.Timestamp + 1 };
        var method = typeof(DiskCacheHostStorage).GetMethod("ReadHostCode", BindingFlags.NonPublic | BindingFlags.Instance);
        var first = ((byte[], CachedShaderStage[]))method.Invoke(storage, args);
        var second = ((byte[], CachedShaderStage[]))method.Invoke(storage, args);
        Check("stale timestamp stays rejected across retained stream reads", first.Item1 == null && second.Item1 == null,
            new { firstRejected = first.Item1 == null, secondRejected = second.Item1 == null });
        (args[1] as Stream)?.Dispose(); (args[2] as Stream)?.Dispose();
    }

    static void BootCase(bool warm, bool changed = true)
    {
        string dir = NewDir(warm ? changed ? "warm-boot" : "warm-positive" : "lazy-boot");
        var writer = new DiskCacheHostStorage(dir);
        writer.AddShader(Context(), ProgramFor(GuestA), HostA);
        var before = OriginalHashes(dir);
        var reader = new DiskCacheHostStorage(dir);
        var context = changed ? Context(nameof(Capabilities.SupportsLayerVertexTessellation), true) : Context();
        var compute = new ComputeShaderCacheHashTable();
        if (warm)
        {
            string warmFile = Path.Combine(dir, "warm.tsv"); File.WriteAllText(warmFile, "0\t0\tfixture\n");
            S2AShaderCacheGuard.PackPrograms = 1; S2AShaderCacheGuard.WarmList = warmFile;
        }
        Recorder.Loaded.Clear(); Recorder.ProgramDisposed.Reset();
        var loader = new ParallelDiskCacheLoader(context, new ShaderCacheHashTable(), compute, reader, (_, _, _) => { }, default);
        var previousError = Console.Error;
        var completion = new WarmCompletionWriter(previousError);
        if (warm) Console.SetError(completion);
        loader.LoadShaders();
        if (warm)
        {
            bool finished = completion.Completed.Wait(TimeSpan.FromSeconds(3));
            Console.SetError(previousError);
            Check(changed ? "changed capabilities prevent completed warm-start admission" : "same capabilities complete warm-start admission",
                finished && Recorder.Loaded.Count == (changed ? 0 : 1) && SameHashes(before, OriginalHashes(dir)),
                new { oldHostLoaded = Recorder.Loaded.Any(bytes => bytes.SequenceEqual(HostA)), warmCompleted = finished,
                    originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
            if (!finished) throw new TimeoutException("Warm worker did not reach its completion boundary; do not close its active reader.");
            if (!changed)
            {
                object table = typeof(ComputeShaderCacheHashTable).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(compute);
                object[] lookup = { new GuestBytes(GuestA), null, null };
                bool found = (bool)table.GetType().GetMethod("TryFindItem").Invoke(table, lookup);
                var list = (ShaderSpecializationList)lookup[1];
                bool hit = found && list.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, false), out _);
                Check("actual warm PreHostCode materializes with matching identity", hit && Recorder.Loaded.Count == 2 && Recorder.Loaded.All(bytes => bytes.SequenceEqual(HostA)), new { rendererLoads = Recorder.Loaded.Count });
            }
        }
        else
        {
            Check("boot indexes guest without eager host load", Recorder.Loaded.Count == 0, new { rendererLoads = Recorder.Loaded.Count });
            object table = typeof(ComputeShaderCacheHashTable).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(compute);
            object[] lookup = { new GuestBytes(GuestA), null, null };
            bool found = (bool)table.GetType().GetMethod("TryFindItem").Invoke(table, lookup);
            var list = (ShaderSpecializationList)lookup[1];
            bool hit = found && list.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, false), out _);
            Check("changed capabilities prevent boot-indexed lazy admission", found && !hit && Recorder.Loaded.Count == 0 && SameHashes(before, OriginalHashes(dir)),
                new { guestFound = found, programHit = hit, rendererLoads = Recorder.Loaded.Count,
                    originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
        }
        S2AShaderCacheGuard.WarmList = null; S2AShaderCacheGuard.PackPrograms = 0;
        Close(reader);
    }

    static void LegacyHostCase()
    {
        string dir = NewDir("legacy-host"); var context = Context(); var storage = new DiskCacheHostStorage(dir);
        storage.AddShader(context, ProgramFor(GuestA), HostA);
        foreach (string extension in new[] { ".toc", ".data" })
            File.Move(HostFile(context, dir, extension), Path.Combine(dir, "vulkan_cache-admission-fixture_bin" + extension));
        var before = OriginalHashes(dir); Recorder.Loaded.Clear();
        var program = Lazy(storage, context, dir, 0, GuestA).Materialize();
        Check("legacy host filename without capability identity is rejected and guest retained",
            program == null && Recorder.Loaded.Count == 0 && SameHashes(before, OriginalHashes(dir)), new { rendererLoads = Recorder.Loaded.Count });
        Close(storage);
    }

    static void CapabilityCoverage()
    {
        var excluded = new Dictionary<string, string>
        {
            [nameof(Capabilities.VendorName)] = "Existing host filename namespace, not shader semantics",
            [nameof(Capabilities.MemoryType)] = "Buffer backing strategy",
            [nameof(Capabilities.MaximumSupportedAnisotropy)] = "Dynamic sampler state",
            [nameof(Capabilities.MaximumGpuMemory)] = "Dynamic texture eviction budget",
            [nameof(Capabilities.SupportsAstcCompression)] = "Texture backing decode, guest TIC still defines shader formats",
            [nameof(Capabilities.SupportsBc123Compression)] = "Texture backing decode, guest TIC still defines shader formats",
            [nameof(Capabilities.SupportsBc45Compression)] = "Texture backing decode, guest TIC still defines shader formats",
            [nameof(Capabilities.SupportsBc67Compression)] = "Texture backing decode, guest TIC still defines shader formats",
            [nameof(Capabilities.SupportsEtc2Compression)] = "Texture backing decode, guest TIC still defines shader formats",
            [nameof(Capabilities.Supports3DTextureCompression)] = "Texture backing conversion",
            [nameof(Capabilities.SupportsR4G4Format)] = "Texture backing repacking",
            [nameof(Capabilities.SupportsR4G4B4A4Format)] = "Texture backing repacking",
            [nameof(Capabilities.Supports5BitComponentFormat)] = "Texture backing repacking",
            [nameof(Capabilities.SupportsSparseBuffer)] = "Buffer backing and range tracking",
            [nameof(Capabilities.SupportsMismatchingViewFormat)] = "View sharing or copy decision",
            [nameof(Capabilities.SupportsCubemapView)] = "View sharing or copy decision",
            [nameof(Capabilities.SupportsViewportSwizzle)] = "Dynamic viewport state",
            [nameof(Capabilities.SupportsIndirectParameters)] = "MME command execution path",
            [nameof(Capabilities.TextureBufferOffsetAlignment)] = "VTG view range and dynamic support-buffer offsets",
        };
        var baseline = Context().Capabilities;
        string identity = HostCacheCapabilities.GetIdentity(baseline);
        object withGs = baseline, withLayer = baseline;
        typeof(Capabilities).GetField(nameof(Capabilities.SupportsGeometryShader)).SetValue(withGs, true);
        typeof(Capabilities).GetField(nameof(Capabilities.SupportsLayerVertexTessellation)).SetValue(withLayer, true);
        Console.WriteLine($"LAYER_CACHE_IDENTITIES={identity}|{HostCacheCapabilities.GetIdentity((Capabilities)withGs)}|{HostCacheCapabilities.GetIdentity((Capabilities)withLayer)}");
        // Actual pre-fix hash of this exact fixture, not a hash of
        // an independently reconstructed serializer. Omitting the route marker
        // must reproduce this old key and fail this assertion.
        const string oldUnsafeHostKey = "906d672ae7c30b1f5fcdfe595ab62b637583e63bfa4b9f5e0f1dbb5a303deac2";
        Check("unsupported Layer route rotates the previously accepted host key",
            !baseline.SupportsGeometryShader && !baseline.SupportsLayerVertexTessellation && identity != oldUnsafeHostKey,
            new { identity, oldUnsafeHostKey });
        var fields = typeof(Capabilities).GetFields(BindingFlags.Public | BindingFlags.Instance);
        var expectedTypes = new Dictionary<string, Type>
        {
            [nameof(Capabilities.Api)] = typeof(TargetApi),
            [nameof(Capabilities.VendorName)] = typeof(string),
            [nameof(Capabilities.MemoryType)] = typeof(SystemMemoryType),
            [nameof(Capabilities.HasFrontFacingBug)] = typeof(bool),
            [nameof(Capabilities.HasVectorIndexingBug)] = typeof(bool),
            [nameof(Capabilities.NeedsFragmentOutputSpecialization)] = typeof(bool),
            [nameof(Capabilities.ReduceShaderPrecision)] = typeof(bool),
            [nameof(Capabilities.SupportsAstcCompression)] = typeof(bool),
            [nameof(Capabilities.SupportsBc123Compression)] = typeof(bool),
            [nameof(Capabilities.SupportsBc45Compression)] = typeof(bool),
            [nameof(Capabilities.SupportsBc67Compression)] = typeof(bool),
            [nameof(Capabilities.SupportsEtc2Compression)] = typeof(bool),
            [nameof(Capabilities.Supports3DTextureCompression)] = typeof(bool),
            [nameof(Capabilities.SupportsBgraFormat)] = typeof(bool),
            [nameof(Capabilities.SupportsR4G4Format)] = typeof(bool),
            [nameof(Capabilities.SupportsR4G4B4A4Format)] = typeof(bool),
            [nameof(Capabilities.SupportsScaledVertexFormats)] = typeof(bool),
            [nameof(Capabilities.S2AVertexPull)] = typeof(bool),
            [nameof(Capabilities.RequiresLinkedVaryingInterface)] = typeof(bool),
            [nameof(Capabilities.MaximumVertexOutputComponents)] = typeof(int),
            [nameof(Capabilities.MaximumFragmentInputComponents)] = typeof(int),
            [nameof(Capabilities.SupportsSnormBufferTextureFormat)] = typeof(bool),
            [nameof(Capabilities.SupportsSparseBuffer)] = typeof(bool),
            [nameof(Capabilities.Supports5BitComponentFormat)] = typeof(bool),
            [nameof(Capabilities.SupportsBlendEquationAdvanced)] = typeof(bool),
            [nameof(Capabilities.SupportsFragmentShaderInterlock)] = typeof(bool),
            [nameof(Capabilities.SupportsFragmentShaderOrderingIntel)] = typeof(bool),
            [nameof(Capabilities.SupportsGeometryShader)] = typeof(bool),
            [nameof(Capabilities.SupportsGeometryShaderOcclusionQuery)] = typeof(bool),
            [nameof(Capabilities.SupportsGeometryShaderPassthrough)] = typeof(bool),
            [nameof(Capabilities.SupportsTransformFeedback)] = typeof(bool),
            [nameof(Capabilities.SupportsImageLoadFormatted)] = typeof(bool),
            [nameof(Capabilities.SupportsLayerVertexTessellation)] = typeof(bool),
            [nameof(Capabilities.SupportsMismatchingViewFormat)] = typeof(bool),
            [nameof(Capabilities.SupportsCubemapView)] = typeof(bool),
            [nameof(Capabilities.SupportsNonConstantTextureOffset)] = typeof(bool),
            [nameof(Capabilities.SupportsQuads)] = typeof(bool),
            [nameof(Capabilities.SupportsSeparateSampler)] = typeof(bool),
            [nameof(Capabilities.SupportsShaderBallot)] = typeof(bool),
            [nameof(Capabilities.SupportsShaderBarrierDivergence)] = typeof(bool),
            [nameof(Capabilities.SupportsShaderFloat64)] = typeof(bool),
            [nameof(Capabilities.SupportsShaderNonUniformIndexing)] = typeof(bool),
            [nameof(Capabilities.SupportsTextureGatherOffsets)] = typeof(bool),
            [nameof(Capabilities.SupportsTextureShadowLod)] = typeof(bool),
            [nameof(Capabilities.SupportsVertexStoreAndAtomics)] = typeof(bool),
            [nameof(Capabilities.SupportsViewportIndexVertexTessellation)] = typeof(bool),
            [nameof(Capabilities.SupportsViewportMask)] = typeof(bool),
            [nameof(Capabilities.SupportsViewportSwizzle)] = typeof(bool),
            [nameof(Capabilities.SupportsIndirectParameters)] = typeof(bool),
            [nameof(Capabilities.SupportsDepthClipControl)] = typeof(bool),
            [nameof(Capabilities.UniformBufferSetIndex)] = typeof(int),
            [nameof(Capabilities.StorageBufferSetIndex)] = typeof(int),
            [nameof(Capabilities.TextureSetIndex)] = typeof(int),
            [nameof(Capabilities.ImageSetIndex)] = typeof(int),
            [nameof(Capabilities.ExtraSetBaseIndex)] = typeof(int),
            [nameof(Capabilities.MaximumExtraSets)] = typeof(int),
            [nameof(Capabilities.MaximumUniformBuffersPerStage)] = typeof(uint),
            [nameof(Capabilities.MaximumStorageBuffersPerStage)] = typeof(uint),
            [nameof(Capabilities.MaximumTexturesPerStage)] = typeof(uint),
            [nameof(Capabilities.MaximumImagesPerStage)] = typeof(uint),
            [nameof(Capabilities.MaximumComputeSharedMemorySize)] = typeof(int),
            [nameof(Capabilities.MaximumSupportedAnisotropy)] = typeof(float),
            [nameof(Capabilities.ShaderSubgroupSize)] = typeof(int),
            [nameof(Capabilities.StorageBufferOffsetAlignment)] = typeof(int),
            [nameof(Capabilities.TextureBufferOffsetAlignment)] = typeof(int),
            [nameof(Capabilities.GatherBiasPrecision)] = typeof(int),
            [nameof(Capabilities.MaximumGpuMemory)] = typeof(ulong),
            [nameof(Capabilities.S2AStorageWindowClamp)] = typeof(bool),
            [nameof(Capabilities.S2AStorageOobRecord)] = typeof(bool),
            [nameof(Capabilities.UnsupportedUniformTexelBufferFormats)] = typeof(Format[]),
            [nameof(Capabilities.SupportsImageStoreFormatted)] = typeof(bool),
            [nameof(Capabilities.S2ASpirv15)] = typeof(bool),
            [nameof(Capabilities.S2ASpirvLayerExt)] = typeof(bool),
            [nameof(Capabilities.S2ASpirvLayerNv)] = typeof(bool),
        };
        Check("capability field names and types are fully classified", fields.Length == expectedTypes.Count && fields.All(field => expectedTypes.TryGetValue(field.Name, out var type) && type == field.FieldType), new { count = fields.Length });
        foreach (var field in fields)
        {
            object changed = baseline;
            object value = field.FieldType == typeof(bool) ? true : field.FieldType == typeof(string) ? "other-vendor" :
                field.FieldType == typeof(float) ? 1.0f : field.FieldType == typeof(ulong) ? 1UL :
                field.FieldType == typeof(uint) ? 1U : field.FieldType == typeof(Format[]) ? new Format[] { Format.R16Float } :
                field.FieldType.IsEnum ? Enum.ToObject(field.FieldType, 1) : 1;
            // Api's Vulkan value is already 1; use its other value.
            if (Equals(field.GetValue(changed), value)) value = Enum.ToObject(field.FieldType, 0);
            field.SetValue(changed, value);
            bool differs = HostCacheCapabilities.GetIdentity((Capabilities)changed) != identity;
            Check("capability field classified: " + field.Name, differs != excluded.ContainsKey(field.Name),
                new { differs, exclusion = excluded.GetValueOrDefault(field.Name) });
        }
        Check("all excluded fields still exist", excluded.Keys.All(name => fields.Any(field => field.Name == name)), new { count = fields.Length });
        var oldCulture = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("fr-FR");
            Check("capability identity is culture independent", HostCacheCapabilities.GetIdentity(baseline) == identity, new { identity });
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = oldCulture; }
    }

    static string HostFile(GpuContext context, string dir, string extension)
    {
        string name = (string)typeof(DiskCacheHostStorage).GetMethod("GetHostFileName", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { context });
        return Path.Combine(dir, name + extension);
    }

    static void StreamDomainCases()
    {
        string a = NewDir("streams-a"), b = NewDir("streams-b");
        var ca = Context(); var cb = Context(nameof(Capabilities.SupportsLayerVertexTessellation), true);
        var sa = new DiskCacheHostStorage(a); var sb = new DiskCacheHostStorage(b);
        sa.AddShader(ca, ProgramFor(GuestA), HostA); sb.AddShader(ca, ProgramFor(GuestA), HostA);
        var ah = OriginalHashes(a); var bh = OriginalHashes(b);
        using (var streams = sa.GetOutputStreams(ca))
        {
            foreach (var item in new[] { (storage: sa, context: cb, name: "different caps"), (storage: sb, context: ca, name: "different root") })
            {
                bool rejected = false;
                try { item.storage.AddShader(item.context, ProgramFor(GuestB), HostB, streams); }
                catch (InvalidOperationException) { rejected = true; }
                Check("batch streams reject " + item.name + " before guest/shared writes",
                    rejected && SameHashes(ah, OriginalHashes(a)) && SameHashes(bh, OriginalHashes(b)), new { rejected });
            }
        }

        // A retained lazy read handle must coexist with append-only background writes.
        var reader = new DiskCacheHostStorage(a);
        var first = Lazy(reader, ca, a, 0, GuestA).Materialize();
        sa.AddShader(ca, ProgramFor(GuestB), HostB);
        Recorder.Loaded.Clear();
        var second = Lazy(reader, ca, a, 1, GuestB).Materialize();
        Check("append while lazy streams stay open preserves new index", first != null && second != null && Recorder.Loaded.Single().SequenceEqual(HostB), new { count = sa.GetProgramCount() });
        Close(reader);

        // Partial batch-open failure releases the already-opened shared files.
        Directory.CreateDirectory(HostFile(cb, a, ".data"));
        bool failed = false;
        try { using var streams = sa.GetOutputStreams(cb); }
        catch (Exception e) when (e is DiskCacheLoadException or UnauthorizedAccessException or IOException) { failed = true; }
        using var proof = new FileStream(Path.Combine(a, "shared.toc"), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Check("partial batch open releases shared handles", failed, new { failed });
    }

    // 10-27 #551 r8：一局 2228 行「着色器磁盘缓存作废 N 支（程序 N 缺主机代码）」，同包第二局仍是同一批 4752 行。
    //   原因：缓存里有同一份客体代码的很多特化变体，宿主二进制按「构建 + 设备 profile」身份分开存；身份一变（换包 / 重建）只有本次
    //   真用到的那几支被按需现编并追加成新条目，其余变体永远没有宿主二进制。旧的按需实化把组内每个缺宿主二进制的条目都报一行红，
    //   即使该组用另一个有宿主二进制的变体命中；于是每局都把同一批变体重报一遍（t85 8E 同包：第 1 局 643 行 / 551 次现编，
    //   第 2 局同样 643 行 / 0 次现编）。这里固定口径：只有「当前运行时状态真的匹配、但该条目的宿主二进制不在」才算一次作废 / 首遇现编。
    static void MissingHostReportingCase()
    {
        string dir = NewDir("missing-host-reporting"); var context = Context(); var writer = new DiskCacheHostStorage(dir);
        writer.AddShader(context, ProgramFor(GuestA), HostA);                                  // 程序 0：有宿主二进制，未对齐关
        writer.AddShader(context, ProgramFor(GuestA, unalignedStorage: true), Array.Empty<byte>());   // 程序 1：缺宿主二进制，未对齐开
        writer.AddShader(context, ProgramFor(GuestA), Array.Empty<byte>());                    // 程序 2：缺宿主二进制，未对齐关
        var reader = new DiskCacheHostStorage(dir);

        var matching = new ShaderSpecializationList();
        for (int index = 0; index < 3; index++) matching.AddLazy(Lazy(reader, context, dir, index, GuestA));
        Recorder.Loaded.Clear();
        int before = S2AShaderCacheGuard.Discarded;
        bool hit = matching.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, false), out _);
        int reported = S2AShaderCacheGuard.Discarded - before;
        Check("group served by a host-coded variant reports no dropped variants",
            hit && reported == 0 && Recorder.Loaded.Count == 1, new { hit, reported, rendererLoads = Recorder.Loaded.Count });

        var missing = new ShaderSpecializationList();
        for (int index = 0; index < 3; index++) missing.AddLazy(Lazy(reader, context, dir, index, GuestA));
        before = S2AShaderCacheGuard.Discarded;
        bool missed = missing.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, true), out _);
        reported = S2AShaderCacheGuard.Discarded - before;
        Check("matching variant without host code reports exactly one on-demand compile",
            !missed && reported == 1, new { hit = missed, reported });
        before = S2AShaderCacheGuard.Discarded;
        missing.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, true), out _);
        Check("the same missing variant is not reported twice in one session",
            S2AShaderCacheGuard.Discarded - before == 0, new { reported = S2AShaderCacheGuard.Discarded - before });

        // 第二局：上一局按需现编的结果由存缓存路径追加成带宿主二进制的新条目（同一客体代码、同一特化状态）。下一局整组实化后命中它，
        //   旧的两条缺宿主二进制条目仍在，但查找命中就走不到核对路径 → 红行 0（验收：同包连续两局，第二局作废行数接近 0）。
        writer.AddShader(context, ProgramFor(GuestA, unalignedStorage: true), HostB);
        Close(reader);
        var secondReader = new DiskCacheHostStorage(dir);
        var second = new ShaderSpecializationList();
        for (int index = 0; index < 4; index++) second.AddLazy(Lazy(secondReader, context, dir, index, GuestA));
        Recorder.Loaded.Clear();
        before = S2AShaderCacheGuard.Discarded;
        bool secondHit = second.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 0, true), out _);
        reported = S2AShaderCacheGuard.Discarded - before;
        Check("second session served by the program compiled in the first session reports nothing",
            secondHit && reported == 0 && Recorder.Loaded.Any(b => b.SequenceEqual(HostB)),
            new { hit = secondHit, reported, rendererLoads = Recorder.Loaded.Count });
        Close(secondReader);
    }

    static void MetalSeedAndRestart()
    {
        string seed = NewDir("metal-seed"), installed = NewDir("metal-installed");
        var context = Context(); context.Capabilities = NxGal.NxCaps.Build(new ulong[] { 31, 32768, 0, 0 });
        var writer = new DiskCacheHostStorage(seed);
        using (var streams = writer.GetOutputStreams(context))
        {
            writer.AddShader(context, ProgramFor(GuestA), HostA, streams);
            writer.AddShader(context, ProgramFor(GuestB), Array.Empty<byte>(), streams);
        }
        // ShaderPack copies every file, including host identity names, without reindexing.
        foreach (string path in Directory.GetFiles(seed)) File.Copy(path, Path.Combine(installed, Path.GetFileName(path)));
        var before = OriginalHashes(installed); var reader = new DiskCacheHostStorage(installed);
        Recorder.Loaded.Clear();
        var hit = Lazy(reader, context, installed, 0, GuestA).Materialize();
        var missing = Lazy(reader, context, installed, 1, GuestB).Materialize();
        Check("NxCaps seed copy and restart retain shared program indices", hit != null && missing == null && Recorder.Loaded.Single().SequenceEqual(HostA) && SameHashes(before, OriginalHashes(installed)), new { count = reader.GetProgramCount() });
        Close(reader);
        writer = new DiskCacheHostStorage(installed);
        writer.AddShader(context, ProgramFor(GuestB), HostB);
        reader = new DiskCacheHostStorage(installed); Recorder.Loaded.Clear();
        var old = Lazy(reader, context, installed, 0, GuestA).Materialize();
        var newHit = Lazy(reader, context, installed, 2, GuestB).Materialize();
        Check("NxCaps append after seed copy survives another restart", old != null && newHit != null && Recorder.Loaded[0].SequenceEqual(HostA) && Recorder.Loaded[1].SequenceEqual(HostB), new { count = reader.GetProgramCount() });
        Close(reader);
    }

    static void FiniteReaderCases()
    {
        foreach (var bytes in new[] { Array.Empty<byte>(), new byte[] { 255 }, new byte[] { 0 }, new byte[] { 1 }, new byte[] { 2 } })
        {
            bool rejected = false;
            try { BinarySerializer.ReadCompressed(new MemoryStream(bytes), new byte[8]); }
            catch (Exception e) when (e is IOException or InvalidDataException or DiskCacheLoadException) { rejected = true; }
            Check("finite compressed read rejects short/invalid input " + Convert.ToHexString(bytes), rejected, new { rejected });
        }
        foreach (var algorithm in new[] { CompressionAlgorithm.Deflate, CompressionAlgorithm.Brotli })
        {
            using var complete = new MemoryStream(); BinarySerializer.WriteCompressed(complete, HostA, algorithm);
            byte[] truncated = complete.ToArray()[..^16]; bool rejected = false;
            try { BinarySerializer.ReadCompressed(new MemoryStream(truncated), new byte[HostA.Length]); }
            catch (Exception e) when (e is IOException or InvalidDataException) { rejected = true; }
            Check("finite compressed read rejects truncated " + algorithm, rejected, new { rejected });
        }
        foreach (var algorithm in new[] { CompressionAlgorithm.None, CompressionAlgorithm.Deflate, CompressionAlgorithm.Brotli })
        {
            using var complete = new MemoryStream(); BinarySerializer.WriteCompressed(complete, HostA, algorithm); complete.Position = 0;
            using var bounded = new BoundedReadStream(complete, complete.Length); bool rejected = false;
            try { BinarySerializer.ReadCompressed(bounded, new byte[HostA.Length - 1]); }
            catch (InvalidDataException) { rejected = true; }
            Check("exact output length rejects extra decoded byte: " + algorithm, rejected, new { rejected });
        }
        using (var guestRecords = new MemoryStream(new byte[] { (byte)CompressionAlgorithm.None, 17, 23 }))
        {
            byte[] first = new byte[1]; BinarySerializer.ReadCompressed(guestRecords, first);
            Check("unbounded guest read leaves next record untouched", first[0] == 17 && guestRecords.ReadByte() == 23, new { first = first[0] });
        }
        using var shortStream = new MemoryStream(new byte[1]); var serializer = new BinarySerializer(shortStream);
        int scalar = 0; bool scalarRejected = false;
        try { serializer.Read(ref scalar); } catch (EndOfStreamException) { scalarRejected = true; }
        Check("finite scalar read rejects EOF", scalarRejected, new { scalarRejected });
        using var invalidSize = new MemoryStream(); using (var bw = new BinaryWriter(invalidSize, System.Text.Encoding.UTF8, true)) { bw.Write(123u); bw.Write(-1); }
        invalidSize.Position = 0; serializer = new BinarySerializer(invalidSize); bool sizeRejected = false;
        try { serializer.ReadWithMagicAndSize(ref scalar, 123u); } catch (DiskCacheLoadException) { sizeRejected = true; }
        Check("negative serialized struct size is typed rejection", sizeRejected, new { sizeRejected });
    }

    static void MalformedHostCases()
    {
        foreach (string kind in new[] { "empty-header", "short-header", "magic", "version", "codegen", "timestamp", "short-entry", "short-data", "short-compressed-extent", "short-declared-output", "bad-tag" })
        {
            string dir = NewDir("malformed-" + kind); var context = Context(); var writer = new DiskCacheHostStorage(dir);
            writer.AddShader(context, ProgramFor(GuestA), HostA);
            string tocPath = HostFile(context, dir, ".toc"), dataPath = HostFile(context, dir, ".data");
            byte[] toc = File.ReadAllBytes(tocPath), data = File.ReadAllBytes(dataPath);
            if (kind == "empty-header") toc = Array.Empty<byte>();
            else if (kind == "short-header") toc = toc[..16];
            else if (kind == "magic") toc[0] ^= 1;
            else if (kind == "version") toc[4] ^= 1;
            else if (kind == "codegen") toc[8] ^= 1;
            else if (kind == "timestamp") toc[16] ^= 1;
            else if (kind == "short-entry") toc = toc[..40];
            else if (kind == "short-data") data = data[..4];
            else if (kind == "short-compressed-extent") BitConverter.GetBytes(1u).CopyTo(toc, 44);
            else if (kind == "short-declared-output") BitConverter.GetBytes((uint)HostA.Length - 1).CopyTo(toc, 40);
            else data[0] = 255;
            File.WriteAllBytes(tocPath, toc); File.WriteAllBytes(dataPath, data);
            var before = OriginalHashes(dir); var reader = new DiskCacheHostStorage(dir); Recorder.Loaded.Clear();
            var first = Lazy(reader, context, dir, 0, GuestA).Materialize();
            var second = Lazy(reader, context, dir, 0, GuestA).Materialize();
            Check("malformed host stays rejected: " + kind, first == null && second == null && Recorder.Loaded.Count == 0 && SameHashes(before, OriginalHashes(dir)), new { rendererLoads = Recorder.Loaded.Count });
            Close(reader);
        }
    }

    static void SharedGenerationCase()
    {
        string dir = NewDir("shared-generation"); var context = Context(); var writer = new DiskCacheHostStorage(dir);
        writer.AddShader(context, ProgramFor(GuestA), HostA);
        var reader = new DiskCacheHostStorage(dir); var old = Lazy(reader, context, dir, 0, GuestA);
        var oldFirst = old.Materialize();
        writer.ClearSharedCache(); writer.AddShader(context, ProgramFor(GuestB), HostB);
        Recorder.Loaded.Clear();
        // Direct host admission checks the old generation even though the retained files now contain the new one.
        var method = typeof(DiskCacheHostStorage).GetMethod("ReadHostCode", BindingFlags.NonPublic | BindingFlags.Instance);
        object[] args = { context, null, null, old.GuestShaders, 0, old.Timestamp };
        var stale = ((byte[], CachedShaderStage[]))method.Invoke(reader, args);
        var current = Lazy(reader, context, dir, 0, GuestB).Materialize();
        Check("shared generation rebuild rejects old host association", oldFirst != null && stale.Item1 == null && current != null && Recorder.Loaded.Single().SequenceEqual(HostB), new { staleRejected = stale.Item1 == null });
        (args[1] as Stream)?.Dispose(); (args[2] as Stream)?.Dispose(); Close(reader);
    }

    static void DerivedComputeStateMiss()
    {
        string dir = NewDir("derived-compute-state");
        var oldContext = Context(nameof(Capabilities.MaximumComputeSharedMemorySize), 32768);
        var oldState = new GpuChannelComputeState(8, 8, 1, 0, 32768, false);
        var source = ProgramFor(GuestA);
        new DiskCacheHostStorage(dir).AddShader(oldContext,
            new CachedShaderProgram(source.HostProgram, new ShaderSpecializationState(ref oldState), source.Shaders), HostA);
        var context = Context(nameof(Capabilities.MaximumComputeSharedMemorySize), 65536);
        var before = OriginalHashes(dir); var reader = new DiskCacheHostStorage(dir); var compute = new ComputeShaderCacheHashTable();
        Recorder.Loaded.Clear();
        var loader = new ParallelDiskCacheLoader(context, new ShaderCacheHashTable(), compute, reader, (_, _, _) => { }, default);
        loader.LoadShaders();
        object table = typeof(ComputeShaderCacheHashTable).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(compute);
        object[] lookup = { new GuestBytes(GuestA), null, null };
        bool found = (bool)table.GetType().GetMethod("TryFindItem").Invoke(table, lookup);
        var list = (ShaderSpecializationList)lookup[1];
        bool hit = found && list.TryFindForCompute(null, default, new GpuChannelComputeState(8, 8, 1, 0, 65536, false), out _);
        Check("derived old compute specialization is not reused after cap change",
            found && !hit && Recorder.Loaded.Count == 0 && ((byte[])lookup[2]).SequenceEqual(GuestA) && SameHashes(before, OriginalHashes(dir)),
            new { guestFound = found, programHit = hit, rendererLoads = Recorder.Loaded.Count, originalBytesPreserved = SameHashes(before, OriginalHashes(dir)) });
        Close(reader);
    }

    // #1411：离线包种入后装载结局三态各自计数——已加载 / 版本不符整批作废 / 文件缺失。
    //   版本不符不许被当成「读到 0 支」（旧口径 PackPrograms>0 && LoadedPrograms==0 在版本不符局照样成立，正是 ShaderCache.Initialize 的误报源）。
    static void PackOutcomeCases()
    {
        // 「要不要报读到 0 支」的判定就是 ShaderCache.Initialize 调用的同一个静态判定，这里直接测它，
        // 不重写一遍条件（#1546 复审：之前测试只测了结局字段、没执行到改的那行判定）。
        const int packSeeded = 1;

        // ① 文件缺失（真没读到）：缓存根目录是空的
        {
            var loader = new ParallelDiskCacheLoader(Context(), new ShaderCacheHashTable(), new ComputeShaderCacheHashTable(),
                new DiskCacheHostStorage(NewDir("pack-missing")), (_, _, _) => { }, default);
            loader.LoadShaders();
            Check("empty cache root is the missing outcome and qualifies for the pack red",
                loader.S2AOutcome == ParallelDiskCacheLoader.S2ALoadOutcome.Missing &&
                loader.LoadedPrograms == 0 && loader.S2AVersionDiscarded == 0 &&
                S2AShaderCacheGuard.ShouldReportPackZero(packSeeded, loader.LoadedPrograms, loader.S2AOutcome),
                new { outcome = loader.S2AOutcome?.ToString() ?? "null", loaded = loader.LoadedPrograms, versionDiscarded = loader.S2AVersionDiscarded });
        }

        // ② 版本不符整批作废：写当前版缓存、把 shared.toc 里的翻译器版本号改旧
        {
            string dir = NewDir("pack-stale");
            var writer = new DiskCacheHostStorage(dir);
            writer.AddShader(Context(), ProgramFor(GuestA), HostA);
            string tocPath = Path.Combine(dir, "shared.toc");
            byte[] toc = File.ReadAllBytes(tocPath);
            BitConverter.GetBytes(DiskCacheHostStorage.CodeGenVersion + 1).CopyTo(toc, 8);   // TocHeader.CodeGenVersion 在偏移 8
            File.WriteAllBytes(tocPath, toc);
            S2AShaderCacheGuard.PackPrograms = 1;   // 同 ShaderPack 种入成功后的真实状态
            var loader = new ParallelDiskCacheLoader(Context(), new ShaderCacheHashTable(), new ComputeShaderCacheHashTable(),
                new DiskCacheHostStorage(dir), (_, _, _) => { }, default);
            var capture = new StringWriter();
            var previous = Console.Error;
            Console.SetError(capture);
            int discarded0 = S2AShaderCacheGuard.Discarded;
            loader.LoadShaders();
            Console.SetError(previous);
            string red = capture.ToString();
            Check("stale translator version discards wholesale, reported with both versions and identities, not as missing",
                loader.S2AOutcome == ParallelDiskCacheLoader.S2ALoadOutcome.StaleVersion &&
                loader.S2AVersionDiscarded == 1 &&
                S2AShaderCacheGuard.Discarded - discarded0 == 1 &&
                !S2AShaderCacheGuard.ShouldReportPackZero(packSeeded, loader.LoadedPrograms, loader.S2AOutcome) &&
                red.Contains("翻译器版本") && red.Contains("能力身份"),
                new { outcome = loader.S2AOutcome?.ToString() ?? "null",
                    versionDiscarded = loader.S2AVersionDiscarded, discarded = S2AShaderCacheGuard.Discarded - discarded0 });
            Check("stale-version cache files are cleared after wholesale discard",
                new FileInfo(tocPath).Length == 0, new { tocBytes = new FileInfo(tocPath).Length });
            S2AShaderCacheGuard.PackPrograms = 0;
        }

        // ③ 已加载：当前版缓存照常索引
        {
            string dir = NewDir("pack-loaded");
            var writer = new DiskCacheHostStorage(dir);
            writer.AddShader(Context(), ProgramFor(GuestA), HostA);
            var loader = new ParallelDiskCacheLoader(Context(), new ShaderCacheHashTable(), new ComputeShaderCacheHashTable(),
                new DiskCacheHostStorage(dir), (_, _, _) => { }, default);
            loader.LoadShaders();
            Check("current-version cache indexes programs and is not missing",
                loader.S2AOutcome == ParallelDiskCacheLoader.S2ALoadOutcome.Loaded &&
                loader.LoadedPrograms == 1 && loader.S2AVersionDiscarded == 0 &&
                !S2AShaderCacheGuard.ShouldReportPackZero(packSeeded, loader.LoadedPrograms, loader.S2AOutcome),
                new { outcome = loader.S2AOutcome?.ToString() ?? "null", loaded = loader.LoadedPrograms });
        }

        // ④ magic 损坏：LoadShaders 在给结局赋值前抛 DiskCacheLoadException，被装载器接住只告警 → 结局 null；
        //    种入了包、文件却坏了读到 0 支，「读到 0 支」红照样要报（#1546 复审：损坏不许被静音）
        {
            string dir = NewDir("pack-corrupt");
            var writer = new DiskCacheHostStorage(dir);
            writer.AddShader(Context(), ProgramFor(GuestA), HostA);
            string tocPath = Path.Combine(dir, "shared.toc");
            byte[] toc = File.ReadAllBytes(tocPath);
            toc[0] ^= 0xFF;   // TocHeader.Magic 在偏移 0
            File.WriteAllBytes(tocPath, toc);
            var loader = new ParallelDiskCacheLoader(Context(), new ShaderCacheHashTable(), new ComputeShaderCacheHashTable(),
                new DiskCacheHostStorage(dir), (_, _, _) => { }, default);
            loader.LoadShaders();
            Check("corrupt magic leaves the outcome undecided and still qualifies for the pack red",
                loader.S2AOutcome == null && loader.LoadedPrograms == 0 &&
                S2AShaderCacheGuard.ShouldReportPackZero(packSeeded, loader.LoadedPrograms, loader.S2AOutcome),
                new { outcome = loader.S2AOutcome?.ToString() ?? "null", loaded = loader.LoadedPrograms });
        }

        // ⑤ 判定真值表：覆盖 Initialize 走不到的组合（未种包、读到非 0）
        Check("pack-zero predicate truth table",
            S2AShaderCacheGuard.ShouldReportPackZero(1, 0, ParallelDiskCacheLoader.S2ALoadOutcome.Missing) &&
            !S2AShaderCacheGuard.ShouldReportPackZero(1, 0, ParallelDiskCacheLoader.S2ALoadOutcome.StaleVersion) &&
            S2AShaderCacheGuard.ShouldReportPackZero(1, 0, null) &&
            !S2AShaderCacheGuard.ShouldReportPackZero(1, 1, ParallelDiskCacheLoader.S2ALoadOutcome.Loaded) &&
            !S2AShaderCacheGuard.ShouldReportPackZero(0, 0, null),
            null);
    }

    static int Main(string[] args)
    {
        Directory.CreateDirectory(Root);
        if (args.Contains("truncated-only"))
        {
            string dir = NewDir("truncated-host");
            var context = Context(); var storage = new DiskCacheHostStorage(dir);
            storage.AddShader(context, ProgramFor(GuestA), HostA);
            storage.ClearHostCache(context);
            Console.WriteLine("ENTER production lazy read after ClearHostCache");
            var program = Lazy(storage, context, dir, 0, GuestA).Materialize();
            Console.WriteLine("RETURN " + (program == null ? "rejected" : "accepted"));
            return program == null ? 0 : 1;
        }
        RejectedProgramCase();
        CapabilityCase(null, null);
        CapabilityCase(nameof(Capabilities.SupportsLayerVertexTessellation), true);
        CapabilityCase(nameof(Capabilities.SupportsViewportIndexVertexTessellation), true);
        CapabilityCase(nameof(Capabilities.ShaderSubgroupSize), 32);
        CapabilityCase(nameof(Capabilities.S2AVertexPull), true);
        CapabilityCase(nameof(Capabilities.RequiresLinkedVaryingInterface), true);
        CapabilityCase(nameof(Capabilities.MaximumVertexOutputComponents), 128);
        CapabilityCase(nameof(Capabilities.MaximumFragmentInputComponents), 128);
        CapabilityCase(nameof(Capabilities.RequiresLinkedVaryingInterface), true, same: true);
        CapabilityCase(nameof(Capabilities.MaximumVertexOutputComponents), 128, same: true);
        CapabilityCase(nameof(Capabilities.MaximumFragmentInputComponents), 128, same: true);
        LanguageCase(true, true); LanguageCase(false, false); LanguageCase(true, false); LanguageCase(false, true);
        AlignmentCase(false); AlignmentCase(true); TimestampCase();
        BootCase(false); BootCase(true); BootCase(true, changed: false); LegacyHostCase();
        CapabilityCoverage(); StreamDomainCases(); MetalSeedAndRestart(); MissingHostReportingCase(); FiniteReaderCases();
        MalformedHostCases(); SharedGenerationCase(); DerivedComputeStateMiss(); PackOutcomeCases();
        File.WriteAllText(Path.Combine(Root, "results.json"), JsonSerializer.Serialize(new { failed = Failed, results = Results }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"Evidence: {Root}; expected safety assertions failed: {Failed}");
        return Failed == 0 ? 0 : 1;
    }
}
