using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Ryujinx.Graphics.GAL;

/// <summary>
/// Selected ordinary-compute decisions. The canonical rule artifact is an executable
/// expression program, not a second descriptive table. Source-linked into GAL so both
/// renderers and GPU accessors use one type without a Vulkan-to-GPU dependency.
/// Other capability/format mappings and graphics rules are not certified by this scope.
/// </summary>
public sealed class ComputeTranslationProfile
{
    public const string Schema = "s2a-compute-selection-v1";
    public const string Scope = "ordinary-compute-options-and-storage-window";
    public const string GraphicsCoverage = "legacy-capability-only";

    // Two-byte instructions: opcode, operand. Input indexes are requested SPIR-V,
    // raw robustBufferAccess, enabled robustBufferAccess, and created OOB recorder.
    // Raw support is provenance; it never substitutes for an enabled device feature.
    private enum Op : byte { Input, Constant, Not, And, Select }
    private sealed record Rule(string Consumer, byte[] Code);
    private static readonly Rule[] Rules =
    [
        new("ShaderCache.CreateTranslationOptions.TargetLanguage",
            [(byte)Op.Input, 0, (byte)Op.Constant, (byte)TargetLanguage.Spirv,
             (byte)Op.Constant, (byte)TargetLanguage.Glsl, (byte)Op.Select, 0]),
        new("ShaderCache.DecodeComputeShader.Flags",
            [(byte)Op.Constant, (byte)(TranslationFlags.DebugMode | TranslationFlags.Compute)]),
        new("GpuAccessorBase.QueryHostStorageWindowClamp",
            [(byte)Op.Input, 2, (byte)Op.Not, 0]),
        new("GpuAccessorBase.QueryHostStorageOobRecord",
            [(byte)Op.Input, 2, (byte)Op.Not, 0, (byte)Op.Input, 3, (byte)Op.And, 0]),
    ];
    private static readonly byte[] Artifact = SerializeRules();
    public static string CurrentExecutionRulesHash { get; } = Hash(Artifact);
    public static byte[] GetRuleArtifact() => (byte[])Artifact.Clone();

    public bool RequestedSpirv { get; }
    public bool RawRobustBufferAccess { get; }
    public bool EnabledRobustBufferAccess { get; }
    public bool StorageRecorderCreated { get; }
    public TargetLanguage Language { get; }
    public TranslationFlags ComputeFlags { get; }
    public bool StorageWindowClamp { get; }
    public bool StorageOobRecord { get; }
    public string ExecutionRulesHash => CurrentExecutionRulesHash;
    public string SelectionKey { get; }

    private ComputeTranslationProfile(bool requestedSpirv, bool rawRobustBufferAccess,
        bool enabledRobustBufferAccess, bool storageRecorderCreated)
    {
        Require(!enabledRobustBufferAccess || rawRobustBufferAccess,
            "enabled robustBufferAccess is absent from raw device support");
        Require(!storageRecorderCreated || !enabledRobustBufferAccess,
            "the storage recorder requires the clamp path");
        RequestedSpirv = requestedSpirv;
        RawRobustBufferAccess = rawRobustBufferAccess;
        EnabledRobustBufferAccess = enabledRobustBufferAccess;
        StorageRecorderCreated = storageRecorderCreated;
        int[] inputs = [requestedSpirv ? 1 : 0, rawRobustBufferAccess ? 1 : 0,
            enabledRobustBufferAccess ? 1 : 0, storageRecorderCreated ? 1 : 0];
        Language = (TargetLanguage)Evaluate(Rules[0].Code, inputs);
        ComputeFlags = (TranslationFlags)Evaluate(Rules[1].Code, inputs);
        StorageWindowClamp = Evaluate(Rules[2].Code, inputs) != 0;
        StorageOobRecord = Evaluate(Rules[3].Code, inputs) != 0;
        using MemoryStream stream = new();
        using (BinaryWriter writer = new(stream, Encoding.UTF8, true))
        {
            writer.Write(Schema);
            writer.Write((int)Language);
            writer.Write((int)ComputeFlags);
            writer.Write(StorageWindowClamp);
            writer.Write(StorageOobRecord);
        }
        SelectionKey = Hash(stream.ToArray());
    }

    public static ComputeTranslationProfile Select(bool requestedSpirv, bool rawRobustBufferAccess,
        bool enabledRobustBufferAccess, bool storageRecorderCreated) =>
        new(requestedSpirv, rawRobustBufferAccess, enabledRobustBufferAccess, storageRecorderCreated);

    /// <summary>Compute flags come from the rule program; graphics keeps its existing flags.</summary>
    public TranslationOptions Options(TranslationFlags flags)
    {
        Require((flags & ~(TranslationFlags.DebugMode | TranslationFlags.VertexA | TranslationFlags.Compute)) == 0,
            "unknown translation flags are not covered by this selection");
        Require((flags & TranslationFlags.Compute) == 0 || flags == ComputeFlags,
            "ordinary compute requires the exact frozen flag set");
        return new TranslationOptions(Language, TargetApi.Vulkan,
            (flags & TranslationFlags.Compute) != 0 ? ComputeFlags : flags);
    }

    public void RequireCapabilities(in Capabilities capabilities)
    {
        Require(capabilities.Api == TargetApi.Vulkan &&
            capabilities.S2AStorageWindowClamp == StorageWindowClamp &&
            capabilities.S2AStorageOobRecord == StorageOobRecord,
            "effective capabilities disagree with the selected storage-window rules");
    }

    private static int Evaluate(ReadOnlySpan<byte> code, ReadOnlySpan<int> inputs)
    {
        Span<int> stack = stackalloc int[8];
        int count = 0;
        for (int i = 0; i < code.Length; i += 2)
        {
            switch ((Op)code[i])
            {
                case Op.Input: stack[count++] = inputs[code[i + 1]]; break;
                case Op.Constant: stack[count++] = code[i + 1]; break;
                case Op.Not: stack[count - 1] = stack[count - 1] == 0 ? 1 : 0; break;
                case Op.And:
                    int right = stack[--count];
                    stack[count - 1] = stack[count - 1] != 0 && right != 0 ? 1 : 0;
                    break;
                case Op.Select:
                    int whenFalse = stack[--count], whenTrue = stack[--count];
                    stack[count - 1] = stack[count - 1] != 0 ? whenTrue : whenFalse;
                    break;
                default: throw new InvalidDataException("Unknown compute rule opcode.");
            }
        }
        Require(count == 1, "invalid compute rule stack");
        return stack[0];
    }

    private static byte[] SerializeRules()
    {
        using MemoryStream stream = new();
        using (BinaryWriter writer = new(stream, Encoding.UTF8, true))
        {
            writer.Write("s2a-compute-expressions-v1");
            writer.Write(Scope);
            writer.Write("inputs:requestedSpirv,rawRobustBufferAccess,enabledRobustBufferAccess,storageRecorderCreated");
            writer.Write("ops:input,constant,boolean-not,boolean-and,select-true-false");
            writer.Write(Rules.Length);
            foreach (Rule rule in Rules)
            {
                writer.Write(rule.Consumer);
                writer.Write(rule.Code.Length);
                writer.Write(rule.Code);
            }
        }
        return stream.ToArray();
    }

    public void WriteJson(Utf8JsonWriter writer)
    {
        writer.WriteStartObject();
        writer.WriteString("schema", Schema);
        writer.WriteString("scope", Scope);
        writer.WriteString("graphicsCoverage", GraphicsCoverage);
        writer.WriteString("executionRulesHash", ExecutionRulesHash);
        writer.WriteString("ruleArtifact", Convert.ToBase64String(Artifact));
        writer.WriteStartObject("inputs");
        writer.WriteBoolean("requestedSpirv", RequestedSpirv);
        writer.WriteBoolean("rawRobustBufferAccess", RawRobustBufferAccess);
        writer.WriteBoolean("enabledRobustBufferAccess", EnabledRobustBufferAccess);
        writer.WriteBoolean("storageRecorderCreated", StorageRecorderCreated);
        writer.WriteEndObject();
        writer.WriteStartObject("effective");
        writer.WriteNumber("language", (int)Language);
        writer.WriteNumber("computeFlags", (int)ComputeFlags);
        writer.WriteBoolean("storageWindowClamp", StorageWindowClamp);
        writer.WriteBoolean("storageOobRecord", StorageOobRecord);
        writer.WriteEndObject();
        writer.WriteEndObject();
    }

    public static ComputeTranslationProfile ReadJson(JsonElement element)
    {
        Fields(element, "schema", "scope", "graphicsCoverage", "executionRulesHash", "ruleArtifact", "inputs", "effective");
        Require(element.GetProperty("schema").GetString() == Schema &&
            element.GetProperty("scope").GetString() == Scope &&
            element.GetProperty("graphicsCoverage").GetString() == GraphicsCoverage,
            "unknown compute selection schema or coverage");
        Require(element.GetProperty("executionRulesHash").GetString() == CurrentExecutionRulesHash &&
            Convert.FromBase64String(element.GetProperty("ruleArtifact").GetString()).AsSpan().SequenceEqual(Artifact),
            "unknown compute rule artifact/version (a rehashed candidate is not admitted)");
        JsonElement inputs = element.GetProperty("inputs"), effective = element.GetProperty("effective");
        Fields(inputs, "requestedSpirv", "rawRobustBufferAccess", "enabledRobustBufferAccess", "storageRecorderCreated");
        Fields(effective, "language", "computeFlags", "storageWindowClamp", "storageOobRecord");
        ComputeTranslationProfile selected = Select(inputs.GetProperty("requestedSpirv").GetBoolean(),
            inputs.GetProperty("rawRobustBufferAccess").GetBoolean(),
            inputs.GetProperty("enabledRobustBufferAccess").GetBoolean(),
            inputs.GetProperty("storageRecorderCreated").GetBoolean());
        Require(effective.GetProperty("language").GetInt32() == (int)selected.Language &&
            effective.GetProperty("computeFlags").GetInt32() == (int)selected.ComputeFlags &&
            effective.GetProperty("storageWindowClamp").GetBoolean() == selected.StorageWindowClamp &&
            effective.GetProperty("storageOobRecord").GetBoolean() == selected.StorageOobRecord,
            "declared compute selection differs from rule execution");
        return selected;
    }

    private static void Fields(JsonElement element, params string[] names)
    {
        Require(element.ValueKind == JsonValueKind.Object, "compute selection object required");
        HashSet<string> remaining = new(names, StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
            Require(remaining.Remove(property.Name), "unknown or duplicate compute selection field " + property.Name);
        Require(remaining.Count == 0, "missing compute selection field");
    }

    private static string Hash(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
    private static void Require(bool condition, string error)
    {
        if (!condition) throw new InvalidDataException(error);
    }
}
