using System;
using System.IO;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int RomFsSymlinkTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_link_{Environment.ProcessId}");
            string rom = Path.Combine(root, "romfs"); Directory.CreateDirectory(rom);
            try
            {
                string target = Path.Combine(root, "content");
                File.WriteAllBytes(target, new byte[4096]);
                string link = Path.Combine(rom, "linked.bin");
                File.CreateSymbolicLink(link, target);
                string index = Path.Combine(root, "index"); RomFsIndex.Write(rom, index);
                using var reader = new BinaryReader(File.OpenRead(index));
                reader.ReadBytes(8); reader.ReadInt64(); int count = reader.ReadInt32();
                reader.ReadInt64(); long length = reader.ReadInt64();
                File.Delete(link); File.CreateSymbolicLink(link, Path.Combine(root, "absent"));
                bool danglingFailed = false;
                try { RomFsIndex.Write(rom, Path.Combine(root, "bad-index")); } catch (IOException) { danglingFailed = true; }
                bool ok = count == 1 && length == 4096 && danglingFailed;
                Console.WriteLine($"RomFS 索引：软链目标长度 / 断链报错 = {count} 文件、{length} / {danglingFailed} {(ok ? "✓" : "✗")}");
                return ok ? 0 : 1;
            }
            finally { Directory.Delete(root, true); }
        }
    }
}
