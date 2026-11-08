// Synthetic adapter, NOT the encrypted NCA/container reader. It feeds an original
// RomFS image to the same production extraction implementation used by nx_unpack.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.FsSystem;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using Path = System.IO.Path;

if (args.Length < 3) return 2;
var input = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(args[^1]));
if (input == null || !input.ContainsKey("exefs/main") || !input.ContainsKey("exefs/main.npdm")) return 2;
string output = args[1];
Directory.CreateDirectory(output);
if (!args.Contains("--nacp-only"))
{
    var builder = new RomFsBuilder();
    foreach (var item in input.Where(x => x.Key.StartsWith("romfs/", StringComparison.Ordinal)).OrderBy(x => x.Key, StringComparer.Ordinal))
        builder.AddFile("/" + item.Key.Substring(6), new StorageFile(new MemoryStorage(Convert.FromBase64String(item.Value)), OpenMode.Read));
    using var image = builder.Build();
    image.GetSize(out long size).ThrowIfFailure();
    byte[] bytes = new byte[checked((int)size)];
    image.Read(0, bytes).ThrowIfFailure();
    RomfsExtraction.Extract(_ => new MemoryStorage(bytes), Path.Combine(output, "romfs"), false, parallelism: 1);
    Directory.CreateDirectory(Path.Combine(output, "exefs"));
    foreach (string name in new[] { "main", "main.npdm" })
        File.WriteAllBytes(Path.Combine(output, "exefs", name), Convert.FromBase64String(input["exefs/" + name]));
}
// 与真 nx_unpack 同形：直连配置版本旁注要 base（本体 CNMT 版本），没有更新时取它。
File.WriteAllText(Path.Combine(output, "unpack.tsv"), "title_id\t0100AAAA00000000\nupdate\t\nbase\t4096\n");
return 0;
