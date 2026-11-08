using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using static Ryujinx.Memory.MemoryManagerUnixHelper;

namespace Ryujinx.Memory
{
    [SupportedOSPlatform("linux")]
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    static partial class MemoryManagementUnix
    {
        private static readonly ConcurrentDictionary<nint, ulong> _allocations = new();

        public static nint Allocate(ulong size, bool forJit)
        {
            return AllocateInternal(size, MmapProts.PROT_READ | MmapProts.PROT_WRITE, forJit);
        }

        public static nint Reserve(ulong size, bool forJit)
        {
            return AllocateInternal(size, MmapProts.PROT_NONE, forJit);
        }

        public static nint ReserveShared(ulong size)
        {
            return AllocateInternal(size, MmapProts.PROT_NONE, forJit: false, shared: true);
        }

        private static nint AllocateInternal(ulong size, MmapProts prot, bool forJit, bool shared = false)
        {
            MmapFlags flags = MmapFlags.MAP_ANONYMOUS;

            if (shared)
            {
                flags |= MmapFlags.MAP_SHARED;
            }
            else
            {
                flags |= MmapFlags.MAP_PRIVATE;
            }

            if (prot == MmapProts.PROT_NONE)
            {
                flags |= MmapFlags.MAP_NORESERVE;
            }

            ApplyAllocationPlatformFlags(ref flags, ref prot, forJit);

            nint ptr;

            if (!TryAllocateS2A(size, prot, forJit, shared, out ptr))
            {
                ptr = Mmap(nint.Zero, size, prot, flags, -1, 0);
            }

            if (ptr == nint.Zero)
            {
                ptr = MAP_FAILED;
            }

            if (ptr == MAP_FAILED)
            {
                throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
            }

            try
            {
                if (!_allocations.TryAdd(ptr, size))
                {
                    // The mapping cannot escape without an owner in the allocation table.
                    throw new InvalidOperationException();
                }
            }
            catch
            {
                munmap(ptr, size);
                throw;
            }

            return ptr;
        }

        public static void Commit(nint address, ulong size, bool forJit)
        {
            MmapProts prot = MmapProts.PROT_READ | MmapProts.PROT_WRITE;

            ApplyCommitPlatformProt(ref prot, forJit);

            if (mprotect(address, size, prot) != 0)
            {
                throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
            }
        }

        public static void Decommit(nint address, ulong size)
        {
            // Must be writable for madvise to work properly.
            if (mprotect(address, size, MmapProts.PROT_READ | MmapProts.PROT_WRITE) != 0)
            {
                throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
            }

            if (madvise(address, size, MADV_REMOVE) != 0)
            {
                throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
            }

            if (mprotect(address, size, MmapProts.PROT_NONE) != 0)
            {
                throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
            }
        }

        public static bool Reprotect(nint address, ulong size, MemoryPermission permission)
        {
            return mprotect(address, size, GetProtection(permission)) == 0;
        }

        private static MmapProts GetProtection(MemoryPermission permission)
        {
            return permission switch
            {
                MemoryPermission.None => MmapProts.PROT_NONE,
                MemoryPermission.Read => MmapProts.PROT_READ,
                MemoryPermission.ReadAndWrite => MmapProts.PROT_READ | MmapProts.PROT_WRITE,
                MemoryPermission.ReadAndExecute => MmapProts.PROT_READ | MmapProts.PROT_EXEC,
                MemoryPermission.ReadWriteExecute => MmapProts.PROT_READ | MmapProts.PROT_WRITE | MmapProts.PROT_EXEC,
                MemoryPermission.Execute => MmapProts.PROT_EXEC,
                _ => throw new MemoryProtectionException(permission),
            };
        }

        public static bool Free(nint address)
        {
            if (_allocations.TryRemove(address, out ulong size))
            {
                return Unmap(address, size);
            }

            return false;
        }

        public static bool Unmap(nint address, ulong size)
        {
            if (TryUnmapS2A(address, size))
            {
                return true;
            }

            return munmap(address, size) == 0;
        }

        public static nint CreateSharedMemory(ulong size, bool reserve)
        {
            int fd = CreateAnonymousSharedFd();

            if (ftruncate(fd, (nint)size) != 0)
            {
                // S2Arm: close the fd before throwing; the caller never gets it to DestroySharedMemory (audit 11-01 P2-31).
                string error = Marshal.GetLastPInvokeErrorMessage();
                close(fd);
                throw new SystemException(error);
            }

            return fd;
        }

        public static void DestroySharedMemory(nint handle)
        {
            close(handle.ToInt32());
        }

        public static nint MapSharedMemory(nint handle, ulong size)
        {
            return Mmap(nint.Zero, size, MmapProts.PROT_READ | MmapProts.PROT_WRITE, MmapFlags.MAP_SHARED, handle.ToInt32(), 0);
        }

        public static void UnmapSharedMemory(nint address, ulong size)
        {
            munmap(address, size);
        }

        public static void MapView(nint sharedMemory, ulong srcOffset, nint location, ulong size)
        {
            Mmap(location, size, MmapProts.PROT_READ | MmapProts.PROT_WRITE, MmapFlags.MAP_FIXED | MmapFlags.MAP_SHARED, sharedMemory.ToInt32(), (long)srcOffset);
        }

        public static void UnmapView(nint location, ulong size)
        {
            Mmap(location, size, MmapProts.PROT_NONE, MmapFlags.MAP_FIXED | MmapFlags.MAP_PRIVATE | MmapFlags.MAP_ANONYMOUS | MmapFlags.MAP_NORESERVE, -1, 0);
        }
    }
}
