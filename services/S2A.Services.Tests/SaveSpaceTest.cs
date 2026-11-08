using System;
using System.Collections.Generic;
using System.IO;

namespace S2A.Services.Tests
{
    // 存档空间（11-04 Minecraft「出错了」）：存档文件系统的 GetFreeSpaceSize / GetTotalSpaceSize 要按存档自己的大小答，
    //   不是宿主磁盘。真机上存档是定长镜像：总量 = 建档大小（附加数据 DataSize）或 am ExtendSaveData 扩到的大小，剩余 = 总量 − 已用。
    //   旧代码原样转给宿主盘（本机约 316 GB），Minecraft 建世界前问剩余空间拿到它就不建世界目录、报「出错了」。
    //   直接在事务层（S2ASaveTransaction）上测，底层是可设宿主剩余 / 总量与附加数据的假存档文件系统；期望全部按真机语义手算
    public static partial class Program
    {
        private sealed class SpaceFakeSaveFs : LibHac.FsSystem.ISaveDataFileSystem
        {
            public long HostFree, HostTotal;
            public LibHac.Fs.SaveDataExtraData Extra;
            protected override LibHac.Result DoGetFreeSpaceSize(out long freeSpace, ref readonly LibHac.Fs.Path path) { freeSpace = HostFree; return LibHac.Result.Success; }
            protected override LibHac.Result DoGetTotalSpaceSize(out long totalSpace, ref readonly LibHac.Fs.Path path) { totalSpace = HostTotal; return LibHac.Result.Success; }
            public override LibHac.Result ReadExtraData(out LibHac.Fs.SaveDataExtraData extraData) { extraData = Extra; return LibHac.Result.Success; }
            protected override LibHac.Result DoCreateFile(ref readonly LibHac.Fs.Path path, long size, LibHac.Fs.Fsa.CreateFileOptions option) => LibHac.Result.Success;
            protected override LibHac.Result DoCleanDirectoryRecursively(ref readonly LibHac.Fs.Path path) => LibHac.Result.Success;
            protected override LibHac.Result DoCommit() => LibHac.Result.Success;
            protected override LibHac.Result DoCreateDirectory(ref readonly LibHac.Fs.Path path) => LibHac.Result.Success;
            protected override LibHac.Result DoDeleteDirectory(ref readonly LibHac.Fs.Path path) => LibHac.Result.Success;
            protected override LibHac.Result DoDeleteDirectoryRecursively(ref readonly LibHac.Fs.Path path) => LibHac.Result.Success;
            protected override LibHac.Result DoDeleteFile(ref readonly LibHac.Fs.Path path) => LibHac.Result.Success;
            protected override LibHac.Result DoGetEntryType(out LibHac.Fs.DirectoryEntryType entryType, ref readonly LibHac.Fs.Path path) { entryType = default; return LibHac.Result.Success; }
            protected override LibHac.Result DoOpenDirectory(ref LibHac.Common.UniqueRef<LibHac.Fs.Fsa.IDirectory> outDirectory, ref readonly LibHac.Fs.Path path, LibHac.Fs.Fsa.OpenDirectoryMode mode) => LibHac.Result.Success;
            protected override LibHac.Result DoOpenFile(ref LibHac.Common.UniqueRef<LibHac.Fs.Fsa.IFile> outFile, ref readonly LibHac.Fs.Path path, LibHac.Fs.OpenMode mode) => LibHac.Result.Success;
            protected override LibHac.Result DoRenameDirectory(ref readonly LibHac.Fs.Path currentPath, ref readonly LibHac.Fs.Path newPath) => LibHac.Result.Success;
            protected override LibHac.Result DoRenameFile(ref readonly LibHac.Fs.Path currentPath, ref readonly LibHac.Fs.Path newPath) => LibHac.Result.Success;
            public override LibHac.Result CommitExtraData(bool updateTimeStamp) => LibHac.Result.Success;
            public override bool IsSaveDataFileSystemCacheEnabled() => false;
            public override void RegisterExtraDataAccessorObserver(LibHac.FsSystem.ISaveDataExtraDataAccessorObserver observer, LibHac.Fs.SaveDataSpaceId spaceId, ulong saveDataId) { }
            public override LibHac.Result RollbackOnlyModified() => LibHac.Result.Success;
            public override LibHac.Result WriteExtraData(in LibHac.Fs.SaveDataExtraData extraData) => LibHac.Result.Success;
        }

        [SoloTest("--save-space")]
        private static int SaveSpace()
        {
            const ulong Program = 0x0100D71004694000, OtherProgram = 0x0100000000010000;
            const long Mib16 = 16 * 1024 * 1024, Ext288 = 0x12000000, HostFree = 339302416384, HostTotal = 2000398934016, Used = 100000;
            List<(string N, string E, string A)> rows = new();

            string root = Path.Combine(Path.GetTempPath(), $"s2a_save_space_{Environment.ProcessId}");
            if (Directory.Exists(root)) Directory.Delete(root, true);

            // 一棵存档目录：工作目录 1/ 里两个文件共 Used 字节（一个在子目录里，已用要按整棵树算）
            string NewSave(string name)
            {
                string d = Path.Combine(root, name);
                Directory.CreateDirectory(Path.Combine(d, "1", "games"));
                File.WriteAllBytes(Path.Combine(d, "1", "a.bin"), new byte[60000]);
                File.WriteAllBytes(Path.Combine(d, "1", "games", "b.bin"), new byte[Used - 60000]);
                return d;
            }

            static LibHac.Fs.SaveDataExtraData Extra(ulong program, LibHac.Fs.SaveDataType type, ulong userLow, long dataSize)
            {
                LibHac.Fs.SaveDataExtraData e = default;
                e.Attribute.ProgramId = new LibHac.Ncm.ProgramId(program);
                e.Attribute.Type = type;
                e.Attribute.UserId = new LibHac.Fs.UserId(0, userLow);
                e.DataSize = dataSize;
                return e;
            }

            string Space(string dir, LibHac.Fs.SaveDataExtraData extra, long hostFree)
            {
                SpaceFakeSaveFs fake = new() { HostFree = hostFree, HostTotal = HostTotal, Extra = extra };
                using LibHac.Common.SharedRef<LibHac.FsSystem.ISaveDataFileSystem> baseFs = new(fake);
                var copy = LibHac.Common.SharedRef<LibHac.FsSystem.ISaveDataFileSystem>.CreateCopy(in baseFs);
                using var tx = new Ryujinx.HLE.FileSystem.S2ASaveTransaction(ref copy, dir);
                var p = new LibHac.Fs.Path();
                p.InitializeWithNormalization("/"u8).ThrowIfFailure();
                LibHac.Result rf = tx.GetFreeSpaceSize(out long free, in p);
                LibHac.Result rt = tx.GetTotalSpaceSize(out long total, in p);
                p.Dispose();
                return rf.IsSuccess() && rt.IsSuccess() ? $"{free} / {total}" : $"失败 {rf.ToStringWithName()} / {rt.ToStringWithName()}";
            }

            // am ExtendSaveData 登记扩容（经反射找：旧代码没有这个类型，用例照样编得过、按「没有」判红）
            var extend = typeof(Ryujinx.HLE.FileSystem.S2ASaveTransaction).Assembly.GetType("Ryujinx.HLE.FileSystem.S2ASaveSpace")?.GetMethod("Extend");
            string Extend(ulong program, LibHac.Fs.SaveDataType type, ulong userLow, long size)
            {
                if (extend == null) return "没有 S2ASaveSpace.Extend";
                extend.Invoke(null, new object[] { program, type, 0UL, userLow, size });
                return "";
            }

            string acc = NewSave("account");

            // 1 账户存档建档 16 MiB、没扩容：am 的 GetSaveDataSize 对游戏答 200000000（上游桩），存档至少这么大 → 总 200000000、剩 200000000 − 100000
            rows.Add(("账户存档 16 MiB 未扩容：剩余 / 总量", "199900000 / 200000000", Space(acc, Extra(Program, LibHac.Fs.SaveDataType.Account, 1, Mib16), HostFree)));

            // 2 Minecraft 实况：am ExtendSaveData 扩到 288 MiB（0x12000000 = 301989888）→ 总 301989888、剩 301989888 − 100000
            string e1 = Extend(Program, LibHac.Fs.SaveDataType.Account, 1, Ext288);
            rows.Add(("am 扩到 288 MiB 后：剩余 / 总量", "301889888 / 301989888", e1 + Space(acc, Extra(Program, LibHac.Fs.SaveDataType.Account, 1, Mib16), HostFree)));

            // 3 扩容只记在那一款那一个用户的账户存档上：别的程序、别的用户仍按 200000000
            rows.Add(("别的程序 / 别的用户不受扩容影响：剩余 / 总量",
                "199900000 / 200000000 ‖ 199900000 / 200000000",
                Space(acc, Extra(OtherProgram, LibHac.Fs.SaveDataType.Account, 1, Mib16), HostFree) + " ‖ " + Space(acc, Extra(Program, LibHac.Fs.SaveDataType.Account, 2, Mib16), HostFree)));

            // 4 缓存存储（不经 am 扩容）：按建档大小 288 MiB
            rows.Add(("缓存存储 288 MiB：剩余 / 总量", "301889888 / 301989888", Space(NewSave("cache"), Extra(Program, LibHac.Fs.SaveDataType.Cache, 0, Ext288), HostFree)));

            // 5 宿主盘只剩 50000 字节：剩余取两者小的
            rows.Add(("宿主盘只剩 50000：剩余 / 总量", "50000 / 301989888", Space(NewSave("hostfull"), Extra(Program, LibHac.Fs.SaveDataType.Cache, 0, Ext288), 50000)));

            // 6 已用超过存档大小（缓存存储建档 65536 字节、已用 100000）：剩余 0，不为负
            rows.Add(("已用超过存档大小：剩余 / 总量", "0 / 65536", Space(NewSave("over"), Extra(Program, LibHac.Fs.SaveDataType.Cache, 0, 65536), HostFree)));

            // 7 附加数据没记大小的系统存档（DataSize 0）：不知道存档多大，照旧按宿主盘
            rows.Add(("系统存档没记大小：剩余 / 总量", $"{HostFree} / {HostTotal}", Space(NewSave("system"), Extra(0, LibHac.Fs.SaveDataType.System, 0, 0), HostFree)));

            Directory.Delete(root, true);

            int bad = 0;
            foreach (var (n, e, a) in rows)
            {
                bool ok = e == a;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：期望 {e} → 真结果 {a}");
            }

            Console.WriteLine(bad == 0 ? $"存档空间：{rows.Count}/{rows.Count} 过" : $"存档空间：{bad}/{rows.Count} 不符");
            return bad == 0 ? 0 : 1;
        }
    }
}
