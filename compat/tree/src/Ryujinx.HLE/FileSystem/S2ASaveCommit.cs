using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSrv.FsCreator;
using LibHac.FsSrv.Impl;
using LibHac.FsSystem;
using LibHac.FsSystem.Save;
using Ryujinx.Common.Logging;
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Path = LibHac.Fs.Path;

namespace Ryujinx.HLE.FileSystem
{
    // S2Arm: writable directory saves on the host's APFS take the transaction from the upstream reference implementation / Super Mario Odyssey iOS (MIT, see README):
    // at mount the committed directory <save>/0 is clonefile'd (copy-on-write, no bytes copied) into the working directory <save>/1 and the
    // game reads and writes there; Commit clones the working directory to <save>/.s2a_new and renamex_np(RENAME_SWAP)s it with <save>/0,
    // then deletes the swapped-out old version. Killed at any moment, <save>/0 is the old version or the new one, never a mix; extra data
    // commits with the same swap (S2ASaveTransaction token). The host primitives (clone / swap / token / directory sync) come from the platform:
    // S2AHostFileSystem.Transaction (IHostDirectoryTransaction; Apple: clonefile / renamex_np / xattr in platform/apple/cs/savecommit).
    // LibHac's own directory save copies the whole tree byte by byte at every mount and every commit. Here LibHac still serves files, locks
    // and extra data (opened with journaling off, so it works on <save>/1 directly and commits nothing); this layer does the clone and the swap.
    // Read-only opens, other kinds of saves and anything the host cannot clone keep LibHac's path unchanged.
    public sealed class S2ASaveDataFileSystemCreator : ISaveDataFileSystemCreator
    {
        private readonly ISaveDataFileSystemCreator _inner;
        private readonly string _baseDir;

        // 本进程里可写存档没走原子提交的原因，位或累计（11-01 全量审计 P2-13）：界面经 services 导出 S2A_SaveAtomicState 读，非 0 就提示
        //   「当前磁盘不能安全保存，请把游戏库挪到本机磁盘」。只记可写、带日志的用户 / 系统存档；只读打开、别的存档种类不算
        public const int NonAtomicUnregistered = 1;   // 平台没登记宿主目录原语（S2AHostFileSystem.Transaction）
        public const int NonAtomicVolume = 2;         // 存档所在的卷过不了克隆 / 原子交换探测（IHostDirectoryTransaction.Supported 为假）
        public const int NonAtomicMount = 4;          // 卷可以，但这次挂载准备工作目录失败（S2ASaveTransaction.Mount 给了原因）
        private static int _nonAtomic;
        public static int NonAtomic => Volatile.Read(ref _nonAtomic);

        public S2ASaveDataFileSystemCreator(ISaveDataFileSystemCreator inner, string baseDir)
        {
            _inner = inner;
            _baseDir = baseDir;
        }

        // Host directory of a save, as LibHac's emulated built-in storage lays it out (<base>/bis/<partition>/save/<id>); null when not a host directory
        internal static string HostDir(string baseDir, SaveDataSpaceId spaceId, ulong saveDataId)
        {
            string partition = spaceId switch
            {
                SaveDataSpaceId.User => "user",
                SaveDataSpaceId.System => "system",
                _ => null,
            };

            if (partition == null)
            {
                return null;
            }

            string dir = System.IO.Path.Combine(baseDir, "bis", partition, "save", saveDataId.ToString("x16"));

            if (!Directory.Exists(dir))
            {
                return null;
            }

            IHostDirectoryTransaction txn = S2AHostFileSystem.Transaction;

            if (txn == null)
            {
                if ((Interlocked.Or(ref _nonAtomic, NonAtomicUnregistered) & NonAtomicUnregistered) == 0)
                {
                    S2ASaveTransaction.Red("存档事务：平台没登记宿主目录原语（S2AHostFileSystem.Transaction），存档走 LibHac 原路、不做原子提交");
                }

                return null;
            }

            if (!txn.Supported(dir))
            {
                if ((Interlocked.Or(ref _nonAtomic, NonAtomicVolume) & NonAtomicVolume) == 0)
                {
                    S2ASaveTransaction.Red($"存档事务：{dir} 所在的卷做不了克隆 / 原子交换，存档走 LibHac 逐字节复制、不做原子提交");
                }

                return null;
            }

            return dir;
        }

        public Result Create(ref SharedRef<ISaveDataFileSystem> outFileSystem, ref readonly SharedRef<IFileSystem> baseFileSystem, SaveDataSpaceId spaceId, ulong saveDataId, bool allowDirectorySaveData, bool isDeviceUniqueMac, bool isJournalingSupported, bool isMultiCommitSupported, bool openReadOnly, bool openShared, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible)
        {
            string dir = openReadOnly || !isJournalingSupported ? null : HostDir(_baseDir, spaceId, saveDataId);
            string why = dir == null ? null : S2ASaveTransaction.Mount(dir);

            if (dir == null || why != null)
            {
                if (why != null)
                {
                    Interlocked.Or(ref _nonAtomic, NonAtomicMount);
                    S2ASaveTransaction.Red($"存档事务：挂载 {dir} 时{why}，这次改走 LibHac 原样的逐字节复制（已提交版本不动）");
                }

                return _inner.Create(ref outFileSystem, in baseFileSystem, spaceId, saveDataId, allowDirectorySaveData, isDeviceUniqueMac, isJournalingSupported, isMultiCommitSupported, openReadOnly, openShared, timeStampGetter, isReconstructible);
            }

            using SharedRef<ISaveDataFileSystem> fileSystem = default;
            Result result = _inner.Create(ref fileSystem.Ref, in baseFileSystem, spaceId, saveDataId, allowDirectorySaveData, isDeviceUniqueMac, isJournalingSupported: false, isMultiCommitSupported, openReadOnly, openShared, timeStampGetter, isReconstructible);

            if (result.IsFailure())
            {
                return result;
            }

            using SharedRef<ISaveDataFileSystem> wrapped = new(new S2ASaveTransaction(ref fileSystem.Ref, dir));
            outFileSystem.SetByMove(ref wrapped.Ref);

            return Result.Success;
        }

        public Result CreateRaw(ref SharedRef<IFile> outFile, ref readonly SharedRef<IFileSystem> fileSystem, ulong saveDataId, OpenMode openMode) => _inner.CreateRaw(ref outFile, in fileSystem, saveDataId, openMode);
        public Result CreateExtraDataAccessor(ref SharedRef<ISaveDataExtraDataAccessor> outExtraDataAccessor, ref readonly SharedRef<IStorage> baseStorage, bool isDeviceUniqueMac, bool isIntegritySaveData, bool isReconstructible) => _inner.CreateExtraDataAccessor(ref outExtraDataAccessor, in baseStorage, isDeviceUniqueMac, isIntegritySaveData, isReconstructible);
        public Result CreateInternalStorage(ref SharedRef<IFileSystem> outFileSystem, ref readonly SharedRef<IFileSystem> baseFileSystem, SaveDataSpaceId spaceId, ulong saveDataId, bool isDeviceUniqueMac, bool useUniqueKey1, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible) => _inner.CreateInternalStorage(ref outFileSystem, in baseFileSystem, spaceId, saveDataId, isDeviceUniqueMac, useUniqueKey1, timeStampGetter, isReconstructible);
        public Result RecoverMasterHeader(ref readonly SharedRef<IFileSystem> baseFileSystem, ulong saveDataId, IBufferManager bufferManager, bool isDeviceUniqueMac, bool isReconstructible) => _inner.RecoverMasterHeader(in baseFileSystem, saveDataId, bufferManager, isDeviceUniqueMac, isReconstructible);
        public Result UpdateMac(ref readonly SharedRef<IFileSystem> baseFileSystem, ulong saveDataId, bool isDeviceUniqueMac, bool isReconstructible) => _inner.UpdateMac(in baseFileSystem, saveDataId, isDeviceUniqueMac, isReconstructible);
        public Result Format(in ValueSubStorage saveImageStorage, long blockSize, int countExpandMax, uint blockCount, uint journalBlockCount, IBufferManager bufferManager, bool isDeviceUniqueMac, in HashSalt hashSalt, RandomDataGenerator encryptionKeyGenerator, bool isReconstructible, uint version) => _inner.Format(in saveImageStorage, blockSize, countExpandMax, blockCount, journalBlockCount, bufferManager, isDeviceUniqueMac, in hashSalt, encryptionKeyGenerator, isReconstructible, version);
        public Result FormatAsIntegritySaveData(in ValueSubStorage saveImageStorage, long blockSize, uint blockCount, IBufferManager bufferManager, bool isDeviceUniqueMac, RandomDataGenerator encryptionKeyGenerator, bool isReconstructible, uint version) => _inner.FormatAsIntegritySaveData(in saveImageStorage, blockSize, blockCount, bufferManager, isDeviceUniqueMac, encryptionKeyGenerator, isReconstructible, version);
        public Result ExtractSaveDataParameters(out JournalIntegritySaveDataParameters outParams, IStorage saveFileStorage, bool isDeviceUniqueMac, bool isReconstructible) => _inner.ExtractSaveDataParameters(out outParams, saveFileStorage, isDeviceUniqueMac, isReconstructible);
        public Result ExtendSaveData(SaveDataExtender extender, in ValueSubStorage baseStorage, in ValueSubStorage logStorage, bool isDeviceUniqueMac, bool isReconstructible) => _inner.ExtendSaveData(extender, in baseStorage, in logStorage, isDeviceUniqueMac, isReconstructible);
        public Result IsProvisionallyCommittedSaveData(out bool outIsProvisionallyCommitted, ref readonly SharedRef<IFileSystem> baseFileSystem, in SaveDataInfo info, bool isDeviceUniqueMac, ISaveDataCommitTimeStampGetter timeStampGetter, bool isReconstructible) => _inner.IsProvisionallyCommittedSaveData(out outIsProvisionallyCommitted, in baseFileSystem, in info, isDeviceUniqueMac, timeStampGetter, isReconstructible);
        public void SetMacGenerationSeed(ReadOnlySpan<byte> seed) => _inner.SetMacGenerationSeed(seed);
        public IMacGenerator GetMacGenerator(bool isDeviceUniqueMac, bool isTemporaryTransferSave) => _inner.GetMacGenerator(isDeviceUniqueMac, isTemporaryTransferSave);
        public void Dispose() => _inner.Dispose();
    }

    // One mounted transactional save: forwards to LibHac's directory save (journaling off, working on <save>/1) and owns Commit / Rollback
    public sealed partial class S2ASaveTransaction : ISaveDataFileSystem
    {
        // 宿主目录原语（克隆 / 原子交换 / 记号 / 目录落盘）由平台登记；能走到这里说明挂载时 Supported 已为真
        private static IHostDirectoryTransaction Txn => S2AHostFileSystem.Transaction;

        // Extra data commits with the directory swap (audit #836 F-save-extra-after-swap): before the swap the new extra data is written as
        // <save>/.s2a_extra_pending = token + ExtraData1, and the same random token goes onto the clone being swapped in (IHostDirectoryTransaction.WriteToken)
        // (the game never sees it). The swap is the one commit point; ExtraData0 is then written from the pending file. If that fails, or the
        // process dies first, the next mount or commit finds the pending file and applies it only when the committed directory carries its token
        // (= the swap happened), so a later mount never copies the old ExtraData0 over the new extra data.
        private const string PendingExtra = ".s2a_extra_pending";
        private const int TokenSize = 16;

        private SharedRef<ISaveDataFileSystem> _base;
        private readonly string _dir;
        // 改这棵存档的所有入口（建 / 删 / 改名文件与目录、以写模式打开、写附加数据）和提交、回滚共用这一把锁：提交的「没有开着的写模式文件」检查和整个
        //   克隆 + 交换都在锁内，别的线程改不进来（11-01 全量审计 P0-2：原先只有提交 / 回滚持锁，提交克隆到一半时别的线程增删改，换上的是新旧混合，下次挂载照样克隆它）。
        //   锁按存档目录取，挂载准备（Mount）和存档点副本（CloneCommitted）也拿它：同一棵存档不论从几条路径挂载、建了几个事务都是同一把
        //   （11-01 18:00 全量审计 P1-8 / P1-51：原先锁是每个实例一把，两个挂载互不相拦；附加数据写入不进锁）
        private readonly object _lock;
        private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object> _dirLocks = new(StringComparer.Ordinal);
        private static int _commits;
        private int _openWritable;   // files open for writing: a commit with one open is refused, as LibHac's journaled commit does

        internal S2ASaveTransaction(ref SharedRef<ISaveDataFileSystem> baseFileSystem, string dir)
        {
            _base = SharedRef<ISaveDataFileSystem>.CreateMove(ref baseFileSystem);
            _dir = dir;
            _lock = LockFor(dir);
        }

        private static object LockFor(string dir) => _dirLocks.GetOrAdd(System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(dir)), static _ => new object());

        // 先写同目录的临时文件并刷到盘，再改名成 path；改名本身要等调用方对所在目录做一次目录落盘（11-01 18:00 全量审计 P1-50）
        private static void WriteFileDurable(string tmp, string path, ReadOnlySpan<byte> data)
        {
            using (FileStream stream = new(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            File.Move(tmp, path, overwrite: true);
        }

        // 存档点副本（services Saves.SnapshotFrom）：在这棵存档的锁里把已提交版本 <dir>/0 整树克隆到 destination（不能已存在）。锁里提交 / 回滚 / 挂载都换不掉 0/，
        //   拿到的一定是某一次成立的提交（11-01 18:00 全量审计 P1-51：原先提交返回、锁放开后逐文件拷，交换前后各解析一次路径，可拼出两次提交）。成功回 null，否则回原因
        public static string CloneCommitted(string dir, string destination)
        {
            IHostDirectoryTransaction txn = Txn;

            if (txn == null)
            {
                return "平台没登记宿主目录原语";
            }

            lock (LockFor(dir))
            {
                if (!Directory.Exists(System.IO.Path.Combine(dir, "0")))
                {
                    return "没有已提交目录";
                }

                int e = txn.CloneTree(System.IO.Path.Combine(dir, "0"), destination);

                return e == 0 ? null : Errno("克隆已提交版本", e);
            }
        }

        internal static void Red(string what)
        {
            Logger.Error?.Print(LogClass.ServiceFs, what);
            S2AHooks.Red?.Invoke(what);
        }

        private static string Errno(string op, int errno) => $"{op} 失败（errno {errno}）";

        // Before LibHac opens the save: clear what an interrupted transaction left, then clone the committed version into the working directory.
        // Returns why it could not (the caller then takes LibHac's own path), or null
        internal static string Mount(string dir)
        {
            lock (LockFor(dir))
            {
                return MountLocked(dir);
            }
        }

        private static string MountLocked(string dir)
        {
            string committed = System.IO.Path.Combine(dir, "0"), working = System.IO.Path.Combine(dir, "1"), fresh = System.IO.Path.Combine(dir, ".s2a_new");

            try
            {
                if (Directory.Exists(fresh))
                {
                    Directory.Delete(fresh, true);   // a clone that never got swapped in, or the old version a swap left behind
                }

                ApplyPendingExtra(dir);

                if (!Directory.Exists(committed))
                {
                    // Never committed (LibHac creates only the working directory for a new save): what it has is the save, as LibHac's own recovery takes it
                    if (!Directory.Exists(working))
                    {
                        Directory.CreateDirectory(working);
                    }

                    int e = Txn.CloneTree(working, committed);

                    if (e != 0)
                    {
                        return Errno("把工作目录克隆成已提交版本", e);
                    }

                    if ((e = Txn.SyncDirectory(dir)) != 0)
                    {
                        return Errno("已提交版本目录项落盘", e);
                    }
                }

                string extra0 = System.IO.Path.Combine(dir, "ExtraData0"), extra1 = System.IO.Path.Combine(dir, "ExtraData1");

                // 没有已提交的附加数据、只有工作份：同上面没提交过的工作目录，把它当成已提交并落盘，回滚才有上一份可回（11-01 18:00 全量审计 P1-8）
                if (!File.Exists(extra0) && File.Exists(extra1))
                {
                    WriteFileDurable(System.IO.Path.Combine(dir, ".s2a_extra"), extra0, File.ReadAllBytes(extra1));

                    int se = Txn.SyncDirectory(dir);

                    if (se != 0)
                    {
                        return Errno("已提交附加数据目录项落盘", se);
                    }
                }

                if (Directory.Exists(working))
                {
                    Directory.Delete(working, true);
                }

                int ce = Txn.CloneTree(committed, working);

                if (ce != 0)
                {
                    return Errno("把已提交版本克隆成工作目录", ce);
                }

                if (File.Exists(extra0))
                {
                    File.Copy(extra0, extra1, overwrite: true);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return $"出错：{e.Message}";
            }

            return null;
        }

        // A pending extra data file left by a commit: written as ExtraData0 when the committed directory carries its token, dropped otherwise
        private static void ApplyPendingExtra(string dir)
        {
            string pending = System.IO.Path.Combine(dir, PendingExtra);

            if (!File.Exists(pending))
            {
                return;
            }

            byte[] data = File.ReadAllBytes(pending);

            if (data.Length >= TokenSize)
            {
                byte[] token = new byte[TokenSize];
                int e = Txn.ReadToken(System.IO.Path.Combine(dir, "0"), token, out int tokenLength);

                // 读不出提交号 = 不知道交换发生没有：待写文件留着、报错，下次挂载 / 提交再判（11-01 全量审计 P2-29：原先当成没交换，把新附加数据删了，
                //   下次挂载再用旧 ExtraData0 盖掉 ExtraData1）。只有读成功且对不上才算确实没交换
                if (e != 0)
                {
                    throw new IOException(Errno("读已提交版本的提交号", e));
                }

                if (tokenLength == TokenSize && data.AsSpan(0, TokenSize).SequenceEqual(token))
                {
                    WriteFileDurable(System.IO.Path.Combine(dir, ".s2a_extra"), System.IO.Path.Combine(dir, "ExtraData0"), data.AsSpan(TokenSize));

                    // ExtraData0 落了盘才删待写文件：反过来掉电，新附加数据两头都丢（11-01 18:00 全量审计 P1-50）
                    int se = Txn.SyncDirectory(dir);

                    if (se != 0)
                    {
                        throw new IOException(Errno("附加数据目录项落盘", se));
                    }
                }
            }

            File.Delete(pending);
        }

        // Swap the working directory in as the committed version, extra data with it; before the swap any failure leaves the committed version as
        // it was, after the swap the commit stands (see the token above)
        private Result CommitLocked()
        {
            if (Volatile.Read(ref _openWritable) > 0)
            {
                return ResultFs.WriteModeFileNotClosed.Log();
            }

            string committed = System.IO.Path.Combine(_dir, "0"), working = System.IO.Path.Combine(_dir, "1"), fresh = System.IO.Path.Combine(_dir, ".s2a_new");
            long t0 = System.Diagnostics.Stopwatch.GetTimestamp();

            string pending = System.IO.Path.Combine(_dir, PendingExtra);

            try
            {
                if (Directory.Exists(fresh))
                {
                    Directory.Delete(fresh, true);
                }

                ApplyPendingExtra(_dir);   // a previous commit's extra data that never landed

                int errno = Txn.CloneTree(working, fresh);

                if (errno != 0)
                {
                    Red($"存档事务：提交 {_dir} 时克隆工作目录失败（errno {errno}），已提交版本不动");

                    return errno == 28 ? ResultFs.UsableSpaceNotEnough.Log() : ResultFs.UnexpectedInLocalFileSystemE.Log();   // 28 = ENOSPC
                }

                byte[] token = System.Security.Cryptography.RandomNumberGenerator.GetBytes(TokenSize);

                if ((errno = Txn.WriteToken(fresh, token)) != 0)
                {
                    Red($"存档事务：提交 {_dir} 时{Errno("给新版本写提交号", errno)}，已提交版本不动");
                    Directory.Delete(fresh, true);

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }

                string extra1 = System.IO.Path.Combine(_dir, "ExtraData1");

                if (File.Exists(extra1))
                {
                    string pendingNew = pending + ".tmp";
                    byte[] extra = File.ReadAllBytes(extra1), data = new byte[TokenSize + extra.Length];
                    token.CopyTo(data, 0);
                    extra.CopyTo(data, TokenSize);
                    WriteFileDurable(pendingNew, pending, data);
                }

                // 交换前让新版本的目录项与待写附加数据落盘：交换落了盘而它们没落，掉电后已提交的是新树、附加数据却回到旧的（11-01 18:00 全量审计 P1-50）。
                //   新版本树里的文件、各级目录与提交号由平台原语的克隆 / 写记号自己落盘（IHostDirectoryTransaction 约定）
                if ((errno = Txn.SyncDirectory(_dir)) != 0)
                {
                    Red($"存档事务：提交 {_dir} 时{Errno("交换前目录项落盘", errno)}，已提交版本不动");
                    Directory.Delete(fresh, true);
                    File.Delete(pending);

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }

                if ((errno = Txn.Exchange(fresh, committed)) != 0)
                {
                    Red($"存档事务：提交 {_dir} 时{Errno("原子交换", errno)}，已提交版本不动");
                    Directory.Delete(fresh, true);
                    File.Delete(pending);

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Red($"存档事务：提交 {_dir} 出错：{e.Message}，已提交版本不动");

                return ResultFs.UnexpectedInLocalFileSystemE.Log();
            }

            // 交换后的两个目录项（0 / .s2a_new）落盘成功才算提交（11-01 全量审计 P1-6：原先落盘失败只报红仍回成功，掉电或强杀回到上一版且没有提示）。
            //   落不了盘就换回去、报失败：已提交的仍是上一版（它的提交号对不上待写附加数据），工作目录不动，游戏再提交一次就重做克隆 + 交换 + 落盘。
            //   不重试落盘：fsync 失败后再调一次成功不说明前面的数据落了盘
            bool durable = true;
            int synced = Txn.SyncDirectory(_dir);

            if (synced != 0)
            {
                int back = Txn.Exchange(fresh, committed);

                if (back == 0)
                {
                    Red($"存档事务：{_dir} 已交换但{Errno("目录项落盘", synced)}，已换回上一版、这次提交报失败（工作目录保留，再提交即重做）");

                    try
                    {
                        File.Delete(pending);
                        Directory.Delete(fresh, true);   // 这次的新版本克隆
                        Txn.SyncDirectory(_dir);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        Red($"存档事务：{_dir} 换回上一版后清理没做完（{e.Message}），下次挂载 / 提交清掉");
                    }

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }

                // 换不回去：已提交的就是这一版（附加数据照常跟上），但经不经得起掉电不知道，按失败报给游戏
                Red($"存档事务：{_dir} 已交换但{Errno("目录项落盘", synced)}，换回上一版也{Errno("交换", back)}：已提交的是这一版、掉电可能丢，这次提交报失败");
                durable = false;
            }

            // Swapped in and on disk: the commit stands. What is left is housekeeping a later mount or commit redoes, so it does not turn the commit into a failure

            try
            {
                ApplyPendingExtra(_dir);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Red($"存档事务：{_dir} 已提交，附加数据这次没写进 ExtraData0（{e.Message}），下次挂载 / 提交补上");
            }

            try
            {
                Directory.Delete(fresh, true);   // the old version, swapped out
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Red($"存档事务：{_dir} 已提交，换出的旧版本没删掉（{e.Message}），下次挂载清掉");
            }

            if (!durable)
            {
                return ResultFs.UnexpectedInLocalFileSystemE.Log();
            }

            Logger.Info?.Print(LogClass.ServiceFs, $"存档提交 #{Interlocked.Increment(ref _commits)}：{_dir} 克隆 + 原子交换 {System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalMilliseconds:F1} ms");

            return Result.Success;
        }

        protected override Result DoCommit()
        {
            lock (_lock)
            {
                return CommitLocked();
            }
        }

        public override Result CommitExtraData(bool updateTimeStamp)
        {
            lock (_lock)
            {
                Result result = _base.Get.CommitExtraData(updateTimeStamp);

                return result.IsFailure() ? result : CommitLocked();
            }
        }

        // Discard what was written since the last commit: the working directory becomes a fresh clone of the committed version, and the working
        // extra data (ExtraData1) a copy of the committed one (ExtraData0), as at mount (11-01 全量审计 P1-19：原先只换文件树，附加数据留着未提交那份，
        // 下次提交把这组不一致的附加数据发布出去；开着写模式文件也照换；换上之后删旧树失败被报成回滚失败)
        protected override Result DoRollback()
        {
            lock (_lock)
            {
                if (Volatile.Read(ref _openWritable) > 0)
                {
                    return ResultFs.WriteModeFileNotClosed.Log();   // 同提交：换走工作目录后，开着的描述符还指在换出的旧树上，再写就丢
                }

                string committed = System.IO.Path.Combine(_dir, "0"), working = System.IO.Path.Combine(_dir, "1"), fresh = System.IO.Path.Combine(_dir, ".s2a_new");
                string extra0 = System.IO.Path.Combine(_dir, "ExtraData0"), extra1 = System.IO.Path.Combine(_dir, "ExtraData1"), extraNew = System.IO.Path.Combine(_dir, ".s2a_extra1");

                try
                {
                    if (Directory.Exists(fresh))
                    {
                        Directory.Delete(fresh, true);
                    }

                    // 交换前备好回滚后的附加数据，交换后只剩一步改名：有已提交的就是它；没有（挂载时两份都没有，见 Mount）就是挂载时 LibHac 新建的那份全 0
                    //   （11-01 18:00 全量审计 P1-8：原先没有上一份就不碰，未提交的附加数据留下、下次提交发布出去）
                    if (File.Exists(extra0))
                    {
                        File.Copy(extra0, extraNew, overwrite: true);
                    }
                    else
                    {
                        File.WriteAllBytes(extraNew, new byte[System.Runtime.CompilerServices.Unsafe.SizeOf<SaveDataExtraData>()]);
                    }

                    int e = Txn.CloneTree(committed, fresh);

                    if (e != 0 || (e = Txn.Exchange(fresh, working)) != 0)
                    {
                        Red($"存档事务：回滚 {_dir} 时{Errno("克隆 / 交换", e)}，工作目录保持原样");
                        File.Delete(extraNew);

                        return ResultFs.UnexpectedInLocalFileSystemE.Log();
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    Red($"存档事务：回滚 {_dir} 出错：{e.Message}，工作目录保持原样");

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }

                // 文件树已换回；附加数据改名失败就把文件树换回回滚前、报失败：失败不留半步，游戏再回滚一次即重做
                //   （11-01 18:00 全量审计 P1-8：原先报回滚失败时工作树已是上一版、附加数据仍是未提交的）
                try
                {
                    File.Move(extraNew, extra1, overwrite: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    int back = Txn.Exchange(fresh, working);

                    Red(back == 0
                        ? $"存档事务：回滚 {_dir} 时附加数据改名失败（{e.Message}），文件树已换回回滚前，这次回滚报失败"
                        : $"存档事务：回滚 {_dir} 时附加数据改名失败（{e.Message}），换回回滚前也{Errno("交换", back)}：工作目录已是上一版、附加数据仍是未提交的，这次回滚报失败");

                    try
                    {
                        File.Delete(extraNew);

                        if (back == 0)
                        {
                            // 这次克隆出来没用上的已提交版本
                            Directory.Delete(fresh, true);
                        }
                    }
                    catch (Exception ce) when (ce is IOException or UnauthorizedAccessException)
                    {
                        Red($"存档事务：{_dir} 回滚失败后清理没做完（{ce.Message}），下次挂载 / 提交清掉");
                    }

                    return ResultFs.UnexpectedInLocalFileSystemE.Log();
                }

                // 回滚已成立：换出的旧工作树删不掉只报红，下次挂载 / 提交清掉
                try
                {
                    Directory.Delete(fresh, true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    Red($"存档事务：{_dir} 已回滚，换出的旧工作目录没删掉（{e.Message}），下次挂载清掉");
                }

                return Result.Success;
            }
        }

        protected override Result DoOpenFile(ref UniqueRef<IFile> outFile, ref readonly Path path, OpenMode mode)
        {
            if ((mode & OpenMode.Write) == 0)
            {
                return _base.Get.OpenFile(ref outFile, in path, mode);
            }

            lock (_lock)   // 写模式：打开与计数在锁内，提交检查计数时不会有刚打开、还没计上的
            {
                return OpenWritableLocked(ref outFile, in path, mode);
            }
        }

        private Result OpenWritableLocked(ref UniqueRef<IFile> outFile, ref readonly Path path, OpenMode mode)
        {
            using UniqueRef<IFile> file = new();
            Result result = _base.Get.OpenFile(ref file.Ref, in path, mode);

            if (result.IsFailure())
            {
                return result;
            }

            Interlocked.Increment(ref _openWritable);
            outFile.Reset(new WritableFile(ref file.Ref, this));

            return Result.Success;
        }

        private sealed class WritableFile : IFile
        {
            private UniqueRef<IFile> _file;
            private S2ASaveTransaction _owner;

            public WritableFile(ref UniqueRef<IFile> file, S2ASaveTransaction owner)
            {
                _file = new UniqueRef<IFile>(ref file);
                _owner = owner;
            }

            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option) => _file.Get.Read(out bytesRead, offset, destination, in option);
            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => _file.Get.Write(offset, source, in option);
            protected override Result DoFlush() => _file.Get.Flush();
            protected override Result DoSetSize(long size) => _file.Get.SetSize(size);
            protected override Result DoGetSize(out long size) => _file.Get.GetSize(out size);
            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer) => _file.Get.OperateRange(outBuffer, operationId, offset, size, inBuffer);

            public override void Dispose()
            {
                _file.Destroy();

                if (_owner != null)
                {
                    Interlocked.Decrement(ref _owner._openWritable);
                    _owner = null;
                }

                base.Dispose();
            }
        }

        protected override Result DoCreateFile(ref readonly Path path, long size, CreateFileOptions option) { lock (_lock) return _base.Get.CreateFile(in path, size, option); }
        protected override Result DoDeleteFile(ref readonly Path path) { lock (_lock) return _base.Get.DeleteFile(in path); }
        protected override Result DoCreateDirectory(ref readonly Path path) { lock (_lock) return _base.Get.CreateDirectory(in path); }
        protected override Result DoDeleteDirectory(ref readonly Path path) { lock (_lock) return _base.Get.DeleteDirectory(in path); }
        protected override Result DoDeleteDirectoryRecursively(ref readonly Path path) { lock (_lock) return _base.Get.DeleteDirectoryRecursively(in path); }
        protected override Result DoCleanDirectoryRecursively(ref readonly Path path) { lock (_lock) return _base.Get.CleanDirectoryRecursively(in path); }
        protected override Result DoRenameFile(ref readonly Path currentPath, ref readonly Path newPath) { lock (_lock) return _base.Get.RenameFile(in currentPath, in newPath); }
        protected override Result DoRenameDirectory(ref readonly Path currentPath, ref readonly Path newPath) { lock (_lock) return _base.Get.RenameDirectory(in currentPath, in newPath); }
        protected override Result DoGetEntryType(out DirectoryEntryType entryType, ref readonly Path path) => _base.Get.GetEntryType(out entryType, in path);
        // Space within the save's size, not the host volume's (S2ASaveSpace)
        protected override Result DoGetFreeSpaceSize(out long freeSpace, ref readonly Path path)
        {
            UnsafeHelpers.SkipParamInit(out freeSpace);
            Result result = _base.Get.GetFreeSpaceSize(out long hostFree, in path);

            if (result.IsFailure())
            {
                return result;
            }

            lock (_lock)
            {
                result = _base.Get.ReadExtraData(out SaveDataExtraData extraData);

                return result.IsFailure() ? result : S2ASaveSpace.GetFreeSpaceSize(out freeSpace, in extraData, System.IO.Path.Combine(_dir, "1"), hostFree);
            }
        }

        protected override Result DoGetTotalSpaceSize(out long totalSpace, ref readonly Path path)
        {
            UnsafeHelpers.SkipParamInit(out totalSpace);
            Result result = _base.Get.GetTotalSpaceSize(out long hostTotal, in path);

            if (result.IsFailure())
            {
                return result;
            }

            lock (_lock)
            {
                result = _base.Get.ReadExtraData(out SaveDataExtraData extraData);

                return result.IsFailure() ? result : S2ASaveSpace.GetTotalSpaceSize(out totalSpace, in extraData, hostTotal);
            }
        }
        protected override Result DoOpenDirectory(ref UniqueRef<IDirectory> outDirectory, ref readonly Path path, OpenDirectoryMode mode) => _base.Get.OpenDirectory(ref outDirectory, in path, mode);
        protected override Result DoCommitProvisionally(long counter) => _base.Get.CommitProvisionally(counter);
        protected override Result DoFlush() => _base.Get.Flush();
        protected override Result DoGetFileTimeStampRaw(out FileTimeStampRaw timeStamp, ref readonly Path path) => _base.Get.GetFileTimeStampRaw(out timeStamp, in path);
        protected override Result DoQueryEntry(Span<byte> outBuffer, ReadOnlySpan<byte> inBuffer, QueryId queryId, ref readonly Path path) => _base.Get.QueryEntry(outBuffer, inBuffer, queryId, in path);
        protected override Result DoGetFileSystemAttribute(out FileSystemAttribute outAttribute) => _base.Get.GetFileSystemAttribute(out outAttribute);

        public override bool IsSaveDataFileSystemCacheEnabled() => _base.Get.IsSaveDataFileSystemCacheEnabled();
        public override Result RollbackOnlyModified() => _base.Get.RollbackOnlyModified();
        public override Result WriteExtraData(in SaveDataExtraData extraData) { lock (_lock) return _base.Get.WriteExtraData(in extraData); }
        public override Result ReadExtraData(out SaveDataExtraData extraData) { lock (_lock) return _base.Get.ReadExtraData(out extraData); }
        public override void RegisterExtraDataAccessorObserver(ISaveDataExtraDataAccessorObserver observer, SaveDataSpaceId spaceId, ulong saveDataId) => _base.Get.RegisterExtraDataAccessorObserver(observer, spaceId, saveDataId);

        public override void Dispose()
        {
            _base.Destroy();
            base.Dispose();
        }
    }
}
