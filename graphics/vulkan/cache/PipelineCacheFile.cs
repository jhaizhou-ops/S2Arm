using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>Identity of one application-controlled Vulkan driver pipeline cache file.</summary>
public sealed record PipelineCacheIdentity(uint VendorId, uint DeviceId, uint DriverVersion, uint ApiVersion,
    byte[] PipelineCacheUuid, uint Schema, string Backend);

/// <summary>
/// Bounded wrapper around a VkPipelineCache blob. The driver blob carries its own
/// VkPipelineCacheHeaderVersionOne; this wrapper adds an application schema, backend token,
/// raw driver identity and a length/hash receipt. A rejected file is a rebuildable miss,
/// never a render success.
/// </summary>
public static class PipelineCacheFile
{
    public const uint Schema = 1;
    public const string Backend = "vulkan";
    public const int MaximumBytes = 64 * 1024 * 1024;
    private const int HeaderBytes = 96;
    private const int BackendBytes = 16;
    private const int UuidBytes = 16;
    private static readonly byte[] Magic = "S2APC001"u8.ToArray();

    public static byte[] Wrap(PipelineCacheIdentity identity, ReadOnlySpan<byte> payload)
    {
        ValidateIdentity(identity);
        if (payload.Length < 32) throw new ArgumentException("Pipeline cache payload is too short.", nameof(payload));
        if (payload.Length > MaximumBytes) throw new ArgumentOutOfRangeException(nameof(payload));

        byte[] output = new byte[HeaderBytes + payload.Length];
        Magic.CopyTo(output, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(8), identity.Schema);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(12), identity.VendorId);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(16), identity.DeviceId);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(20), identity.DriverVersion);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(24), identity.ApiVersion);
        identity.PipelineCacheUuid.AsSpan(0, UuidBytes).CopyTo(output.AsSpan(28, UuidBytes));
        Encoding.ASCII.GetBytes(identity.Backend).AsSpan(0, Math.Min(BackendBytes, identity.Backend.Length))
            .CopyTo(output.AsSpan(44, BackendBytes));
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(60), (uint)payload.Length);
        SHA256.HashData(payload).CopyTo(output.AsSpan(64, 32));
        payload.CopyTo(output.AsSpan(HeaderBytes));
        return output;
    }

    public static bool TryUnwrap(ReadOnlySpan<byte> file, PipelineCacheIdentity expected,
        out byte[] payload, out string error)
    {
        payload = null;
        error = null;
        if (!TryValidateIdentity(expected, out error))
            return false;
        if (file.Length < HeaderBytes + 32 || file.Length > HeaderBytes + MaximumBytes)
        {
            error = "LENGTH: pipeline cache file size is outside the bound";
            return false;
        }
        if (!file[..8].SequenceEqual(Magic))
        {
            error = "MAGIC: unknown pipeline cache wrapper";
            return false;
        }
        if (BinaryPrimitives.ReadUInt32LittleEndian(file[8..]) != expected.Schema)
        {
            error = "SCHEMA: pipeline cache schema changed";
            return false;
        }
        if (BinaryPrimitives.ReadUInt32LittleEndian(file[12..]) != expected.VendorId ||
            BinaryPrimitives.ReadUInt32LittleEndian(file[16..]) != expected.DeviceId ||
            BinaryPrimitives.ReadUInt32LittleEndian(file[20..]) != expected.DriverVersion ||
            BinaryPrimitives.ReadUInt32LittleEndian(file[24..]) != expected.ApiVersion)
        {
            error = "IDENTITY: vendor/device/driver/api identity changed";
            return false;
        }
        if (!file.Slice(28, UuidBytes).SequenceEqual(expected.PipelineCacheUuid))
        {
            error = "UUID: pipelineCacheUUID changed";
            return false;
        }
        ReadOnlySpan<byte> backend = file.Slice(44, BackendBytes);
        int backendLength = backend.IndexOf((byte)0);
        if (backendLength < 0) backendLength = BackendBytes;
        if (Encoding.ASCII.GetString(backend[..backendLength]) != expected.Backend)
        {
            error = "BACKEND: pipeline cache backend mismatch";
            return false;
        }
        uint length = BinaryPrimitives.ReadUInt32LittleEndian(file[60..]);
        if (length != file.Length - HeaderBytes)
        {
            error = "LENGTH: declared payload length does not match the file";
            return false;
        }
        ReadOnlySpan<byte> body = file[HeaderBytes..];
        if (!CryptographicOperations.FixedTimeEquals(file.Slice(64, 32), SHA256.HashData(body)))
        {
            error = "HASH: pipeline cache payload digest mismatch";
            return false;
        }
        if (!TryCheckDriverHeader(body, expected, out error))
            return false;
        payload = body.ToArray();
        return true;
    }

    public static bool TryRead(string path, PipelineCacheIdentity expected, out byte[] payload, out string error)
    {
        payload = null;
        error = null;
        if (string.IsNullOrEmpty(path))
        {
            error = "PATH: no application pipeline cache path";
            return false;
        }
        try
        {
            FileInfo info = new(path);
            if (!info.Exists)
            {
                error = "MISS: no application pipeline cache";
                return false;
            }
            if (info.Length < HeaderBytes + 32 || info.Length > HeaderBytes + MaximumBytes)
            {
                error = "LENGTH: pipeline cache file size is outside the bound";
                return false;
            }
            return TryUnwrap(File.ReadAllBytes(path), expected, out payload, out error);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            error = "IO: " + e.Message;
            return false;
        }
    }

    public static bool TryWriteAtomic(string path, PipelineCacheIdentity identity, ReadOnlySpan<byte> payload,
        out string error)
    {
        error = null;
        if (string.IsNullOrEmpty(path))
        {
            error = "PATH: no application pipeline cache path";
            return false;
        }
        string temporary = path + ".tmp." + Environment.ProcessId + "." + Interlocked.Increment(ref _writes);
        try
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            byte[] wrapped = Wrap(identity, payload);
            using (FileStream stream = new(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 4096,
                FileOptions.WriteThrough))
            {
                stream.Write(wrapped);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            error = "IO: " + e.Message;
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { }
            return false;
        }
    }

    /// <summary>
    /// Startup cleanup for atomic-write temporaries left behind by killed processes
    /// (&lt;cache name&gt;.tmp.&lt;pid&gt;.&lt;n&gt;): the periodic save makes writes more frequent,
    /// so killed-mid-write residue accumulates (each up to 64 MiB). Call once at session start
    /// before the first write. Only files whose writer pid is provably dead are removed.
    /// A file stamped with our own pid is left alone too: sessions are rebuilt inside one
    /// process, and the previous session may still have a background write in flight on
    /// that exact file — deleting it would make its rename fail or drop the snapshot.
    /// Residue from a recycled pid is reclaimed once that process exits; the worst case
    /// is one extra file, never lost data. Files whose names do not match the temp
    /// naming exactly are left alone. Best effort, returns the deleted count.
    /// </summary>
    public static int CleanOrphanedTemporaries(string path)
    {
        if (string.IsNullOrEmpty(path)) return 0;
        try
        {
            string directory = Path.GetDirectoryName(path);
            string name = Path.GetFileName(path);
            if (string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(name) || !Directory.Exists(directory))
                return 0;
            string prefix = name + ".tmp.";
            int removed = 0;
            foreach (string candidate in Directory.EnumerateFiles(directory, prefix + "*"))
            {
                string[] parts = Path.GetFileName(candidate)[prefix.Length..].Split('.');
                if (parts.Length != 2 || !int.TryParse(parts[0], out int pid) || pid <= 0 ||
                    !int.TryParse(parts[1], out int counter) || counter <= 0)
                    continue;
                if (pid == Environment.ProcessId || ProcessAlive(pid)) continue;
                try { File.Delete(candidate); removed++; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            return removed;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            return 0;
        }
    }

    private static bool ProcessAlive(int pid)
    {
        try
        {
            using System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException) { return false; }
        catch (Exception e) when (e is InvalidOperationException or NotSupportedException or System.ComponentModel.Win32Exception)
        {
            return true;   // 查不到死活按活着处理，不误删
        }
    }

    private static bool TryCheckDriverHeader(ReadOnlySpan<byte> payload, PipelineCacheIdentity expected,
        out string error)
    {
        error = null;
        if (payload.Length < 32)
        {
            error = "DRIVER: pipeline cache payload is too short";
            return false;
        }
        uint headerSize = BinaryPrimitives.ReadUInt32LittleEndian(payload);
        uint headerVersion = BinaryPrimitives.ReadUInt32LittleEndian(payload[4..]);
        if (headerSize != 32 || headerVersion != 1)
        {
            error = "DRIVER: unsupported VkPipelineCache header";
            return false;
        }
        if (BinaryPrimitives.ReadUInt32LittleEndian(payload[8..]) != expected.VendorId ||
            BinaryPrimitives.ReadUInt32LittleEndian(payload[12..]) != expected.DeviceId ||
            !payload.Slice(16, UuidBytes).SequenceEqual(expected.PipelineCacheUuid))
        {
            error = "DRIVER: embedded pipeline cache identity mismatch";
            return false;
        }
        return true;
    }

    private static void ValidateIdentity(PipelineCacheIdentity identity)
    {
        if (identity == null) throw new ArgumentNullException(nameof(identity));
        if (!TryValidateIdentity(identity, out string error)) throw new ArgumentException(error);
    }

    private static bool TryValidateIdentity(PipelineCacheIdentity identity, out string error)
    {
        error = null;
        if (identity == null)
        {
            error = "IDENTITY: null pipeline cache identity";
            return false;
        }
        if (identity.PipelineCacheUuid == null || identity.PipelineCacheUuid.Length != UuidBytes)
        {
            error = "UUID: pipelineCacheUUID must be 16 bytes";
            return false;
        }
        if (identity.Backend == null || identity.Backend.Length is 0 or > BackendBytes ||
            !identity.Backend.All(static c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-'))
        {
            error = "BACKEND: invalid backend token";
            return false;
        }
        return true;
    }

    private static int _writes;
}
