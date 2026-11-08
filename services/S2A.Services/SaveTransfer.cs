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
    private static void Require(bool value, string message, string code = "save_invalid")
    {
        if (!value) throw new Failure(code, message);
    }
    private static JsonNode Parse(ReadOnlySpan<byte> bytes)
    {
        Require(bytes.Length <= MaxMetadata, "JSON 元数据超过上限。");
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { MaxDepth = 64 });
        var objects = new Stack<HashSet<string>>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
            else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
            else if (reader.TokenType == JsonTokenType.PropertyName)
                Require(objects.Peek().Add(reader.GetString()), "JSON 字段重复。");
        }
        return JsonNode.Parse(bytes) ?? throw new Failure("save_invalid", "JSON 内容为空。");
    }
    private static string Str(JsonNode node, string key) => node[key]?.GetValue<string>()
        ?? throw new Failure("save_invalid", "缺少字段：" + key);
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
        Require(file.Length <= MaxMetadata, "存档元数据超过上限。");
        using var memory = new MemoryStream();
        file.CopyTo(memory);
        Require(memory.Length <= MaxMetadata, "存档元数据超过上限。");
        return memory.ToArray();
    }
    private static string Absolute(string path)
    {
        Require(Path.IsPathFullyQualified(path) && Path.GetFullPath(path) == path.TrimEnd('/'), "需要规范的绝对路径。");
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
            Require((attributes & FileAttributes.ReparsePoint) == 0, "存档路径包含链接。", "save_unsafe_path");
        }
    }
    private static void Name(string name)
    {
        Require(!string.IsNullOrEmpty(name) && Encoding.UTF8.GetByteCount(name) <= 1024 &&
            name == name.Normalize(NormalizationForm.FormC) && !name.Contains('\\') && !name.Contains(':') &&
            !name.Any(c => c < 32), "存档路径无效。");
        string[] parts = name.Split('/');
        Require(parts.Length <= 32 && parts.All(p => p is not "" and not "." and not ".." && !p.EndsWith(' ') && !p.EndsWith('.')), "存档路径无效。");
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
            Require(!File.Exists(root), "存档根不是目录。");
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
                Require(names.Add(name), "存档路径大小写冲突。");
                var attr = File.GetAttributes(path);
                Require((attr & FileAttributes.ReparsePoint) == 0, "存档包含链接或特殊文件。");
                if ((attr & FileAttributes.Directory) != 0)
                {
                    dirs.Add(name);
                    Require(dirs.Count <= MaxFiles, "存档目录数量超过上限。");
                    pending.Push(path);
                }
                else
                {
                    using var file = ReadFile(path);
                    long size = file.Length;
                    total = checked(total + size);
                    Require(files.Count < MaxFiles && total <= MaxBytes, "存档数据超过上限。");
                    files.Add(name, size);
                }
            }
        }
        dirs.Sort(StringComparer.Ordinal);
        return new(files, dirs);
    }
    private static string Fingerprint(string root)
    {
        var scan = Scan(root);
        var value = new JsonArray(Directory.Exists(root));
        value.Add((JsonNode)new JsonArray(scan.Directories.Select(d => (JsonNode)JsonValue.Create(d)).ToArray()));
        var files = new JsonArray();
        foreach (var file in scan.Files) files.Add((JsonNode)new JsonArray(file.Key, file.Value, HashFile(Path.Combine(root, file.Key))));
        value.Add((JsonNode)files);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value.ToJsonString())));
    }
    private static void Profiles(byte[] data)
    {
        var root = Parse(data);
        Require(root is JsonObject && root["profiles"] is JsonArray, "用户资料无效。");
        var profiles = root["profiles"].AsArray();
        Require(profiles.Count <= 100, "用户资料过多。");
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var profile in profiles)
        {
            string id = Str(profile, "user_id").ToLowerInvariant();
            Require(Hex(id, 32) && id.Any(c => c != '0') && ids.Add(id), "用户标识无效。");
            if (profile["name"] != null) _ = profile["name"].GetValue<string>();
        }
    }
    private static JsonArray Entries(Func<string, byte[]> read, IEnumerable<string> files, IEnumerable<string> directories)
    {
        var fileSet = files.ToHashSet(StringComparer.Ordinal);
        var dirSet = directories.ToHashSet(StringComparer.Ordinal);
        Require(fileSet.Contains(Index), "缺少已提交存档索引。");
        byte[] bytes = read(Index);
        Require(bytes.Length is >= 12 and <= MaxMetadata, "存档索引大小无效。");
        var indexedEntries = ReadIndex(bytes);
        var entries = new SortedDictionary<string, JsonNode>(StringComparer.Ordinal);
        var attributes = new HashSet<string>(StringComparer.Ordinal);
        var ids = new HashSet<ulong>();
        foreach (var indexedEntry in indexedEntries)
        {
            var attribute = indexedEntry.Attribute;
            var indexed = indexedEntry.Value;
            string key = Convert.ToHexString(MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(in attribute, 1)));
            Require(attributes.Add(key) && indexed.SaveDataId != 0 && ids.Add(indexed.SaveDataId), "LibHac 索引重复。");
            if ((attribute.Type != SaveDataType.Account && attribute.Type != SaveDataType.Device) || indexed.SpaceId != SaveDataSpaceId.User) continue;
            bool account = attribute.Type == SaveDataType.Account;
            Require(attribute.ProgramId.Value != 0 && attribute.StaticSaveDataId == 0 && (int)attribute.Rank == 0 &&
                attribute.Index == 0 && (int)indexed.State == 0 && (account != (attribute.UserId == UserId.InvalidId)), "不支持此存档状态或槽位。");
            string sid = indexed.SaveDataId.ToString("x16");
            Require(dirSet.Contains("bis/user/save/" + sid + "/0"), "缺少已提交存档目录。");
            entries.Add(sid, new JsonObject { ["saveId"] = sid, ["programId"] = attribute.ProgramId.Value.ToString("x16"),
                ["type"] = account ? "account" : "device", ["userId"] = attribute.UserId.Id.High.ToString("x16") + attribute.UserId.Id.Low.ToString("x16") });
        }
        foreach (string name in fileSet.Concat(dirSet).Where(n => n.StartsWith("bis/user/save/", StringComparison.Ordinal)))
        {
            string sid = name.Split('/')[3];
            Require(Hex(sid, 16) && ids.Contains(Convert.ToUInt64(sid, 16)), "存档目录未被索引覆盖。");
        }
        Require(entries.Count != 0, "未找到账号或设备存档。");
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
        Require(value is JsonObject, "设备设置元信息必须为对象。");
        foreach (var pair in value.AsObject())
            Require(pair.Key is "system_time" or "language" or "region" or "timezone" && pair.Value is JsonValue && pair.Value.GetValue<string>().Length <= 256, "设备设置元信息无效。");
        return (JsonObject)value.DeepClone();
    }
    private sealed class Context
    {
        internal readonly JsonNode Request, Game;
        internal readonly string Root, Work, Transactions, Backups, Journal;
        internal Context(JsonNode request)
        {
            Request = request;
            Game = request["game"] ?? throw new Failure("save_game_id", "缺少游戏标识。");
            string id = Str(Game, "id");
            Require(Hex(id.ToLowerInvariant(), 16), "游戏标识无效。", "save_game_id");
            Require(Game["version"].GetValue<long>() >= 0 && Hex(Str(Game, "contentIdentity"), 64), "游戏版本或内容标识无效。");
            _ = Str(Game, "name");
            Root = Absolute(Str(request, "dataRoot"));
            Work = Absolute(Str(request, "workRoot"));
            Require(!Within(Root, Work) && !Within(Work, Root), "数据根与事务目录必须独立。");
            DurableDirectory(Work);
            Transactions = Path.Combine(Work, "save-transactions");
            Backups = Path.Combine(Work, "save-backups", id);
            Journal = Path.Combine(Transactions, id + ".json");
            CheckLinks(Transactions); CheckLinks(Backups);
            Require(!File.Exists(Transactions) && !File.Exists(Backups), "存档事务或备份路径不是目录。", "save_recovery");
        }
    }
    /// <summary>Returns a JSON envelope. Errors never include save contents or keys.</summary>
    public static string Execute(string requestJson)
    {
        lock (Gate)
        {
            try
            {
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
                    _ => throw new Failure("save_invalid", "未知存档操作。")
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
                return Error("save_unsupported_runtime", "存档格式库或运行时不兼容：" + ex.GetType().Name + "。未完成的事务记录已保留。");
            }
        }
    }
    // 失败原因转人话（审计 P2-11：原先玩家只看到「存档操作失败：IOException」）：按 errno / 异常类型分成空间不足、没权限、备份损坏、
    //   读写出错、数据不符五句，与 Mac pack/jobs/saves.py 同口径；类型名与系统原文只进 stderr 日志。
    //   .NET 在 Unix 上把 errno 原样放进 IOException.HResult（ENOSPC 28、EDQUOT 69 / Linux 122、EACCES 13、EPERM 1）；Windows 磁盘满是 112
    internal static (string Code, string Message) Describe(Exception ex)
    {
        const string keep = "原副本与事务记录已保留。";
        int e = ex is IOException ? ex.HResult & 0xFFFF : 0;
        if (e is 28 or 69 or 122 or 112) return ("save_space", "设备存储空间不足，存档操作没有完成。请清理空间后重试。" + keep);
        if (ex is UnauthorizedAccessException || e is 1 or 13) return ("save_invalid", "没有权限读写存档目录，存档操作没有完成。请关闭 App 重新打开后再试。" + keep);
        if (ex is InvalidDataException or JsonException or OverflowException) return ("save_invalid", "备份文件已损坏或格式不对。请重新导出一份备份再试。" + keep);
        if (ex is IOException) return ("save_invalid", "读写存档时出错，存档操作没有完成。请关闭 App 重新打开后再试；仍失败可导出诊断包。" + keep);
        return ("save_invalid", "存档数据不符合要求，这次操作没有完成。" + keep);
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
            throw new Failure("save_unsupported_runtime", "宿主尚未登记存档目录事务接口。");
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
