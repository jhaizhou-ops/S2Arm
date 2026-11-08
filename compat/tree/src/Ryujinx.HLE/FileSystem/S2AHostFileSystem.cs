using System;

namespace Ryujinx.HLE.FileSystem
{
    // S2Arm 平台 adapter（P6 存储提交，签名定稿见 #1072）：存档事务（S2ASaveCommit.cs）与存档迁移（services SaveTransfer，#211）要的宿主存储原语。
    // 事务逻辑（工作目录、提交、记号）留在共用的 S2ASaveCommit；平台只实现下面这些原语，由平台装配在 Boot 之前登记。
    // 没登记 = 不启用事务、存档走 LibHac 原路（打一行红）。实现必须无状态、线程安全（FS 服务线程上不同存档并发调）、不抛异常，一律返回 0 / errno；路径都是宿主绝对路径。
    public interface IHostDirectoryTransaction
    {
        // 这个目录所在的卷能不能做本事务：挂载时问一次；false 时走 LibHac 原路。可在该卷建、删自己的探测目录（.s2a_probe_<pid>_<随机>），返回前清干净；任何失败都返回 false
        bool Supported(string directory);
        // 把整棵目录 source 复制或克隆到 destination（destination 必须不存在）。失败时实现负责清理，destination 不存在。
        //   返回 0 时树里的文件、各级目录与 destination 本身已落盘（destination 在父目录里的目录项由调用方对父目录 SyncDirectory）
        int CloneTree(string source, string destination);
        // 原子交换两个目录名：任何时刻被杀，两个名字下都是完整的某一版
        int Exchange(string a, string b);
        // 目录上的小记号（≤ 64 字节）：超长 EINVAL、不写。返回 0 时记号已落盘
        int WriteToken(string directory, ReadOnlySpan<byte> value);
        // 没有记号：返回 0、length = 0；缓冲不够：返回 ERANGE、length = 实际长度（同 getxattr）
        int ReadToken(string directory, Span<byte> value, out int length);
        // 目录项落盘：在 directory 里新建 / 改名 / 删除之后调，只落这个目录本身、不递归；不跟随符号链接（是链接返回非 0 errno：Darwin 带 O_DIRECTORY 时为 ENOTDIR）
        int SyncDirectory(string directory);
        // 安全只读打开一个普通文件（存档迁移读归档 / 存档文件用，#211）：不跟随符号链接、不因 FIFO / 设备文件阻塞（O_NOFOLLOW | O_NONBLOCK 打开后核是普通文件）；
        //   成功返回 0、handle 归调用方（可交给 FileStream）；是链接 / 不是普通文件 / 打不开返回非 0 errno、handle 为 null
        int OpenRead(string path, out Microsoft.Win32.SafeHandles.SafeFileHandle handle);
    }

    public static class S2AHostFileSystem
    {
        // 平台装配在 Host.Boot 之前设一次，之后只读
        public static IHostDirectoryTransaction Transaction { get; set; }

        public const int TokenMax = 64;
    }
}
