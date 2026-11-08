using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace S2A.Services.Tests
{
    // 存档提交事务（11-01 全量审计 N1 族：P1-6 P1-16 P1-19 P1-20 P1-53 P2-13 P2-29；18:00 审计存档族：P1-8 P1-50 P1-51 P2-22）。全部直接在事务层 / 被测函数上测，不经 IPC
    //   （IPC 上面还有别的包装层会把调用串行化，旧代码也绿，P0-2 踩过）。底层是只记建文件的假存档文件系统（Program.FakeSaveFs）、
    //   宿主目录原语是苹果实现外包一层可注入失败的 FaultTransaction。期望全部按语义手写，不跑被测实现推算
    public static partial class Program
    {
        private static int _txnCommitted;
        private static void TxnCommitted() => _txnCommitted++;

        [SoloTest("--save-commit-txn")]
        private static unsafe int SaveCommitTxn()
        {
            List<(string N, string E, string A)> rows = new();
            void Row(string n, string e, string a) => rows.Add((n, e, a));
            static void Chflags(string flag, string p) { using System.Diagnostics.Process proc = System.Diagnostics.Process.Start("/usr/bin/chflags", new[] { flag, p }); proc.WaitForExit(); }
            static string Txt(string p) => File.Exists(p) ? File.ReadAllText(p) : "无";
            const int EIO = 5;
            Red.Strict = false;
            int reds = 0;
            Red.Log = line => { reds++; Console.Error.WriteLine(line); };
            Ryujinx.HLE.S2AHooks.Red = _ => reds++;   // 事务层的红经这里出（S2ASaveTransaction.Red）

            var real = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();
            FaultTransaction fault = new(real);
            string root = Path.Combine(Path.GetTempPath(), $"s2a_txn_n1_{Environment.ProcessId}");
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.CreateDirectory(root);

            // 一棵存档目录：已提交 0/a.bin = OLD、工作 1/a.bin = NEW、ExtraData0 = E0、ExtraData1 = E1
            string NewSave(string name)
            {
                string d = Path.Combine(root, name);
                Directory.CreateDirectory(Path.Combine(d, "0")); Directory.CreateDirectory(Path.Combine(d, "1"));
                File.WriteAllText(Path.Combine(d, "0", "a.bin"), "OLD"); File.WriteAllText(Path.Combine(d, "1", "a.bin"), "NEW");
                File.WriteAllText(Path.Combine(d, "ExtraData0"), "E0"); File.WriteAllText(Path.Combine(d, "ExtraData1"), "E1");
                return d;
            }

            Ryujinx.HLE.FileSystem.S2ASaveTransaction Open(string d) => OpenWith(d, new FakeSaveFs());
            Ryujinx.HLE.FileSystem.S2ASaveTransaction OpenWith(string d, FakeSaveFs fake)
            {
                using LibHac.Common.SharedRef<LibHac.FsSystem.ISaveDataFileSystem> baseFs = new(fake);
                var copy = LibHac.Common.SharedRef<LibHac.FsSystem.ISaveDataFileSystem>.CreateCopy(in baseFs);
                return new Ryujinx.HLE.FileSystem.S2ASaveTransaction(ref copy, d);
            }

            Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;

            // P1-6 交换后目录落盘失败：期望提交报失败、已提交仍是 OLD（换回去了）、不留待写附加数据与 .s2a_new、工作目录仍是 NEW、ExtraData0 仍是 E0；
            //   落盘恢复后再提交一次：成功、已提交 NEW、ExtraData0 = E1。旧代码落盘失败只报红仍回成功、已提交 NEW → 判红
            {
                string d = NewSave("p1_6");
                var tx = Open(d);
                // 只让交换之后的落盘失败（交换前那次落盘是 P1-50 加的，失败走「已提交版本不动」，不是本条要测的换回路径）
                fault.AfterExchange = () => fault.SyncErr = EIO;
                bool ok1 = tx.Commit().IsSuccess();
                string s1 = $"{ok1} / {Txt(Path.Combine(d, "0", "a.bin"))} / {File.Exists(Path.Combine(d, ".s2a_extra_pending"))} / {Directory.Exists(Path.Combine(d, ".s2a_new"))} / {Txt(Path.Combine(d, "1", "a.bin"))} / {Txt(Path.Combine(d, "ExtraData0"))}";
                fault.SyncErr = 0;
                bool ok2 = tx.Commit().IsSuccess();
                string s2 = $"{ok2} / {Txt(Path.Combine(d, "0", "a.bin"))} / {Txt(Path.Combine(d, "ExtraData0"))}";
                tx.Dispose();
                Row("P1-6 落盘失败：提交 / 已提交 / 待写附加数据在 / .s2a_new 在 / 工作目录 / ExtraData0 ‖ 落盘恢复再提交：提交 / 已提交 / ExtraData0",
                    "False / OLD / False / False / NEW / E0 ‖ True / NEW / E1", $"{s1} ‖ {s2}");
            }

            // P1-19 回滚：开着写模式文件时拒绝（WriteModeFileNotClosed），工作目录不动；关掉后回滚成功、工作目录回到 OLD、ExtraData1 回到 E0；
            //   换出的旧工作树里放一个不可删（chflags uchg）的文件让删除失败，回滚仍算成功。旧代码：开着也换、附加数据不回、删除失败报回滚失败 → 判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = real;
                string d = NewSave("p1_19");
                string locked = Path.Combine(d, "1", "locked.bin");
                File.WriteAllText(locked, "L");
                var tx = Open(d);
                using LibHac.Common.UniqueRef<LibHac.Fs.Fsa.IFile> wf = new();
                var p0 = new LibHac.Fs.Path();
                tx.OpenFile(ref wf.Ref, in p0, LibHac.Fs.OpenMode.ReadWrite);
                LibHac.Result rOpen = tx.Rollback();
                string whileOpen = $"{(rOpen.IsSuccess() ? "成功" : rOpen == LibHac.Fs.ResultFs.WriteModeFileNotClosed.Value ? "写文件没关" : "别的失败")} / {Txt(Path.Combine(d, "1", "a.bin"))}";
                wf.Reset();
                Chflags("uchg", locked);
                int redsBefore = reds;
                bool ok = tx.Rollback().IsSuccess();
                string fresh = Path.Combine(d, ".s2a_new");
                string after = $"{ok} / {Txt(Path.Combine(d, "1", "a.bin"))} / {Txt(Path.Combine(d, "ExtraData1"))} / {Txt(Path.Combine(d, "0", "a.bin"))} / 报红 +{reds - redsBefore}";
                Chflags("nouchg", Path.Combine(fresh, "locked.bin"));
                tx.Dispose();
                Row("P1-19 回滚：开着写文件（结果 / 工作目录） ‖ 关了回滚、旧树删不掉（结果 / 工作目录 / ExtraData1 / 已提交 / 报红）",
                    "写文件没关 / NEW ‖ True / OLD / E0 / OLD / 报红 +1", $"{whileOpen} ‖ {after}");
            }

            // P2-29 读提交号失败：已提交 0/ 带提交号 T，待写附加数据 = T + 「E1new」。读提交号报 EIO 时挂载报原因（不静默成功）、待写文件留着、ExtraData0 仍 E0；
            //   读恢复后再挂载：成功、待写文件用掉、ExtraData0 = E1new。旧代码读失败当成没交换，挂载成功并删掉待写文件 → 判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;
                string d = NewSave("p2_29");
                byte[] token = new byte[16]; for (int i = 0; i < 16; i++) token[i] = (byte)(0xA0 + i);
                int wt = real.WriteToken(Path.Combine(d, "0"), token);
                string pending = Path.Combine(d, ".s2a_extra_pending");
                byte[] payload = Encoding.ASCII.GetBytes("E1new"), data = new byte[16 + payload.Length];
                token.CopyTo(data, 0); payload.CopyTo(data, 16);
                File.WriteAllBytes(pending, data);
                fault.ReadTokenErr = EIO;
                string why = Ryujinx.HLE.FileSystem.S2ASaveTransaction.Mount(d);
                string s1 = $"{(why == null ? "成功" : why.Contains("errno 5") ? "报 errno 5" : "别的原因")} / {File.Exists(pending)} / {Txt(Path.Combine(d, "ExtraData0"))}";
                fault.ReadTokenErr = 0;
                string why2 = Ryujinx.HLE.FileSystem.S2ASaveTransaction.Mount(d);
                string s2 = $"{(why2 == null ? "成功" : why2)} / {File.Exists(pending)} / {Txt(Path.Combine(d, "ExtraData0"))}";
                Row("P2-29 写提交号 ‖ 读提交号 EIO 挂载（结果 / 待写在 / ExtraData0） ‖ 恢复后挂载（结果 / 待写在 / ExtraData0）",
                    "0 ‖ 报 errno 5 / True / E0 ‖ 成功 / False / E1new", $"{wt} ‖ {s1} ‖ {s2}");
            }

            // P2-13 没走原子提交的原因对外可读（S2ASaveDataFileSystemCreator.NonAtomic，services 导出 S2A_SaveAtomicState）：本进程起始 0；
            //   卷可以时挂载不加位；平台没登记 +1；卷过不了探测 +2；挂载准备工作目录失败（克隆报 EIO）+4，且这次交给 LibHac 原路（内层 Create 调 1 次）。
            //   旧代码不记任何位 → 判红
            {
                const ulong id = 0x1234;
                string baseDir = Path.Combine(root, "p2_13");
                string sd = Path.Combine(baseDir, "bis", "user", "save", id.ToString("x16"));
                Directory.CreateDirectory(Path.Combine(sd, "0")); Directory.CreateDirectory(Path.Combine(sd, "1"));
                int v0 = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = real;
                bool okDir = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.HostDir(baseDir, LibHac.Fs.SaveDataSpaceId.User, id) == sd;
                int vOk = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = null;
                Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.HostDir(baseDir, LibHac.Fs.SaveDataSpaceId.User, id);
                int vUnreg = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;
                fault.Unsupported = true;
                Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.HostDir(baseDir, LibHac.Fs.SaveDataSpaceId.User, id);
                int vVol = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
                fault.Unsupported = false;
                fault.CloneErr = EIO;
                SaveCommitFakes.FakeCreator inner = new();
                var creator = new Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator(inner, baseDir);
                using LibHac.Common.SharedRef<LibHac.FsSystem.ISaveDataFileSystem> outFs = new();
                using LibHac.Common.SharedRef<LibHac.Fs.Fsa.IFileSystem> baseFs = new();
                creator.Create(ref outFs.Ref, in baseFs, LibHac.Fs.SaveDataSpaceId.User, id, true, false, true, false, false, false, null, false);
                int vMount = Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
                fault.CloneErr = 0;
                Row("P2-13 非原子原因位：起始 / 卷可以（目录、位） / 没登记 / 卷不行 / 挂载失败（位、内层 Create 次数）",
                    "0 / True、0 / 1 / 3 / 7、1", $"{v0} / {okDir}、{vOk} / {vUnreg} / {vVol} / {vMount}、{inner.Creates}");
            }

            // P1-20 只有游戏的账号 / 设备存档提交才打存档点：同样提交成功，非存档文件系统（无键）0 次、缓存 / 临时存储（有键非游戏存档）0 次、游戏存档 1 次。
            //   旧代码任何提交成功都打 → 3 次，判红
            {
                Ryujinx.HLE.S2AHooks.SaveCommitted = &TxnCommitted;
                int Commits(string key, bool gameSave)
                {
                    _txnCommitted = 0;
                    using LibHac.Common.SharedRef<LibHac.Fs.Fsa.IFileSystem> fs = new(new FakeSaveFs());
                    using LibHac.Common.SharedRef<LibHac.FsSrv.Sf.IFileSystem> sf = LibHac.FsSrv.Impl.FileSystemInterfaceAdapter.CreateShared(ref fs.Ref, false);
                    var copy = LibHac.Common.SharedRef<LibHac.FsSrv.Sf.IFileSystem>.CreateCopy(in sf);
                    var ipc = new Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy.IFileSystem(ref copy, key, gameSave);
                    var rc = ipc.Commit(null);
                    return rc == Ryujinx.HLE.HOS.Services.Fs.ResultCode.Success ? _txnCommitted : -1;
                }
                int none = Commits(null, false), cache = Commits("01:cache", false), game = Commits("01:game", true);
                Ryujinx.HLE.S2AHooks.SaveCommitted = null;
                Row("P1-20 提交成功后打存档点次数：非存档 / 缓存或临时存储 / 游戏存档", "0 / 0 / 1", $"{none} / {cache} / {game}");
            }

            // P1-53 苹果目录落盘（AppleHostDirectoryTransaction.FlushAndClose，各步注入 errno；Darwin EIO 5 / EBADF 9 / ENOTSUP 45 / EINVAL 22）：
            //   F_FULLFSYNC 报 EIO 不退回 fsync、原样 5（fsync 不该被调）；ENOTSUP / EINVAL 退回 fsync，fsync 成功 0、失败取 fsync 的 5；
            //   都成功但 close 报 EBADF → 9；每种情况 close 都调 1 次；真目录落盘 0。旧代码：EIO 退回 fsync 报 0、close 不看 → 判红
            {
                string Case(int full, int sync, int close)
                {
                    int fs = 0, cl = 0;
                    int r = S2A.Apple.SaveCommit.AppleHostDirectoryTransaction.FlushAndClose(-1, _ => full, _ => { fs++; return sync; }, _ => { cl++; return close; });
                    return $"{r}（fsync {fs}、close {cl}）";
                }
                string td = Path.Combine(root, "p1_53"); Directory.CreateDirectory(td);
                Row("P1-53 落盘：全量 EIO / 不支持→fsync 成功 / EINVAL→fsync EIO / close EBADF / 真目录",
                    "5（fsync 0、close 1） / 0（fsync 1、close 1） / 5（fsync 1、close 1） / 9（fsync 0、close 1） / 0",
                    $"{Case(EIO, 0, 0)} / {Case(45, 0, 0)} / {Case(22, EIO, 0)} / {Case(0, 0, 9)} / {real.SyncDirectory(td)}");
            }

            // P1-16 存档点副本读索引失败：dir 已有一份旧副本；索引第一次读就失败 → 返回 0、dir 与 dir.tmp 都不在、报红 +1。
            //   旧代码读失败当「没有更多条目」，写 user 换掉旧副本 → dir 在且只剩 user，判红
            {
                string dir = Path.Combine(root, "snap.save3");
                Directory.CreateDirectory(Path.Combine(dir, "account")); File.WriteAllText(Path.Combine(dir, "user"), "old");
                int redsBefore = reds;
                int kinds = Saves.SnapshotFrom((out long n, Span<LibHac.Fs.SaveDataInfo> infos) => { n = 0; return LibHac.Fs.ResultFs.TargetNotFound.Value; }, default, "u", dir);
                Row("P1-16 读索引失败：返回 / dir 在 / dir.tmp 在 / 报红",
                    "0 / False / False / +1", $"{kinds} / {Directory.Exists(dir)} / {Directory.Exists(dir + ".tmp")} / +{reds - redsBefore}");
            }

            // P1-8 附加数据写入与提交同锁、且跨挂载：同一棵存档开两个事务（两条挂载路径各建一个）。tx1 提交停在克隆（锁内）的 400 ms 里，
            //   另一线程经 tx2 写附加数据不能落到底层（0 次）；放行后提交成功、写附加数据成功、底层共写 1 次。旧代码：锁按实例、WriteExtraData 不进锁 → 停住时已写 1 次，判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;
                string d = NewSave("p1_8_lock");
                FakeSaveFs fake2 = new();
                var tx1 = Open(d);
                var tx2 = OpenWith(d, fake2);
                fault.CloneGate = new(false); fault.CloneEntered = new(false);
                bool okCommit = false, okWrite = false;
                System.Threading.Thread tc = new(() => okCommit = tx1.Commit().IsSuccess());
                tc.Start();
                bool entered = fault.CloneEntered.Wait(5000);
                System.Threading.Thread tw = new(() => { LibHac.Fs.SaveDataExtraData x = default; okWrite = tx2.WriteExtraData(in x).IsSuccess(); });
                tw.Start();
                System.Threading.Thread.Sleep(400);
                int during = System.Threading.Volatile.Read(ref fake2.ExtraWrites);
                fault.CloneGate.Set(); tc.Join(); tw.Join();
                fault.CloneGate = null; fault.CloneEntered = null;
                tx1.Dispose(); tx2.Dispose();
                Row("P1-8 跨挂载同锁：克隆停住 / 停住时另一挂载写附加数据已落底层次数 / 提交 / 写附加数据 / 底层共写次数",
                    "True / 0 / True / True / 1", $"{entered} / {during} / {okCommit} / {okWrite} / {fake2.ExtraWrites}");
            }

            // P1-8 没有上一份已提交附加数据：①只有 ExtraData1 = E1 时挂载，把它当成已提交（ExtraData0 = E1，同挂载时把没提交过的工作目录当成已提交）；
            //   之后 ExtraData1 改成 E1x 再回滚 → ExtraData1 回到 E1。②挂载时两份都没有（LibHac 随后新建全 0 的 ExtraData1，0x200 字节），之后写成 X 再回滚 →
            //   ExtraData1 回到 0x200 字节全 0。旧代码：挂载不建 ExtraData0、回滚不碰当前份 → 「无 / E1x ‖ X」，判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = real;
                string d = NewSave("p1_8_noextra");
                File.Delete(Path.Combine(d, "ExtraData0"));
                string why = Ryujinx.HLE.FileSystem.S2ASaveTransaction.Mount(d);
                string e0 = Txt(Path.Combine(d, "ExtraData0"));
                File.WriteAllText(Path.Combine(d, "ExtraData1"), "E1x");
                var tx = Open(d);
                bool ok1 = tx.Rollback().IsSuccess();
                string e1 = Txt(Path.Combine(d, "ExtraData1"));
                tx.Dispose();
                string d2 = NewSave("p1_8_none");
                File.Delete(Path.Combine(d2, "ExtraData0")); File.Delete(Path.Combine(d2, "ExtraData1"));
                string why2 = Ryujinx.HLE.FileSystem.S2ASaveTransaction.Mount(d2);
                File.WriteAllText(Path.Combine(d2, "ExtraData1"), "X");
                var tx2 = Open(d2);
                bool ok2 = tx2.Rollback().IsSuccess();
                string p2 = Path.Combine(d2, "ExtraData1");
                byte[] b2 = File.Exists(p2) ? File.ReadAllBytes(p2) : null;
                string e2 = b2 == null ? "无" : b2.Length == 0x200 && Array.TrueForAll(b2, v => v == 0) ? "0x200 字节全 0" : Encoding.ASCII.GetString(b2);
                tx2.Dispose();
                Row("P1-8 无上一份附加数据：挂载 / ExtraData0 / 改 E1x 回滚 / ExtraData1 ‖ 两份都没有：挂载 / 写 X 回滚 / ExtraData1",
                    "成功 / E1 / True / E1 ‖ 成功 / True / 0x200 字节全 0", $"{why ?? "成功"} / {e0} / {ok1} / {e1} ‖ {why2 ?? "成功"} / {ok2} / {e2}");
            }

            // P1-8 回滚交换后附加数据改名失败（ExtraData1 设 chflags uchg，改名覆盖它报 EPERM）：失败不留半步——文件树换回回滚前（工作目录仍 NEW）、
            //   ExtraData1 仍 E1、不留 .s2a_extra1 与 .s2a_new，回滚报失败。旧代码：报失败但工作树已是 OLD、留着 .s2a_extra1 与换出的旧树 → 判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = real;
                string d = NewSave("p1_8_swapback");
                string e1p = Path.Combine(d, "ExtraData1");
                var tx = Open(d);
                Chflags("uchg", e1p);
                bool ok = tx.Rollback().IsSuccess();
                Chflags("nouchg", e1p);
                string s = $"{ok} / {Txt(Path.Combine(d, "1", "a.bin"))} / {Txt(e1p)} / {File.Exists(Path.Combine(d, ".s2a_extra1"))} / {Directory.Exists(Path.Combine(d, ".s2a_new"))}";
                tx.Dispose();
                Row("P1-8 回滚后附加数据改名失败：回滚 / 工作目录 / ExtraData1 / .s2a_extra1 在 / .s2a_new 在",
                    "False / NEW / E1 / False / False", s);
            }

            // P1-50 落盘顺序：一次正常提交，宿主原语按调用顺序记下。期望：克隆工作目录 → 给新版本写提交号 → 交换前存档根落盘（新版本目录项 + 待写附加数据）→
            //   交换 → 交换后存档根落盘 → 读提交号 → ExtraData0 改名落盘（之后才删待写文件）。克隆与写提交号各自落盘由平台原语自己保证（接口约定）。
            //   旧代码：交换前不落盘、ExtraData0 写完不落盘就删待写文件 → 少两次 Sync，判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;
                string d = NewSave("p1_50");
                var tx = Open(d);
                fault.Ops = new(); fault.Root = d;
                bool ok = tx.Commit().IsSuccess();
                string ops = string.Join(" ", fault.Ops);
                fault.Ops = null; fault.Root = null;
                string s = $"{ok} / {Txt(Path.Combine(d, "0", "a.bin"))} / {Txt(Path.Combine(d, "ExtraData0"))} / {File.Exists(Path.Combine(d, ".s2a_extra_pending"))}";
                tx.Dispose();
                Row("P1-50 提交：原语顺序 ‖ 提交 / 已提交 / ExtraData0 / 待写文件在",
                    "Clone(1,.s2a_new) Token(.s2a_new) Sync(.) Exchange(.s2a_new,0) Sync(.) ReadToken(0) Sync(.) ‖ True / NEW / E1 / False", $"{ops} ‖ {s}");
            }

            // P1-50 苹果克隆带落盘（接口约定：返回 0 时目标树已落盘）：树里有子目录、点文件、指向文件的符号链接，克隆返回 0、内容与链接照原样；
            //   目标已存在时返回非 0 且不动它。落盘本身（fsync / F_FULLFSYNC）单测量不到，这行只守「逐个落盘的遍历不把正常树判成失败」
            {
                string src = Path.Combine(root, "p1_50_apple"), dst = src + "_c";
                Directory.CreateDirectory(Path.Combine(src, "sub"));
                File.WriteAllText(Path.Combine(src, "sub", "a.bin"), "A"); File.WriteAllText(Path.Combine(src, ".hidden"), "H");
                File.CreateSymbolicLink(Path.Combine(src, "link"), Path.Combine(src, ".hidden"));
                int c1 = real.CloneTree(src, dst);
                string got = $"{c1} / {Txt(Path.Combine(dst, "sub", "a.bin"))} / {Txt(Path.Combine(dst, ".hidden"))} / {new FileInfo(Path.Combine(dst, "link")).LinkTarget != null}";
                int c2 = real.CloneTree(src, dst);
                Row("P1-50 苹果克隆：返回 / 子目录文件 / 点文件 / 链接仍是链接 ‖ 目标已存在：返回非 0 / 原内容在",
                    "0 / A / H / True ‖ True / A", $"{got} ‖ {c2 != 0} / {Txt(Path.Combine(dst, "sub", "a.bin"))}");
            }

            // P1-51 存档点副本在提交锁里取：数据根下一棵账号存档（已提交 OLD、工作 NEW），提交交换之后停住、随后目录落盘失败换回 OLD（这次提交没成立）。
            //   停住的 400 ms 里另一线程打存档点；放行后：提交失败、副本 account/a.bin = OLD（只可能是成立过的版本）。
            //   旧代码：副本在锁外逐文件拷，停住时就拷到了换进来的 NEW（一个从没提交成立的版本）→ 判红
            {
                Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = fault;
                string baseDir = Path.Combine(root, "p1_51_base");
                Directory.CreateDirectory(baseDir);
                Ryujinx.Common.Configuration.AppDataManager.Initialize(baseDir);
                const ulong sid = 0xA51;
                string saveRoot = Path.Combine(Ryujinx.Common.Configuration.AppDataManager.BaseDirPath, "bis", "user", "save");
                string d = Path.Combine(saveRoot, sid.ToString("x16"));
                Directory.CreateDirectory(Path.Combine(d, "0")); Directory.CreateDirectory(Path.Combine(d, "1"));
                File.WriteAllText(Path.Combine(d, "0", "a.bin"), "OLD"); File.WriteAllText(Path.Combine(d, "1", "a.bin"), "NEW");
                var tx = Open(d);
                var user = new LibHac.Fs.UserId(1, 2);
                System.Threading.ManualResetEventSlim swapped = new(false), gate = new(false);
                fault.AfterExchange = () => { swapped.Set(); gate.Wait(10000); fault.SyncErr = EIO; };
                bool okCommit = true;
                System.Threading.Thread tc = new(() => okCommit = tx.Commit().IsSuccess());
                tc.Start();
                bool inSwap = swapped.Wait(5000);
                string snap = Path.Combine(root, "p1_51.save1");
                int kinds = -1, served = 0;
                System.Threading.Thread ts = new(() => kinds = Saves.SnapshotFrom((out long n, Span<LibHac.Fs.SaveDataInfo> infos) =>
                {
                    n = served++ == 0 ? 1 : 0;
                    if (n == 1) infos[0] = new LibHac.Fs.SaveDataInfo { SaveDataId = sid, Type = LibHac.Fs.SaveDataType.Account, UserId = user };
                    return LibHac.Result.Success;
                }, user, "u", snap));
                ts.Start();
                ts.Join(400);
                gate.Set(); tc.Join(); ts.Join();
                fault.SyncErr = 0; fault.AfterExchange = null;
                tx.Dispose();
                Row("P1-51 存档点在提交锁里取：交换后停住 / 提交 / 副本种类 / 副本 account/a.bin / 已提交",
                    "True / False / 1 / OLD / OLD", $"{inSwap} / {okCommit} / {kinds} / {Txt(Path.Combine(snap, "account", "a.bin"))} / {Txt(Path.Combine(d, "0", "a.bin"))}");

                // P2-22 已提交目录不存在：索引里唯一一条账号存档只有工作目录 1/、没有 0/，dir 已有一份旧副本。期望：返回 0、dir 与 dir.tmp 都不在（不换上空副本）、报红 +1。
                //   旧代码：报红后照样写 user、换掉旧副本 → dir 在，判红
                const ulong sid2 = 0xB22;
                string d2 = Path.Combine(saveRoot, sid2.ToString("x16"));
                Directory.CreateDirectory(Path.Combine(d2, "1"));
                string snap2 = Path.Combine(root, "p2_22.save1");
                Directory.CreateDirectory(Path.Combine(snap2, "account")); File.WriteAllText(Path.Combine(snap2, "user"), "old");
                int served2 = 0, redsBefore = reds;
                int kinds2 = Saves.SnapshotFrom((out long n, Span<LibHac.Fs.SaveDataInfo> infos) =>
                {
                    n = served2++ == 0 ? 1 : 0;
                    if (n == 1) infos[0] = new LibHac.Fs.SaveDataInfo { SaveDataId = sid2, Type = LibHac.Fs.SaveDataType.Account, UserId = user };
                    return LibHac.Result.Success;
                }, user, "u", snap2);
                Row("P2-22 没有已提交目录：返回 / dir 在 / dir.tmp 在 / 报红",
                    "0 / False / False / +1", $"{kinds2} / {Directory.Exists(snap2)} / {Directory.Exists(snap2 + ".tmp")} / +{reds - redsBefore}");
            }

            Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = null;
            try { Directory.Delete(root, true); } catch (Exception e) { Console.Error.WriteLine($"清理 {root}：{e.Message}"); }

            int failures = 0;
            foreach ((string n, string e, string a) in rows)
            {
                bool ok = e == a;
                if (!ok) failures++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {a}");
            }
            return failures == 0 ? 0 : 1;
        }

        // 宿主目录原语外包一层，按字段注入失败（非 0 = 该原语直接返回这个 errno，不调里层）。Ops 非空时按调用顺序记原语名与路径（相对 Root）；
        //   CloneGate 非空时「克隆」先置 CloneEntered 再等 CloneGate；AfterExchange 非空时交换成功后调一次（调前先清空，只触发一次）
        private sealed class FaultTransaction : Ryujinx.HLE.FileSystem.IHostDirectoryTransaction
        {
            private readonly Ryujinx.HLE.FileSystem.IHostDirectoryTransaction _inner;
            public bool Unsupported;
            public int CloneErr, SyncErr, ReadTokenErr;
            public List<string> Ops;
            public string Root;
            public System.Threading.ManualResetEventSlim CloneGate, CloneEntered;
            public Action AfterExchange;
            public FaultTransaction(Ryujinx.HLE.FileSystem.IHostDirectoryTransaction inner) => _inner = inner;
            private void Log(string op, params string[] paths)
            {
                if (Ops == null) return;
                lock (Ops) Ops.Add($"{op}({string.Join(",", Array.ConvertAll(paths, p => Root == null ? p : Path.GetRelativePath(Root, p)))})");
            }
            public bool Supported(string directory) => !Unsupported && _inner.Supported(directory);
            public int CloneTree(string source, string destination)
            {
                Log("Clone", source, destination);
                if (CloneGate != null) { CloneEntered?.Set(); CloneGate.Wait(10000); }
                return CloneErr != 0 ? CloneErr : _inner.CloneTree(source, destination);
            }
            public int Exchange(string a, string b)
            {
                Log("Exchange", a, b);
                int e = _inner.Exchange(a, b);
                Action after = AfterExchange;
                if (e == 0 && after != null) { AfterExchange = null; after(); }
                return e;
            }
            public int WriteToken(string directory, ReadOnlySpan<byte> value) { Log("Token", directory); return _inner.WriteToken(directory, value); }
            public int ReadToken(string directory, Span<byte> value, out int length)
            {
                Log("ReadToken", directory);
                if (ReadTokenErr != 0) { length = 0; return ReadTokenErr; }
                return _inner.ReadToken(directory, value, out length);
            }
            public int SyncDirectory(string directory) { Log("Sync", directory); return SyncErr != 0 ? SyncErr : _inner.SyncDirectory(directory); }
            public int OpenRead(string path, out Microsoft.Win32.SafeHandles.SafeFileHandle handle) => _inner.OpenRead(path, out handle);
        }
    }
}

namespace S2A.Services.Tests.SaveCommitFakes
{
    using LibHac;
    using LibHac.Common;
    using LibHac.Fs;
    using LibHac.Fs.Fsa;
    using LibHac.FsSrv.FsCreator;
    using LibHac.FsSrv.Impl;
    using LibHac.FsSystem;
    using LibHac.FsSystem.Save;
    using System;

    // 只记 Create 调用次数的存档文件系统建造器（挂载失败退回 LibHac 原路时被调）；别的成员本用例不走
    internal sealed class FakeCreator : ISaveDataFileSystemCreator
    {
        public int Creates;
        public Result Create(ref SharedRef<ISaveDataFileSystem> outFileSystem, ref readonly SharedRef<IFileSystem> baseFileSystem, SaveDataSpaceId spaceId, ulong saveDataId, bool allowDirectorySaveData, bool isDeviceUniqueMac, bool isJournalingSupported, bool isMultiCommitSupported, bool openReadOnly, bool openShared, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible) { Creates++; return Result.Success; }
        public Result CreateRaw(ref SharedRef<IFile> outFile, ref readonly SharedRef<IFileSystem> fileSystem, ulong saveDataId, OpenMode openMode) => throw new NotSupportedException();
        public Result CreateExtraDataAccessor(ref SharedRef<ISaveDataExtraDataAccessor> outExtraDataAccessor, ref readonly SharedRef<IStorage> baseStorage, bool isDeviceUniqueMac, bool isIntegritySaveData, bool isReconstructible) => throw new NotSupportedException();
        public Result CreateInternalStorage(ref SharedRef<IFileSystem> outFileSystem, ref readonly SharedRef<IFileSystem> baseFileSystem, SaveDataSpaceId spaceId, ulong saveDataId, bool isDeviceUniqueMac, bool useUniqueKey1, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible) => throw new NotSupportedException();
        public Result RecoverMasterHeader(ref readonly SharedRef<IFileSystem> baseFileSystem, ulong saveDataId, IBufferManager bufferManager, bool isDeviceUniqueMac, bool isReconstructible) => throw new NotSupportedException();
        public Result UpdateMac(ref readonly SharedRef<IFileSystem> baseFileSystem, ulong saveDataId, bool isDeviceUniqueMac, bool isReconstructible) => throw new NotSupportedException();
        public Result Format(in ValueSubStorage saveImageStorage, long blockSize, int countExpandMax, uint blockCount, uint journalBlockCount, IBufferManager bufferManager, bool isDeviceUniqueMac, in HashSalt hashSalt, RandomDataGenerator encryptionKeyGenerator, bool isReconstructible, uint version) => throw new NotSupportedException();
        public Result FormatAsIntegritySaveData(in ValueSubStorage saveImageStorage, long blockSize, uint blockCount, IBufferManager bufferManager, bool isDeviceUniqueMac, RandomDataGenerator encryptionKeyGenerator, bool isReconstructible, uint version) => throw new NotSupportedException();
        public Result ExtractSaveDataParameters(out JournalIntegritySaveDataParameters outParams, IStorage saveFileStorage, bool isDeviceUniqueMac, bool isReconstructible) => throw new NotSupportedException();
        public Result ExtendSaveData(SaveDataExtender extender, in ValueSubStorage baseStorage, in ValueSubStorage logStorage, bool isDeviceUniqueMac, bool isReconstructible) => throw new NotSupportedException();
        public Result IsProvisionallyCommittedSaveData(out bool outIsProvisionallyCommitted, ref readonly SharedRef<IFileSystem> baseFileSystem, in SaveDataInfo info, bool isDeviceUniqueMac, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible) => throw new NotSupportedException();
        public void SetMacGenerationSeed(ReadOnlySpan<byte> seed) => throw new NotSupportedException();
        public IMacGenerator GetMacGenerator(bool isDeviceUniqueMac, bool isTemporaryTransferSave) => throw new NotSupportedException();
        public void Dispose() { }
    }
}
