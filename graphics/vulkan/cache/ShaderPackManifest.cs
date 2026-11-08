using Ryujinx.Graphics.GAL;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// One file listed by the offline Vulkan pack. Paths are relative to the pack root and use
/// '/' separators.
/// </summary>
public sealed record ShaderPackEntry(string Path, long Bytes, string Sha256);

public sealed record ShaderPackCounts(int Programs, int Written, int Unsupported, int Failed);

/// <summary>
/// Offline Vulkan pack manifest (layout: shaders/vulkan/&lt;graphicsMode&gt;/&lt;profileKey&gt;/).
/// The producer writes it after every payload file; the consumer verifies digests and the
/// translation identity before importing anything. Manual JSON, no reflection, so the same
/// parser runs in NativeAOT.
/// </summary>
public sealed class ShaderPackManifest
{
    public const string Schema = "s2a-vulkan-pack-v1";
    public const int MaximumBytes = 4 * 1024 * 1024;
    public const int MaximumFiles = 8192;
    public const long MaximumTotalBytes = 2L * 1024 * 1024 * 1024;
    public const int MaximumPathLength = 512;
    public const string GraphicsMode = "generic";
    public const string Backend = "vulkan";

    public string TitleId { get; }
    public string ContentRoot { get; }
    public ProgramBinaryIdentity Identity { get; }
    public string TranslatorClosure { get; }
    public string ShaderAssemblyMvid { get; }
    public ShaderPackCounts Counts { get; }
    public ShaderPackEntry[] Files { get; }

    private ShaderPackManifest(string titleId, string contentRoot, ProgramBinaryIdentity identity,
        string translatorClosure, string shaderAssemblyMvid, ShaderPackCounts counts, ShaderPackEntry[] files)
    {
        TitleId = titleId;
        ContentRoot = contentRoot;
        Identity = identity;
        TranslatorClosure = translatorClosure;
        ShaderAssemblyMvid = shaderAssemblyMvid;
        Counts = counts;
        Files = files;
    }

    /// <summary>Pack identity used to decide whether an already-seeded cache is current.</summary>
    public string PackKey
    {
        get
        {
            StringBuilder text = new();
            text.Append(Schema).Append('|').Append(GraphicsMode).Append('|').Append(Backend).Append('|')
                .Append(TitleId).Append('|').Append(ContentRoot).Append('|').Append(Identity.Scheme).Append('|')
                .Append(Identity.ProfileKey).Append('|').Append(Identity.TranslationKey).Append('|')
                .Append(Identity.BindingAbi).Append('|').Append(TranslatorClosure).Append('|').Append(ShaderAssemblyMvid);
            foreach (ShaderPackEntry file in Files)
                text.Append('\n').Append(file.Path).Append('\t').Append(file.Bytes).Append('\t').Append(file.Sha256);
            return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
        }
    }

    /// <summary>
    /// Builds a manifest from every file below <paramref name="root"/> (sorted by ordinal
    /// path). The producer must have finished writing all payload files first.
    /// </summary>
    public static ShaderPackManifest Create(string root, string titleId, string contentRoot,
        ProgramBinaryIdentity identity, string translatorClosure, string shaderAssemblyMvid,
        ShaderPackCounts counts)
    {
        Require(Directory.Exists(root), "PACK_LAYOUT", "pack root does not exist");
        Require(ShaderPackLayout.IsTitleId(titleId), "PACK_TITLE", "invalid title id");
        Require(ShaderPackLayout.IsContentRoot(contentRoot), "PACK_CONTENT", "invalid content root");
        Require(IsMvid(shaderAssemblyMvid), "PACK_SCHEMA", "invalid shader assembly id");
        Require(ProgramBinaryProfile.Token(identity?.Scheme) && ProgramBinaryProfile.Token(identity.ProfileKey) &&
            ProgramBinaryProfile.Token(identity.TranslationKey) && ProgramBinaryProfile.Token(identity.BindingAbi),
            "PACK_IDENTITY", "invalid identity");
        Require(TranslatorClosureValid(translatorClosure), "PACK_SCHEMA", "invalid translator closure");
        Require(counts is { Programs: >= 0, Written: >= 0, Unsupported: >= 0, Failed: >= 0 } &&
            counts.Written + counts.Unsupported + counts.Failed <= counts.Programs, "PACK_SCHEMA",
            "inconsistent program counts");

        List<ShaderPackEntry> files = new();
        long total = 0;
        foreach (string path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            Require(RelativePathValid(relative, titleId), "PACK_LAYOUT", "invalid pack path " + relative);
            FileInfo info = new(path);
            total += info.Length;
            Require(files.Count < MaximumFiles && total <= MaximumTotalBytes, "PACK_LIMIT", "pack too large");
            files.Add(new ShaderPackEntry(relative, info.Length, HashFile(path)));
        }

        Require(files.Count > 0, "PACK_LAYOUT", "empty pack");
        files.Sort((a, b) => string.CompareOrdinal(a.Path, b.Path));
        Require(files.Select(f => f.Path).Distinct(StringComparer.Ordinal).Count() == files.Count, "PACK_LAYOUT",
            "duplicate pack path");
        Require(files.Any(f => f.Path == "profile.json"), "PACK_LAYOUT", "pack has no profile.json");
        Require(files.Any(f => UnderTitle(f.Path, titleId)), "PACK_LAYOUT",
            "pack has no shader cache for the title");
        if (counts.Written > 0)
            Require(files.Any(f => IsHostProgramCacheFile(f.Path)), "PACK_LAYOUT",
                "manifest claims host records but lists no host program cache file");

        return new ShaderPackManifest(titleId, contentRoot, identity, translatorClosure, shaderAssemblyMvid,
            counts, files.ToArray());
    }

    public byte[] ToJson()
    {
        using MemoryStream stream = new();
        using (Utf8JsonWriter writer = new(stream, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteString("schema", Schema);
            writer.WriteString("graphicsMode", GraphicsMode);
            writer.WriteString("backend", Backend);
            writer.WriteString("titleId", TitleId);
            writer.WriteString("contentRoot", ContentRoot);
            writer.WriteStartObject("identity");
            writer.WriteString("scheme", Identity.Scheme);
            writer.WriteString("profileKey", Identity.ProfileKey);
            writer.WriteString("translationKey", Identity.TranslationKey);
            writer.WriteString("bindingAbi", Identity.BindingAbi);
            writer.WriteEndObject();
            writer.WriteStartObject("translator");
            writer.WriteString("closure", TranslatorClosure);
            writer.WriteString("shaderMvid", ShaderAssemblyMvid);
            writer.WriteEndObject();
            writer.WriteStartObject("counts");
            writer.WriteNumber("programs", Counts.Programs);
            writer.WriteNumber("written", Counts.Written);
            writer.WriteNumber("unsupported", Counts.Unsupported);
            writer.WriteNumber("failed", Counts.Failed);
            writer.WriteEndObject();
            writer.WriteStartArray("files");
            foreach (ShaderPackEntry file in Files)
            {
                writer.WriteStartObject();
                writer.WriteString("path", file.Path);
                writer.WriteNumber("bytes", file.Bytes);
                writer.WriteString("sha256", file.Sha256);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    public void Save(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        byte[] json = ToJson();
        Require(json.Length <= MaximumBytes, "PACK_LIMIT", "manifest too large");
        string temporary = path + ".tmp";
        File.WriteAllBytes(temporary, json);
        File.Move(temporary, path, overwrite: true);
    }

    public static ShaderPackManifest Load(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        long length = new FileInfo(path).Length;
        Require(length is > 0 and <= MaximumBytes, "PACK_LIMIT", "manifest size out of range");
        return Parse(File.ReadAllBytes(path));
    }

    public static ShaderPackManifest Parse(ReadOnlySpan<byte> json)
    {
        Require(json.Length is > 0 and <= MaximumBytes, "PACK_LIMIT", "manifest size out of range");

        string schema = null, graphicsMode = null, backend = null, titleId = null, contentRoot = null;
        ProgramBinaryIdentity identity = null;
        string closure = null, shaderMvid = null;
        ShaderPackCounts counts = null;
        ShaderPackEntry[] files = null;

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
        }
        catch (JsonException e)
        {
            throw new ProgramBinaryException("PACK_SCHEMA", "invalid manifest JSON: " + e.Message);
        }

        using JsonDocument _ = document;

        JsonElement root = document.RootElement;
        Require(root.ValueKind == JsonValueKind.Object, "PACK_SCHEMA", "manifest root is not an object");

        HashSet<string> seen = new(StringComparer.Ordinal);
        foreach (JsonProperty property in root.EnumerateObject())
        {
            Require(seen.Add(property.Name), "PACK_SCHEMA", "duplicate manifest field " + property.Name);
            switch (property.Name)
            {
                case "schema": schema = Text(property.Value); break;
                case "graphicsMode": graphicsMode = Text(property.Value); break;
                case "backend": backend = Text(property.Value); break;
                case "titleId": titleId = Text(property.Value); break;
                case "contentRoot": contentRoot = Text(property.Value); break;
                case "identity": identity = ReadIdentity(property.Value); break;
                case "translator":
                    Require(property.Value.ValueKind == JsonValueKind.Object, "PACK_SCHEMA",
                        "translator is not an object");
                    HashSet<string> tr = new(StringComparer.Ordinal);
                    foreach (JsonProperty field in property.Value.EnumerateObject())
                    {
                        Require(tr.Add(field.Name), "PACK_SCHEMA", "duplicate translator field " + field.Name);
                        switch (field.Name)
                        {
                            case "closure": closure = Text(field.Value); break;
                            case "shaderMvid": shaderMvid = Text(field.Value); break;
                            default:
                                throw new ProgramBinaryException("PACK_SCHEMA",
                                    "unknown translator field " + field.Name);
                        }
                    }
                    break;
                case "counts": counts = ReadCounts(property.Value); break;
                case "files": files = ReadFiles(property.Value); break;
                default:
                    throw new ProgramBinaryException("PACK_SCHEMA", "unknown manifest field " + property.Name);
            }
        }

        Require(schema == Schema, "PACK_SCHEMA", "unsupported manifest schema");
        Require(graphicsMode == GraphicsMode, "PACK_SCHEMA", "unsupported graphics mode");
        Require(backend == Backend, "PACK_SCHEMA", "unsupported backend");
        Require(ShaderPackLayout.IsTitleId(titleId), "PACK_TITLE", "invalid title id");
        Require(ShaderPackLayout.IsContentRoot(contentRoot), "PACK_CONTENT", "invalid content root");
        Require(identity != null, "PACK_SCHEMA", "missing identity");
        Require(TranslatorClosureValid(closure), "PACK_SCHEMA", "invalid translator closure");
        Require(IsMvid(shaderMvid), "PACK_SCHEMA", "invalid shader assembly id");
        Require(counts != null, "PACK_SCHEMA", "missing counts");
        Require(files is { Length: > 0 and <= MaximumFiles }, "PACK_LIMIT", "file list length out of range");
        if (counts.Written > 0)
            Require(files.Any(f => IsHostProgramCacheFile(f.Path)), "PACK_LAYOUT",
                "manifest claims host records but lists no host program cache file");
        Require(files.Any(f => f.Path == "profile.json"), "PACK_LAYOUT", "pack has no profile.json");
        Require(files.Any(f => UnderTitle(f.Path, titleId)), "PACK_LAYOUT",
            "pack has no shader cache for the title");

        long total = 0;
        HashSet<string> paths = new(StringComparer.Ordinal);
        foreach (ShaderPackEntry file in files)
        {
            Require(RelativePathValid(file.Path, titleId), "PACK_LAYOUT", "invalid pack path " + file.Path);
            Require(paths.Add(file.Path), "PACK_LAYOUT", "duplicate pack path " + file.Path);
            Require(file.Bytes >= 0, "PACK_LAYOUT", "negative file size");
            total = checked(total + file.Bytes);
            Require(total <= MaximumTotalBytes, "PACK_LIMIT", "pack too large");
        }

        for (int i = 1; i < files.Length; i++)
            Require(string.CompareOrdinal(files[i - 1].Path, files[i].Path) < 0, "PACK_LAYOUT",
                "file list is not sorted");

        return new ShaderPackManifest(titleId, contentRoot, identity, closure, shaderMvid, counts, files);
    }

    /// <summary>
    /// Verifies the pack against the runtime's translation identity, the installed title and
    /// content revision, and the actual bytes on disk. Any mismatch is a rejected pack, never
    /// a cache hit. The translator check is selected by the runtime: NativeAOT compares the
    /// translator closure because it does not preserve the producer assembly's MVID.
    /// </summary>
    public void Verify(string root, ProgramBinaryIdentity expectedIdentity, string expectedTitleId,
        string expectedContentRoot, string expectedShaderMvid, string expectedTranslatorClosure) =>
        Verify(root, expectedIdentity, expectedTitleId, expectedContentRoot, expectedShaderMvid,
            expectedTranslatorClosure, !RuntimeFeature.IsDynamicCodeSupported);

    internal void Verify(string root, ProgramBinaryIdentity expectedIdentity, string expectedTitleId,
        string expectedContentRoot, string expectedShaderMvid, string expectedTranslatorClosure, bool nativeAot)
    {
        VerifyMetadata(root, expectedIdentity, expectedTitleId, expectedContentRoot, expectedShaderMvid,
            expectedTranslatorClosure, nativeAot);
        foreach (ShaderPackEntry file in Files)
        {
            string path = Path.Combine(root, file.Path.Replace('/', Path.DirectorySeparatorChar));
            FileInfo info = new(path);
            Require(info.Exists && info.Length == file.Bytes, "PACK_FILE", "pack file size differs " + file.Path);
            Require(HashFile(path) == file.Sha256, "PACK_FILE", "pack file digest differs " + file.Path);
        }
    }

    /// <summary>
    /// Everything except re-reading payload digests: identity, title, content revision,
    /// translator build, exact file set and link-free paths. An importer must combine this
    /// with hashing while copying (never with a separate verify-then-reopen pass). On
    /// NativeAOT the translator check uses the pack's closure field, which is the same
    /// semantic identity the direct package path uses; a JIT build keeps the MVID check.
    /// </summary>
    public void VerifyMetadata(string root, ProgramBinaryIdentity expectedIdentity, string expectedTitleId,
        string expectedContentRoot, string expectedShaderMvid, string expectedTranslatorClosure) =>
        VerifyMetadata(root, expectedIdentity, expectedTitleId, expectedContentRoot, expectedShaderMvid,
            expectedTranslatorClosure, !RuntimeFeature.IsDynamicCodeSupported);

    internal void VerifyMetadata(string root, ProgramBinaryIdentity expectedIdentity, string expectedTitleId,
        string expectedContentRoot, string expectedShaderMvid, string expectedTranslatorClosure, bool nativeAot)
    {
        Require(Directory.Exists(root), "PACK_LAYOUT", "pack root does not exist");
        Require(expectedIdentity != null, "PACK_IDENTITY", "runtime identity is missing");
        Require(TitleId == expectedTitleId, "PACK_TITLE", "pack title id differs from the installed game");
        Require(ContentRoot == expectedContentRoot, "PACK_CONTENT",
            "pack content root differs from the installed content revision");
        Require(Identity == expectedIdentity, "PACK_IDENTITY", "pack translation identity differs from this runtime");
        if (nativeAot)
            Require(TranslatorClosure == expectedTranslatorClosure, "PACK_TRANSLATOR",
                "pack was produced by a different shader translator closure");
        else
            Require(ShaderAssemblyMvid == expectedShaderMvid, "PACK_TRANSLATOR",
                "pack was produced by a different shader translator build");

        HashSet<string> expected = new(Files.Select(f => f.Path), StringComparer.Ordinal);
        foreach (string path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            if (relative == "manifest.json") continue;   // the manifest itself is written beside the pack, outside its own list
            Require(expected.Remove(relative), "PACK_LAYOUT", "pack contains an unlisted file " + relative);
        }

        Require(expected.Count == 0, "PACK_LAYOUT", "pack is missing listed files");

        if (Counts.Written > 0)
            Require(Files.Any(f => IsHostProgramCacheFile(f.Path)), "PACK_LAYOUT",
                "manifest claims host records but lists no host program cache file");

        foreach (ShaderPackEntry file in Files)
            RequireNoLink(root, file.Path);
    }

    // A pack is extracted from a game package; a symlink could make every lexical path check
    // pass while the bytes live outside the pack root. Reject links at every component.
    internal static void RequireNoLink(string root, string relative)
    {
        string current = root;
        foreach (string segment in relative.Split('/'))
        {
            current = Path.Combine(current, segment);
            Require(!File.GetAttributes(current).HasFlag(FileAttributes.ReparsePoint), "PACK_LAYOUT",
                "pack contains a link " + relative);
        }
    }

    // Host program cache files (<api>_<vendor>_bin_<caps>_<discriminator>.data/.toc).
    private static bool IsHostProgramCacheFile(string path) =>
        Path.GetFileName(path).Contains("_bin_", StringComparison.Ordinal) &&
        (path.EndsWith(".toc", StringComparison.Ordinal) || path.EndsWith(".data", StringComparison.Ordinal));

    private static ProgramBinaryIdentity ReadIdentity(JsonElement element)
    {
        Require(element.ValueKind == JsonValueKind.Object, "PACK_SCHEMA", "identity is not an object");
        string scheme = null, profileKey = null, translationKey = null, bindingAbi = null;
        HashSet<string> seen = new(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            Require(seen.Add(property.Name), "PACK_SCHEMA", "duplicate identity field " + property.Name);
            switch (property.Name)
            {
                case "scheme": scheme = Text(property.Value); break;
                case "profileKey": profileKey = Text(property.Value); break;
                case "translationKey": translationKey = Text(property.Value); break;
                case "bindingAbi": bindingAbi = Text(property.Value); break;
                default:
                    throw new ProgramBinaryException("PACK_SCHEMA", "unknown identity field " + property.Name);
            }
        }

        Require(ProgramBinaryProfile.Token(scheme) && ProgramBinaryProfile.Token(profileKey) &&
            ProgramBinaryProfile.Token(translationKey) && ProgramBinaryProfile.Token(bindingAbi),
            "PACK_IDENTITY", "identity token missing or malformed");
        return new ProgramBinaryIdentity(scheme, profileKey, translationKey, bindingAbi);
    }

    private static ShaderPackCounts ReadCounts(JsonElement element)
    {
        Require(element.ValueKind == JsonValueKind.Object, "PACK_SCHEMA", "counts is not an object");
        int? programs = null, written = null, unsupported = null, failed = null;
        HashSet<string> seen = new(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            Require(seen.Add(property.Name), "PACK_SCHEMA", "duplicate counts field " + property.Name);
            int? value = property.Value.ValueKind == JsonValueKind.Number && property.Value.TryGetInt32(out int read)
                ? read
                : null;
            Require(value >= 0, "PACK_SCHEMA", "negative count " + property.Name);
            switch (property.Name)
            {
                case "programs": programs = value; break;
                case "written": written = value; break;
                case "unsupported": unsupported = value; break;
                case "failed": failed = value; break;
                default:
                    throw new ProgramBinaryException("PACK_SCHEMA", "unknown counts field " + property.Name);
            }
        }

        Require(programs.HasValue && written.HasValue && unsupported.HasValue && failed.HasValue, "PACK_SCHEMA",
            "counts field missing");
        Require(written + unsupported + failed <= programs, "PACK_SCHEMA", "inconsistent program counts");
        return new ShaderPackCounts(programs.Value, written.Value, unsupported.Value, failed.Value);
    }

    private static ShaderPackEntry[] ReadFiles(JsonElement element)
    {
        Require(element.ValueKind == JsonValueKind.Array, "PACK_SCHEMA", "files is not an array");
        List<ShaderPackEntry> files = new();
        foreach (JsonElement item in element.EnumerateArray())
        {
            Require(files.Count < MaximumFiles, "PACK_LIMIT", "too many pack files");
            Require(item.ValueKind == JsonValueKind.Object, "PACK_SCHEMA", "file entry is not an object");
            string path = null, sha256 = null;
            long? bytes = null;
            HashSet<string> seen = new(StringComparer.Ordinal);
            foreach (JsonProperty property in item.EnumerateObject())
            {
                Require(seen.Add(property.Name), "PACK_SCHEMA", "duplicate file field " + property.Name);
                switch (property.Name)
                {
                    case "path": path = Text(property.Value); break;
                    case "bytes":
                        Require(property.Value.ValueKind == JsonValueKind.Number, "PACK_SCHEMA", "invalid file size");
                        Require(property.Value.TryGetInt64(out long size) && size >= 0, "PACK_SCHEMA",
                            "invalid file size");
                        bytes = size;
                        break;
                    case "sha256": sha256 = Text(property.Value); break;
                    default:
                        throw new ProgramBinaryException("PACK_SCHEMA", "unknown file field " + property.Name);
                }
            }

            Require(path != null && bytes.HasValue && sha256 != null, "PACK_SCHEMA", "file field missing");
            Require(IsHex64(sha256), "PACK_SCHEMA", "invalid file digest " + path);
            files.Add(new ShaderPackEntry(path, bytes.Value, sha256));
        }

        return files.ToArray();
    }

    private static string Text(JsonElement element)
    {
        Require(element.ValueKind == JsonValueKind.String, "PACK_SCHEMA", "expected a string");
        string value = element.GetString();
        Require(value is { Length: > 0 and <= MaximumPathLength }, "PACK_SCHEMA", "string field length out of range");
        return value;
    }

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    private static bool RelativePathValid(string path, string titleId)
    {
        if (path is not { Length: > 0 and <= MaximumPathLength }) return false;
        if (path.Contains('\\') || path.Contains(':') || path[0] == '/') return false;
        string[] segments = path.Split('/');
        foreach (string segment in segments)
            if (segment.Length == 0 || segment is "." or "..") return false;
        return path == "profile.json" || path == "pso_warm.tsv" || UnderTitle(path, titleId);
    }

    // The A0 artifact names the title in upper case; the Ryujinx cache directory uses lower
    // case (ShaderCache.GetDiskCachePath). Accept the package's own casing here and keep the
    // segment count exact so a nested or aliased directory can never pass.
    private static bool UnderTitle(string path, string titleId)
    {
        string[] segments = path.Split('/');
        return segments.Length >= 3 && segments[0] == "shcache" &&
            string.Equals(segments[1], titleId, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsHex64(string value) => ShaderPackLayout.IsHex64(value);

    private static bool IsMvid(string value) => value is { Length: 32 } &&
        value.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');

    private static bool TranslatorClosureValid(string value) =>
        value is { Length: 65 } && value[32] == ':' && IsMvid(value[..32]) && IsMvid(value[33..]);

    private static void Require(bool condition, string code, string message)
    {
        if (!condition) throw new ProgramBinaryException(code, message);
    }
}
