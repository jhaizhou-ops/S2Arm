using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

static class FrozenProfileTests
{
    static int _count;
    const uint Vulkan12 = 0x00402000;
    const string Closure = "0123456789abcdef0123456789abcdef:fedcba9876543210fedcba9876543210";
    const string GpuProducer = "0123456789abcdef0123456789abcdef";
    const string RuleProducer = "fedcba9876543210fedcba9876543210";
    static void Check(bool value, string label)
    {
        if (!value) throw new Exception("FAIL frozen-profile: " + label);
        _count++;
        Console.WriteLine("PASS frozen-profile " + label);
    }
    static void Reject<T>(Action action, string label) where T : Exception
    {
        try { action(); }
        catch (T) { Check(true, label); return; }
        throw new Exception("FAIL frozen-profile accepted " + label);
    }
    static VulkanProfile Profile(bool spirv = true, bool raw = true, bool robust = false, bool record = false,
        string gpuProducer = GpuProducer, string ruleProducer = RuleProducer)
    {
        ComputeTranslationProfile selected = ComputeTranslationProfile.Select(spirv, raw, robust, record);
        Capabilities caps = S2Tests.Caps(clamp: !robust, record: record);
        return VulkanProfile.CreateFrozen(in caps, Vulkan12, Closure, selected, gpuProducer, ruleProducer);
    }
    static void JsonReject(VulkanProfile profile, Action<JsonObject> mutation, string label, string code = "PROFILE_RULES")
    {
        JsonObject changed = JsonNode.Parse(profile.ToJson()).AsObject();
        mutation(changed);
        try { _ = VulkanProfile.Parse(Encoding.UTF8.GetBytes(changed.ToJsonString())); }
        catch (ProgramBinaryException e) { Check(e.Code == code, label + " (" + e.Code + ")"); return; }
        throw new Exception("FAIL frozen-profile accepted " + label);
    }
    public static int Run()
    {
        _count = 0;
        // Independent truth table. Raw support is never treated as an enabled feature.
        foreach (bool spirv in new[] { false, true })
        foreach (bool raw in new[] { false, true })
        foreach (bool enabled in new[] { false, true })
        foreach (bool recorder in new[] { false, true })
        {
            if ((enabled && !raw) || (enabled && recorder))
            {
                Reject<InvalidDataException>(() => ComputeTranslationProfile.Select(spirv, raw, enabled, recorder),
                    $"impossible facts rejected {spirv}/{raw}/{enabled}/{recorder}");
                continue;
            }
            ComputeTranslationProfile selected = ComputeTranslationProfile.Select(spirv, raw, enabled, recorder);
            TranslationOptions options = selected.Options(TranslationFlags.Compute | TranslationFlags.DebugMode);
            Check(options.TargetApi == TargetApi.Vulkan && options.TargetLanguage == (spirv ? TargetLanguage.Spirv : TargetLanguage.Glsl) &&
                options.Flags == (TranslationFlags.Compute | TranslationFlags.DebugMode) &&
                selected.StorageWindowClamp == !enabled && selected.StorageOobRecord == (!enabled && recorder),
                $"rule program truth table {spirv}/{raw}/{enabled}/{recorder}");
        }
        VulkanProfile original = Profile();
        byte[] json = original.ToJson();
        VulkanProfile read = VulkanProfile.Parse(json);
        Check(original.IsFrozen && read.ToJson().SequenceEqual(json) && original.Identity == read.Identity,
            "v2 round-trip preserves canonical export and identity");
        Check(original.ToJson().SequenceEqual(original.ToJson()), "repeated exports are identical");
        Check(original.ComputeProfile.RawRobustBufferAccess && !original.ComputeProfile.EnabledRobustBufferAccess &&
            original.Capabilities.S2AStorageWindowClamp, "Raw/Enabled/Effective remain distinct");
        Check(original.ComputeProfile.ExecutionRulesHash == Convert.ToHexStringLower(SHA256.HashData(ComputeTranslationProfile.GetRuleArtifact())),
            "version locates the exact executable rule artifact");
        byte[] artifact = ComputeTranslationProfile.GetRuleArtifact(); artifact[0] ^= 1;
        Check(!artifact.SequenceEqual(ComputeTranslationProfile.GetRuleArtifact()), "artifact getter cannot mutate registered rules");
        Check(Profile(spirv: false).Identity.ProfileKey != original.Identity.ProfileKey &&
            Profile(robust: true).Identity.ProfileKey != original.Identity.ProfileKey &&
            Profile(record: true).Identity.ProfileKey != original.Identity.ProfileKey,
            "language and storage rule selections specialize profile identity");
        Check(Profile(raw: false).Identity == original.Identity,
            "different raw support with equal selected semantics does not specialize program bytes");
        VulkanProfile changedProducer = Profile(gpuProducer: new string('a', 32), ruleProducer: new string('b', 32));
        Check(changedProducer.Identity.ProfileKey == original.Identity.ProfileKey &&
            changedProducer.Identity.TranslationKey != original.Identity.TranslationKey &&
            changedProducer.ComputeProfile.ExecutionRulesHash == original.ComputeProfile.ExecutionRulesHash,
            "pure implementation changes alter producer identity without inventing rule changes");
        Capabilities legacyCaps = original.Capabilities;
        VulkanProfile legacy = VulkanProfile.Create(in legacyCaps, Vulkan12, Closure);
        Check(!legacy.IsFrozen && legacy.Identity == ProgramBinaryProfile.Create(in legacyCaps, Vulkan12, Closure) &&
            legacy.Identity.ProfileKey != original.Identity.ProfileKey,
            "v1 payload/key preserved and v2 uses an explicit separate domain");
        original.RequireConsumer(GpuProducer, RuleProducer, Closure[..32]);
        Reject<ProgramBinaryException>(() => original.RequireConsumer(new string('a', 32), RuleProducer, Closure[..32]), "foreign GPU consumer rejected");
        Reject<ProgramBinaryException>(() => original.RequireConsumer(GpuProducer, new string('b', 32), Closure[..32]), "foreign rule implementation rejected");
        Reject<ProgramBinaryException>(() => original.RequireConsumer(GpuProducer, RuleProducer, new string('c', 32)),
            "foreign actual Shader implementation rejected even with a self-consistent profile identity");
        Reject<InvalidDataException>(() => original.ComputeProfile.Options(TranslationFlags.Compute), "missing compute flags rejected");
        Reject<InvalidDataException>(() => original.ComputeProfile.Options(TranslationFlags.Compute | TranslationFlags.DebugMode | TranslationFlags.VertexA),
            "extra compute flags rejected rather than discarded");
        Reject<InvalidDataException>(() => original.ComputeProfile.Options((TranslationFlags)128), "unknown future flags rejected");
        Check(original.ComputeProfile.Options(TranslationFlags.DebugMode | TranslationFlags.VertexA).Flags ==
            (TranslationFlags.DebugMode | TranslationFlags.VertexA), "graphics flags retained with frozen common language");
        JsonReject(original, o => o["computeProfile"]["executionRulesHash"] = new string('0', 64), "unknown rule version rejected");
        JsonReject(original, o => {
            byte[] rules = Convert.FromBase64String(o["computeProfile"]["ruleArtifact"].GetValue<string>());
            rules[^1] ^= 1;
            o["computeProfile"]["ruleArtifact"] = Convert.ToBase64String(rules);
            string changedHash = Convert.ToHexStringLower(SHA256.HashData(rules));
            o["computeProfile"]["executionRulesHash"] = changedHash;
            string changedProfileKey = "s2a-vkpb-profile-v2|" + legacy.Identity.ProfileKey + "|" + changedHash + "|" + original.ComputeProfile.SelectionKey;
            o["identity"]["profileKey"] = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(changedProfileKey)));
        }, "unknown rule program rejected after rule and VKPB identity rehash");
        JsonReject(original, o => o["computeProfile"]["effective"]["computeFlags"] = 2, "unexecuted effective flags rejected");
        JsonReject(original, o => o["computeProfile"]["inputs"]["enabledRobustBufferAccess"] = true,
            "changed facts cannot retain old effective selection");
        JsonReject(original, o => o.Remove("computeProfile"), "v2 without actual rule source rejected", "PROFILE_SCHEMA");
        JsonReject(original, o => o["schema"] = VulkanProfile.Schema, "v1 cannot silently claim frozen semantics", "PROFILE_SCHEMA");
        JsonReject(original, o => o["computeProfile"]["unknown"] = 1, "unknown rule mapping rejected");
        JsonReject(original, o => o["computeProfile"]["graphicsCoverage"] = "complete", "graphics coverage cannot be overstated");
        JsonReject(original, o => o["gpuTranslationProducer"] = "example", "sample producer cannot stand in for assembly id", "PROFILE_SCHEMA");
        object owner = new(), rebuiltOwner = new();
        ProgramBinaryProfileSnapshot snapshot = new(owner, original);
        Check(ReferenceEquals(snapshot.RequireCurrent(owner), original), "selected profile object is shared");
        Capabilities runtimeCaps = snapshot.Capabilities(owner, 12345678);
        Check(runtimeCaps.MaximumGpuMemory == 12345678 && runtimeCaps.S2AStorageWindowClamp &&
            original.ToJson().SequenceEqual(json), "runtime memory capacity does not rewrite the frozen profile");
        Reject<InvalidOperationException>(() => snapshot.RequireCurrent(rebuiltOwner), "foreign device generation rejected");
        snapshot.Retire(owner);
        Reject<InvalidOperationException>(() => snapshot.RequireCurrent(owner), "retired device profile rejected");
        ProgramBinaryProfileSnapshot rebuilt = new(rebuiltOwner, Profile());
        Check(!ReferenceEquals(rebuilt.RequireCurrent(rebuiltOwner).ComputeProfile, original.ComputeProfile) &&
            rebuilt.Profile.Identity == original.Identity,
            "rebuild creates new snapshot but portable disk identity stays deterministic");
        Reject<InvalidOperationException>(() => rebuilt.RequireCurrent(owner), "old owner cannot consume rebuilt device");
        // Copy preservation guard: a newly added GAL field with a constructor default must
        // not silently disappear from the frozen-capability/runtime-budget adapter.
        foreach (var field in typeof(Capabilities).GetFields())
        {
            if (field.Name == nameof(Capabilities.MaximumGpuMemory)) continue;
            object box = S2Tests.Caps(clamp: true);
            object before = field.GetValue(box);
            object changed = field.FieldType == typeof(bool) ? !(bool)before :
                field.FieldType == typeof(string) ? "ChangedVendor" :
                field.FieldType == typeof(int) ? (int)before + 1 :
                field.FieldType == typeof(uint) ? (uint)before + 1 :
                field.FieldType == typeof(float) ? (float)before + 0.5f :
                field.FieldType == typeof(Format[]) ? new Format[] { Format.R16Sint } :
                field.FieldType.IsEnum ? Enum.ToObject(field.FieldType, 1) :
                throw new Exception("Add snapshot copy coverage for " + field.Name);
            field.SetValue(box, changed);
            Capabilities modified = (Capabilities)box;
            Capabilities copied = ProgramBinaryProfileSnapshot.WithMemoryBudget(in modified, 8765);
            Check(Equals(field.GetValue(copied), changed) && copied.MaximumGpuMemory == 8765,
                "capability copy preserves " + field.Name);
        }
        object concurrentOwner = new();
        ProgramBinaryProfileSnapshot concurrent = new(concurrentOwner, Profile());
        using var entered = new System.Threading.ManualResetEventSlim();
        var observer = System.Threading.Tasks.Task.Run(() => {
            entered.Set();
            while (true)
            {
                try { _ = concurrent.RequireCurrent(concurrentOwner); }
                catch (InvalidOperationException) { return true; }
            }
        });
        entered.Wait();
        concurrent.Retire(concurrentOwner);
        Check(observer.Wait(5000) && observer.Result, "retirement is visible to another profile consumer thread");
        Console.WriteLine($"FROZEN_PROFILE checks={_count} gpu_executed=false");
        return _count;
    }
}
