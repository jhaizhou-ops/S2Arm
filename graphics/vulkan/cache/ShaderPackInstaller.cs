using Ryujinx.Graphics.GAL;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>Outcome of one offline-pack install attempt.</summary>
public sealed record ShaderPackInstall(string PackageRoot, string CacheRoot, string PackKey, bool Installed,
    bool Replaced, int Files, long Bytes, int Programs, string Warning);

/// <summary>
/// Seeds the Ryujinx shader cache from an offline Vulkan pack. The pack is verified while it
/// is copied into a staging directory next to the cache; only a complete copy replaces the
/// cache, so a truncated or swapped file never leaves a half-imported cache. A pack that is
/// already seeded (same pack key and file sizes) is left alone, keeping what the session
/// learned at runtime.
/// </summary>
public static class ShaderPackInstaller
{
    private const int BufferBytes = 64 * 1024;

    public static ShaderPackInstall Install(string packageRoot, string cacheRoot,
        ProgramBinaryIdentity identity, string titleId, string contentRoot, string shaderAssemblyMvid,
        string translatorClosure) =>
        Install(packageRoot, cacheRoot, identity, titleId, contentRoot, shaderAssemblyMvid, translatorClosure,
            !RuntimeFeature.IsDynamicCodeSupported);

    internal static ShaderPackInstall Install(string packageRoot, string cacheRoot,
        ProgramBinaryIdentity identity, string titleId, string contentRoot, string shaderAssemblyMvid,
        string translatorClosure, bool nativeAot)
    {
        ArgumentNullException.ThrowIfNull(packageRoot);
        ArgumentNullException.ThrowIfNull(cacheRoot);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(titleId);

        string manifestPath = Path.Combine(packageRoot, "manifest.json");
        Require(File.Exists(manifestPath), "PACK_LAYOUT", "pack has no manifest.json");
        ShaderPackManifest manifest = ShaderPackManifest.Load(manifestPath);
        manifest.VerifyMetadata(packageRoot, identity, titleId, contentRoot, shaderAssemblyMvid, translatorClosure,
            nativeAot);

        string packKey = manifest.PackKey;
        if (IsSeeded(manifest, cacheRoot, packKey, titleId))
        {
            return new ShaderPackInstall(packageRoot, cacheRoot, packKey, false, false,
                manifest.Files.Length, manifest.Files.Sum(f => f.Bytes), manifest.Counts.Programs, null);
        }

        string parent = Path.GetDirectoryName(Path.GetFullPath(cacheRoot));
        Require(!string.IsNullOrEmpty(parent), "PACK_LAYOUT", "cache root has no parent directory");
        Directory.CreateDirectory(parent);

        // A killed process can leave a staging directory or a moved-aside cache; they are
        // never a valid seed, so remove our own leftovers before writing a new one.
        TryDeleteLeftovers(parent, ".s2a-shader-*");
        TryDeleteLeftovers(parent, Path.GetFileName(cacheRoot) + ".old-*");

        string staging = Path.Combine(parent, ".s2a-shader-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);

        long bytes = 0;
        try
        {
            foreach (ShaderPackEntry entry in manifest.Files)
            {
                // Checked again immediately before opening: the metadata pass only establishes
                // that the pack was link-free when it was inspected.
                ShaderPackManifest.RequireNoLink(packageRoot, entry.Path);
                string source = Path.Combine(packageRoot, entry.Path.Replace('/', Path.DirectorySeparatorChar));
                string target = Path.Combine(staging, CacheRelativePath(entry.Path, titleId).Replace('/', Path.DirectorySeparatorChar));
                string directory = Path.GetDirectoryName(target);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                bytes += CopyVerified(source, target, entry);
            }

            File.WriteAllText(Path.Combine(staging, ShaderPackLayout.StampFileName), packKey + "\n");
        }
        catch
        {
            TryDelete(staging);
            throw;
        }

        bool replaced = Directory.Exists(cacheRoot) && Directory.EnumerateFileSystemEntries(cacheRoot).Any();
        string backup = null;
        try
        {
            if (Directory.Exists(cacheRoot))
            {
                backup = cacheRoot + ".old-" + Guid.NewGuid().ToString("N");
                Directory.Move(cacheRoot, backup);
            }

            Directory.Move(staging, cacheRoot);
        }
        catch
        {
            TryDelete(staging);
            if (backup != null) TryMove(backup, cacheRoot);
            throw;
        }

        string warning = null;
        if (backup != null && !TryDelete(backup))
            warning = "previous shader cache backup could not be removed: " + backup;

        return new ShaderPackInstall(packageRoot, cacheRoot, packKey, true, replaced,
            manifest.Files.Length, bytes, manifest.Counts.Programs, warning);
    }

    private static bool IsSeeded(ShaderPackManifest manifest, string cacheRoot, string packKey, string titleId)
    {
        string stamp = Path.Combine(cacheRoot, ShaderPackLayout.StampFileName);
        if (!File.Exists(stamp) || File.ReadAllText(stamp).Trim() != packKey) return false;

        foreach (ShaderPackEntry entry in manifest.Files)
        {
            FileInfo info = new(Path.Combine(cacheRoot,
                CacheRelativePath(entry.Path, titleId).Replace('/', Path.DirectorySeparatorChar)));
            if (!info.Exists || info.Length != entry.Bytes) return false;
        }

        return true;
    }

    /// <summary>
    /// The pack keeps its guest/shared files under shcache/&lt;titleId&gt;/, but Ryujinx reads
    /// them directly from the cache root (&lt;games&gt;/&lt;title&gt;/cache/shader).  Strip the
    /// pack-only prefix for both the install copy and the already-seeded check; profile.json
    /// stays where it is (harmless, and the pack manifest lists it).
    /// </summary>
    internal static string CacheRelativePath(string path, string titleId)
    {
        string prefix = "shcache/" + titleId + "/";
        return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? path[prefix.Length..] : path;
    }

    private static long CopyVerified(string source, string target, ShaderPackEntry entry)
    {
        using FileStream input = new(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using FileStream output = new(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[BufferBytes];
        long total = 0;
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            total += read;
            Require(total <= entry.Bytes, "PACK_FILE", "pack file grew while reading " + entry.Path);
            hash.AppendData(buffer, 0, read);
            output.Write(buffer, 0, read);
        }

        output.Flush();
        Require(total == entry.Bytes, "PACK_FILE", "pack file size differs " + entry.Path);
        Require(Convert.ToHexStringLower(hash.GetHashAndReset()) == entry.Sha256, "PACK_FILE",
            "pack file digest differs " + entry.Path);
        return total;
    }

    private static void TryDeleteLeftovers(string parent, string pattern)
    {
        try
        {
            foreach (string directory in Directory.EnumerateDirectories(parent, pattern))
                TryDelete(directory);
        }
        catch
        {
            // Cleanup is best-effort; the new import still verifies and swaps atomically.
        }
    }

    private static bool TryDelete(string directory)
    {
        try
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void TryMove(string from, string to)
    {
        try
        {
            if (Directory.Exists(from) && !Directory.Exists(to)) Directory.Move(from, to);
        }
        catch
        {
            // The caller reports the original failure; a leftover backup is ignored here.
        }
    }

    private static void Require(bool condition, string code, string message)
    {
        if (!condition) throw new ProgramBinaryException(code, message);
    }
}
