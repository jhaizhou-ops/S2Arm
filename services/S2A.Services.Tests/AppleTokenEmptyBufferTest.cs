using System;
using System.IO;

namespace S2A.Services.Tests
{
    // 苹果存档记号空缓冲读（11-01 全量审计 P2-59）：接口约定（Ryujinx.HLE/FileSystem/S2AHostFileSystem.cs IHostDirectoryTransaction.ReadToken）
    //   「缓冲不够：返回 ERANGE、length = 实际长度」。期望按约定手写（Darwin ERANGE = 34）：写 16 字节记号后，空缓冲读 34、16；
    //   没有记号的目录空缓冲读 0、0（没有记号不算缓冲不够）。旧代码空缓冲钉成空指针，getxattr 只报长度 → 返回 0、16，判红
    public static partial class Program
    {
        [SoloTest("--apple-token-empty-buffer")]
        private static int AppleTokenEmptyBuffer()
        {
            Ryujinx.HLE.FileSystem.IHostDirectoryTransaction tx = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();
            string td = Path.Combine(Path.GetTempPath(), $"s2a_tokempty_{Environment.ProcessId}"), tn = td + "_none";
            foreach (string d in new[] { td, tn }) { if (Directory.Exists(d)) Directory.Delete(d, true); Directory.CreateDirectory(d); }
            int w = tx.WriteToken(td, new byte[16] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
            int r = tx.ReadToken(td, Span<byte>.Empty, out int len);
            int rn = tx.ReadToken(tn, Span<byte>.Empty, out int lenN);
            Directory.Delete(td, true); Directory.Delete(tn, true);
            string expect = "0 / 34、16 / 0、0", actual = $"{w} / {r}、{len} / {rn}、{lenN}";
            bool ok = expect == actual;
            Console.WriteLine($"{(ok ? "✓" : "✗")} 存档记号空缓冲读（写 16 字节 / 有记号空缓冲读 / 无记号空缓冲读）：{expect} → {actual}");
            return ok ? 0 : 1;
        }
    }
}
