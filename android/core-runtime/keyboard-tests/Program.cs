using System;
using System.Text.Json;
using S2A.Android.Aot;

static class Program
{
    static int checks;
    static void Check(bool result) { checks++; if (!result) throw new Exception("check " + checks); }
    static void Reject(Action action) {
        checks++;
        try { action(); } catch (Exception) { return; }
        throw new Exception("expected rejection " + checks);
    }
    static string reply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"ok\",\"text\":\"测试😀\"}";
    static string Exchange(string request) {
        using var document = JsonDocument.Parse(request);
        var r = document.RootElement;
        Check(r.GetProperty("version").GetInt32() == 1);
        Check(r.GetProperty("type").GetString() == "software-keyboard");
        Check(r.GetProperty("header").GetString() == "姓名\"标题");
        Check(r.GetProperty("initial").GetString() == "");
        return reply;
    }
    static bool Show(out string text, uint mode = 0, int min = 1, int max = 12) =>
        AndroidKeyboard.Show(Exchange, mode, "姓名\"标题", "说明", "提示", "", "确定", min, max, out text) == AndroidKeyboard.Outcome.Accepted;
    static void Main() {
        TransportTests.Run(Check, Reject);
        Check(Show(out string value) && value == "测试😀");
        Check(Show(out value, 5) && value == "测试😀");
        reply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"cancel\"}";
        Check(!Show(out value) && value == null);
        reply = null; Check(!Show(out value) && value == null);
        Check(AndroidKeyboard.Show(_ => null, 0, "", "", "", "", "", 0, 8, out _) == AndroidKeyboard.Outcome.HostRevoked);
        Check(AndroidKeyboard.Show(_ => "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"cancel\"}",
            0, "", "", "", "", "", 0, 8, out _) == AndroidKeyboard.Outcome.UserCancelled);
        reply = "{\"version\":2,\"type\":\"software-keyboard\",\"status\":\"ok\",\"text\":\"x\"}";
        Reject(() => Show(out _));
        reply = "{\"version\":1,\"type\":\"other\",\"status\":\"cancel\"}"; Reject(() => Show(out _));
        reply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"unsupported\"}"; Reject(() => Show(out _));
        reply = "{}"; Reject(() => Show(out _));
        reply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"ok\",\"text\":\"\"}"; Reject(() => Show(out _));
        Reject(() => Show(out _, 4)); Reject(() => Show(out _, 0, 13, 12)); Reject(() => Show(out _, 0, 1, 1025));
        Check(AndroidKeyboard.Valid("中文😀", 1, 4, 0));
        Check(!AndroidKeyboard.Valid("中文😀", 1, 3, 0));
        Check(!AndroidKeyboard.Valid("x\0", 0, 8, 0));
        Check(!AndroidKeyboard.Valid("\ud800", 0, 8, 0));
        Check(!AndroidKeyboard.Valid("中文", 0, 8, 2));
        Check(AndroidKeyboard.Valid("ASCII", 1, 8, 2));
        Check(AndroidKeyboard.Valid("12.3", 1, 8, 1));
        Check(!AndroidKeyboard.Valid("12a", 1, 8, 1));
        Reject(() => AndroidKeyboard.Show(Exchange, 0, new string('a', 4096), "", "", "", "", 0, 8, out _));
        Console.WriteLine($"PASS {checks} keyboard protocol assertions");
    }
}
