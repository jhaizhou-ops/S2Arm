using System;
using System.IO;
using System.IO.Compression;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// APK-asset delivery of an offline pack: assets/game/shaders.zip holds the same
/// vulkan/generic/&lt;profileKey&gt;/ tree the producer writes. Extraction is bounded and
/// rejects absolute, parent-relative or drive-qualified entries; the caller still verifies
/// the manifest before importing anything.
/// </summary>
public static class ShaderPackArchive
{
    public const long MaximumBytes = 1L << 30;

    /// <summary>Extracts the archive and returns the pack root for <paramref name="profileKey"/>.</summary>
    public static string Extract(string archivePath, string destinationRoot, string profileKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(archivePath);
        ArgumentException.ThrowIfNullOrEmpty(destinationRoot);
        Require(ShaderPackLayout.IsProfileKey(profileKey), "PACK_IDENTITY", "invalid profile key");

        FileInfo archive = new(archivePath);
        Require(archive.Exists && archive.Length > 0 && archive.Length <= MaximumBytes, "PACK_LIMIT",
            "offline pack archive is missing or too large");

        if (Directory.Exists(destinationRoot)) Directory.Delete(destinationRoot, true);
        Directory.CreateDirectory(destinationRoot);

        long total = 0;
        using (ZipArchive zip = ZipFile.OpenRead(archivePath))
        {
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string name = entry.FullName.Replace('\\', '/');
                if (name.EndsWith('/')) continue;
                string[] segments = name.Split('/');
                foreach (string segment in segments)
                    Require(segment.Length != 0 && segment is not "." and not "..", "PACK_LAYOUT",
                        "unsafe archive entry " + name);
                Require(name[0] != '/' && !name.Contains(':'), "PACK_LAYOUT", "unsafe archive entry " + name);
                Require(entry.Length >= 0, "PACK_LAYOUT", "archive entry has no size " + name);
                total += entry.Length;
                Require(total <= MaximumBytes, "PACK_LIMIT", "offline pack archive is too large");

                string target = Path.Combine(destinationRoot, name.Replace('/', Path.DirectorySeparatorChar));
                string directory = Path.GetDirectoryName(target);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                entry.ExtractToFile(target, overwrite: true);
            }
        }

        string expected = Path.Combine(destinationRoot, ShaderPackLayout.BackendDirectory,
            ShaderPackManifest.GraphicsMode, profileKey);
        Require(File.Exists(Path.Combine(expected, "manifest.json")), "PACK_LAYOUT",
            "offline pack archive has no manifest for this profile");
        return expected;
    }

    private static void Require(bool condition, string code, string message)
    {
        if (!condition) throw new ProgramBinaryException(code, message);
    }
}
