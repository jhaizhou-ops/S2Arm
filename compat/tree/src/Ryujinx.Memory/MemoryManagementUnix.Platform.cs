using System;
using System.Runtime.InteropServices;
using static Ryujinx.Memory.MemoryManagerUnixHelper;

namespace Ryujinx.Memory
{
    static partial class MemoryManagementUnix
    {
        // Darwin 10.14+ 的 JIT 规则：Allocate 与 Commit 共用同一条判定。
        // 仅按真实平台条件收口，不把「Apple 平台」简化成放行，iOS 不因此额外开放可执行权限。
        private static bool IsDarwinJit(bool forJit) => OperatingSystem.IsMacOSVersionAtLeast(10, 14) && forJit;   // 平台例外：#1067 MemoryManagementUnix 源码分区，合并两处上游 IsMacOSVersionAtLeast 判断

        private static void ApplyAllocationPlatformFlags(ref MmapFlags flags, ref MmapProts prot, bool forJit)
        {
            if (!IsDarwinJit(forJit))
            {
                return;
            }

            flags |= MmapFlags.MAP_JIT_DARWIN;

            if (prot == (MmapProts.PROT_READ | MmapProts.PROT_WRITE))
            {
                prot |= MmapProts.PROT_EXEC;
            }
        }

        private static void ApplyCommitPlatformProt(ref MmapProts prot, bool forJit)
        {
            if (IsDarwinJit(forJit))
            {
                prot |= MmapProts.PROT_EXEC;
            }
        }

        // 匿名共享 fd 创建：Darwin 走 shm_open + shm_unlink，Linux 走 /dev/shm 的 mkstemp + unlink。
        // fd 在成功返回前归这里：拿到 fd 之后的失败路径（shm_unlink / unlink）先取错误文本、关 fd 再抛（11-01 审计 P2-31：原先不关，一次失败漏一个 fd）。
        private static unsafe int CreateAnonymousSharedFd()
        {
            int fd;

            if (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
            {
                byte[] memName = "Ryujinx-XXXXXX"u8.ToArray();

                fixed (byte* pMemName = memName)
                {
                    fd = shm_open((nint)pMemName, 0x2 | 0x200 | 0x800 | 0x400, 384); // O_RDWR | O_CREAT | O_EXCL | O_TRUNC, 0600
                    if (fd == -1)
                    {
                        throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
                    }

                    if (shm_unlink((nint)pMemName) != 0)
                    {
                        string error = Marshal.GetLastPInvokeErrorMessage();
                        close(fd);
                        throw new SystemException(error);
                    }
                }
            }
            else
            {
                byte[] fileName = "/dev/shm/Ryujinx-XXXXXX"u8.ToArray();

                fixed (byte* pFileName = fileName)
                {
                    fd = mkstemp((nint)pFileName);
                    if (fd == -1)
                    {
                        throw new SystemException(Marshal.GetLastPInvokeErrorMessage());
                    }

                    if (unlink((nint)pFileName) != 0)
                    {
                        string error = Marshal.GetLastPInvokeErrorMessage();
                        close(fd);
                        throw new SystemException(error);
                    }
                }
            }

            return fd;
        }
    }
}
