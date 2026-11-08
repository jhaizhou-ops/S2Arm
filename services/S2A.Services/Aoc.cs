using LibHac.Fs;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Path = System.IO.Path;

namespace S2A.Services
{
    // 追加内容（DLC）登记（总指挥 10-20：jhz 要暗黑2 认出术士君临 DLC，九款通用）。
    //   出包在游戏数据目录放 aoc.tsv（表头 idx / title_id / version / files / bytes，每个 DLC 一行；files = -1 = 仅授权，没有数据）
    //   与 aoc/<idx>/（该 DLC 数据分区 RomFS 解开后的目录树，仅 files ≥ 0 的有）。
    //   全部 DLC（含仅授权）向 Ryujinx ContentManager 登记为已拥有 → aoc:u Count / List 按清单回答；
    //   游戏挂载数据（fs OpenDataStorageByDataId → ContentManager.GetAocDataStorage → S2AHooks.OpenAocDataStorage）：
    //   有数据的从 aoc/<idx>/ 现建 RomFS；仅授权的报红、不给数据（不静默回成功）
    public static class Aoc
    {
        public const string ListFile = "aoc.tsv";

        // 程序号 → 数据目录（null = 仅授权）
        private static readonly Dictionary<ulong, string> _dirs = new();

        public static IReadOnlyDictionary<ulong, string> Registered => _dirs;

        internal static void Reset()
        {
            _dirs.Clear();
            Ryujinx.HLE.S2AHooks.OpenAocDataStorage = null;
        }

        // 读 aoc.tsv 并登记；返回登记个数（没有清单回 0）
        public static int Register(string gameDir)
        {
            string list = Path.Combine(gameDir, ListFile);

            if (!File.Exists(list))
            {
                return 0;
            }

            Ryujinx.HLE.S2AHooks.OpenAocDataStorage = Open;
            string[] lines = File.ReadAllLines(list);
            string[] head = lines.Length > 0 ? lines[0].Split('\t') : Array.Empty<string>();
            int ci = Array.IndexOf(head, "idx"), ct = Array.IndexOf(head, "title_id"), cf = Array.IndexOf(head, "files");

            if (ci < 0 || ct < 0 || cf < 0)
            {
                Red.Report("DLC 清单表头不对（要 idx / title_id / files）", list);
                return 0;
            }

            List<string> got = new();

            for (int n = 1; n < lines.Length; n++)
            {
                string[] c = lines[n].Split('\t');

                if (c.Length <= Math.Max(ci, Math.Max(ct, cf)) || !ulong.TryParse(c[ct].Trim().Replace("0x", ""), NumberStyles.HexNumber, null, out ulong id))
                {
                    continue;
                }

                string dir = Path.Combine(gameDir, "aoc", c[ci].Trim());
                bool data = int.TryParse(c[cf].Trim(), out int files) && files >= 0 && Directory.Exists(dir);

                if (_dirs.TryAdd(id, data ? dir : null))
                {
                    Host.Device.System.ContentManager.AddAocItem(id, data ? dir : list, "", mergedToContainer: true);
                    got.Add($"{id:X16}（{(data ? $"有数据 {files} 个文件" : "仅授权")}）");
                }
            }

            Console.Error.WriteLine($"[S2A DLC] 登记 {got.Count} 个已拥有：{string.Join("、", got)}");
            return got.Count;
        }

        private static IStorage Open(ulong id)
        {
            if (!_dirs.TryGetValue(id, out string dir))
            {
                return null;
            }

            if (dir == null)
            {
                Red.Report($"游戏要挂载仅授权 DLC {id:X16} 的数据（包里没有这个 DLC 的数据，不给游戏假数据）", "");
                return null;
            }

            Console.Error.WriteLine($"[S2A DLC] 挂载 {id:X16} ← {dir}");
            return Application.RomFsFromDirectory(dir);
        }
    }
}
