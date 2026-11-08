using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using S2A.Services;

Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();

if (args.Length == 2 && args[0] == "--request")
{
    Console.WriteLine(SaveTransfer.Execute(File.ReadAllText(args[1])));
    return;
}
if (args.Length == 4 && args[0] == "--crash-child")
{
    Environment.SetEnvironmentVariable("SAVE_TRANSFER_CHECKPOINT", args[2]);
    Environment.SetEnvironmentVariable("SAVE_TRANSFER_SIGNAL", args[3]);
    Console.WriteLine(SaveTransfer.Execute(File.ReadAllText(args[1])));
    return;
}
if (args.Length != 6 || args[0] != "--source" || args[2] != "--game" || args[4] != "--g05")
    throw new ArgumentException("Use --request request.json, or --source /private/real-root --game identity.json --g05 real-g05.s2asave. Source is read only; tests use private temporary copies.");
RealTests.Run(args[1], args[3], args[5]);

internal static class RealTests
{
    private static JsonObject game;
    private static string source;
    private static string progress;
    private static int passed;
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    private static JsonObject Request(string root, string work, string operation, string path = null) => new()
    {
        ["operation"] = operation, ["dataRoot"] = root, ["workRoot"] = work, ["game"] = game.DeepClone(), ["path"] = path
    };
    private static JsonObject Call(JsonObject request)
    {
        var response = JsonNode.Parse(SaveTransfer.Execute(request.ToJsonString()));
        Assert(response["ok"].GetValue<bool>(), response.ToJsonString());
        return response["result"].AsObject();
    }
    private static void Reject(JsonObject request, string code = null)
    {
        var response = JsonNode.Parse(SaveTransfer.Execute(request.ToJsonString()));
        Assert(!response["ok"].GetValue<bool>(), "Expected rejection");
        if (code != null) Assert(response["error"]["code"].GetValue<string>() == code, response.ToJsonString());
    }
    private static void Pass(string name) { passed++; Console.WriteLine("PASS " + name); }
    private static SortedDictionary<string, string> Hashes(string root) => new(Directory.GetFiles(root, "*", SearchOption.AllDirectories)
        .ToDictionary(p => Path.GetRelativePath(root, p), p => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(p)))), StringComparer.Ordinal);
    private static bool Equal(SortedDictionary<string, string> a, SortedDictionary<string, string> b) => a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var hash) && hash == p.Value);
    private static void Copy(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string dir in Directory.GetDirectories(from, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        foreach (string file in Directory.GetFiles(from, "*", SearchOption.AllDirectories)) File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
    }
    private static JsonObject Confirm(string root, string work, string archive)
    {
        var preview = Call(Request(root, work, "inspect", archive));
        var request = Request(root, work, "restore", archive);
        request["archiveSha256"] = preview["archiveSha256"].DeepClone();
        request["targetFingerprint"] = preview["targetFingerprint"].DeepClone();
        return request;
    }
    private static void MutateProgress(string root)
    {
        string path = Path.Combine(root, progress);
        byte[] bytes = File.ReadAllBytes(path);
        Assert(bytes.Length > 0, "Need a nonempty real savedata file");
        bytes[0] ^= 0x40;
        File.WriteAllBytes(path, bytes);
    }
    private static void Rewrite(string input, string output, Action<JsonObject> change = null, string extra = null)
    {
        using var original = ZipFile.OpenRead(input);
        using var zip = ZipFile.Open(output, ZipArchiveMode.Create);
        foreach (var entry in original.Entries)
        {
            using var src = entry.Open();
            using var dst = zip.CreateEntry(entry.FullName).Open();
            if (entry.FullName == "manifest.json" && change != null)
            {
                var manifest = JsonNode.Parse(src).AsObject(); change(manifest);
                dst.Write(Encoding.UTF8.GetBytes(manifest.ToJsonString()));
            }
            else src.CopyTo(dst);
        }
        if (extra != null) using (var target = zip.CreateEntry(extra).Open()) target.WriteByte(1);
    }
    internal static void Run(string sourcePath, string gamePath, string macArchive)
    {
        source = Path.GetFullPath(sourcePath);
        macArchive = Path.GetFullPath(macArchive);
        game = JsonNode.Parse(File.ReadAllText(gamePath)).AsObject();
        var original = Hashes(source);
        progress = original.Keys.First(p => p.StartsWith("bis/user/save/", StringComparison.Ordinal) && p.Contains("/0/") && new FileInfo(Path.Combine(source, p)).Length > 0);
        string scratch = Path.Combine(Path.GetTempPath(), "s2arm-transfer-" + Guid.NewGuid().ToString("N"));
        if (scratch.StartsWith("/var/")) scratch = "/private" + scratch;
        Directory.CreateDirectory(scratch);
        string root = Path.Combine(scratch, "source"), work = Path.Combine(scratch, "work"), archive = Path.Combine(scratch, "save.s2asave");
        try
        {
            Copy(source, root);
            var g05 = Call(Request(root, work, "inspect", macArchive));
            Assert(g05["fileCount"].GetValue<int>() > 0, "Real G05 archive"); Pass("inspect real G05 archive with exact game identity");
            Call(Request(root, work, "export", archive));
            var preview = Call(Request(root, work, "inspect", archive));
            Assert(preview["manifest"]["files"].AsArray().All(f => !f["path"].GetValue<string>().Contains("saveMeta")), "Whitelist");
            Pass("export real private save copy and validate CRC/hash/index");
            Reject(Request(root, work, "export", archive), "save_exists"); Pass("exclusive export");
            var stale = Confirm(root, work, archive);
            MutateProgress(root); Reject(stale, "save_changed"); Pass("changed target after preview");
            var restored = Call(Confirm(root, work, archive));
            Assert(restored["committed"].GetValue<bool>() && Equal(original, Hashes(root)), "byte-for-byte restore including nonwhitelisted original data");
            Assert(File.Exists(restored["previousBackup"].GetValue<string>()), "Previous archive");
            Call(Request(root, work, "inspect", restored["previousBackup"].GetValue<string>()));
            Call(Request(root, work, "recover"));
            Pass("real save restore, preserved saveMeta and selectable previous backup");
            string emptyRoot = Path.Combine(scratch, "empty");
            Call(Confirm(emptyRoot, work + "-empty", macArchive));
            foreach (var file in g05["manifest"]["files"].AsArray())
                Assert(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(emptyRoot, file["path"].GetValue<string>())))) == file["sha256"].GetValue<string>(), "G05 imported bytes");
            Pass("restore actual G05 archive into empty target");
            var wrong = Request(root, work, "inspect", archive); wrong["game"]["id"] = "0000000000000000"; Reject(wrong, "save_wrong_game");
            wrong = Request(root, work, "inspect", archive); wrong["game"]["version"] = game["version"].GetValue<long>() + 1; Reject(wrong, "save_version");
            wrong = Request(root, work, "inspect", archive); wrong["game"]["contentIdentity"] = new string('0', 64); Reject(wrong, "save_version");
            Pass("reject game/version/contentIdentity mismatch");
            string other = Path.Combine(scratch, "other-owner"); Copy(source, other); OwnershipVariant.Change(other);
            Reject(Request(other, work + "-other", "inspect", archive), "save_wrong_user"); Pass("reject changed actual LibHac account owner");
            string duplicate = Path.Combine(scratch, "duplicate-index"); Copy(source, duplicate);
            string indexPath = Path.Combine(duplicate, "bis/system/save/8000000000000000/0/imkvdb.arc");
            byte[] indexBytes = File.ReadAllBytes(indexPath);
            Assert(indexBytes.Length >= 292, "Need actual multi-entry index for malformed ownership check");
            indexBytes.AsSpan(24, 64).CopyTo(indexBytes.AsSpan(164, 64));
            File.WriteAllBytes(indexPath, indexBytes);
            RejectInChild(Request(duplicate, work + "-duplicate", "status"), scratch);
            Pass("malformed duplicate actual index fails without terminating process");
            string bad = Path.Combine(scratch, "bad.s2asave");
            Rewrite(archive, bad, m => m["schema"] = 2); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, extra: "payload/../escape"); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, extra: "MANIFEST.json"); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["files"][0]["sha256"] = new string('0', 64)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["saveEntries"][0]["userId"] = new string('0', 32)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["saveEntries"] = null); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Rewrite(archive, bad, m => m["deviceSettings"] = null); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("reject altered real archive: unknown schema, traversal, collisions, hash and forged ownership");
            Rewrite(archive, bad, m => { m.Remove("saveEntries"); m.Remove("deviceSettings"); m["users"] = new JsonObject(); });
            Call(Request(root, work, "inspect", bad)); File.Delete(bad); Pass("old schema1 derives owner from actual committed index");
            byte[] archiveBytes = File.ReadAllBytes(archive);
            File.WriteAllBytes(bad, archiveBytes.Concat(new byte[] { 1, 2, 3 }).ToArray()); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, new byte[] { 1, 2, 3 }.Concat(archiveBytes).ToArray()); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("reject trailing and prepended data");
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, false)); Call(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, false, true)); Call(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, true, false)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            File.WriteAllBytes(bad, SaveTransfer.Zip64Variant(archiveBytes, false, true)); Reject(Request(root, work, "inspect", bad)); File.Delete(bad);
            Pass("standard ZIP64 accepts actual archive; excessive count and extensible record reject before entries");
            File.CreateSymbolicLink(Path.Combine(root, "link"), archive); Reject(Request(root, work, "export", bad)); File.Delete(Path.Combine(root, "link")); Pass("reject source symlink");
            foreach (string phase in new[] { "prepared", "oldMoved", "newMoved", "committed" }) Crash(scratch, phase, archive);
            Assert(Equal(original, Hashes(source)), "Source savedata was modified"); Pass("source savedata hashes unchanged");
            Console.WriteLine($"Save transfer actual-data verification: {passed} groups passed; no game was launched.");
        }
        finally { Directory.Delete(scratch, recursive: true); }
    }
    private static ProcessStartInfo Driver()
    {
        string executable = Environment.ProcessPath;
        var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable) == "dotnet") start.ArgumentList.Add(typeof(RealTests).Assembly.Location);
        return start;
    }
    private static void RejectInChild(JsonObject request, string scratch)
    {
        string path = Path.Combine(scratch, "bad-index-request.json");
        File.WriteAllText(path, request.ToJsonString());
        var start = Driver(); start.ArgumentList.Add("--request"); start.ArgumentList.Add(path);
        using var process = Process.Start(start);
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        Assert(process.WaitForExit(20000) && process.ExitCode == 0, "Malformed index terminated process: " + error);
        Assert(!JsonNode.Parse(output)["ok"].GetValue<bool>(), "Malformed index accepted");
    }
    private static void Crash(string scratch, string phase, string archive)
    {
        string root = Path.Combine(scratch, "crash-" + phase), work = root + "-work";
        Copy(source, root); MutateProgress(root);
        var before = Hashes(root);
        string request = root + ".json", signal = root + ".checkpoint";
        File.WriteAllText(request, Confirm(root, work, archive).ToJsonString());
        var start = Driver();
        foreach (string arg in new[] { "--crash-child", request, phase, signal }) start.ArgumentList.Add(arg);
        using var child = Process.Start(start);
        var timer = Stopwatch.StartNew();
        while (!File.Exists(signal) && !child.HasExited && timer.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(10);
        Assert(File.Exists(signal), "Checkpoint failed: " + phase + (child.HasExited ? child.StandardError.ReadToEnd() + child.StandardOutput.ReadToEnd() : " timeout"));
        child.Kill(); child.WaitForExit();
        Call(Request(root, work, "recover"));
        Assert(Equal(phase == "committed" ? Hashes(source) : before, Hashes(root)), "Crash recovery bytes: " + phase);
        Pass("real child kill and actual-data recovery at " + phase);
    }
}

namespace S2A.Services
{
    public static partial class SaveTransfer
    {
        static partial void Checkpoint(string phase)
        {
            if (Environment.GetEnvironmentVariable("SAVE_TRANSFER_CHECKPOINT") != phase) return;
            File.WriteAllText(Environment.GetEnvironmentVariable("SAVE_TRANSFER_SIGNAL"), phase);
            Thread.Sleep(Timeout.Infinite);
        }
    }
}
