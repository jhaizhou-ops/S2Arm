// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.IO;
using System.Runtime.InteropServices;
using Ryujinx.HLE.FileSystem;
using S2A.Android.SaveCommit;

namespace S2A.Android.SaveCommitProbe;

// Synthetic app-private interop only. This does not run the shared transaction
// state machine, Host.Boot, a game, process termination, or a power-loss test.
public static unsafe class Probe
{
    [UnmanagedCallersOnly(EntryPoint = "s2a_savecommit_managed_test")]
    public static int Run(byte* path, int* checks)
    {
        if (checks == null) return -1;
        *checks = 0;
        int count = 0;
        try
        {
            string parent = Marshal.PtrToStringUTF8((IntPtr)path);
            if (string.IsNullOrEmpty(parent) || !Path.IsPathFullyQualified(parent) || !Directory.Exists(parent))
                throw new IOException("Invalid app-owned fixture parent");
            IHostDirectoryTransaction tx = S2AHostFileSystem.Transaction;
            Check(tx is AndroidDirectoryTransaction, "actual AOT registration", ref count);
            string root = Path.Combine(parent, "managed-owned");
            Check(!Directory.Exists(root), "fresh fixture", ref count);
            Directory.CreateDirectory(root);
            Check(tx.Supported(root), "supported app-private volume", ref count);
            Check(Directory.GetFileSystemEntries(root).Length == 0, "probe cleanup", ref count);
            string committed = Path.Combine(root, "committed"), working = Path.Combine(root, "working"), fresh = Path.Combine(root, "fresh");
            Directory.CreateDirectory(committed);
            File.WriteAllBytes(Path.Combine(committed, "payload"), new byte[] { 1, 2, 3 });
            Check(tx.CloneTree(committed, working) == 0, "clone committed to working", ref count);
            byte[] next = new byte[] { 9, 8, 7, 6, 5 };
            File.WriteAllBytes(Path.Combine(working, "payload"), next);
            Check(tx.CloneTree(working, fresh) == 0, "clone candidate", ref count);
            Check(tx.ReadToken(fresh, Span<byte>.Empty, out int n) == 0 && n == 0, "missing token", ref count);
            byte[] token = new byte[16];
            for (int i = 0; i < token.Length; ++i) token[i] = (byte)(i + 17);
            Check(tx.WriteToken(fresh, token) == 0, "write token", ref count);
            Check(tx.ReadToken(fresh, new byte[15], out n) == 34 && n == 16, "ERANGE actual length", ref count);
            Check(tx.WriteToken(fresh, new byte[65]) == 22, "oversize token rejected", ref count);
            Check(tx.Exchange(fresh, committed) == 0, "exchange complete versions", ref count);
            Check(tx.SyncDirectory(root) == 0, "sync namespace", ref count);
            byte[] actual = new byte[16];
            Check(tx.ReadToken(committed, actual, out n) == 0 && n == token.Length && actual.AsSpan().SequenceEqual(token), "token follows new version", ref count);
            Check(tx.OpenRead(Path.Combine(committed, "payload"), out var handle) == 0 && handle is not null && !handle.IsInvalid, "reopen committed payload", ref count);
            using (var stream = new FileStream(handle, FileAccess.Read))
            {
                byte[] read = new byte[next.Length];
                stream.ReadExactly(read);
                Check(read.AsSpan().SequenceEqual(next) && stream.ReadByte() == -1, "reopened bytes exact", ref count);
            }
            Check(handle.IsClosed, "FileStream owns descriptor", ref count);
            Check(File.ReadAllBytes(Path.Combine(fresh, "payload")).AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }), "old version intact", ref count);
            string link = Path.Combine(root, "link");
            File.CreateSymbolicLink(link, Path.Combine(committed, "payload"));
            Check(tx.OpenRead(link, out var rejected) != 0 && rejected is null, "link refused", ref count);
            Check(tx.OpenRead(committed, out rejected) != 0 && rejected is null, "directory refused", ref count);
            Check(tx.OpenRead("relative", out rejected) == 22 && rejected is null, "relative path refused", ref count);
            Check(tx.ReadToken("/bad\0path", actual, out n) == 22 && n == 0, "NUL path refused", ref count);
            Directory.Delete(root, recursive: true);
            *checks = count;
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"managed probe failed after {count} checks: {error.GetType().Name}: {error.Message}");
            *checks = count;
            return 1;
        }
    }

    private static void Check(bool ok, string label, ref int count)
    {
        ++count;
        if (!ok) throw new IOException(label);
    }
}
