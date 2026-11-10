// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 控制口对 s2armctl 的约定：头 + Content-Length、令牌校验、control.json 的三个字段、/state 走缓存不经处理函数。
public static class ControlPortCases
{
    private static async Task<string> Ask(int port, string raw)
    {
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", port);
        var stream = client.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes(raw));
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return await reader.ReadToEndAsync();
    }

    public static async Task Run(Action<bool, string> check)
    {
        check(ControlRequest.Parse("POST /keys HTTP/1.1\r\nContent-Length: 5\r\n\r\n{\"a\""u8) is null, "control: incomplete body waits");
        var parsed = ControlRequest.Parse("POST /games?x=1 HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"paths\":[\"p\"]}"u8);
        check(parsed is { Method: "POST", Path: "/games" } && parsed.Strings("paths")?.Single() == "p", "control: path without query, body strings");

        var root = Path.Combine(Path.GetTempPath(), "s2a-control-" + Guid.NewGuid().ToString("N"));
        var handled = 0;
        PrivateJobRequest.EnsurePrivateRoot(root);
        Directory.CreateDirectory(root);
        ControlPort.ReportStartFailure(root, "port busy");
        var errorFile = Path.Combine(root, ControlPort.ErrorFileName);
        check(File.ReadAllText(errorFile) == "port busy", "control: start failure reason reaches the data root");
        using (var port = new ControlPort(root, r => { handled++; return Task.FromResult(ControlReply.Ok()); }))
        {
            check(!File.Exists(errorFile), "control: successful start clears the old failure");
            using var info = JsonDocument.Parse(File.ReadAllText(port.ControlFile));
            check(info.RootElement.GetProperty("port").GetInt32() == port.Port && info.RootElement.GetProperty("token").GetString() == port.Token &&
                  info.RootElement.GetProperty("pid").GetInt32() == Environment.ProcessId, "control: control.json port, token, pid");
            check((await Ask(port.Port, "POST /refresh HTTP/1.1\r\nX-S2Arm-Token: wrong\r\n\r\n")).StartsWith("HTTP/1.1 401") && handled == 0, "control: wrong token refused before the handler");
            port.UpdateState("{\"cached\":true}"u8.ToArray());
            var state = await Ask(port.Port, $"GET /state HTTP/1.1\r\nX-S2Arm-Token: {port.Token}\r\n\r\n");
            check(state.StartsWith("HTTP/1.1 200") && state.EndsWith("{\"cached\":true}") && handled == 0, "control: /state served from cache");
            check((await Ask(port.Port, $"POST /refresh HTTP/1.1\r\nX-S2Arm-Token: {port.Token}\r\n\r\n")).StartsWith("HTTP/1.1 200") && handled == 1, "control: command reaches the handler");
            var file = port.ControlFile;
            port.Dispose();
            check(!File.Exists(file), "control: stop removes control.json");
        }
        // 作业记录：看不见的作业不进；running 且进程还在照报；running 但进程没了按中断报
        var jobs = Path.Combine(root, "logs", "jobs");   // 没设置库：作业记录在 私有目录\logs\jobs（LibraryPaths.JobsDir）
        Directory.CreateDirectory(jobs);
        File.WriteAllText(Path.Combine(jobs, "a.json"), "{\"id\":\"a\",\"operation\":\"catalog\",\"state\":\"completed\",\"started\":1}");
        File.WriteAllText(Path.Combine(jobs, "b.json"), $"{{\"id\":\"b\",\"operation\":\"ipa\",\"state\":\"running\",\"started\":2,\"pid\":{Environment.ProcessId}}}");
        File.WriteAllText(Path.Combine(jobs, "c.json"), "{\"id\":\"c\",\"operation\":\"ipa\",\"state\":\"running\",\"started\":3,\"pid\":2147483646}");
        File.WriteAllText(Path.Combine(jobs, "c.request.json"), "{\"id\":\"x\",\"operation\":\"ipa\"}");
        var tasks = ControlJournal.Tasks(root);
        check(tasks.Count == 2 && tasks[0].GetProperty("id").GetString() == "b" && tasks[0].GetProperty("state").GetString() == "running", "journal: live job stays running, hidden and request files skipped");
        check(tasks[1].GetProperty("state").GetString() == "interrupted", "journal: running job with a dead process reads interrupted");
        // 游戏库结构 P3：库建好（有 .s2arm-library.json）后日志与作业记录在 库\logs；只有文件夹没标识仍在私有目录
        var lib = Path.Combine(root, "lib");
        Directory.CreateDirectory(lib);
        File.WriteAllText(LibraryPaths.PreferenceFile(root), lib);
        check(LibraryPaths.JobsDir(root) == Path.Combine(root, "logs", "jobs"), "paths: unbuilt library keeps logs in the private root");
        File.WriteAllText(Path.Combine(lib, ".s2arm-library.json"), "{\"schema\":1,\"id\":\"x\"}");
        check(LibraryPaths.JobsDir(root) == Path.Combine(lib, "logs", "jobs") && LibraryPaths.LogsRoot(root, lib) == Path.Combine(lib, "logs"), "paths: built library holds logs and jobs");
        check(LibraryPaths.DefaultLibrary(root) == Path.Combine(root, "DefaultLibrary"), "paths: custom data root keeps its own default library");
        // 私有目录 / 新缺省库和作业层同一取法：先读 LOCALAPPDATA / USERPROFILE 环境变量（作业层 layout.standard_private、Path.home()）
        var savedLocal = Environment.GetEnvironmentVariable("LOCALAPPDATA"); var savedProfile = Environment.GetEnvironmentVariable("USERPROFILE");
        try
        {
            Environment.SetEnvironmentVariable("LOCALAPPDATA", Path.Combine(root, "AppData", "Local"));
            Environment.SetEnvironmentVariable("USERPROFILE", Path.Combine(root, "home"));
            check(LibraryPaths.StandardPrivateRoot == Path.Combine(root, "AppData", "Local", "S2Arm", "WindowsLauncher"), "paths: private root follows LOCALAPPDATA like the job layer");
            check(LibraryPaths.DefaultLibrary(LibraryPaths.StandardPrivateRoot) == Path.Combine(root, "home", "S2Arm"), "paths: new default library follows USERPROFILE like the job layer");
        }
        finally { Environment.SetEnvironmentVariable("LOCALAPPDATA", savedLocal); Environment.SetEnvironmentVariable("USERPROFILE", savedProfile); }
        // 搬库标记：设置里是旧路径、新位置有库、旧位置没库 → 用新位置；别的路径不动
        var old = Path.Combine(root, "DefaultLibrary");
        File.WriteAllText(Path.Combine(root, "library-relocate.json"), JsonSerializer.Serialize(new Dictionary<string, string> { ["from"] = old, ["to"] = lib, ["state"] = "done" }));
        check(LibraryPaths.Library(root, old) == lib, "paths: relocated default library follows the marker");
        check(LibraryPaths.Library(root, Path.Combine(root, "other")) == Path.Combine(root, "other"), "paths: a player-chosen library is untouched");
        // 0.1.x 老玩家升级（没有 library-location.txt、库在私有目录下的 DefaultLibrary）：缺省库换成用户主目录后也要先交旧路径给作业层去搬
        var up = Path.Combine(Path.GetTempPath(), "s2a-upgrade-" + Guid.NewGuid().ToString("N"));
        var upLegacy = LibraryPaths.LegacyDefaultLibrary(up);
        var upNew = Path.Combine(up, "home", "S2Arm");
        Directory.CreateDirectory(upLegacy);
        File.WriteAllText(Path.Combine(upLegacy, ".s2arm-library.json"), "{\"schema\":1,\"id\":\"old\"}");
        check(LibraryPaths.SavedLibrary(up, upNew) == upLegacy, "paths: upgrade without settings hands the old default library to the job layer");
        Directory.CreateDirectory(upNew); File.WriteAllText(Path.Combine(upNew, "README.md"), "someone else's folder");
        check(LibraryPaths.SavedLibrary(up, upNew) == upLegacy, "paths: new default folder taken by other files keeps the old library");
        Directory.Delete(upNew, true);
        // ③ 0.2.0 已在新位置建了空库（有库标识、0 款），旧库里有游戏、玩家没选过位置：接回旧库
        Directory.CreateDirectory(upNew); File.WriteAllText(Path.Combine(upNew, ".s2arm-library.json"), "{\"schema\":1,\"id\":\"empty-new\"}");
        check(LibraryPaths.SavedLibrary(up, upNew) == upLegacy, "paths: an empty library made at the new default by 0.2.0 does not hide the old one");
        // 按临时绕法把位置选回旧库（设置文件指向旧路径）：照用旧库
        File.WriteAllText(LibraryPaths.PreferenceFile(up), upLegacy);
        check(LibraryPaths.SavedLibrary(up, upNew) == upLegacy, "paths: the workaround setting pointing at the old library keeps working");
        File.Delete(LibraryPaths.PreferenceFile(up));
        Directory.Delete(upNew, true);
        Directory.Move(upLegacy, upNew);   // 作业层搬成：旧位置没了、新位置有库、搬库标记 done
        File.WriteAllText(Path.Combine(up, "library-relocate.json"), JsonSerializer.Serialize(new Dictionary<string, string> { ["from"] = upLegacy, ["to"] = upNew, ["state"] = "done" }));
        check(LibraryPaths.SavedLibrary(up, upNew) == upNew, "paths: after the job layer moved it the library is the new default");
        var fresh = Path.Combine(up, "fresh");
        Directory.CreateDirectory(fresh);
        check(LibraryPaths.SavedLibrary(fresh, upNew) == upNew, "paths: a fresh install uses the new default library");
        Directory.Delete(up, true);
        Directory.Delete(root, true);
    }
}
