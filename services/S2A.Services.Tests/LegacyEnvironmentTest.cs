using System;
using System.Runtime.CompilerServices;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int LegacyEnvironmentTest()
        {
            Environment.SetEnvironmentVariable("S2A_DOCKED", "0");
            Environment.SetEnvironmentVariable("S2A_SYSTEM_LANGUAGE", "AmericanEnglish");
            RuntimeHelpers.RunClassConstructor(typeof(Host).TypeHandle);
            Environment.SetEnvironmentVariable("S2A_DOCKED", "1");
            Environment.SetEnvironmentVariable("S2A_SYSTEM_LANGUAGE", "Japanese");
            bool docked = Host.Docked;
            SystemLanguage language = Host.Language;
            string seed = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"s2a_legacy_seed_{Environment.ProcessId}");
            string oldSaveDir = Environment.GetEnvironmentVariable("S2A_SAVE_DIR");
            Environment.SetEnvironmentVariable("S2A_SAVE_DIR", seed);
            bool legacySeed = Saves.Dir() == seed;
            Environment.SetEnvironmentVariable("S2A_SAVE_DIR", oldSaveDir);
            Console.WriteLine($"Legacy 存档种子路径保持可用：{legacySeed} {(legacySeed ? "✓" : "✗")}");
            bool ok = docked && language == SystemLanguage.Japanese && legacySeed;
            Console.WriteLine($"Legacy 环境在首次访问时读取：Docked / Language = {docked} / {language} {(ok ? "✓" : "✗")}");
            return ok ? 0 : 1;
        }
    }
}
