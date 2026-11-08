// CPU-only compute seam. The registered smoke rule is deliberately not a game profile.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;

namespace S2A.ShBake
{
    public static class ComputeBake
    {
        const string Rule = "s2arm.compute-smoke";
        const string Abi = "synthetic-compute-layout-v1";

        static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidDataException(message);
        }

        static void Fields(JsonElement value, params string[] names)
        {
            Require(value.ValueKind == JsonValueKind.Object, "expected object");
            string[] found = value.EnumerateObject().Select(p => p.Name).ToArray();
            Require(found.Length == names.Length && found.Distinct().Count() == found.Length &&
                found.Order().SequenceEqual(names.Order()), "missing, duplicate or unknown field");
        }

        // Every value below belongs to the selected, versioned smoke rule. These
        // are not inferred device capabilities or defaults for missing W5 fields.
        static Capabilities Caps(JsonElement p)
        {
            Fields(p, "contract", "apiVersion", "spirvVersion", "bindingAbi", "codegen", "requiredCaps", "shaderRules", "transforms");
            Require(p.GetProperty("contract").GetString() == "s2arm.translation-profile.draft1", "unknown profile contract");
            Require(p.GetProperty("apiVersion").GetString() == "1.1" && p.GetProperty("spirvVersion").GetString() == "1.3", "smoke supports Vulkan 1.1 / SPIR-V 1.3 only");
            Require(p.GetProperty("bindingAbi").GetString() == Abi, "unknown smoke binding ABI");
            var rules = p.GetProperty("shaderRules");
            Require(rules.GetArrayLength() == 1, "explicit compute-smoke rule required");
            Fields(rules[0], "id", "version");
            Require(rules[0].GetProperty("id").GetString() == Rule && rules[0].GetProperty("version").GetString() == "1", "unknown smoke semantics");
            Require(p.GetProperty("transforms").GetArrayLength() == 0, "transforms unsupported by smoke");
            var cg = p.GetProperty("codegen");
            Fields(cg, "features", "maxComputeSharedMemorySize", "subgroupSize");
            var f = cg.GetProperty("features");
            Fields(f, "geometryShader", "tessellationShader", "shaderFloat64", "shaderInt64");
            Require(!f.GetProperty("geometryShader").GetBoolean() && !f.GetProperty("tessellationShader").GetBoolean() && !f.GetProperty("shaderInt64").GetBoolean(), "unsupported smoke feature mapping");
            Require(cg.GetProperty("subgroupSize").GetInt32() == 32, "smoke requires explicit subgroup32 semantics");
            int shared = cg.GetProperty("maxComputeSharedMemorySize").GetInt32();
            Require(shared > 0 && shared <= 49152, "unsupported smoke shared-memory budget");
            var requirements = p.GetProperty("requiredCaps");
            Fields(requirements, "features", "minLimits", "exactLimits");
            var minimum = requirements.GetProperty("minLimits");
            var exact = requirements.GetProperty("exactLimits");
            Fields(minimum, "maxComputeSharedMemorySize", "maxBoundDescriptorSets");
            Fields(exact, "subgroupSize");
            Require(minimum.GetProperty("maxComputeSharedMemorySize").GetInt32() >= shared &&
                minimum.GetProperty("maxBoundDescriptorSets").GetInt32() >= 4 && exact.GetProperty("subgroupSize").GetInt32() == 32,
                "requirements do not cover selected smoke semantics");
            string[] requiredFeatures = requirements.GetProperty("features").EnumerateArray().Select(v => v.GetString()).ToArray();
            Require(requiredFeatures.SequenceEqual(f.GetProperty("shaderFloat64").GetBoolean() ? new[] { "shaderFloat64" } : Array.Empty<string>()), "unsupported or missing smoke feature requirement");
            // requiredCaps is checked against Effective by the Python entrypoint;
            // this CLI alone makes no device-admission claim.
            return new Capabilities(
                api: TargetApi.Vulkan, vendorName: "s2arm-compute-smoke", memoryType: SystemMemoryType.UnifiedMemory,
                hasFrontFacingBug: false, hasVectorIndexingBug: false, needsFragmentOutputSpecialization: false,
                reduceShaderPrecision: false, supportsAstcCompression: false, supportsBc123Compression: false,
                supportsBc45Compression: false, supportsBc67Compression: false, supportsEtc2Compression: false,
                supports3DTextureCompression: false, supportsBgraFormat: false, supportsR4G4Format: false,
                supportsR4G4B4A4Format: false, supportsScaledVertexFormats: false, supportsSnormBufferTextureFormat: false,
                supports5BitComponentFormat: false, supportsSparseBuffer: false, supportsBlendEquationAdvanced: false,
                supportsFragmentShaderInterlock: false, supportsFragmentShaderOrderingIntel: false,
                supportsGeometryShader: false, supportsGeometryShaderPassthrough: false, supportsTransformFeedback: false,
                supportsImageLoadFormatted: false, supportsLayerVertexTessellation: false, supportsMismatchingViewFormat: false,
                supportsCubemapView: false, supportsNonConstantTextureOffset: false, supportsQuads: false,
                supportsSeparateSampler: false, supportsShaderBallot: false, supportsShaderBarrierDivergence: false,
                supportsShaderFloat64: f.GetProperty("shaderFloat64").GetBoolean(), supportsShaderNonUniformIndexing: false,
                supportsTextureGatherOffsets: false, supportsTextureShadowLod: false, supportsVertexStoreAndAtomics: false,
                supportsViewportIndexVertexTessellation: false, supportsViewportMask: false, supportsViewportSwizzle: false,
                supportsIndirectParameters: false, supportsDepthClipControl: false,
                uniformBufferSetIndex: 0, storageBufferSetIndex: 1, textureSetIndex: 2, imageSetIndex: 3,
                extraSetBaseIndex: 4, maximumExtraSets: 0,
                maximumUniformBuffersPerStage: 18, maximumStorageBuffersPerStage: 16,
                maximumTexturesPerStage: 64, maximumImagesPerStage: 16,
                maximumComputeSharedMemorySize: shared, maximumSupportedAnisotropy: 1,
                shaderSubgroupSize: 32, storageBufferOffsetAlignment: 16, textureBufferOffsetAlignment: 16,
                gatherBiasPrecision: 0, maximumGpuMemory: 0, s2aVertexPull: false);
        }

        static GpuChannelComputeState State(JsonElement s)
        {
            Fields(s, "contract", "stage", "localSize", "localMemoryBytes", "sharedMemoryBytes", "constantBuffers", "textures");
            Require(s.GetProperty("contract").GetString() == "s2arm.synthetic-compute-state.draft1" && s.GetProperty("stage").GetString() == "cs", "unknown compute state");
            var size = s.GetProperty("localSize");
            Require(size.GetArrayLength() == 3, "localSize must have three dimensions");
            int x = size[0].GetInt32(), y = size[1].GetInt32(), z = size[2].GetInt32();
            Require(x > 0 && y > 0 && z > 0 && x <= 1024 && y <= 1024 && z <= 1024 && (long)x * y * z <= 1024, "invalid smoke workgroup size");
            // No backing/layout proof for resource-bearing programs in this first slice.
            Require(s.GetProperty("localMemoryBytes").GetInt32() == 0 && s.GetProperty("sharedMemoryBytes").GetInt32() == 0, "smoke memory must be zero");
            Require(s.GetProperty("constantBuffers").GetArrayLength() == 0 && s.GetProperty("textures").GetArrayLength() == 0, "resource state unsupported by smoke");
            return new GpuChannelComputeState(x, y, z, 0, 0, false);
        }

        // Reuse the real disk-cache accessor. A translator diagnostic is a hard
        // failure here, not permission to silently omit an unsupported opcode.
        sealed class StrictAccessor : DiskCacheGpuAccessor, IGpuAccessor
        {
            public StrictAccessor(GpuContext ctx, byte[] code, ShaderSpecializationState oldState, ShaderSpecializationState newState)
                : base(ctx, code, Array.Empty<byte>(), oldState, newState, new ResourceCounts(), 0, false) { }
            public new void Log(string message) => throw new InvalidDataException("translator diagnostic: " + message);
        }

        // The same translation owns both SPIR-V and complete GAL metadata. W12
        // consumers receive these objects, never a reconstructed diagnostic budget.
        public sealed record Translation(ShaderSource Source, ShaderInfo Info, string MetadataJson, string ResourcesJson);

        public static Translation Translate(JsonElement profile, JsonElement state, byte[] code)
        {
            Capabilities caps = Caps(profile);
            GpuChannelComputeState cs = State(state);
            Require(code.Length >= 32 && code.Length <= 1024 * 1024 && code.Length % 8 == 0, "invalid guest-code size");
            GpuContext ctx = ShaderBake.MakeContext(caps);
            // The selected rule owns these semantics, not inherited A/B env flags.
            TranslatorContext.S2AStageIndep = true;
            TranslatorContext.S2ARuntimeState = true;
            TranslatorContext.S2AVertexRawEnv = false;
            ShaderSpecializationState oldSpec = new(ref cs), newSpec = new(ref cs);
            oldSpec.RecordConstantBufferUse(0, 0);
            StrictAccessor accessor = new(ctx, code, oldSpec, newSpec);
            accessor.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);
            ShaderProgram program = ShaderCache.DecodeComputeShader(accessor, TargetApi.Vulkan, 0).Translate();
            Require(program.Info.Stage == Ryujinx.Graphics.Shader.ShaderStage.Compute, "unexpected shader stage");
            Require(program.Info.CBuffers.Count == 0 && program.Info.SBuffers.Count == 0 && program.Info.Textures.Count == 0 && program.Info.Images.Count == 0, "resource-bearing shaders unsupported by smoke");
            var reservations = new ResourceReservationCounts(false, false);
            var metadata = new {
                contract = "s2arm.compute-smoke-result.draft1", stage = "compute", entryPoint = "main",
                localSize = new[] { cs.LocalSizeX, cs.LocalSizeY, cs.LocalSizeZ }, bindingAbi = Abi,
                uniformBufferSet = caps.UniformBufferSetIndex, storageBufferSet = caps.StorageBufferSetIndex,
                textureSet = caps.TextureSetIndex, imageSet = caps.ImageSetIndex,
                perStageBudgets = new { uniformBuffers = caps.MaximumUniformBuffersPerStage,
                    storageBuffers = caps.MaximumStorageBuffersPerStage, textures = caps.MaximumTexturesPerStage,
                    images = caps.MaximumImagesPerStage }, extraSetBase = caps.ExtraSetBaseIndex, extraSetBudget = caps.MaximumExtraSets,
                reservedUniformBuffers = reservations.ReservedConstantBuffers,
                reservedStorageBuffers = reservations.ReservedStorageBuffers,
                reservedTextures = reservations.ReservedTextures, reservedImages = reservations.ReservedImages,
                userResources = 0, deviceAdmission = "unverified", runtimeProgram = false
            };
            ShaderInfo info = ShaderInfoBuilder.BuildForCompute(ctx, program.Info);
            var resources = new {
                contract = "s2arm.compute-gal-observation.draft1",
                fragmentOutputMap = info.FragmentOutputMap, fromCache = info.FromCache,
                pipelineState = info.State,
                sets = info.ResourceLayout.Sets.Select((set, index) => new {
                    set = index,
                    descriptors = set.Descriptors.Select(d => new {
                        binding = d.Binding, count = d.Count, type = d.Type.ToString(), stages = (int)d.Stages }),
                    usages = info.ResourceLayout.SetUsages[index].Usages.Select(u => new {
                        binding = u.Binding, arrayLength = u.ArrayLength, type = u.Type.ToString(), stages = (int)u.Stages, write = u.Write })
                }),
                sharedMemoryBytes = cs.SharedMemorySize, localMemoryBytes = cs.LocalMemorySize
            };
            return new Translation(new ShaderSource(program.BinaryCode, program.Info.Stage, TargetLanguage.Spirv),
                info, JsonSerializer.Serialize(metadata), JsonSerializer.Serialize(resources, new JsonSerializerOptions { IncludeFields = true }));
        }

        public static int Run(string[] args)
        {
            string staging = null;
            try
            {
                Require(args.Length == 8, "compute-smoke --profile FILE --state FILE --code FILE --output NEW_DIR");
                Dictionary<string, string> opts = new();
                for (int i = 0; i < args.Length; i += 2) Require(opts.TryAdd(args[i], args[i + 1]), "duplicate argument");
                Require(opts.Keys.Order().SequenceEqual(new[] { "--code", "--output", "--profile", "--state" }), "unknown or missing argument");
                string output = Path.GetFullPath(opts["--output"]);
                Require(!Directory.Exists(output) && !File.Exists(output), "output already exists");
                using var profile = JsonDocument.Parse(File.ReadAllBytes(opts["--profile"]));
                using var state = JsonDocument.Parse(File.ReadAllBytes(opts["--state"]));
                Translation translated = Translate(profile.RootElement, state.RootElement, File.ReadAllBytes(opts["--code"]));
                staging = output + ".tmp-" + Guid.NewGuid().ToString("N");
                Directory.CreateDirectory(staging);
                File.WriteAllBytes(Path.Combine(staging, "compute.spv"), translated.Source.BinaryCode);
                File.WriteAllText(Path.Combine(staging, "metadata.json"), translated.MetadataJson + "\n");
                File.WriteAllText(Path.Combine(staging, "gal-info.json"), translated.ResourcesJson + "\n");
                Directory.Move(staging, output);
                staging = null;
                Console.WriteLine(translated.MetadataJson);
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(JsonSerializer.Serialize(new { error = new { code = "COMPUTE_SMOKE_REJECTED", message = ex.Message } }));
                return 2;
            }
            finally
            {
                if (staging != null && Directory.Exists(staging)) Directory.Delete(staging, true);
            }
        }
    }
}
