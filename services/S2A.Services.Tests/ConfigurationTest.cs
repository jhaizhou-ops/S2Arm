using System;
using System.IO;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int ConfigurationTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_config_test_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            try
            {
                string game = Path.Combine(root, "game");
                Directory.CreateDirectory(game);
                Directory.CreateDirectory(Path.Combine(game, "nested"));
                string alias = Path.Combine(root, "alias");
                Directory.CreateSymbolicLink(alias, Path.Combine(game, "nested"));
                HostConfiguration New(string state) => new(game, state, SystemLanguage.AmericanEnglish,
                    RegionCode.USA, "Etc/UTC", false, new HostUi());
                bool outsideOk = New(Path.Combine(root, "state")) != null;
                bool nestedRejected = false;
                try { New(Path.Combine(alias, "new-state")); }
                catch (ArgumentException) { nestedRejected = true; }
                string dangling = Path.Combine(root, "dangling");
                Directory.CreateSymbolicLink(dangling, Path.Combine(root, "missing"));
                bool danglingRejected = false;
                try { New(Path.Combine(dangling, "state")); }
                catch (IOException) { danglingRejected = true; }
                bool ok = outsideOk && nestedRejected && danglingRejected;
                Console.WriteLine($"配置路径真实目录：外部可用 / 指向游戏内部的祖先软链拒绝 / 断链拒绝 = {outsideOk} / {nestedRejected} / {danglingRejected} {(ok ? "✓" : "✗")}");
                return ok ? 0 : 1;
            }
            finally { Directory.Delete(root, true); }
        }
    }
}
