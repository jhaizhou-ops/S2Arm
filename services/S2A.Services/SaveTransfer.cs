using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LibHac.Fs;
using LibHac.FsSrv;
using LibHac.Kvdb;
using Microsoft.Win32.SafeHandles;
using Ryujinx.HLE.FileSystem;
using Path = System.IO.Path;

namespace S2A.Services;

/// <summary>Stopped-game transfer of an isolated Ryujinx data root. The caller must
/// serialize this API with game initialization; no runtime/test-seed APIs are used.</summary>
public static partial class SaveTransfer
{
    private const int MaxFiles = 20000, MaxMetadata = 8 << 20;
    private const long MaxBytes = 32L << 30;
    private const string Profile = "system/Profiles.json";
    private const string Index = "bis/system/save/8000000000000000/0/imkvdb.arc";
    private static readonly string[] Trees = { "bis/user/save", "bis/system/save" };
    private static readonly object Gate = new();
    public static readonly object HostGate = new();
    public static bool HostStarted;
    private sealed class Failure(string code, string message) : Exception(message)
    {
        internal readonly string Code = code;
    }
    // 玩家看得到的说明按请求里的 language 出中文或英文（#316）：iOS 宿主（ios/save_transfer.m，含 iCloud 同步经 s2a_shell_save_context）带
    //   "language"（"en" / "zh-Hans"）；没带（Mac 等其它调用方）照旧中文。错误码不变；日志（stderr）照旧中文。一次请求在本线程上有效，入口处设定
    [ThreadStatic] private static bool s_english;
    internal static bool English => s_english;
    internal static string T(string zh, string en) => s_english ? en : zh;
    /// <summary>读请求里的 language（取不到 / 不是 JSON 按中文）；SaveTransferExports 与 Execute 入口各调一次</summary>
    internal static void UseLanguage(string requestJson)
    {
        s_english = false;
        try { if (JsonNode.Parse(requestJson)?["language"] is JsonValue v && v.TryGetValue(out string language)) s_english = !language.StartsWith("zh", StringComparison.OrdinalIgnoreCase); }
        catch (Exception ex) when (ex is JsonException or ArgumentException or InvalidOperationException) { }
    }
    private static void Require(bool value, string message, string code = "save_invalid")
    {
        if (!value) throw new Failure(code, message);
    }
    private static JsonNode Parse(ReadOnlySpan<byte> bytes)
    {
        Require(bytes.Length <= MaxMetadata, T("JSON 元数据超过上限。", "JSON metadata exceeds the limit."));
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { MaxDepth = 64 });
        var objects = new Stack<HashSet<string>>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
            else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
            else if (reader.TokenType == JsonTokenType.PropertyName)
                Require(objects.Peek().Add(reader.GetString()), T("JSON 字段重复。", "Duplicate JSON field."));
        }
        return JsonNode.Parse(bytes) ?? throw new Failure("save_invalid", T("JSON 内容为空。", "JSON content is empty."));
    }
    private static string Str(JsonNode node, string key) => node[key]?.GetValue<string>()
        ?? throw new Failure("save_invalid", T("缺少字段：", "Missing field: ") + key);
    private static bool Hex(string value, int length) => value.Length == length && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static JsonNode Copy(JsonNode node) => node?.DeepClone();
    private static string Hash(Stream stream) => Convert.ToHexStringLower(SHA256.HashData(stream));
    private static string HashFile(string path)
    {
        using var file = ReadFile(path);
        return Hash(file);
    }
    private static byte[] SmallFile(string path)
    {
        using var file = ReadFile(path);
        Require(file.Length <= MaxMetadata, T("存档元数据超过上限。", "Save metadata exceeds the limit."));
        using var memory = new MemoryStream();
        file.CopyTo(memory);
        Require(memory.Length <= MaxMetadata, T("存档元数据超过上限。", "Save metadata exceeds the limit."));
        return memory.ToArray();
    }
    private static string Absolute(string path)
    {
        Require(Path.IsPathFullyQualified(path) && Path.GetFullPath(path) == path.TrimEnd('/'), T("需要规范的绝对路径。", "A normalized absolute path is required."));
        CheckLinks(path);
        return path;
    }
    private static bool Within(string path, string root) => path == root || path.StartsWith(root + "/", StringComparison.Ordinal);
    private static void CheckLinks(string path)
    {
        string current = Path.GetPathRoot(path);
        foreach (string part in path.Substring(current.Length).Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            FileAttributes attributes;
            try { attributes = File.GetAttributes(current); }
            catch (FileNotFoundException) { continue; }
            catch (DirectoryNotFoundException) { continue; }
            Require((attributes & FileAttributes.ReparsePoint) == 0, T("存档路径包含链接。", "The save path contains a link."), "save_unsafe_path");
        }
    }
    private static void Name(string name)
    {
        Require(!string.IsNullOrEmpty(name) && Encoding.UTF8.GetByteCount(name) <= 1024 &&
            name == name.Normalize(NormalizationForm.FormC) && !name.Contains('\\') && !name.Contains(':') &&
            !name.Any(c => c < 32), T("存档路径无效。", "Invalid save path."));
        string[] parts = name.Split('/');
        Require(parts.Length <= 32 && parts.All(p => p is not "" and not "." and not ".." && !p.EndsWith(' ') && !p.EndsWith('.')), T("存档路径无效。", "Invalid save path."));
    }
    private static bool Allowed(string name, bool directory = false) =>
        (!directory && name == Profile) || Trees.Any(t => directory && name == t || name.StartsWith(t + "/", StringComparison.Ordinal));
    private sealed record Snapshot(SortedDictionary<string, long> Files, List<string> Directories);
    private static Snapshot Scan(string root)
    {
        CheckLinks(root);
        var files = new SortedDictionary<string, long>(StringComparer.Ordinal);
        var dirs = new List<string>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total = 0;
        if (!Directory.Exists(root))
        {
            Require(!File.Exists(root), T("存档根不是目录。", "The save root is not a folder."));
            return new(files, dirs);
        }
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count != 0)
        {
            foreach (string path in Directory.EnumerateFileSystemEntries(pending.Pop()).Order(StringComparer.Ordinal))
            {
                string name = Path.GetRelativePath(root, path);
                Name(name);
                Require(names.Add(name), T("存档路径大小写冲突。", "Save paths conflict by letter case."));
                var attr = File.GetAttributes(path);
                Require((attr & FileAttributes.ReparsePoint) == 0, T("存档包含链接或特殊文件。", "The save contains links or special files."));
                if ((attr & FileAttributes.Directory) != 0)
                {
                    dirs.Add(name);
                    Require(dirs.Count <= MaxFiles, T("存档目录数量超过上限。", "Too many folders in the save."));
                    pending.Push(path);
                }
                else
                {
                    using var file = ReadFile(path);
                    long size = file.Length;
                    total = checked(total + size);
                    Require(files.Count < MaxFiles && total <= MaxBytes, T("存档数据超过上限。", "Save data exceeds the limit."));
                    files.Add(name, size);
                }
            }
        }
        dirs.Sort(StringComparer.Ordinal);
        return new(files, dirs);
    }
    // 只哈希进备份的存档三处（审计 P2-175：原先整个数据根逐文件 SHA-256，着色器缓存一变导出就按「存档变化」失败，大缓存还多两遍哈希）
    private static string Fingerprint(string root)
    {
        var scan = Scan(root);
        var value = new JsonArray(Directory.Exists(root));
        value.Add((JsonNode)new JsonArray(scan.Directories.Where(d => Allowed(d, directory: true)).Select(d => (JsonNode)JsonValue.Create(d)).ToArray()));
        var files = new JsonArray();
        foreach (var file in scan.Files.Where(f => Allowed(f.Key))) files.Add((JsonNode)new JsonArray(file.Key, file.Value, HashFile(Path.Combine(root, file.Key))));
        value.Add((JsonNode)files);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value.ToJsonString())));
    }
    private static void Profiles(byte[] data)
    {
        var root = Parse(data);
        Require(root is JsonObject && root["profiles"] is JsonArray, T("用户资料无效。", "Invalid user profiles."));
        var profiles = root["profiles"].AsArray();
        Require(profiles.Count <= 100, T("用户资料过多。", "Too many user profiles."));
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var profile in profiles)
        {
            string id = Str(profile, "user_id").ToLowerInvariant();
            Require(Hex(id, 32) && id.Any(c => c != '0') && ids.Add(id), T("用户标识无效。", "Invalid user ID."));
            if (profile["name"] != null) _ = profile["name"].GetValue<string>();
        }
    }
    private static JsonArray Entries(Func<string, byte[]> read, IEnumerable<string> files, IEnumerable<string> directories)
    {
        var fileSet = files.ToHashSet(StringComparer.Ordinal);
        var dirSet = directories.ToHashSet(StringComparer.Ordinal);
        Require(fileSet.Contains(Index), T("缺少已提交存档索引。", "The committed save index is missing."));
        byte[] bytes = read(Index);
        Require(bytes.Length is >= 12 and <= MaxMetadata, T("存档索引大小无效。", "Invalid save index size."));
        var indexedEntries = ReadIndex(bytes);
        var entries = new SortedDictionary<string, JsonNode>(StringComparer.Ordinal);
        var attributes = new HashSet<string>(StringComparer.Ordinal);
        var ids = new HashSet<ulong>();
        foreach (var indexedEntry in indexedEntries)
        {
            var attribute = indexedEntry.Attribute;
            var indexed = indexedEntry.Value;
            string key = Convert.ToHexString(MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(in attribute, 1)));
            Require(attributes.Add(key) && indexed.SaveDataId != 0 && ids.Add(indexed.SaveDataId), T("LibHac 索引重复。", "Duplicate LibHac index entry."));
            if ((attribute.Type != SaveDataType.Account && attribute.Type != SaveDataType.Device) || indexed.SpaceId != SaveDataSpaceId.User) continue;
            bool account = attribute.Type == SaveDataType.Account;
            Require(attribute.ProgramId.Value != 0 && attribute.StaticSaveDataId == 0 && (int)attribute.Rank == 0 &&
                attribute.Index == 0 && (int)indexed.State == 0 && (account != (attribute.UserId == UserId.InvalidId)), T("不支持此存档状态或槽位。", "This save state or slot isn’t supported."));
            string sid = indexed.SaveDataId.ToString("x16");
            Require(dirSet.Contains("bis/user/save/" + sid + "/0"), T("缺少已提交存档目录。", "A committed save folder is missing."));
            entries.Add(sid, new JsonObject { ["saveId"] = sid, ["programId"] = attribute.ProgramId.Value.ToString("x16"),
                ["type"] = account ? "account" : "device", ["userId"] = attribute.UserId.Id.High.ToString("x16") + attribute.UserId.Id.Low.ToString("x16") });
        }
        foreach (string name in fileSet.Concat(dirSet).Where(n => n.StartsWith("bis/user/save/", StringComparison.Ordinal)))
        {
            string sid = name.Split('/')[3];
            Require(Hex(sid, 16) && ids.Contains(Convert.ToUInt64(sid, 16)), T("存档目录未被索引覆盖。", "A save folder isn’t covered by the index."));
        }
        Require(entries.Count != 0, T("未找到账号或设备存档。", "No account or device save was found."));
        return new JsonArray(entries.Values.ToArray());
    }
    private static JsonObject Users(JsonArray entries)
    {
        string[] ids = entries.Where(e => Str(e, "type") == "account").Select(e => Str(e, "userId")).Distinct().Order(StringComparer.Ordinal).ToArray();
        return new() { ["ids"] = new JsonArray(ids.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()), ["active"] = ids.FirstOrDefault() ?? "" };
    }
    private static JsonObject Settings(JsonNode value)
    {
        if (value == null) return new();
        Require(value is JsonObject, T("设备设置元信息必须为对象。", "Device settings metadata must be an object."));
        foreach (var pair in value.AsObject())
            Require(pair.Key is "system_time" or "language" or "region" or "timezone" && pair.Value is JsonValue && pair.Value.GetValue<string>().Length <= 256, T("设备设置元信息无效。", "Invalid device settings metadata."));
        return (JsonObject)value.DeepClone();
    }
    private sealed class Context
    {
        internal readonly JsonNode Request, Game;
        internal readonly string Root, Work, Transactions, Backups, Journal;
        internal Context(JsonNode request)
        {
            Request = request;
            Game = request["game"] ?? throw new Failure("save_game_id", T("缺少游戏标识。", "The game identity is missing."));
            string id = Str(Game, "id");
            Require(Hex(id.ToLowerInvariant(), 16), T("游戏标识无效。", "Invalid game identity."), "save_game_id");
            Require(Game["version"].GetValue<long>() >= 0 && Hex(Str(Game, "contentIdentity"), 64), T("游戏版本或内容标识无效。", "Invalid game version or content identity."));
            _ = Str(Game, "name");
            Root = Absolute(Str(request, "dataRoot"));
            Work = Absolute(Str(request, "workRoot"));
            Require(!Within(Root, Work) && !Within(Work, Root), T("数据根与事务目录必须独立。", "The data root and the transaction folder must be separate."));
            DurableDirectory(Work);
            Transactions = Path.Combine(Work, "save-transactions");
            Backups = Path.Combine(Work, "save-backups", id);
            Journal = Path.Combine(Transactions, id + ".json");
            CheckLinks(Transactions); CheckLinks(Backups);
            Require(!File.Exists(Transactions) && !File.Exists(Backups), T("存档事务或备份路径不是目录。", "The save transaction or backup path is not a folder."), "save_recovery");
        }
    }
    /// <summary>Returns a JSON envelope. Errors never include save contents or keys.</summary>
    public static string Execute(string requestJson)
    {
        lock (Gate)
        {
            try
            {
                UseLanguage(requestJson);
                _ = DirectoryTransaction;
                var c = new Context(Parse(Encoding.UTF8.GetBytes(requestJson)));
                string lockPath = Path.Combine(c.Work, "save-transfer.lock");
                CheckLinks(lockPath);
                using var execution = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                bool recovered = Recover(c);
                JsonObject result = Str(c.Request, "operation") switch
                {
                    "recover" => new() { ["recovered"] = recovered },
                    "status" => Status(c, recovered),
                    "export" => Export(c),
                    "inspect" => Inspect(c),
                    "restore" => Restore(c),
                    _ => throw new Failure("save_invalid", T("未知存档操作。", "Unknown save operation."))
                };
                return new JsonObject { ["ok"] = true, ["result"] = result }.ToJsonString();
            }
            catch (Failure ex) { return Error(ex.Code, ex.Message); }
            catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or JsonException or OverflowException or NotSupportedException or KeyNotFoundException)
            {
                System.Console.Error.WriteLine("存档操作失败：" + ex.GetType().Name + "（" + ex.HResult + "）：" + ex.Message);
                var (code, message) = Describe(ex);
                return Error(code, message);
            }
            catch (Exception ex)
            {
#if SAVE_TRANSFER_TEST
                System.Console.Error.WriteLine(ex);
#endif
                return Error("save_unsupported_runtime", T("存档格式库或运行时不兼容：", "The save format library or runtime is incompatible: ") + ex.GetType().Name + T("。未完成的事务记录已保留。", ". Unfinished transaction records are kept."));
            }
        }
    }
    // 失败原因转人话（审计 P2-11：原先玩家只看到「存档操作失败：IOException」）：按 errno / 异常类型分成空间不足、没权限、备份损坏、
    //   读写出错、数据不符五句，与 Mac pack/jobs/saves.py 同口径；类型名与系统原文只进 stderr 日志。
    //   .NET 在 Unix 上把 errno 原样放进 IOException.HResult（ENOSPC 28、EDQUOT 69 / Linux 122、EACCES 13、EPERM 1）；Windows 磁盘满是 112
    internal static (string Code, string Message) Describe(Exception ex)
    {
        string keep = T("原副本与事务记录已保留。", " The original copy and transaction records are kept.");
        int e = ex is IOException ? ex.HResult & 0xFFFF : 0;
        if (e is 28 or 69 or 122 or 112) return ("save_space", T("设备存储空间不足，存档操作没有完成。请清理空间后重试。", "Not enough storage on the device, so the save operation didn’t finish. Free up space and try again.") + keep);
        if (ex is UnauthorizedAccessException || e is 1 or 13) return ("save_invalid", T("没有权限读写存档目录，存档操作没有完成。请关闭 App 重新打开后再试。", "No permission to read or write the save folder, so the save operation didn’t finish. Close and reopen the app, then try again.") + keep);
        if (ex is InvalidDataException or JsonException or OverflowException) return ("save_invalid", T("备份文件已损坏或格式不对。请重新导出一份备份再试。", "The backup file is damaged or in the wrong format. Export a new backup and try again.") + keep);
        if (ex is IOException) return ("save_invalid", T("读写存档时出错，存档操作没有完成。请关闭 App 重新打开后再试；仍失败可导出诊断包。", "An error occurred while reading or writing the save, so the save operation didn’t finish. Close and reopen the app, then try again; if it still fails, export diagnostics.") + keep);
        return ("save_invalid", T("存档数据不符合要求，这次操作没有完成。", "The save data doesn’t meet the requirements, so this operation didn’t finish.") + keep);
    }
    internal static string Error(string code, string message) => new JsonObject { ["ok"] = false,
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message } }.ToJsonString();

    private static IHostDirectoryTransaction DirectoryTransaction
    {
        get
        {
            var transaction = S2AHostFileSystem.Transaction;
            if (transaction != null) return transaction;
            Console.Error.WriteLine("【红】存档迁移：宿主尚未登记存档目录事务接口，拒绝操作。");
            throw new Failure("save_unsupported_runtime", T("宿主尚未登记存档目录事务接口。", "The host hasn’t registered the save folder transaction interface."));
        }
    }

    // The platform provider rejects links and non-regular files without blocking.
    private static FileStream ReadFile(string path)
    {
        CheckLinks(path);
        int error = DirectoryTransaction.OpenRead(path, out SafeFileHandle handle);
        if (error != 0) throw new IOException("Cannot open regular save file.", error);
        try
        {
            var stream = new FileStream(handle, FileAccess.Read);
            _ = stream.Length;
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }
    private static void SyncDirectory(string path)
    {
        CheckLinks(path);
        int error = DirectoryTransaction.SyncDirectory(path);
        if (error != 0) throw new IOException("Cannot sync save directory.", error);
    }
}
