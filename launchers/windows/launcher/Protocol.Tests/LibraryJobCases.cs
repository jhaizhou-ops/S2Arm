// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

internal static class LibraryJobCases
{
    public static void Run(Action<bool, string> check)
    {
        // 导入失败的去向：只有读取器确认通用密钥版本不足（keys_outdated）才引导换密钥；
        // 无法读取、缺票据、内容截断都不是换 prod.keys 能解决的。
        check(ImportFailureRoute.For("keys_missing", false) == ImportFailureRoute.ImportKeys, "missing prod.keys asks to import keys");
        check(ImportFailureRoute.For("keys_outdated", true) == ImportFailureRoute.ReplaceKeys, "outdated keys asks to replace keys");
        check(ImportFailureRoute.For("keys_outdated", false) == ImportFailureRoute.ShowMessage, "outdated keys without ready keys shows the message");
        foreach (var code in new[] { "content_unreadable", "ticket_missing", "content_truncated", "disk_full", null })
            check(ImportFailureRoute.For(code, true) == ImportFailureRoute.ShowMessage, "no key prompt for " + (code ?? "no code"));
        const string sample = """
        {"schema":1,"jobId":"catalog-test","taskId":"catalog-test","seq":1,"type":"stage","operation":"catalog","state":"running","message":"读取游戏库"}
        {"schema":1,"jobId":"catalog-test","taskId":"catalog-test","seq":2,"type":"result","operation":"catalog","state":"succeeded","message":"操作完成","result":{"games":[{"id":"0100000000000001","name":"Synthetic game","display":"1.2","cover":"","hidden":false,"missing":["Need base"],"ready":false}],"keys":{"ready":false,"verified":false,"message":"尚未导入"}}}
        """;
        var report = LibraryJobResult.Parse(sample, 0, "catalog-test", "catalog");
        check(report.Succeeded && report.Message == "操作完成", "jobs terminal result and exit agree");
        var catalog = LibraryCatalog.Parse(report.Result);
        check(catalog.Games.Count == 1 && catalog.Games[0].Name == "Synthetic game" &&
            catalog.Games[0].Version == "1.2" && !catalog.KeysReady, "handwritten catalog values preserved");
        check(catalog.Games[0].Missing.Single() == "Need base", "backend requirements preserved without UI inference");
        void Reject(string data, int exit, string label)
        {
            try { LibraryJobResult.Parse(data, exit, "catalog-test", "catalog"); }
            catch (LibraryProtocolException) { check(true, label); return; }
            throw new Exception("accepted " + label);
        }
        Reject(sample, 1, "successful result cannot hide failed process exit");
        Reject(sample.Split('\n')[0], 0, "EOF without terminal result is not success");
        Reject(sample.Replace("catalog-test", "other-job"), 0, "reject foreign task events");
        Reject(sample.Replace("\"operation\":\"catalog\"", "\"operation\":\"import\""), 0, "reject foreign operation events");
        Reject(sample.Replace("\"seq\":2", "\"seq\":1"), 0, "reject repeated sequence");
        Reject(sample.Replace("\"schema\":1", "\"schema\":2"), 0, "reject unknown event schema");
        Reject(sample + "\n" + sample.Split('\n')[0], 0, "no event after terminal result");
        Reject(sample.Replace("\"seq\":2", "\"seq\":2,\"seq\":3"), 0, "reject duplicate JSON fields");
        var failed = sample.Replace("succeeded", "failed");
        check(!LibraryJobResult.Parse(failed, 1, "catalog-test", "catalog").Succeeded, "backend failure remains failure");
        Reject(failed, 0, "failure result and zero exit disagree");
        Reject("not json", 0, "non JSON stdout rejected");
        var recorded = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "library-catalog.ndjson"));
        var empty = LibraryCatalog.Parse(LibraryJobResult.Parse(recorded, 0, "recorded-catalog", "catalog").Result);
        check(empty.Games.Count == 0 && !empty.KeysReady, "recorded real empty Windows catalogue has no games or keys");
        check(empty.KeysMessage == "尚未导入 prod.keys", "recorded backend key status stays verbatim");
        var canonical = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "canonical-library"));
        using var setup = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(new { library = canonical, libraryId = "legacy-id" }));
        LibraryConnection connection;
        try { connection = LibraryConnection.Parse(setup.RootElement); }
        catch (LibraryProtocolException error) { throw new Exception("backend library id is opaque", error); }
        check(connection.Id == "legacy-id" && connection.Folder == canonical, "backend canonical folder and opaque identifier preserved");
        foreach (var invalid in new[] { new {library="relative-library", libraryId="legacy-id"}, new {library=canonical, libraryId=""} })
        {
            using var document = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(invalid));
            try { LibraryConnection.Parse(document.RootElement); throw new Exception("accepted invalid library connection"); }
            catch (LibraryProtocolException) { check(true, "reject invalid connection envelope"); }
        }
        foreach (var malformed in new[] { "{}", "{\"games\":[],\"keys\":{\"ready\":\"yes\",\"message\":\"\"}}" })
        {
            using var document = System.Text.Json.JsonDocument.Parse(malformed);
            try { LibraryCatalog.Parse(document.RootElement); throw new Exception("accepted malformed catalogue"); }
            catch (LibraryProtocolException) { check(true, "reject malformed catalogue"); }
        }

    }
}
