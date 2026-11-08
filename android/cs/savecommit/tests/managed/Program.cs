// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Ryujinx.HLE.FileSystem;
using S2A.Android.SaveCommit;

if (args.Length != 1 || (args[0] != "--missing-binding" && !Path.IsPathFullyQualified(args[0])))
    throw new ArgumentException("Pass --missing-binding or an absolute path to the real Linux libs2a_native.so.");
bool missing = args[0] == "--missing-binding";
if (!missing && !OperatingSystem.IsLinux())
    throw new PlatformNotSupportedException("Real native interop tests require Linux; compile/missing-binding is not native proof.");
IntPtr native = IntPtr.Zero;
if (!missing)
{
    native = NativeLibrary.Load(args[0]);
    foreach (string suffix in new[] { "supported", "clone_tree", "exchange", "write_token", "read_token", "sync_directory", "open_read", "close_fd" })
        _ = NativeLibrary.GetExport(native, "s2a_savecommit_" + suffix);
}
NativeLibrary.SetDllImportResolver(typeof(AndroidDirectoryTransaction).Assembly, (name, _, _) =>
    name == "s2a_native" ? (missing ? throw new DllNotFoundException("Deliberate unavailable binding") : native) : IntPtr.Zero);
IHostDirectoryTransaction tx = S2AHostFileSystem.Transaction;
if (tx is not AndroidDirectoryTransaction)
{
    Console.Error.WriteLine("FAIL: actual Android AOT module initializer did not register adapter before use");
    Environment.Exit(1);
}
int checks = 0;
void Check(bool condition, string label)
{
    ++checks;
    if (!condition) throw new Exception("FAIL: " + label);
}
foreach (string bad in new[] { null!, "", "relative", "/bad\0tail", "/bad\ud800" })
{
    Check(!tx.Supported(bad), "invalid Supported");
    Check(tx.CloneTree(bad, "/b") == 22 && tx.CloneTree("/a", bad) == 22, "invalid CloneTree");
    Check(tx.Exchange(bad, "/b") == 22 && tx.Exchange("/a", bad) == 22, "invalid Exchange");
    Check(tx.WriteToken(bad, []) == 22, "invalid WriteToken");
    Check(tx.ReadToken(bad, [], out int n) == 22 && n == 0, "invalid ReadToken");
    Check(tx.SyncDirectory(bad) == 22, "invalid SyncDirectory");
    Check(tx.OpenRead(bad, out var badHandle) == 22 && badHandle is null, "invalid OpenRead null handle");
}
Check(tx.WriteToken("/not-accessed", new byte[65]) == 22, "oversized token rejected before native");
if (missing)
{
    Check(!tx.Supported("/a"), "unavailable Supported");
    Check(tx.CloneTree("/a", "/b") == 38, "unavailable CloneTree");
    Check(tx.Exchange("/a", "/b") == 38, "unavailable Exchange");
    Check(tx.WriteToken("/a", []) == 38, "unavailable WriteToken");
    Check(tx.ReadToken("/a", [], out int n) == 38 && n == 0, "unavailable ReadToken");
    Check(tx.SyncDirectory("/a") == 38, "unavailable SyncDirectory");
    Check(tx.OpenRead("/a", out var absentHandle) == 38 && absentHandle is null, "unavailable OpenRead null handle");
    Console.WriteLine($"PASS {checks} managed validation/missing-binding checks; NOT native interop proof.");
    return;
}
string root = Path.Combine(Path.GetTempPath(), "s2a_managed_" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    Check(tx.Supported(root), "volume supports primitive (unsupported volume fails this run)");
    Check(!Directory.EnumerateFileSystemEntries(root).Any(), "Supported cleans probe");
    string a = Path.Combine(root, "存档-a"), b = Path.Combine(root, "copy-b");
    Directory.CreateDirectory(a);
    Directory.CreateDirectory(Path.Combine(a, "nested"));
    byte[] payload = Enumerable.Range(0, 8193).Select(i => (byte)(i * 31)).ToArray();
    File.WriteAllBytes(Path.Combine(a, "nested", "payload"), payload);
    string regular = Path.Combine(a, "nested", "payload");
    Check(tx.OpenRead(regular, out var opened) == 0 && opened is not null && !opened.IsInvalid, "OpenRead regular");
    string descriptorPath = "/proc/self/fd/" + opened!.DangerousGetHandle().ToInt64();
    using (var stream = new FileStream(opened, FileAccess.Read))
    {
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        Check(copy.ToArray().SequenceEqual(payload), "OpenRead FileStream bytes");
    }
    Check(opened.IsClosed && !File.Exists(descriptorPath), "FileStream disposal closes owned fd");
    // A valid Unix descriptor zero must not be rejected or leaked. Restore only
    // this test process's original stdin after disposing the returned owner.
    int savedStdin = TestDescriptors.dup(0);
    Check(savedStdin >= 0, "save test stdin");
    try
    {
        Check(TestDescriptors.close(0) == 0, "release test stdin slot");
        int zeroResult = tx.OpenRead(regular, out var zeroHandle);
        using (zeroHandle)
        {
            Check(zeroResult == 0 && zeroHandle is not null && !zeroHandle.IsInvalid &&
                zeroHandle.DangerousGetHandle() == IntPtr.Zero, "OpenRead owns valid fd zero");
        }
        Check(zeroHandle!.IsClosed, "fd zero wrapper disposed");
    }
    finally
    {
        int restored = TestDescriptors.dup2(savedStdin, 0);
        TestDescriptors.close(savedStdin);
        Check(restored == 0, "restore test stdin");
    }
    string fileLink = Path.Combine(root, "file-link");
    File.CreateSymbolicLink(fileLink, regular);
    foreach (string rejected in new[] { fileLink, a, Path.Combine(root, "absent") })
        Check(tx.OpenRead(rejected, out var failure) != 0 && failure is null, "OpenRead rejection/null handle");
    string fifo = Path.Combine(root, "fifo");
    using (var mkfifo = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("mkfifo")
    {
        ArgumentList = { "--", fifo }, UseShellExecute = false
    }) ?? throw new Exception("Cannot start mkfifo"))
    {
        mkfifo.WaitForExit();
        Check(mkfifo.ExitCode == 0, "create FIFO fixture");
    }
    // External runner should also bound the whole test process (e.g. timeout 30s).
    var fifoCall = Task.Run(() =>
    {
        int result = tx.OpenRead(fifo, out var failure);
        bool ok = result != 0 && failure is null;
        failure?.Dispose();
        return ok;
    });
    Check(fifoCall.Wait(TimeSpan.FromSeconds(2)) && fifoCall.Result, "FIFO rejected without blocking and null handle");
    Check(tx.ReadToken(a, [], out int n) == 0 && n == 0, "missing token");
    byte[] token = Enumerable.Range(0, 64).Select(i => (byte)i).ToArray();
    Check(tx.WriteToken(a, token) == 0, "64-byte token");
    byte[] small = new byte[63];
    Check(tx.ReadToken(a, small, out n) == 34 && n == 64, "ERANGE actual length");
    byte[] actual = new byte[64];
    Check(tx.ReadToken(a, actual, out n) == 0 && n == 64 && actual.SequenceEqual(token), "token round trip");
    Check(tx.WriteToken(a, new byte[65]) == 22, "overlong token");
    Check(tx.ReadToken(a, actual, out n) == 0 && actual.SequenceEqual(token), "overlong write leaves token intact");
    Check(tx.CloneTree(a, b) == 0, "clone");
    Check(SHA256.HashData(File.ReadAllBytes(Path.Combine(b, "nested", "payload"))).SequenceEqual(SHA256.HashData(payload)), "clone payload hash");
    Check(tx.ReadToken(b, actual, out n) == 0 && n == 64 && actual.SequenceEqual(token), "clone token");
    File.WriteAllText(Path.Combine(b, "marker"), "new");
    Check(tx.Exchange(a, b) == 0 && File.Exists(Path.Combine(a, "marker")) && !File.Exists(Path.Combine(b, "marker")), "exchange names");
    Check(tx.SyncDirectory(root) == 0, "sync parent");
    string link = Path.Combine(root, "link");
    Directory.CreateSymbolicLink(link, a);
    Check(tx.SyncDirectory(link) != 0 && tx.SyncDirectory(link + "/") != 0, "sync symlink rejected, errno unspecified");
    // Corrupt/external fallback can exceed the managed length type. Never wrap it.
    using (FileStream sparse = File.Create(Path.Combine(a, ".s2a_token"))) sparse.SetLength((long)int.MaxValue + 1);
    Check(tx.ReadToken(a, [], out n) == 75 && n == 0, "unrepresentable actual length returns EOVERFLOW");
    Console.WriteLine($"PASS {checks} managed/real-native checks; NOT Android ext4/f2fs or crash-recovery acceptance.");
}
finally
{
    Directory.Delete(root, recursive: true);
}

internal static partial class TestDescriptors
{
    [LibraryImport("libc")] internal static partial int dup(int descriptor);
    [LibraryImport("libc")] internal static partial int dup2(int source, int destination);
    [LibraryImport("libc")] internal static partial int close(int descriptor);
}
