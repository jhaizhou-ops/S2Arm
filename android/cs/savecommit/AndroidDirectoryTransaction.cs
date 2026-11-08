// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Ryujinx.HLE.FileSystem;
using Microsoft.Win32.SafeHandles;

namespace S2A.Android.SaveCommit;

// The shared save-commit state machine owns sequencing and namespace serialization.
// This adapter does not register itself, cache capability results, or retain buffers.
public sealed unsafe partial class AndroidDirectoryTransaction : IHostDirectoryTransaction
{
    // Android/Linux errno values; these are returned directly, not Marshal.GetLastPInvokeError().
    private const int Eio = 5;
    private const int Enomem = 12;
    private const int Einval = 22;
    private const int Enosys = 38;
    private const int Eoverflow = 75;

    public bool Supported(string directory)
    {
        if (!ValidPath(directory)) return false;
        try { return NativeSupported(directory) == 1; }
        catch (Exception exception) when (BoundaryFailure(exception)) { return false; }
    }

    public int CloneTree(string source, string destination)
    {
        if (!ValidPath(source) || !ValidPath(destination)) return Einval;
        try { return Result(NativeCloneTree(source, destination)); }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
    }

    public int Exchange(string a, string b)
    {
        if (!ValidPath(a) || !ValidPath(b)) return Einval;
        try { return Result(NativeExchange(a, b)); }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
    }

    public int WriteToken(string directory, ReadOnlySpan<byte> value)
    {
        if (!ValidPath(directory) || value.Length > S2AHostFileSystem.TokenMax) return Einval;
        try
        {
            fixed (byte* pointer = value)
                return Result(NativeWriteToken(directory, pointer, (nuint)value.Length));
        }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
    }

    public int ReadToken(string directory, Span<byte> buffer, out int length)
    {
        length = 0;
        if (!ValidPath(directory)) return Einval;
        try
        {
            nuint nativeLength = 0;
            int result;
            fixed (byte* pointer = buffer)
                result = Result(NativeReadToken(directory, pointer, (nuint)buffer.Length, &nativeLength));
            // An external/corrupt fallback file can exceed Int32.MaxValue. There
            // is no representable actual length: return EOVERFLOW with length 0.
            if (nativeLength > int.MaxValue) return Eoverflow;
            length = (int)nativeLength;
            return result;
        }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
    }

    public int SyncDirectory(string directory)
    {
        if (!ValidPath(directory)) return Einval;
        try { return Result(NativeSyncDirectory(directory)); }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
    }

    public int OpenRead(string path, out SafeFileHandle handle)
    {
        handle = null!; // The approved contract requires null, not an invalid wrapper.
        if (!ValidPath(path)) return Einval;
        int descriptor = -1;
        try
        {
            // Resolve cleanup before acquiring ownership: an older/incomplete
            // library must fail ENOSYS without first handing us an unclosable fd.
            // close(-1) has no side effects; its errno is intentionally ignored.
            _ = NativeCloseFd(-1);
            int result = Result(NativeOpenRead(path, &descriptor));
            if (result != 0) return result;
            if (descriptor < 0) return Eio;
            // Unix SafeFileHandle treats fd 0 as valid. Ownership passes only
            // after construction succeeds; a wrapping failure closes below.
            handle = new SafeFileHandle((IntPtr)descriptor, ownsHandle: true);
            descriptor = -1;
            return 0;
        }
        catch (Exception exception) when (BoundaryFailure(exception)) { return Error(exception); }
        finally
        {
            if (descriptor >= 0) NativeCloseFd(descriptor);
        }
    }

    private static bool ValidPath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path[0] != '/') return false;
        // Reject NUL truncation and malformed UTF-16 instead of allowing UTF-8
        // replacement to operate on a different host path. Do not canonicalize
        // paths: native O_NOFOLLOW must see the final component, including links.
        for (int i = 0; i < path.Length; i++)
        {
            char value = path[i];
            if (value == '\0') return false;
            if (char.IsHighSurrogate(value))
            {
                if (++i == path.Length || !char.IsLowSurrogate(path[i])) return false;
            }
            else if (char.IsLowSurrogate(value)) return false;
        }
        return true;
    }

    // Fail closed on ABI violations rather than presenting a negative status as
    // a valid errno. Binding and normal marshalling failures stay at this boundary.
    private static int Result(int result) => result >= 0 ? result : Eio;
    private static bool BoundaryFailure(Exception exception) => exception is
        DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or
        MarshalDirectiveException or NotSupportedException or ArgumentException or OutOfMemoryException;
    private static int Error(Exception exception) => exception switch
    {
        OutOfMemoryException => Enomem,
        ArgumentException => Einval,
        _ => Enosys,
    };

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_supported", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeSupported(string directory);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_clone_tree", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeCloneTree(string source, string destination);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_exchange", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeExchange(string a, string b);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_write_token", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeWriteToken(string directory, byte* value, nuint length);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_read_token", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeReadToken(string directory, byte* buffer, nuint capacity, nuint* length);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_sync_directory", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeSyncDirectory(string directory);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_open_read", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeOpenRead(string path, int* descriptor);

    [LibraryImport("s2a_native", EntryPoint = "s2a_savecommit_close_fd")]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static partial int NativeCloseFd(int descriptor);

}
