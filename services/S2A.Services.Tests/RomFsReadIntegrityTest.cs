// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using LibHac;
using LibHac.Fs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    // 审计 #1534 P1-5 / P1-6：RomFS 读取只交完整、属于游戏目录的字节。
    // 期望值不跑被测实现：文件内容是本测写下的固定字节（目录内 0x11、目录外 0x5A），失败码取 LibHac 现有定义
    //   （越出根 = 路径规范化的 DirectoryUnobtainable；宿主文件与索引 / 自身长度对不上 = HostFileDataCorrupted）。
    static class RomFsReadIntegrityTest
    {
        const int Len = 4096;

        sealed record Entry(long Offset, long Length, int PathAt, int PathLen, string Path);

        static List<Entry> Entries(byte[] idx)
        {
            int p = 16, n = BitConverter.ToInt32(idx, p); p += 4;
            var raw = new List<(long, long, int, int)>();
            for (int i = 0; i < n; i++, p += 24)
                raw.Add((BitConverter.ToInt64(idx, p), BitConverter.ToInt64(idx, p + 8), BitConverter.ToInt32(idx, p + 16), BitConverter.ToInt32(idx, p + 20)));
            int pathBase = p + 4;
            var list = new List<Entry>();
            foreach ((long off, long len, int po, int pl) in raw)
                list.Add(new Entry(off, len, pathBase + po, pl, Encoding.UTF8.GetString(idx, pathBase + po, pl)));
            return list;
        }

        static (Result R, byte[] Data) Read(IStorage s, long offset, int count)
        {
            byte[] b = new byte[count];
            Array.Fill(b, (byte)0xEE);
            return (s.Read(offset, b), b);
        }

        static bool All(byte[] b, byte v) => Array.TrueForAll(b, x => x == v);

        [SoloTest("--romfs-read-integrity")]
        public static int Run()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_integrity_{Environment.ProcessId}");
            string rom = Path.Combine(root, "romfs");
            bool strict = Red.Strict;
            int cases = 0, failures = 0;
            void Check(string name, string expected, string actual)
            {
                cases++;
                bool ok = expected == actual;
                if (!ok) failures++;
                Console.WriteLine($"{name}：期望 {expected} → 实 {actual} {(ok ? "✓" : "✗")}");
            }
            try
            {
                Red.Strict = false;   // 预期的红行（越界 / 长度不符）不终止本测
                Directory.CreateDirectory(rom);
                byte[] inside = new byte[Len]; Array.Fill(inside, (byte)0x11);
                byte[] outside = new byte[Len]; Array.Fill(outside, (byte)0x5A);
                // 「zz_secret.bin」与「../secret.bin」同为 13 字节：改索引路径区不动长度，模拟被改过的索引
                File.WriteAllBytes(Path.Combine(rom, "zz_secret.bin"), inside);
                File.WriteAllBytes(Path.Combine(rom, "short.bin"), inside);
                File.WriteAllBytes(Path.Combine(rom, "long.bin"), inside);
                File.WriteAllBytes(Path.Combine(rom, "shrink.bin"), inside);
                File.WriteAllBytes(Path.Combine(root, "secret.bin"), outside);
                string index = Path.Combine(root, "index");
                RomFsIndex.Write(rom, index);
                byte[] idx = File.ReadAllBytes(index);
                List<Entry> entries = Entries(idx);
                Entry E(string path) => entries.Find(e => e.Path == path) ?? throw new InvalidDataException($"索引里没有 {path}");

                // 正对照：未改的索引按原路径读到目录内的字节
                {
                    using IStorage s = RomFsIndex.Open(rom, index);
                    (Result r, byte[] d) = Read(s, E("zz_secret.bin").Offset, Len);
                    Check("P1-5 正对照：目录内文件", "Success/0x11", $"{(r.IsSuccess() ? "Success" : r.ToString())}/{(All(d, 0x11) ? "0x11" : "其它")}");
                }

                // P1-5：路径改成 ../secret.bin → 拼完走出 romfs/，这次读要失败，且不交目录外的字节
                {
                    Entry z = E("zz_secret.bin");
                    byte[] bad = (byte[])idx.Clone();
                    Encoding.UTF8.GetBytes("../secret.bin").CopyTo(bad, z.PathAt);
                    string badIndex = Path.Combine(root, "index.escape");
                    File.WriteAllBytes(badIndex, bad);
                    using IStorage s = RomFsIndex.Open(rom, badIndex);
                    (Result r, byte[] d) = Read(s, z.Offset, Len);
                    Check("P1-5 索引路径走出 romfs/（../secret.bin）", $"{ResultFs.DirectoryUnobtainable.Value}/无目录外字节",
                        $"{r}/{(Array.IndexOf(d, (byte)0x5A) >= 0 ? "读到目录外 0x5A" : "无目录外字节")}");
                }

                // P1-6 ①：建索引之后文件被截短（索引过期）：长度不符要失败，不补零
                File.WriteAllBytes(Path.Combine(rom, "short.bin"), inside.AsSpan(0, 1000).ToArray());
                {
                    using IStorage s = RomFsIndex.Open(rom, index);
                    (Result r, byte[] d) = Read(s, E("short.bin").Offset, Len);
                    Check("P1-6 索引长度与宿主文件不符（4096 / 1000）", $"{ResultFs.HostFileDataCorrupted.Value}", $"{r}{(r.IsSuccess() && d[2000] == 0 ? "（尾部补了零）" : "")}");
                }

                // P1-6 ①'：建索引之后文件被换成更长的（读得满，但已不是索引记下的那份）：同样回失败
                byte[] longer = new byte[Len + 904]; Array.Fill(longer, (byte)0x22);
                File.WriteAllBytes(Path.Combine(rom, "long.bin"), longer);
                {
                    using IStorage s = RomFsIndex.Open(rom, index);
                    (Result r, byte[] d) = Read(s, E("long.bin").Offset, Len);
                    Check("P1-6 索引长度与宿主文件不符（4096 / 5000）", $"{ResultFs.HostFileDataCorrupted.Value}", $"{r}{(r.IsSuccess() && d[0] == 0x22 ? "（交了换过的内容）" : "")}");
                }

                // P1-6 ②：打开时长度对得上、之后文件变短 → 短读要失败，不补零当完整
                {
                    using IStorage s = RomFsIndex.Open(rom, index);
                    Entry k = E("shrink.bin");
                    (Result first, _) = Read(s, k.Offset, 16);   // 先读一次：打开并缓存句柄（此时长度 4096 对得上）
                    using (var f = new System.IO.FileStream(Path.Combine(rom, "shrink.bin"), FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) f.SetLength(1000);
                    (Result r, byte[] d) = Read(s, k.Offset, Len);
                    Check("P1-6 打开后变短的短读（索引路径）", $"Success/{ResultFs.HostFileDataCorrupted.Value}", $"{(first.IsSuccess() ? "Success" : first.ToString())}/{r}{(r.IsSuccess() && d[2000] == 0 ? "（尾部补了零）" : "")}");
                }

                // P1-6 ③：没有预建索引、按目录现建的镜像（LibHac 建表 + LazyHostFile）同样不许短读成功
                File.WriteAllBytes(Path.Combine(rom, "shrink.bin"), inside);
                {
                    IStorage s = Application.RomFsFromDirectory(rom);
                    // 目录现建的镜像里文件偏移与预建索引同布局（索引就是记下 LibHac 建出的布局）
                    Entry k = E("shrink.bin");
                    (Result first, _) = Read(s, k.Offset, 16);
                    using (var f = new System.IO.FileStream(Path.Combine(rom, "shrink.bin"), FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) f.SetLength(1000);
                    (Result r, byte[] d) = Read(s, k.Offset, Len);
                    Check("P1-6 打开后变短的短读（目录现建）", $"Success/{ResultFs.HostFileDataCorrupted.Value}", $"{(first.IsSuccess() ? "Success" : first.ToString())}/{r}{(r.IsSuccess() && d[2000] != 0x11 ? "（尾部不是文件内容）" : "")}");
                }
            }
            finally
            {
                Red.Strict = strict;
                LazyHostFile.CloseAll();
                Directory.Delete(root, true);
            }
            Console.WriteLine($"RomFS 读取完整性：{cases} 例，{failures} 不符（隔离夹具：临时目录 + 真实 RomFsIndex / LazyHostFile / LibHac 建表；非整机局）");
            return failures == 0 && cases == 6 ? 0 : 1;
        }
    }
}
