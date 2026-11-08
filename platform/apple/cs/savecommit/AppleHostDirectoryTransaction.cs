using Ryujinx.HLE.FileSystem;
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace S2A.Apple.SaveCommit
{
    // 存档事务的宿主目录原语，苹果实现（平台 adapter P6，接口见 Ryujinx.HLE/FileSystem/S2AHostFileSystem.cs、#1072）：
    // APFS 的 clonefile（写时复制、不拷字节）/ renamex_np(RENAME_SWAP) / 扩展属性记号 / F_FULLFSYNC 目录落盘。
    // 原先写在共用的 S2ASaveCommit.cs 里（补丁 0242 / 20261029-0045），按 IsMacOS() || IsIOS() 开；搬到这里由苹果装配登记。
    // 无状态、线程安全、不抛异常，一律返回 0 / errno
    public sealed unsafe partial class AppleHostDirectoryTransaction : IHostDirectoryTransaction
    {
        private const uint RenameSwap = 0x2;           // renamex_np RENAME_SWAP
        private const int ONonBlock = 0x4, ONoFollow = 0x100, ODirectory = 0x100000, FFullFsync = 51, SIfMt = 0xF000, SIfReg = 0x8000;
        private const int EIo = 5, EInval = 22, ENotTy = 25, ERange = 34, ENotSup = 45, ENoAttr = 93;
        private const string TokenAttr = "com.s2arm.save.commit";

        [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
        private static partial int clonefile(string src, string dst, uint flags);

        [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
        private static partial int renamex_np(string from, string to, uint flags);

        [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
        private static partial int setxattr(string path, string name, byte* value, nuint size, uint position, int options);

        [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
        private static partial nint getxattr(string path, string name, byte* value, nuint size, uint position, int options);

        [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
        private static partial int open(string path, int flags);

        [LibraryImport("libc", SetLastError = true)]
        private static partial int fcntl(int fd, int cmd, int arg);

        [LibraryImport("libc", SetLastError = true)]
        private static partial int fsync(int fd);

        [LibraryImport("libc", SetLastError = true)]
        private static partial int fstat(int fd, byte* st);   // arm64 Darwin 只有 64 位 inode 版 struct stat：st_mode 是偏移 4 的 uint16

        [LibraryImport("libc", SetLastError = true)]
        private static partial int close(int fd);

        private static int Err() => Marshal.GetLastPInvokeError();

        // 在该卷上实测一遍克隆 + 交换 + 记号；探测目录返回前删净，任何一步失败（含清理）都返回 false
        public bool Supported(string directory)
        {
            string a = Path.Combine(directory, $".s2a_probe_{Environment.ProcessId}_{Random.Shared.Next():x8}"), b = a + "_c";
            bool ok = false;

            try
            {
                Directory.CreateDirectory(a);
                ok = CloneTree(a, b) == 0 && Exchange(a, b) == 0 && WriteToken(a, stackalloc byte[] { 1 }) == 0;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                ok = false;
            }

            try
            {
                if (Directory.Exists(a)) Directory.Delete(a, true);
                if (Directory.Exists(b)) Directory.Delete(b, true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }

            return ok && !Directory.Exists(a) && !Directory.Exists(b);
        }

        // 克隆后把新树落了盘再返回（接口约定：返回 0 时目标树已落盘）：clonefile 只改元数据、不刷盘（11-01 18:00 全量审计 P1-50）。
        //   树里各文件、各级子目录 fsync，最后对树根 F_FULLFSYNC 让盘把缓存一起写下；任一步失败删掉目标、回 errno
        public int CloneTree(string source, string destination)
        {
            if (clonefile(source, destination, 0) != 0) return Err();

            int e = SyncTree(destination);

            if (e == 0) e = SyncDirectory(destination);

            if (e != 0)
            {
                try
                {
                    Directory.Delete(destination, true);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                }
            }

            return e;
        }

        private static readonly EnumerationOptions AllEntries = new() { AttributesToSkip = 0, IgnoreInaccessible = false, RecurseSubdirectories = false };

        // 树里的普通文件与子目录逐个 fsync（符号链接不跟随，链接本身随所在目录落盘；FIFO 不阻塞）；树根留给调用方 F_FULLFSYNC
        private static int SyncTree(string directory)
        {
            try
            {
                foreach (FileSystemInfo entry in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", AllEntries))
                {
                    if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) continue;

                    bool isDir = entry is DirectoryInfo;
                    int e = isDir ? SyncTree(entry.FullName) : 0;

                    if (e == 0) e = FsyncPath(entry.FullName, isDir ? ODirectory | ONoFollow : ONoFollow | ONonBlock);

                    if (e != 0) return e;
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return EIo;
            }

            return 0;
        }

        private static int FsyncPath(string path, int flags)
        {
            // O_RDONLY = 0
            int fd = open(path, flags);

            if (fd < 0) return Err();

            int e = fsync(fd) == 0 ? 0 : Err();
            int c = close(fd) == 0 ? 0 : Err();

            return e != 0 ? e : c;
        }

        public int Exchange(string a, string b) => renamex_np(a, b, RenameSwap) == 0 ? 0 : Err();

        public int WriteToken(string directory, ReadOnlySpan<byte> value)
        {
            if (value.Length > S2AHostFileSystem.TokenMax) return EInval;

            fixed (byte* p = value)
            {
                if (setxattr(directory, TokenAttr, p, (nuint)value.Length, 0, 0) != 0) return Err();
            }

            // 记号在目录自己的节点上：落了盘再返回（接口约定；11-01 18:00 全量审计 P1-50：原先只 setxattr、不刷盘）
            return SyncDirectory(directory);
        }

        public int ReadToken(string directory, Span<byte> value, out int length)
        {
            nint n;

            fixed (byte* p = value)
            {
                n = getxattr(directory, TokenAttr, p, (nuint)value.Length, 0, 0);
            }

            if (n >= 0)
            {
                // 空缓冲钉成空指针，Darwin getxattr(…, NULL, 0) 只报属性长度、不报 ERANGE（11-01 审计 P2-59）：长度装不下按接口约定回 ERANGE、length = 实际长度
                length = (int)n;
                return n > value.Length ? ERange : 0;
            }

            int e = Err();
            length = 0;

            if (e == ENoAttr) return 0;

            if (e == ERange)
            {
                nint need = getxattr(directory, TokenAttr, null, 0, 0, 0);
                length = need > 0 ? (int)need : 0;
            }

            return e;
        }

        public int SyncDirectory(string directory)
        {
            int fd = open(directory, ODirectory | ONoFollow);   // O_RDONLY = 0

            if (fd < 0) return Err();

            return FlushAndClose(fd, static f => fcntl(f, FFullFsync, 0) == 0 ? 0 : Err(), static f => fsync(f) == 0 ? 0 : Err(), static f => close(f) == 0 ? 0 : Err());
        }

        // F_FULLFSYNC 落盘再关 fd，返回第一个错误（各步返回 0 / errno；拆出来是为单测注入失败）。只有卷不支持 F_FULLFSYNC（ENOTSUP / EINVAL / ENOTTY）才退回 fsync、
        //   结果取 fsync 的；EIO 等真刷盘失败原样返回；close 的失败也算（11-01 全量审计 P1-53：原先任何 F_FULLFSYNC 失败都退回 fsync，fsync 成功就报 0，close 不看）
        public static int FlushAndClose(int fd, Func<int, int> fullFsync, Func<int, int> plainFsync, Func<int, int> closeFd)
        {
            int e = fullFsync(fd);

            if (e is ENotSup or EInval or ENotTy) e = plainFsync(fd);

            int c = closeFd(fd);

            return e != 0 ? e : c;
        }

        public int OpenRead(string path, out Microsoft.Win32.SafeHandles.SafeFileHandle handle)
        {
            handle = null;
            int fd = open(path, ONoFollow | ONonBlock);   // O_RDONLY = 0；FIFO 不在这里卡住，链接直接失败

            if (fd < 0) return Err();

            byte* st = stackalloc byte[256];

            if (fstat(fd, st) != 0)
            {
                int e = Err();
                close(fd);
                return e;
            }

            if ((*(ushort*)(st + 4) & SIfMt) != SIfReg)
            {
                close(fd);
                return EInval;   // FIFO / 设备 / 目录：不是普通文件
            }

            handle = new Microsoft.Win32.SafeHandles.SafeFileHandle(fd, ownsHandle: true);

            return 0;
        }
    }
}
