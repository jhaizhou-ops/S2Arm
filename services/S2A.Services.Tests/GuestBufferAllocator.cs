using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // HIPC X/A/B descriptors encode 39-bit guest addresses. Intel malloc may return
    // higher host addresses; never send a truncated pointer to the real service parser.
    internal static unsafe class GuestBufferAllocator
    {
        private const ulong Limit = 1UL << 39;
        private const nuint Alignment = 0x4000;
        private static readonly bool UseMapping = OperatingSystem.IsMacOS() && RuntimeInformation.ProcessArchitecture == Architecture.X64;
        private static readonly Dictionary<nint, (nint Raw, nuint Length)> Mappings = new();

        [DllImport("/usr/lib/libSystem.B.dylib", SetLastError = true)]
        private static extern nint mmap(nint address, nuint length, int protection, int flags, int fd, nint offset);
        [DllImport("/usr/lib/libSystem.B.dylib", SetLastError = true)]
        private static extern int munmap(nint address, nuint length);

        internal static bool FitsDescriptor(ulong address, ulong size) =>
            address != 0 && address < Limit && size != 0 && size <= Limit - address;

        internal static byte* Alloc(int size)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(size);
            if (!UseMapping)
            {
                byte* pointer = (byte*)NativeMemory.AlignedAlloc((nuint)size, Alignment);
                if (pointer == null) throw new OutOfMemoryException("Guest fixture allocation failed.");
                if (FitsDescriptor((ulong)pointer, (ulong)size)) return pointer;
                NativeMemory.AlignedFree(pointer);
                throw new InvalidOperationException("Guest fixture allocation exceeds the 39-bit HIPC address range.");
            }

            // Anonymous mmap chooses an unused range; no MAP_FIXED, address truncation,
            // or replacement of an existing mapping. Keep the raw range for paired free.
            nuint length = checked((nuint)size + Alignment - 1);
            nint raw = mmap(0, length, 3 /* READ | WRITE */, 0x1002 /* PRIVATE | ANON */, -1, 0);
            if (raw == -1) throw new InvalidOperationException($"Guest fixture mmap failed: {Marshal.GetLastPInvokeError()}.");
            ulong aligned = checked((ulong)raw + (ulong)Alignment - 1) & ~((ulong)Alignment - 1);
            if (!FitsDescriptor(aligned, (ulong)size))
            {
                Unmap(raw, length);
                throw new InvalidOperationException("Guest fixture mapping exceeds the 39-bit HIPC address range.");
            }
            lock (Mappings) Mappings.Add((nint)aligned, (raw, length));
            return (byte*)aligned;
        }

        internal static void Free(byte* pointer)
        {
            if (pointer == null) return;
            if (!UseMapping)
            {
                NativeMemory.AlignedFree(pointer);
                return;
            }
            (nint Raw, nuint Length) mapping;
            lock (Mappings)
                if (!Mappings.Remove((nint)pointer, out mapping))
                    throw new InvalidOperationException("Unknown guest fixture mapping.");
            Unmap(mapping.Raw, mapping.Length);
        }

        private static void Unmap(nint raw, nuint length)
        {
            if (munmap(raw, length) != 0)
                throw new InvalidOperationException($"Guest fixture munmap failed: {Marshal.GetLastPInvokeError()}.");
        }
    }
}
