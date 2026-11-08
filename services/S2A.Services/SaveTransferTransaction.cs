using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace S2A.Services;

public static partial class SaveTransfer
{
    private static string Previous(Context c)
    {
        if (!Directory.Exists(c.Backups)) return "";
        CheckLinks(c.Backups);
        var paths = Directory.EnumerateDirectories(c.Backups).Select(d => Path.Combine(d, "before-restore.s2asave")).ToArray();
        foreach (string path in paths) CheckLinks(path);
        return paths.Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault() ?? "";
    }
    private static JsonObject Status(Context c, bool recovered)
    {
        var scan = Scan(c.Root);
        bool hasSave = scan.Files.Keys.Any(n => n.StartsWith("bis/user/save/", StringComparison.Ordinal));
        JsonObject manifest = hasSave ? MakeManifest(c, c.Root, out _) : null;
        return new() { ["hasSave"] = hasSave, ["fileCount"] = hasSave ? scan.Files.Count : 0,
            ["totalBytes"] = hasSave ? scan.Files.Sum(p => p.Value) : 0, ["users"] = Copy(manifest?["users"]),
            ["previousBackup"] = Previous(c), ["recovered"] = recovered };
    }
    private static void Atomic(string path, JsonNode value)
    {
        CheckLinks(path);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var file = NewFile(temporary))
            {
                file.Write(Encoding.UTF8.GetBytes(value.ToJsonString()));
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
            SyncDirectory(Path.GetDirectoryName(path));
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    // 审计 P2-24：恢复时原先把整个数据根（着色器缓存等非存档文件常有几百 MB 到数 GB）逐字节流式拷进事务目录，存档三处随后又删掉重填。
    //   现在 skipSaves 跳过存档三处（反正要从备份包填回）；其余文件用 File.Copy——苹果 APFS 上它是写时复制克隆（本机实测 1 GB：克隆 0 ms、流式 1979 ms），
    //   不占额外空间、之后两边各写各的。不用硬链接：旧数据根会整棵挪进备份区保留，硬链接下新根原地写会连带改坏备份。
    //   仍先经平台接口打开源文件（拒链接 / 非普通文件），拷完核长度
    internal static void CopyTree(string source, string destination, bool skipSaves = false)
    {
        var scan = Scan(source);
        Directory.CreateDirectory(destination);
        foreach (string name in scan.Directories) if (!(skipSaves && Allowed(name, directory: true))) Directory.CreateDirectory(Path.Combine(destination, name));
        foreach (var file in scan.Files)
        {
            if (skipSaves && Allowed(file.Key)) continue;
            string sourcePath = Path.Combine(source, file.Key), target = Path.Combine(destination, file.Key);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            using (var src = ReadFile(sourcePath)) Require(src.Length == file.Value, "复制期间目标存档发生变化。", "save_changed");
            File.Copy(sourcePath, target);
            using var dst = new FileStream(target, FileMode.Open, FileAccess.ReadWrite);
            Require(dst.Length == file.Value, "复制期间目标存档发生变化。", "save_changed");
            dst.Flush(flushToDisk: true);
        }
    }
    private static void SyncTree(string root)
    {
        var scan = Scan(root);
        foreach (string dir in scan.Directories.OrderByDescending(d => d.Count(c => c == '/'))) SyncDirectory(Path.Combine(root, dir));
        SyncDirectory(root);
    }
    private static void SyncParents(string path, string boundary)
    {
        string current = path;
        while (current != null)
        {
            SyncDirectory(current);
            if (current == boundary) return;
            current = Path.GetDirectoryName(current);
        }
    }
    private static void DurableDirectory(string path)
    {
        CheckLinks(path);
        var missing = new System.Collections.Generic.Stack<string>();
        string current = path;
        while (!Directory.Exists(current))
        {
            Require(!File.Exists(current), "目录路径已被普通文件占用。");
            missing.Push(current);
            current = Path.GetDirectoryName(current) ?? throw new Failure("save_invalid", "找不到可访问的父目录。");
        }
        while (missing.Count != 0)
        {
            current = missing.Pop();
            Directory.CreateDirectory(current, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            SyncDirectory(current);
            SyncDirectory(Path.GetDirectoryName(current));
        }
    }
    private static bool Recover(Context c)
    {
        CheckLinks(c.Journal);
        if (!File.Exists(c.Journal)) return false;
        try
        {
            var record = Parse(SmallFile(c.Journal));
            string token = Str(record, "transaction");
            string phase = Str(record, "phase");
            bool hadOriginal = record["hadOriginal"].GetValue<bool>();
            Require(record["schema"].GetValue<int>() == 1 && Str(record, "gameId") == Str(c.Game, "id") &&
                Str(record, "dataRoot") == c.Root && Hex(token, 32) && phase is "prepared" or "committed", "恢复记录无效。");
            string transaction = Path.Combine(c.Transactions, token);
            string previous = Path.Combine(c.Backups, token);
            string old = Path.Combine(previous, "data");
            string next = Path.Combine(transaction, "new");
            CheckLinks(old); CheckLinks(next);
            var expectedOwner = new JsonObject { ["schema"] = 1, ["gameId"] = Copy(c.Game["id"]), ["dataRoot"] = c.Root, ["transaction"] = token };
            Require(JsonNode.DeepEquals(Parse(SmallFile(Path.Combine(transaction, "owner.json"))), expectedOwner), "事务归属记录不符。");
            Require(!File.Exists(old), "原存档副本不是目录。");
            if (phase == "committed") Require(Directory.Exists(c.Root), "已提交存档根缺失。");
            else if (Directory.Exists(old))
            {
                if (Directory.Exists(c.Root))
                {
                    Require(!Directory.Exists(next) && !File.Exists(next), "恢复状态不明确。");
                    Directory.Move(c.Root, next);
                    SyncDirectory(Path.GetDirectoryName(c.Root)); SyncDirectory(transaction);
                }
                DurableDirectory(Path.GetDirectoryName(c.Root));
                Directory.Move(old, c.Root);
                SyncDirectory(Path.GetDirectoryName(c.Root)); SyncDirectory(previous);
            }
            else if (hadOriginal)
                Require(Directory.Exists(c.Root) && Directory.Exists(next), "原存档副本缺失。");
            else if (Directory.Exists(c.Root))
            {
                Require(!Directory.Exists(next), "恢复时出现未知存档根。");
                Directory.Move(c.Root, next);
                SyncDirectory(Path.GetDirectoryName(c.Root)); SyncDirectory(transaction);
            }
            File.Delete(c.Journal);
            SyncDirectory(c.Transactions);
            Directory.Delete(transaction, recursive: true);
            SyncDirectory(c.Transactions);
            return phase != "committed";
        }
        catch (Exception ex) when (ex is Failure or IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or System.Text.Json.JsonException)
        {
            throw new Failure("save_recovery", "未完成的存档事务无法安全恢复，已阻止后续操作。请保留原副本和事务记录。");
        }
    }
    private static JsonObject Restore(Context c)
    {
        using var archive = new Archive(Source(c));
        Identity(c, archive.Manifest);
        string fingerprint = Fingerprint(c.Root);
        Require(c.Request["archiveSha256"]?.GetValue<string>() == archive.Sha &&
            c.Request["targetFingerprint"]?.GetValue<string>() == fingerprint, "备份或目标已变化，请重新检查后确认。", "save_changed");
        long total = Scan(c.Root).Files.Sum(p => p.Value) + archive.Manifest["files"].AsArray().Sum(f => f["size"].GetValue<long>());
        Space(c.Work, checked(2 * total + (64 << 20)));
        string token = Guid.NewGuid().ToString("N");
        string transaction = Path.Combine(c.Transactions, token);
        string previous = Path.Combine(c.Backups, token);
        string next = Path.Combine(transaction, "new");
        string old = Path.Combine(previous, "data");
        bool hadOriginal = Directory.Exists(c.Root);
        DurableDirectory(transaction);
        DurableDirectory(previous);
        Atomic(Path.Combine(transaction, "owner.json"), new JsonObject { ["schema"] = 1, ["gameId"] = Copy(c.Game["id"]), ["dataRoot"] = c.Root, ["transaction"] = token });
        SyncParents(transaction, c.Work); SyncParents(previous, c.Work);
        string priorArchive = "";
        try
        {
            if (Scan(c.Root).Files.Keys.Any(n => n.StartsWith("bis/user/save/", StringComparison.Ordinal)))
            {
                priorArchive = Path.Combine(previous, "before-restore.s2asave");
                WriteArchive(c, c.Root, priorArchive);
            }
            CopyTree(c.Root, next, skipSaves: true);
            foreach (string name in Trees.Append(Profile))
            {
                string path = Path.Combine(next, name);
                if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
                else if (File.Exists(path)) File.Delete(path);
            }
            foreach (var dir in archive.Manifest["directories"].AsArray()) Directory.CreateDirectory(Path.Combine(next, dir.GetValue<string>()));
            foreach (var item in archive.Manifest["files"].AsArray())
            {
                string path = Path.Combine(next, Str(item, "path"));
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                var entry = archive.Zip.GetEntry("payload/" + Str(item, "path"));
                using var src = entry.Open();
                using var dst = NewFile(path);
                CopyEntry(src, dst, item["size"].GetValue<long>(), Str(item, "sha256"), entry.Crc32);
                dst.Flush(flushToDisk: true);
            }
            archive.Source.Position = 0;
            Require(Hash(archive.Source) == archive.Sha && Fingerprint(c.Root) == fingerprint, "确认后备份或目标发生变化。", "save_changed");
            SyncTree(next);
            var record = new JsonObject { ["schema"] = 1, ["gameId"] = Copy(c.Game["id"]), ["dataRoot"] = c.Root,
                ["transaction"] = token, ["hadOriginal"] = hadOriginal, ["phase"] = "prepared" };
            Atomic(c.Journal, record);
            Checkpoint("prepared");
            DurableDirectory(Path.GetDirectoryName(c.Root));
            SyncDirectory(Path.GetDirectoryName(c.Root));
            if (hadOriginal)
            {
                Directory.Move(c.Root, old);
                SyncDirectory(previous); SyncDirectory(Path.GetDirectoryName(c.Root));
            }
            Checkpoint("oldMoved");
            Directory.Move(next, c.Root);
            SyncDirectory(transaction); SyncDirectory(Path.GetDirectoryName(c.Root));
            Checkpoint("newMoved");
            record["phase"] = "committed";
            Atomic(c.Journal, record);
            Checkpoint("committed");
            // Keep the committed journal until the next prelaunch/status operation.
            // This makes the commit point unambiguous even if cleanup is interrupted.
            return new() { ["committed"] = true, ["hadOriginal"] = hadOriginal, ["outputPath"] = c.Root,
                ["previousBackup"] = priorArchive, ["cleanupPending"] = true };
        }
        catch
        {
            if (File.Exists(c.Journal)) Recover(c);
            throw;
        }
    }
    // No implementation is linked into production. The process-exit tests pause
    // after real durable filesystem boundaries and kill the child from its parent.
    static partial void Checkpoint(string phase);
}
