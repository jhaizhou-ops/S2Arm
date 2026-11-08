using System;
using System.Diagnostics;
using System.IO;

// 用法：romfs_index <游戏数据根> [--list <RomFS 清单>]   → 读 <根>/romfs/，写 <根>/romfs.s2aidx
//   --list：出包期由 graphics/nvn/tools/romfs_list.py sizes 写的清单（字节数\t相对路径），给了就不再枚举目录、逐个打开取长度
if (!(args.Length == 1 || args.Length == 3 && args[1] == "--list") || !Directory.Exists(Path.Combine(args[0], "romfs")))
{
    Console.Error.WriteLine("用法：romfs_index <游戏数据根（含 romfs/）> [--list <RomFS 清单>]");
    return 2;
}

Stopwatch sw = Stopwatch.StartNew();
string outPath = Path.Combine(args[0], S2A.Services.RomFsIndex.FileName);
S2A.Services.RomFsIndex.Write(Path.Combine(args[0], "romfs"), outPath, args.Length == 3 ? args[2] : null);
Console.Error.WriteLine($"🟢 RomFS 索引 {outPath}：{new FileInfo(outPath).Length} 字节，用时 {sw.ElapsedMilliseconds} ms");
return 0;
