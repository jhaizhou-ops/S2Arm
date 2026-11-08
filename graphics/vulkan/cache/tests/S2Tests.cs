using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

static class S2Tests
{
    private static int _count;

    private const string Title = "01001B300B9BE000";
    private const string TitleDir = "01001b300b9be000";   // Ryujinx writes the cache directory in lower case
    private const string ContentRoot = "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string Closure = "0123456789abcdef0123456789abcdef:fedcba9876543210fedcba9876543210";
    private const string OtherClosure = "fedcba9876543210fedcba9876543210:0123456789abcdef0123456789abcdef";

    private static void Check(bool ok, string name)
    {
        if (!ok) throw new Exception("FAIL: " + name);
        _count++;
        Console.WriteLine("PASS " + name);
    }

    private static void Reject(Action action, string code, string name)
    {
        try
        {
            action();
        }
        catch (ProgramBinaryException e)
        {
            Check(e.Code == code, name + " (" + e.Code + ")");
            return;
        }

        throw new Exception("FAIL: accepted " + name);
    }

    // Plausible Adreno-class Vulkan capabilities; only the host codec and manifest are under
    // test here, no VkDevice is created and no device claim is made.
    internal static Capabilities Caps(TargetApi api = TargetApi.Vulkan, bool geometry = true, bool clamp = false, bool record = false, bool storeWithout = false, bool gsOcc = false, bool spirv15 = false, bool layerExt = false, bool layerNv = false)
    {
        return new Capabilities(
            api: api,
            vendorName: "Qualcomm",
            memoryType: SystemMemoryType.UnifiedMemory,
            hasFrontFacingBug: false,
            hasVectorIndexingBug: true,
            needsFragmentOutputSpecialization: false,
            reduceShaderPrecision: false,
            supportsAstcCompression: true,
            supportsBc123Compression: true,
            supportsBc45Compression: true,
            supportsBc67Compression: true,
            supportsEtc2Compression: true,
            supports3DTextureCompression: true,
            supportsBgraFormat: true,
            supportsR4G4Format: false,
            supportsR4G4B4A4Format: true,
            supportsScaledVertexFormats: true,
            supportsSnormBufferTextureFormat: true,
            supports5BitComponentFormat: true,
            supportsSparseBuffer: true,
            supportsBlendEquationAdvanced: true,
            supportsFragmentShaderInterlock: true,
            supportsFragmentShaderOrderingIntel: false,
            supportsGeometryShader: geometry,
            supportsGeometryShaderPassthrough: true,
            supportsTransformFeedback: true,
            supportsImageLoadFormatted: true,
            supportsLayerVertexTessellation: true,
            supportsMismatchingViewFormat: true,
            supportsCubemapView: true,
            supportsNonConstantTextureOffset: false,
            supportsQuads: false,
            supportsSeparateSampler: true,
            supportsShaderBallot: false,
            supportsShaderBarrierDivergence: true,
            supportsShaderFloat64: false,
            supportsShaderNonUniformIndexing: true,
            supportsTextureGatherOffsets: true,
            supportsTextureShadowLod: false,
            supportsVertexStoreAndAtomics: true,
            supportsViewportIndexVertexTessellation: true,
            supportsViewportMask: true,
            supportsViewportSwizzle: false,
            supportsIndirectParameters: true,
            supportsDepthClipControl: false,
            uniformBufferSetIndex: 0,
            storageBufferSetIndex: 1,
            textureSetIndex: 2,
            imageSetIndex: 3,
            extraSetBaseIndex: 4,
            maximumExtraSets: 12,
            maximumUniformBuffersPerStage: 16,
            maximumStorageBuffersPerStage: 16,
            maximumTexturesPerStage: 64,
            maximumImagesPerStage: 16,
            maximumComputeSharedMemorySize: 32768,
            maximumSupportedAnisotropy: 16f,
            shaderSubgroupSize: 64,
            storageBufferOffsetAlignment: 16,
            textureBufferOffsetAlignment: 16,
            gatherBiasPrecision: 0,
            maximumGpuMemory: 0,
            s2aVertexPull: false,
            s2aStorageWindowClamp: clamp,
            s2aStorageOobRecord: record,
            supportsImageStoreFormatted: storeWithout,
            supportsGeometryShaderOcclusionQuery: gsOcc,
            s2aSpirv15: spirv15,
            s2aSpirvLayerExt: layerExt,
            s2aSpirvLayerNv: layerNv);
    }

    private static void Profile()
    {
        const uint vk12 = (1u << 22) | (2u << 12);

        VulkanProfile profile = VulkanProfile.Create(Caps(), vk12, Closure);
        byte[] json = profile.ToJson();
        VulkanProfile read = VulkanProfile.Parse(json);
        Check(read.Identity == profile.Identity && read.TargetVulkanVersion == vk12 &&
            read.TranslatorClosure == Closure && read.Capabilities.Api == TargetApi.Vulkan &&
            read.Capabilities.VendorName == "Qualcomm", "Vulkan profile JSON round-trip keeps identity/caps");
        Check(read.TargetEnv == "vulkan1.2" && profile.Describe().Contains("Qualcomm"),
            "Vulkan profile target env and summary");

        string text = Encoding.UTF8.GetString(json);
        string tamperedKey = text.Replace(profile.Identity.ProfileKey, new string('0', 64));
        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(tamperedKey)), "PROFILE_IDENTITY",
            "declared identity that no longer matches the capabilities is rejected");

        // Same declared identity, different capability payload: translation must not trust it.
        VulkanProfile other = VulkanProfile.Create(Caps(geometry: false), vk12, Closure);
        string swapped = Encoding.UTF8.GetString(other.ToJson())
            .Replace(other.Identity.ProfileKey, profile.Identity.ProfileKey);
        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(swapped)), "PROFILE_IDENTITY",
            "capability payload swapped under a foreign identity is rejected");

        string versionMismatch = Encoding.UTF8.GetString(profile.ToJson()).Replace(
            "\"spirvVersion\": 4202496", "\"spirvVersion\": 4198400");
        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(versionMismatch)), "PROFILE",
            "capability payload for another Vulkan version is rejected");

        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(text.Replace("s2a-vulkan-profile-v1", "s2a-vulkan-profile-v2"))),
            "PROFILE_SCHEMA", "unknown profile schema is rejected");
        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(text.Replace("\"schema\":", "\"extra\": 1,\n  \"schema\":"))),
            "PROFILE_SCHEMA", "unknown profile field is rejected");
        Reject(() => VulkanProfile.Parse(Encoding.UTF8.GetBytes(text[..(text.Length / 2)])), "PROFILE_SCHEMA",
            "truncated profile JSON is rejected");
        Reject(() => VulkanProfile.Create(Caps(TargetApi.OpenGL), vk12, Closure), "PROFILE",
            "non-Vulkan capabilities cannot form a Vulkan profile");
        Reject(() => VulkanProfile.Create(Caps(), 0x00400000, Closure), "PROFILE",
            "Vulkan version outside the supported 1.1-1.4 range is rejected");
        Reject(() => VulkanProfile.Create(Caps(), vk12, "not-a-closure"), "PROFILE_SCHEMA",
            "malformed translator closure is rejected");

        byte[] payload = ProgramBinaryProfile.SerializeProfile(Caps(), vk12);
        Check(ProgramBinaryProfile.TryReadProfile(payload, out Capabilities decoded, out uint decodedVersion, out _) &&
            decoded.Api == TargetApi.Vulkan && decodedVersion == vk12 && decoded.VendorName == "Qualcomm",
            "canonical profile payload round-trips");
        Check(!ProgramBinaryProfile.TryReadProfile(payload.Concat(new byte[] { 0 }).ToArray(), out _, out _, out string trailing) &&
            trailing.StartsWith("PROFILE"), "trailing bytes after the canonical payload are rejected");
        Check(!ProgramBinaryProfile.TryReadProfile(payload[..^1], out _, out _, out string truncated) &&
            truncated.StartsWith("PROFILE"), "truncated canonical payload is rejected");

        // S2A (F1): the storage-window flags are an optional trailing byte written only when set, so a host
        // without the clamp keeps its exact profile bytes; set flags round-trip and change the profile key.
        foreach ((bool clamp, bool record) in new[] { (true, false), (true, true) })
        {
            byte[] flagged = ProgramBinaryProfile.SerializeProfile(Caps(clamp: clamp, record: record), vk12);
            Check(flagged.Length == payload.Length + 1 && flagged.AsSpan(0, payload.Length).SequenceEqual(payload),
                "storage-window flags only append one byte to the unflagged profile");
            Check(ProgramBinaryProfile.TryReadProfile(flagged, out Capabilities flaggedCaps, out _, out _) &&
                flaggedCaps.S2AStorageWindowClamp == clamp && flaggedCaps.S2AStorageOobRecord == record,
                "storage-window flags round-trip");
            Check(ProgramBinaryProfile.Create(Caps(clamp: clamp, record: record), vk12, Closure).ProfileKey !=
                ProgramBinaryProfile.Create(Caps(), vk12, Closure).ProfileKey, "storage-window flags change the profile key");
        }
        Check(!ProgramBinaryProfile.TryReadProfile(payload.Concat(new byte[] { 2 }).ToArray(), out _, out _, out string recordOnly) &&
            recordOnly.StartsWith("PROFILE"), "OOB record without the clamp is rejected");
        Check(!Caps(record: true).S2AStorageOobRecord, "OOB record capability requires the storage-window clamp");

        // S2A (VUID-08737): store-without-format 位（位 2）独立自由——不带 clamp/oob 也合法、往返保真、改 profile key。
        byte[] storeFlagged = ProgramBinaryProfile.SerializeProfile(Caps(storeWithout: true), vk12);
        Check(storeFlagged.Length == payload.Length + 1 && storeFlagged.AsSpan(0, payload.Length).SequenceEqual(payload),
            "store-without-format flag only appends one byte to the unflagged profile");
        Check(ProgramBinaryProfile.TryReadProfile(storeFlagged, out Capabilities storeCaps, out _, out _) &&
            storeCaps.SupportsImageStoreFormatted && !storeCaps.S2AStorageWindowClamp,
            "store-without-format flag round-trips without the clamp");
        Check(ProgramBinaryProfile.Create(Caps(storeWithout: true), vk12, Closure).ProfileKey !=
            ProgramBinaryProfile.Create(Caps(), vk12, Closure).ProfileKey,
            "store-without-format flag changes the profile key");

        // #1456: gs+遮挡位（位 3）独立自由——往返保真、改 profile key。
        byte[] gsOccFlagged = ProgramBinaryProfile.SerializeProfile(Caps(gsOcc: true), vk12);
        Check(gsOccFlagged.Length == payload.Length + 1 && gsOccFlagged.AsSpan(0, payload.Length).SequenceEqual(payload),
            "gs+occlusion flag only appends one byte to the unflagged profile");
        Check(ProgramBinaryProfile.TryReadProfile(gsOccFlagged, out Capabilities gsOccCaps, out _, out _) &&
            gsOccCaps.SupportsGeometryShaderOcclusionQuery && !gsOccCaps.SupportsImageStoreFormatted,
            "gs+occlusion flag round-trips");
        Check(ProgramBinaryProfile.Create(Caps(gsOcc: true), vk12, Closure).ProfileKey !=
            ProgramBinaryProfile.Create(Caps(), vk12, Closure).ProfileKey,
            "gs+occlusion flag changes the profile key");
        byte[] spirv15 = ProgramBinaryProfile.SerializeProfile(Caps(spirv15: true), vk12);
        Check(ProgramBinaryProfile.TryReadProfile(spirv15, out Capabilities spirvCaps, out _, out _) && spirvCaps.S2ASpirv15,
            "SPIR-V 1.5 target round-trips");
        Check(ProgramBinaryProfile.Create(Caps(spirv15: true), vk12, Closure).ProfileKey !=
            ProgramBinaryProfile.Create(Caps(), vk12, Closure).ProfileKey, "SPIR-V 1.5 target changes profile identity");
        Reject(() => ProgramBinaryProfile.SerializeProfile(Caps(spirv15: true), 0x00401000), "PROFILE",
            "Vulkan 1.1 cannot claim SPIR-V 1.5 output");
        byte[] forgedVersion = (byte[])spirv15.Clone();
        using var profileReader = new BinaryReader(new MemoryStream(forgedVersion));
        _ = profileReader.ReadString();
        _ = profileReader.ReadString();
        int versionOffset = checked((int)profileReader.BaseStream.Position);
        BitConverter.GetBytes(0x00401000u).CopyTo(forgedVersion, versionOffset);
        Check(!ProgramBinaryProfile.TryReadProfile(forgedVersion, out _, out _, out _),
            "a forged Vulkan 1.1 profile cannot claim SPIR-V 1.5 output");
        foreach (bool ext in new[] { false, true }) foreach (bool nv in new[] { false, true })
        {
            byte[] bytes = ProgramBinaryProfile.SerializeProfile(Caps(layerExt: ext, layerNv: nv), vk12);
            Check(ProgramBinaryProfile.TryReadProfile(bytes, out Capabilities caps, out _, out _) &&
                caps.S2ASpirvLayerExt == ext && caps.S2ASpirvLayerNv == nv, "layer extension identity round-trips");
        }
        Check(!ProgramBinaryProfile.TryReadProfile(payload.Concat(new byte[] { 128 }).ToArray(), out _, out _, out string unknownBit) &&
            unknownBit.StartsWith("PROFILE"), "unknown flag bits are rejected");
    }

    private static void Manifest()
    {
        VulkanProfile profile = VulkanProfile.Create(Caps(), (1u << 22) | (2u << 12), Closure);
        string root = Path.Combine(Path.GetTempPath(), "s2a-vkpack-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "shcache", TitleDir));
            File.WriteAllBytes(Path.Combine(root, "profile.json"), profile.ToJson());
            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "shared.toc"), Enumerable.Range(0, 48).Select(i => (byte)i).ToArray());
            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "guest.data"), new byte[] { 1, 2, 3, 4, 5 });
            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "vulkan_qualcomm_bin_deadbeef.data"), new byte[] { 7, 7 });

            ShaderPackManifest manifest = ShaderPackManifest.Create(root, Title, ContentRoot, profile.Identity,
                Closure, new string('a', 32), new ShaderPackCounts(10, 7, 2, 1));
            manifest.Save(Path.Combine(root, "manifest.json"));
            ShaderPackManifest read = ShaderPackManifest.Load(Path.Combine(root, "manifest.json"));
            Check(read.Files.Length == 4 && read.PackKey == manifest.PackKey && read.Identity == profile.Identity &&
                read.Counts == new ShaderPackCounts(10, 7, 2, 1), "pack manifest round-trip keeps files/identity/counts");

            read.Verify(root, profile.Identity, Title, ContentRoot, new string('a', 32), Closure);
            Check(true, "pack verifies against the runtime identity/title/content/translator");

            // NativeAOT does not preserve the producer assembly's MVID: the same closure must
            // still mount, while a different closure is rejected with PACK_TRANSLATOR.
            read.VerifyMetadata(root, profile.Identity, Title, ContentRoot, new string('b', 32), Closure, nativeAot: true);
            Check(true, "NativeAOT accepts a pack with the same translator closure and a different assembly MVID");
            Reject(() => read.VerifyMetadata(root, profile.Identity, Title, ContentRoot, new string('a', 32),
                OtherClosure, nativeAot: true), "PACK_TRANSLATOR",
                "NativeAOT rejects another translator closure");
            Reject(() => read.VerifyMetadata(root, profile.Identity, Title, ContentRoot, new string('b', 32),
                Closure, nativeAot: false), "PACK_TRANSLATOR",
                "JIT still rejects another translator assembly MVID (negative control)");

            Reject(() => read.Verify(root, profile.Identity, "0100000000000000", ContentRoot, new string('a', 32), Closure),
                "PACK_TITLE", "pack for another title is rejected");
            Reject(() => read.Verify(root, profile.Identity, Title,
                "sha256-" + new string('0', 64), new string('a', 32), Closure), "PACK_CONTENT",
                "pack for another content revision is rejected");
            Reject(() => read.Verify(root, profile.Identity with { ProfileKey = new string('b', 64) }, Title,
                ContentRoot, new string('a', 32), Closure), "PACK_IDENTITY", "pack for another translation profile is rejected");
            Reject(() => read.Verify(root, profile.Identity, Title, ContentRoot, new string('b', 32), Closure),
                "PACK_TRANSLATOR", "pack from another translator build is rejected");

            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "guest.data"), new byte[] { 1, 2, 3, 4, 6 });
            Reject(() => read.Verify(root, profile.Identity, Title, ContentRoot, new string('a', 32), Closure),
                "PACK_FILE", "pack file whose bytes changed is rejected");

            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "guest.data"), new byte[] { 1, 2, 3, 4, 5 });
            File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "extra.bin"), new byte[] { 9 });
            Reject(() => read.Verify(root, profile.Identity, Title, ContentRoot, new string('a', 32), Closure),
                "PACK_LAYOUT", "unlisted file in the pack is rejected");
            File.Delete(Path.Combine(root, "shcache", TitleDir, "extra.bin"));

            string outside = Path.Combine(Path.GetTempPath(), "s2a-vkpack-outside-" + Guid.NewGuid().ToString("N"));
            File.WriteAllBytes(outside, new byte[] { 1, 2, 3, 4, 5 });
            try
            {
                File.Delete(Path.Combine(root, "shcache", TitleDir, "guest.data"));
                File.CreateSymbolicLink(Path.Combine(root, "shcache", TitleDir, "guest.data"), outside);
                Reject(() => read.Verify(root, profile.Identity, Title, ContentRoot, new string('a', 32), Closure),
                    "PACK_LAYOUT", "pack entry that is a symlink is rejected");
                File.Delete(Path.Combine(root, "shcache", TitleDir, "guest.data"));
                File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "guest.data"), new byte[] { 1, 2, 3, 4, 5 });
            }
            finally
            {
                File.Delete(outside);
            }

            byte[] json = File.ReadAllBytes(Path.Combine(root, "manifest.json"));
            string text = Encoding.UTF8.GetString(json);
            Reject(() => ShaderPackManifest.Parse(Encoding.UTF8.GetBytes(text.Replace("\"graphicsMode\": \"generic\"", "\"graphicsMode\": \"direct\""))),
                "PACK_SCHEMA", "unknown graphics mode is rejected");
            Reject(() => ShaderPackManifest.Parse(Encoding.UTF8.GetBytes(text.Replace("\"path\": \"profile.json\"", "\"path\": \"../profile.json\""))),
                "PACK_LAYOUT", "path traversal in the manifest is rejected");
            Reject(() => ShaderPackManifest.Parse(Encoding.UTF8.GetBytes(text.Replace("\"files\": [", "\"files\": [\n    {\"path\": \"profile.json\", \"bytes\": 1, \"sha256\": \"" + new string('0', 64) + "\"},"))),
                "PACK_LAYOUT", "duplicate file entry is rejected");
            Reject(() => ShaderPackManifest.Parse(Encoding.UTF8.GetBytes(text.Replace("\"counts\":", "\"unexpected\": 1,\n  \"counts\":"))),
                "PACK_SCHEMA", "unknown manifest field is rejected");
            Reject(() => ShaderPackManifest.Parse(Encoding.UTF8.GetBytes(text[..(text.Length - 3)])), "PACK_SCHEMA",
                "truncated manifest JSON is rejected");

            string missingProfile = Path.Combine(Path.GetTempPath(), "s2a-vkpack-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path.Combine(missingProfile, "shcache", TitleDir));
            try
            {
                File.WriteAllBytes(Path.Combine(missingProfile, "shcache", TitleDir, "shared.toc"), new byte[] { 1 });
                Reject(() => ShaderPackManifest.Create(missingProfile, Title, ContentRoot, profile.Identity, Closure,
                    new string('a', 32), new ShaderPackCounts(1, 1, 0, 0)), "PACK_LAYOUT", "pack without profile.json is rejected");
            }
            finally
            {
                Directory.Delete(missingProfile, true);
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static string TempRoot()
    {
        string root = Path.Combine(Path.GetTempPath(), "s2a-vkpack-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return root;
    }

    // A valid pack on disk: profile.json, one guest/shared file pair and one host program
    // cache file, with the manifest written last by the producer.
    private static VulkanProfile MakePack(string root, bool warm = true)
    {
        VulkanProfile profile = VulkanProfile.Create(Caps(), (1u << 22) | (2u << 12), Closure);
        Directory.CreateDirectory(Path.Combine(root, "shcache", TitleDir));
        File.WriteAllBytes(Path.Combine(root, "profile.json"), profile.ToJson());
        File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "shared.toc"), Enumerable.Range(0, 48).Select(i => (byte)i).ToArray());
        File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "guest.data"), new byte[] { 1, 2, 3, 4, 5 });
        File.WriteAllBytes(Path.Combine(root, "shcache", TitleDir, "vulkan_qualcomm_bin_deadbeef.data"), new byte[] { 7, 7 });
        if (warm)
            File.WriteAllText(Path.Combine(root, "pso_warm.tsv"), "0\t0\tvs\n");
        ShaderPackManifest.Create(root, Title, ContentRoot, profile.Identity, Closure, new string('a', 32),
            new ShaderPackCounts(2, 1, 1, 0)).Save(Path.Combine(root, "manifest.json"));
        return profile;
    }

    private static void Installer()
    {
        string pack = TempRoot(), cache = TempRoot() + "-cache";
        try
        {
            VulkanProfile profile = MakePack(pack);
            string parent = Path.GetDirectoryName(cache);
            string stale = Path.Combine(parent, ".s2a-shader-stale");
            Directory.CreateDirectory(stale);
            File.WriteAllText(Path.Combine(stale, "half-copied.bin"), "x");
            ShaderPackInstall first = ShaderPackInstaller.Install(pack, cache, profile.Identity, Title, ContentRoot,
                new string('a', 32), Closure);
            Check(!Directory.Exists(stale), "a leftover staging directory from a killed import is removed");
            Check(first.Installed && !first.Replaced && first.Files == 5 && first.Programs == 2 &&
                File.Exists(Path.Combine(cache, "profile.json")) &&
                File.Exists(Path.Combine(cache, "shared.toc")) &&
                File.Exists(Path.Combine(cache, "guest.data")) &&
                File.Exists(Path.Combine(cache, "pso_warm.tsv")) &&
                File.ReadAllText(Path.Combine(cache, ShaderPackLayout.StampFileName)).Trim() == first.PackKey,
                "pack install copies every file flat into the cache root (pso_warm.tsv stays at the root) and writes the pack stamp");
            Check(ShaderPackLayout.CacheProgramCount(cache) == 2,
                "seeded pack is visible at the shared.toc path ShaderCache reads (2 programs)");

            File.WriteAllText(Path.Combine(cache, "learned-at-runtime.bin"), "x");
            ShaderPackInstall second = ShaderPackInstaller.Install(pack, cache, profile.Identity, Title, ContentRoot,
                new string('a', 32), Closure);
            Check(!second.Installed && File.Exists(Path.Combine(cache, "learned-at-runtime.bin")),
                "same pack is left alone and keeps runtime learning");

            File.Delete(Path.Combine(cache, "shared.toc"));
            ShaderPackInstall restored = ShaderPackInstaller.Install(pack, cache, profile.Identity, Title, ContentRoot,
                new string('a', 32), Closure);
            Check(restored.Installed && restored.Replaced &&
                File.Exists(Path.Combine(cache, "shared.toc")),
                "a cache missing a listed file is re-seeded from the same pack");
            Check(ShaderPackLayout.CacheProgramCount(cache) == 2,
                "re-seeded pack is still visible to ShaderCache");

            string noWarmPack = TempRoot(), noWarmCache = TempRoot() + "-cache";
            try
            {
                VulkanProfile noWarmProfile = MakePack(noWarmPack, warm: false);
                ShaderPackInstall noWarm = ShaderPackInstaller.Install(noWarmPack, noWarmCache, noWarmProfile.Identity,
                    Title, ContentRoot, new string('a', 32), Closure);
                Check(noWarm.Installed && noWarm.Programs == 2 &&
                    !File.Exists(Path.Combine(noWarmCache, "pso_warm.tsv")),
                    "pack without pso_warm.tsv still installs but leaves the warm list absent (no fake success)");
            }
            finally
            {
                if (Directory.Exists(noWarmPack)) Directory.Delete(noWarmPack, true);
                if (Directory.Exists(noWarmCache)) Directory.Delete(noWarmCache, true);
            }

            string aotCache = cache + "-aot";
            try
            {
                ShaderPackInstall aot = ShaderPackInstaller.Install(pack, aotCache, profile.Identity, Title, ContentRoot,
                    new string('b', 32), Closure, nativeAot: true);
                Check(aot.Installed && File.Exists(Path.Combine(aotCache, "shared.toc")) &&
                    ShaderPackLayout.CacheProgramCount(aotCache) == 2,
                    "NativeAOT installs a pack with the same translator closure and a different assembly MVID");
            }
            finally
            {
                if (Directory.Exists(aotCache)) Directory.Delete(aotCache, true);
            }

            string otherClosureCache = cache + "-other-closure";
            try
            {
                Reject(() => ShaderPackInstaller.Install(pack, otherClosureCache, profile.Identity, Title, ContentRoot,
                    new string('a', 32), OtherClosure, nativeAot: true), "PACK_TRANSLATOR",
                    "NativeAOT install rejects another translator closure");
                Check(!Directory.Exists(otherClosureCache), "closure rejection leaves no cache behind");
            }
            finally
            {
                if (Directory.Exists(otherClosureCache)) Directory.Delete(otherClosureCache, true);
            }

            string badPack = TempRoot(), badCache = cache + "-bad";
            try
            {
                File.WriteAllBytes(Path.Combine(pack, "shcache", TitleDir, "guest.data"), new byte[] { 9, 9, 9, 9, 9 });
                Reject(() => ShaderPackInstaller.Install(pack, badCache, profile.Identity, Title, ContentRoot,
                    new string('a', 32), Closure), "PACK_FILE", "payload swapped after manifest creation is rejected");
                Check(!Directory.Exists(badCache), "rejected pack leaves no cache behind");
            }
            finally
            {
                if (Directory.Exists(badPack)) Directory.Delete(badPack, true);
            }

            string outside = Path.Combine(Path.GetTempPath(), "s2a-vkpack-outside-" + Guid.NewGuid().ToString("N"));
            string linkCache = cache + "-link";
            try
            {
                string linked = Path.Combine(pack, "shcache", TitleDir, "guest.data");
                File.WriteAllBytes(outside, new byte[] { 1, 2, 3, 4, 5 });
                File.Delete(linked);
                File.CreateSymbolicLink(linked, outside);
                Reject(() => ShaderPackInstaller.Install(pack, linkCache, profile.Identity, Title, ContentRoot,
                    new string('a', 32), Closure), "PACK_LAYOUT", "symlinked pack file is rejected at import");
                Check(!Directory.Exists(linkCache), "symlink rejection leaves no cache behind");
            }
            finally
            {
                File.Delete(outside);
            }
            string oldLayout = cache + "-old-layout";
            try
            {
                Directory.CreateDirectory(Path.Combine(oldLayout, "shcache", TitleDir));
                File.Copy(Path.Combine(pack, "shcache", TitleDir, "shared.toc"),
                    Path.Combine(oldLayout, "shcache", TitleDir, "shared.toc"));
                Check(ShaderPackLayout.CacheProgramCount(oldLayout) == 0,
                    "negative control: the producer's shcache/<title> layout is invisible to ShaderCache (0 programs; the old installer was red)");
            }
            finally
            {
                if (Directory.Exists(oldLayout)) Directory.Delete(oldLayout, true);
            }
        }
        finally
        {
            if (Directory.Exists(pack)) Directory.Delete(pack, true);
            if (Directory.Exists(cache)) Directory.Delete(cache, true);
        }
    }

    private static void Layout()
    {
        string revisions = Path.Combine("/game", "revisions", ContentRoot.Replace("sha256-", "sha256-"));
        Check(ShaderPackLayout.ContentRootOf(revisions) == ContentRoot, "content root is read from revisions/<contentRoot>");
        Check(ShaderPackLayout.ContentRootOf("/game/revisions/not-a-content-root") == null,
            "game data outside revisions/<contentRoot> yields no content root");
        Check(ShaderPackLayout.ContentRootOf(null) == null, "missing game data directory yields no content root");
        Check(ShaderPackLayout.PackageRoot("/game/revisions/" + ContentRoot, new string('c', 64)) ==
            Path.Combine("/game/revisions/" + ContentRoot, "shaders", "vulkan", "generic", new string('c', 64)),
            "pack root layout matches the producer");
        Check(ShaderPackLayout.CacheRoot("/games", Title) == Path.Combine("/games", TitleDir, "cache", "shader"),
            "cache root uses the lower-case Ryujinx game directory");
        string revision = Path.Combine(Path.GetTempPath(), "s2a-revision-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(revision);
        try
        {
            File.WriteAllText(Path.Combine(revision, "index.tsv"),
                "ctl/control.nacp\t1\t" + new string('a', 64) + "\n" +
                "romfs/a.bin\t2\t" + new string('b', 64) + "\n" +
                "shaders/vulkan/generic/" + new string('c', 64) + "/profile.json\t3\t" + new string('d', 64) + "\n");
            string id = ShaderPackLayout.GameContentRoot(revision);
            Check(id != null && id.StartsWith("sha256-") && id.Length == 71,
                "game content root is the installed index without shader cache rows");

            File.AppendAllText(Path.Combine(revision, "index.tsv"),
                "shaders/vulkan/generic/" + new string('e', 64) + "/manifest.json\t4\t" + new string('f', 64) + "\n");
            Check(ShaderPackLayout.GameContentRoot(revision) == id,
                "adding or changing shader cache files does not change the pack content root");

            File.WriteAllText(Path.Combine(revision, "index.tsv"), "romfs/a.bin\t2\t" + new string('b', 64) + "\n");
            Check(ShaderPackLayout.GameContentRoot(revision) != id,
                "changing game content changes the pack content root");
            Check(ShaderPackLayout.GameContentRoot(revision + "-missing") == null,
                "revision without index.tsv has no game content root");
        }
        finally
        {
            Directory.Delete(revision, true);
        }

        Reject(() => ShaderPackLayout.PackageRoot("/game", "not-a-key"), "PACK_IDENTITY",
            "invalid profile key is rejected");
        Reject(() => ShaderPackLayout.CacheRoot("/games", "short"), "PACK_TITLE", "invalid title id is rejected");
    }

    private static void Archive()
    {
        const uint vk12 = (1u << 22) | (2u << 12);
        VulkanProfile profile = VulkanProfile.Create(Caps(), vk12, Closure);
        string archive = Path.Combine(Path.GetTempPath(), "s2a-pack-" + Guid.NewGuid().ToString("N") + ".zip");
        string root = Path.GetTempPath() + "s2a-unpack-" + Guid.NewGuid().ToString("N");
        try
        {
            using (FileStream stream = File.Create(archive))
            using (ZipArchive zip = new(stream, ZipArchiveMode.Create))
            {
                void Add(string name, byte[] bytes)
                {
                    ZipArchiveEntry entry = zip.CreateEntry(name);
                    using Stream output = entry.Open();
                    output.Write(bytes);
                }

                Add($"vulkan/generic/{profile.Identity.ProfileKey}/manifest.json", Encoding.UTF8.GetBytes("{}"));
                Add($"vulkan/generic/{profile.Identity.ProfileKey}/shcache/01001b300b9be000/shared.toc", new byte[] { 1, 2, 3 });
            }

            string pack = ShaderPackArchive.Extract(archive, root, profile.Identity.ProfileKey);
            Check(File.Exists(Path.Combine(pack, "manifest.json")) &&
                File.ReadAllBytes(Path.Combine(pack, "shcache", TitleDir, "shared.toc")).SequenceEqual(new byte[] { 1, 2, 3 }),
                "offline pack archive extracts the profile tree");

            string missing = Path.Combine(Path.GetTempPath(), "s2a-pack-" + Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                using (FileStream stream = File.Create(missing))
                using (ZipArchive zip = new(stream, ZipArchiveMode.Create))
                {
                    ZipArchiveEntry entry = zip.CreateEntry("vulkan/generic/" + new string('f', 64) + "/manifest.json");
                    using Stream output = entry.Open();
                    output.WriteByte(0);
                }

                Reject(() => ShaderPackArchive.Extract(missing, root + "-missing", profile.Identity.ProfileKey),
                    "PACK_LAYOUT", "archive for another profile is rejected");
            }
            finally
            {
                File.Delete(missing);
            }

            string unsafeArchive = Path.Combine(Path.GetTempPath(), "s2a-pack-" + Guid.NewGuid().ToString("N") + ".zip");
            string escape = Path.Combine(Path.GetTempPath(), "s2a-escape-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                using (FileStream stream = File.Create(unsafeArchive))
                using (ZipArchive zip = new(stream, ZipArchiveMode.Create))
                {
                    ZipArchiveEntry entry = zip.CreateEntry("../" + Path.GetFileName(escape));
                    using Stream output = entry.Open();
                    output.WriteByte(7);
                }

                Reject(() => ShaderPackArchive.Extract(unsafeArchive, root + "-unsafe", profile.Identity.ProfileKey),
                    "PACK_LAYOUT", "archive entry escaping the destination is rejected");
                Check(!File.Exists(escape), "rejected archive wrote nothing outside its root");
            }
            finally
            {
                File.Delete(unsafeArchive);
            }
        }
        finally
        {
            if (File.Exists(archive)) File.Delete(archive);
            if (Directory.Exists(root)) Directory.Delete(root, true);
            if (Directory.Exists(root + "-missing")) Directory.Delete(root + "-missing", true);
            if (Directory.Exists(root + "-unsafe")) Directory.Delete(root + "-unsafe", true);
        }
    }

    public static int Run()
    {
        Profile();
        Manifest();
        Layout();
        Installer();
        Archive();
        Console.WriteLine("S2 profile/pack checks=" + _count);
        return _count;
    }
}
