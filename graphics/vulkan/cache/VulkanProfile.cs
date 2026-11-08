using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// Explicit Android Vulkan translation profile exported by the device and consumed by the
/// offline producer. It pins the capabilities, the Vulkan target version and the
/// translator/codegen closure; the VKPB identity is recomputed from those bytes on load so a
/// hand-edited file cannot claim one capability set while hashing another.
///
/// JSON uses <see cref="Utf8JsonWriter"/>/<see cref="JsonDocument"/> only (no reflection), so
/// the same code runs in the NativeAOT Android runtime and in the desktop ShBake tool.
/// </summary>
public sealed class VulkanProfile
{
    public const string Schema = "s2a-vulkan-profile-v1";
    public const string FrozenSchema = "s2a-vulkan-profile-v2";
    public const int MaximumBytes = 64 * 1024;

    private const uint Vulkan11 = (1u << 22) | (1u << 12);
    private const uint Vulkan12 = (1u << 22) | (2u << 12);
    private const uint Vulkan13 = (1u << 22) | (3u << 12);
    private const uint Vulkan14 = (1u << 22) | (4u << 12);

    public ComputeTranslationProfile ComputeProfile { get; }
    public string GpuTranslationProducer { get; }
    public string RuleProducer { get; }
    public bool IsFrozen => ComputeProfile != null;

    public Capabilities Capabilities { get; }

    public uint TargetVulkanVersion { get; }

    public string TranslatorClosure { get; }

    public ProgramBinaryIdentity Identity { get; }

    public string VendorName => Capabilities.VendorName;

    private VulkanProfile(in Capabilities capabilities, uint targetVulkanVersion, string translatorClosure,
        ProgramBinaryIdentity identity, ComputeTranslationProfile computeProfile = null,
        string gpuTranslationProducer = null, string ruleProducer = null)
    {
        Capabilities = capabilities;
        TargetVulkanVersion = targetVulkanVersion;
        TranslatorClosure = translatorClosure;
        Identity = identity;
        ComputeProfile = computeProfile;
        GpuTranslationProducer = gpuTranslationProducer;
        RuleProducer = ruleProducer;
    }

    /// <summary>The spirv-val target environment implied by the profile's Vulkan version.</summary>
    public string TargetEnv => ((TargetVulkanVersion >> 12) & 0x3FF) switch
    {
        >= 4 => "vulkan1.4",
        3 => "vulkan1.3",
        2 => "vulkan1.2",
        _ => "vulkan1.1",
    };

    public static VulkanProfile Create(in Capabilities capabilities, uint targetVulkanVersion,
        string translatorClosure)
    {
        Require(targetVulkanVersion is >= Vulkan11 and <= Vulkan14 && (targetVulkanVersion & 0xFFF) == 0 &&
            (targetVulkanVersion >> 22) == 1, "PROFILE", "unsupported Vulkan target version");
        Require(capabilities.Api == TargetApi.Vulkan, "PROFILE", "profile capabilities are not Vulkan");
        Require(IsClosure(translatorClosure), "PROFILE_SCHEMA",
            "translatorClosure must be two lowercase 32-hex assembly ids");

        ProgramBinaryIdentity identity = ProgramBinaryProfile.Create(in capabilities, targetVulkanVersion,
            translatorClosure);
        return new VulkanProfile(in capabilities, targetVulkanVersion, translatorClosure, identity);
    }

    public static VulkanProfile CreateFrozen(in Capabilities capabilities, uint targetVulkanVersion,
        string translatorClosure, ComputeTranslationProfile selected, string gpuProducer, string ruleProducer)
    {
        _ = Create(in capabilities, targetVulkanVersion, translatorClosure);
        Require(IsAssemblyId(gpuProducer) && IsAssemblyId(ruleProducer), "PROFILE_PRODUCER",
            "GPU and rule producers must be lowercase 32-hex assembly ids");
        ProgramBinaryIdentity identity = ProgramBinaryProfile.CreateFrozen(in capabilities, targetVulkanVersion,
            translatorClosure, selected, gpuProducer, ruleProducer);
        return new VulkanProfile(in capabilities, targetVulkanVersion, translatorClosure, identity, selected,
            gpuProducer, ruleProducer);
    }

    /// <summary>Offline v2 consumers must execute the same GPU accessor and rule implementation.</summary>
    public void RequireConsumer(string gpuProducer, string ruleProducer, string shaderProducer)
    {
        if (IsFrozen)
            Require(GpuTranslationProducer == gpuProducer && RuleProducer == ruleProducer &&
                TranslatorClosure[..32] == shaderProducer,
                "PROFILE_PRODUCER", "the selected GPU/rule/shader producer is not this consumer build");
    }

    public static VulkanProfile Load(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        long length = new FileInfo(path).Length;
        Require(length is > 0 and <= MaximumBytes, "PROFILE", "profile file size out of range");
        return Parse(File.ReadAllBytes(path));
    }

    public static VulkanProfile Parse(ReadOnlySpan<byte> json)
    {
        Require(json.Length is > 0 and <= MaximumBytes, "PROFILE", "profile length out of range");

        string schema = null, translatorClosure = null, vendorName = null, capabilityBytes = null;
        JsonElement? identityElement = null, computeElement = null;
        string gpuProducer = null, ruleProducer = null;
        uint? targetVersion = null;

        JsonDocument parsed;
        try
        {
            parsed = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
        }
        catch (JsonException e)
        {
            throw new ProgramBinaryException("PROFILE_SCHEMA", "invalid profile JSON: " + e.Message);
        }

        using (parsed)
        {
            JsonElement root = parsed.RootElement;
            Require(root.ValueKind == JsonValueKind.Object, "PROFILE_SCHEMA", "profile root is not an object");

            HashSet<string> seen = new(StringComparer.Ordinal);
            foreach (JsonProperty property in root.EnumerateObject())
            {
                Require(seen.Add(property.Name), "PROFILE_SCHEMA", "duplicate profile field " + property.Name);
                switch (property.Name)
                {
                    case "schema":
                        schema = Text(property.Value, "PROFILE_SCHEMA", "schema");
                        break;
                    case "spirvVersion":
                        Require(property.Value.ValueKind == JsonValueKind.Number, "PROFILE_SCHEMA",
                            "spirvVersion is not an unsigned integer");
                        Require(property.Value.TryGetUInt32(out uint version), "PROFILE_SCHEMA",
                            "spirvVersion is not an unsigned integer");
                        targetVersion = version;
                        break;
                    case "translatorClosure":
                        translatorClosure = Text(property.Value, "PROFILE_SCHEMA", "translatorClosure");
                        break;
                    case "vendorName":
                        vendorName = Text(property.Value, "PROFILE_SCHEMA", "vendorName");
                        break;
                    case "capabilities":
                        capabilityBytes = Text(property.Value, "PROFILE_SCHEMA", "capabilities");
                        break;
                    case "gpuTranslationProducer":
                        gpuProducer = Text(property.Value, "PROFILE_SCHEMA", property.Name);
                        break;
                    case "ruleProducer":
                        ruleProducer = Text(property.Value, "PROFILE_SCHEMA", property.Name);
                        break;
                    case "computeProfile":
                        computeElement = property.Value.Clone();
                        break;
                    case "identity":
                        Require(property.Value.ValueKind == JsonValueKind.Object, "PROFILE_SCHEMA",
                            "identity is not an object");
                        identityElement = property.Value.Clone();
                        break;
                    default:
                        throw new ProgramBinaryException("PROFILE_SCHEMA", "unknown profile field " + property.Name);
                }
            }
        }

        Require(schema == Schema || schema == FrozenSchema, "PROFILE_SCHEMA", "unsupported profile schema");
        Require(targetVersion.HasValue, "PROFILE_SCHEMA", "missing spirvVersion");
        Require(translatorClosure != null, "PROFILE_SCHEMA", "missing translatorClosure");
        Require(vendorName != null, "PROFILE_SCHEMA", "missing vendorName");
        Require(capabilityBytes != null, "PROFILE_SCHEMA", "missing capabilities");
        Require(identityElement.HasValue, "PROFILE_SCHEMA", "missing identity");

        ProgramBinaryProfile.RequireClosure(translatorClosure);
        Require(IsClosure(translatorClosure), "PROFILE_SCHEMA",
            "translatorClosure must be two lowercase 32-hex assembly ids");

        byte[] payload;
        try
        {
            payload = Convert.FromBase64String(capabilityBytes);
        }
        catch (FormatException)
        {
            throw new ProgramBinaryException("PROFILE_SCHEMA", "capabilities are not base64");
        }

        if (!ProgramBinaryProfile.TryReadProfile(payload, out Capabilities capabilities, out uint readVersion,
            out string error))
        {
            throw new ProgramBinaryException("PROFILE", error);
        }

        Require(readVersion == targetVersion.Value, "PROFILE", "capabilities carry a different Vulkan version");
        Require(capabilities.Api == TargetApi.Vulkan, "PROFILE", "capabilities are not Vulkan");
        Require(string.Equals(capabilities.VendorName, vendorName, StringComparison.Ordinal), "PROFILE",
            "vendorName does not match the capabilities");
        Require(targetVersion.Value is >= Vulkan11 and <= Vulkan14 && (targetVersion.Value & 0xFFF) == 0 &&
            (targetVersion.Value >> 22) == 1, "PROFILE", "unsupported Vulkan target version");

        ComputeTranslationProfile computeProfile = null;
        if (schema == FrozenSchema)
        {
            Require(computeElement.HasValue && IsAssemblyId(gpuProducer) && IsAssemblyId(ruleProducer),
                "PROFILE_SCHEMA", "v2 requires compute selection and separate GPU/rule producers");
            try
            {
                computeProfile = ComputeTranslationProfile.ReadJson(computeElement.Value);
                computeProfile.RequireCapabilities(in capabilities);
            }
            catch (Exception e) when (e is InvalidDataException or InvalidOperationException or FormatException or
                KeyNotFoundException or ArgumentException)
            {
                throw new ProgramBinaryException("PROFILE_RULES", e.Message);
            }
        }
        else
        {
            Require(!computeElement.HasValue && gpuProducer == null && ruleProducer == null,
                "PROFILE_SCHEMA", "v1 cannot claim frozen compute rules");
        }

        ProgramBinaryIdentity expected = computeProfile == null
            ? ProgramBinaryProfile.Create(in capabilities, targetVersion.Value, translatorClosure)
            : ProgramBinaryProfile.CreateFrozen(in capabilities, targetVersion.Value, translatorClosure,
                computeProfile, gpuProducer, ruleProducer);
        ProgramBinaryIdentity declared = ReadIdentity(identityElement.Value);

        Require(declared.Scheme == expected.Scheme && declared.ProfileKey == expected.ProfileKey &&
            declared.TranslationKey == expected.TranslationKey && declared.BindingAbi == expected.BindingAbi,
            "PROFILE_IDENTITY", "declared identity does not match the profile contents");

        return new VulkanProfile(in capabilities, targetVersion.Value, translatorClosure, declared, computeProfile,
            gpuProducer, ruleProducer);
    }

    public byte[] ToJson()
    {
        using MemoryStream stream = new();
        using (Utf8JsonWriter writer = new(stream, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteString("schema", IsFrozen ? FrozenSchema : Schema);
            writer.WriteNumber("spirvVersion", TargetVulkanVersion);
            writer.WriteString("translatorClosure", TranslatorClosure);
            writer.WriteString("vendorName", VendorName);
            Capabilities capabilities = Capabilities;
            writer.WriteString("capabilities",
                Convert.ToBase64String(ProgramBinaryProfile.SerializeProfile(in capabilities, TargetVulkanVersion)));
            if (IsFrozen)
            {
                writer.WriteString("gpuTranslationProducer", GpuTranslationProducer);
                writer.WriteString("ruleProducer", RuleProducer);
                writer.WritePropertyName("computeProfile");
                ComputeProfile.WriteJson(writer);
            }
            writer.WriteStartObject("identity");
            writer.WriteString("scheme", Identity.Scheme);
            writer.WriteString("profileKey", Identity.ProfileKey);
            writer.WriteString("translationKey", Identity.TranslationKey);
            writer.WriteString("bindingAbi", Identity.BindingAbi);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    public void Save(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        byte[] json = ToJson();
        string temporary = path + ".tmp";
        File.WriteAllBytes(temporary, json);
        File.Move(temporary, path, overwrite: true);
    }

    /// <summary>Bounded one-line identity for logs; never used as a lookup key.</summary>
    public string Describe() =>
        $"vulkan {TargetVulkanVersion >> 22}.{(TargetVulkanVersion >> 12) & 0x3FF}, {VendorName}, " +
        $"profile {Identity.ProfileKey[..12]}, closure {TranslatorClosure[..12]}";

    private static ProgramBinaryIdentity ReadIdentity(JsonElement element)
    {
        string scheme = null, profileKey = null, translationKey = null, bindingAbi = null;
        HashSet<string> seen = new(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            Require(seen.Add(property.Name), "PROFILE_SCHEMA", "duplicate identity field " + property.Name);
            switch (property.Name)
            {
                case "scheme":
                    scheme = Text(property.Value, "PROFILE_SCHEMA", "identity.scheme");
                    break;
                case "profileKey":
                    profileKey = Text(property.Value, "PROFILE_SCHEMA", "identity.profileKey");
                    break;
                case "translationKey":
                    translationKey = Text(property.Value, "PROFILE_SCHEMA", "identity.translationKey");
                    break;
                case "bindingAbi":
                    bindingAbi = Text(property.Value, "PROFILE_SCHEMA", "identity.bindingAbi");
                    break;
                default:
                    throw new ProgramBinaryException("PROFILE_SCHEMA", "unknown identity field " + property.Name);
            }
        }

        Require(Token(scheme) && Token(profileKey) && Token(translationKey) && Token(bindingAbi),
            "PROFILE_SCHEMA", "identity token missing or malformed");
        return new ProgramBinaryIdentity(scheme, profileKey, translationKey, bindingAbi);
    }

    private static string Text(JsonElement element, string code, string field)
    {
        Require(element.ValueKind == JsonValueKind.String, code, field + " is not a string");
        string value = element.GetString();
        Require(value is { Length: > 0 and <= 4096 }, code, field + " length out of range");
        return value;
    }

    private static bool Token(string value) => value is { Length: > 0 and <= 128 } &&
        Ascii(value, c => char.IsAsciiLetterOrDigit(c) || "._:-".Contains(c));

    private static bool IsAssemblyId(string value) => value is { Length: 32 } &&
        Ascii(value, c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');

    private static bool IsClosure(string value) => value is { Length: 65 } &&
        value[32] == ':' && Ascii(value[..32], c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f') &&
        Ascii(value[33..], c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');

    private static bool Ascii(string value, Func<char, bool> allowed)
    {
        foreach (char c in value)
            if (!allowed(c)) return false;
        return true;
    }

    private static void Require(bool condition, string code, string message)
    {
        if (!condition) throw new ProgramBinaryException(code, message);
    }
}
