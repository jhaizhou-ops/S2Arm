using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// Layout of a game's offline Vulkan pack and its runtime cache. Kept free of Android
/// types so the producer, the host tests and the NativeAOT runtime all use the same rules.
///
/// Pack (inside the game package):  shaders/vulkan/generic/&lt;profileKey&gt;/
/// Game data directory:             &lt;gameRoot&gt;/revisions/&lt;contentRoot&gt;/  (A0 install)
/// Runtime cache:                   &lt;AppDataManager.GamesDirPath&gt;/&lt;title&gt;/cache/shader
/// </summary>
public static class ShaderPackLayout
{
    public const string ShadersDirectory = "shaders";
    public const string BackendDirectory = "vulkan";
    public const string RevisionsDirectory = "revisions";
    public const string StampFileName = "s2a_pack.key";

    /// <summary>The A0 content root ("sha256-…") of the installed revision, or null.</summary>
    public static string ContentRootOf(string gameDataDirectory)
    {
        if (string.IsNullOrEmpty(gameDataDirectory)) return null;
        string full = Path.GetFullPath(gameDataDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string name = Path.GetFileName(full);
        string parent = Path.GetFileName(Path.GetDirectoryName(full));
        return parent == RevisionsDirectory && IsContentRoot(name) ? name : null;
    }

    /// <summary>
    /// Game-content identity carried by an offline pack: the installed revision's index.tsv
    /// without the cache files under shaders/. A pack can therefore live inside the package
    /// without changing the identity it claims, and a game/content update still changes it.
    /// The producer computes the same value from the package's index.tsv before adding the
    /// pack. Canonical form: lines split on '\n', drop the shaders/ rows and the trailing
    /// empty line, join with '\n', append one trailing '\n', SHA-256.
    /// </summary>
    public static string GameContentRoot(string revisionDirectory)
    {
        if (string.IsNullOrEmpty(revisionDirectory)) return null;
        string index = Path.Combine(revisionDirectory, "index.tsv");
        if (!File.Exists(index)) return null;

        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        StringBuilder kept = new();
        foreach (string line in File.ReadAllLines(index))
        {
            if (line.StartsWith(ShadersDirectory + "/", StringComparison.Ordinal)) continue;
            kept.Append(line).Append('\n');
        }

        hash.AppendData(Encoding.UTF8.GetBytes(kept.ToString()));
        return "sha256-" + Convert.ToHexStringLower(hash.GetHashAndReset());
    }

    /// <summary>&lt;gameData&gt;/shaders/vulkan/generic/&lt;profileKey&gt;.</summary>
    public static string PackageRoot(string gameDataDirectory, string profileKey)
    {
        if (string.IsNullOrEmpty(gameDataDirectory))
            throw new ProgramBinaryException("PACK_LAYOUT", "game data directory is missing");
        if (!IsProfileKey(profileKey))
            throw new ProgramBinaryException("PACK_IDENTITY", "invalid profile key");
        return Path.Combine(gameDataDirectory, ShadersDirectory, BackendDirectory,
            ShaderPackManifest.GraphicsMode, profileKey);
    }

    /// <summary>&lt;games&gt;/&lt;title&gt;/cache/shader, the directory Ryujinx reads.</summary>
    public static string CacheRoot(string gamesDirectory, string titleId)
    {
        if (string.IsNullOrEmpty(gamesDirectory))
            throw new ProgramBinaryException("PACK_LAYOUT", "games directory is missing");
        if (!IsTitleId(titleId))
            throw new ProgramBinaryException("PACK_TITLE", "invalid title id");
        return Path.Combine(gamesDirectory, titleId.ToLowerInvariant(), "cache", "shader");
    }

    /// <summary>
    /// Number of programs a Ryujinx shared.toc at the cache root exposes, using the same
    /// formula as DiskCacheHostStorage.GetProgramCount.  Tests use this to assert that a
    /// seeded pack is visible at the path the runtime actually reads (not merely that files
    /// exist under the producer's shcache/&lt;titleId&gt;/ layout).
    /// </summary>
    public static int CacheProgramCount(string cacheRoot)
    {
        string toc = Path.Combine(cacheRoot, "shared.toc");
        if (!File.Exists(toc)) return 0;
        return Math.Max((int)((new FileInfo(toc).Length - 32) / sizeof(ulong)), 0);
    }

    public static bool IsContentRoot(string value) => value is { Length: 71 } &&
        value.StartsWith("sha256-", StringComparison.Ordinal) && IsHex64(value[7..]);

    public static bool IsTitleId(string value) => value is { Length: 16 } &&
        value.All(c => char.IsAsciiDigit(c) || c is >= 'A' and <= 'F');

    public static bool IsProfileKey(string value) => IsHex64(value);

    public static bool IsHex64(string value) => value is { Length: 64 } &&
        value.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');
}
