/*
MIT License

Copyright (c) 2026 LumaDock contributors
Copyright (c) 2026 jhaizhou (reference-port-derived portions)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
// Machine-readable, read-only container inspection for launchers. Uses the same
// LibHac indexing, ticket handling and integrity policy as the existing unpacker.
// Metadata interface originated in LumaDock 238c1dd (MIT notice below).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.Ncm;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;

static partial class P {
    // 程序位数的唯一判法（11-01 维护者：只留这一份，oneclick.sh / tools/census/api_census.py 经 `nx_unpack --npdm-isa <main.npdm>` 调它）：
    //   main.npdm 的 META 头第 0x0C 字节最低位 = 1 是 AArch64、0 是 AArch32——加载器真正认的依据；不是 META 或不足 0x80 字节 = unknown
    internal static string NpdmIsa(byte[] npdm) =>
        npdm == null || npdm.Length < 0x80 || Encoding.ASCII.GetString(npdm, 0, 4) != "META" ? "unknown" : (npdm[0x0c] & 1) != 0 ? "aarch64" : "aarch32";
    // nx_unpack --npdm-isa <main.npdm>：打印 aarch64 / aarch32 / unknown；读不了或 unknown 退出 3
    static int NpdmIsaCli(string path) {
        byte[] b; try { b = File.ReadAllBytes(path); } catch (Exception e) { Console.Error.WriteLine($"🔴 读不了 {path}：{e.Message}"); return 3; }
        string isa = NpdmIsa(b); Console.WriteLine(isa); return isa == "unknown" ? 3 : 0;
    }
    static int Inspect(string[] args) {
        // stdout 只留给最后那一行 JSON（oneclick / 普查直接 json.load）：其余一切提示改走 stderr。标题密钥「已载入」、Index / Resolve 的 🟡 行原先
        //   都写进 stdout，prod.keys 旁有 title.keys 时 JSON 前多一行，调用方 JSONDecodeError、一键出包直接失败（#1186 转，两份 Wonder 原件复现）
        var json = Console.Out; Console.SetOut(Console.Error);
        try {
            Ks = ExternalKeyReader.ReadKeyFile(args[0]);
            string titleKeys = null;
            for (int i = 2; i < args.Length; i++) if (args[i].StartsWith("--title-keys=", StringComparison.Ordinal)) titleKeys = args[i].Substring(13);
            LoadTitleKeys(args[0], titleKeys);
            Index(args[2], inspect: true); Resolve();
            var packages = new List<object>();
            foreach (var open in Where.Values.ToArray()) {
                var meta = new Nca(Ks, open());
                if (meta.Header.ContentType != NcaContentType.Meta) continue;
                var fs = meta.OpenFileSystem(0, IntegrityCheckLevel.ErrorOnInvalid);
                foreach (DirectoryEntryEx entry in fs.EnumerateEntries("*.cnmt", SearchOptions.Default)) {
                    byte[] raw = InspectRead(fs, entry.FullPath, 1 << 20);
                    var m = new Cnmt(new MemoryStream(raw));
                    string kind = m.Type switch {
                        ContentMetaType.Application => "base", ContentMetaType.Patch => "update",
                        ContentMetaType.AddOnContent => "dlc", _ => null
                    };
                    if (kind == null) continue;
                    string name = "", englishName = "", display = "", guestIsa = "unknown", icon = "";
                    var builds = new Dictionary<string,string>(); int controls = 0;
                    foreach (var content in m.ContentEntries) {
                        string id = Convert.ToHexString(content.NcaId).ToLowerInvariant();
                        if (!Where.TryGetValue(id, out var contentOpen)) continue;
                        var nca = new Nca(Ks, contentOpen());
                        // 一份清单引用多份 Control（10-25 #418 猎天使魔女3 整合样本：更新 CNMT 两份 Control，显示 1.2.0 / 1.1.0）：与正式解包（Program.cs Cid，FirstOrDefault）
                        //   取同一份——第一份；原先遍历到最后一份覆盖，两个入口显示版本不一样。份数记在 controls，调用方据它标「显示版本有歧义」
                        if (content.Type == ContentType.Control && controls++ == 0) {
                            var control = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
                            byte[] nacp = InspectRead(control, "/control.nacp", 1 << 20);
                            if (nacp.Length < 0x3070) throw new IOException("Short NACP");
                            name = TitleName(nacp, 14) ?? TitleName(nacp, 0) ?? TitleName(nacp, -1) ?? "";
                            // 英文名（美式 → 英式）：库里每款的文件夹按它取名（layout.folder_name）；界面名优先简体中文，两者分开给
                            englishName = TitleName(nacp, 0) ?? TitleName(nacp, 1) ?? "";
                            display = Encoding.UTF8.GetString(nacp, 0x3060, 16).TrimEnd('\0');
                            if (args.Length > 3) {
                                Directory.CreateDirectory(args[3]);
                                foreach (string lang in IconLangs) {
                                    byte[] bytes = ReadAll(control, "/icon_" + lang + ".dat");
                                    if (bytes == null) continue;
                                    if (bytes.Length > 16 << 20) throw new IOException("Large icon");
                                    icon = Path.Combine(args[3], m.TitleId.ToString("X16") + ".jpg");
                                    File.WriteAllBytes(icon, bytes);
                                    break;
                                }
                            }
                        }
                        // 更新包的 ExeFS 是完整的（不是差分），真正跑的是最新更新里的程序：有的游戏本体是 32 位、更新后变 64 位
                        //（马车8：1.0 是 AArch32，4.0.1 更新是 AArch64；10-23 Spare-host 一键出包被误拒）。更新的读不出就记 unknown，由调用方退回看本体
                        if (content.Type == ContentType.Program && kind == "update") {
                            try {
                                var ucode = nca.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
                                byte[] unpdm = InspectRead(ucode, "/main.npdm", 1 << 20);
                                guestIsa = NpdmIsa(unpdm);
                            } catch (Exception) { guestIsa = "unknown"; }
                        }
                        if (content.Type == ContentType.Program && kind == "base") {
                            var code = nca.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
                            byte[] npdm = InspectRead(code, "/main.npdm", 1 << 20);
                            guestIsa = NpdmIsa(npdm);
                            if (guestIsa == "unknown") throw new IOException("Invalid NPDM");
                            foreach (DirectoryEntryEx file in code.EnumerateEntries("*", SearchOptions.Default)) {
                                if (file.Type != DirectoryEntryType.File || file.Size < 0x60) continue;
                                using var handle = new UniqueRef<IFile>();
                                code.OpenFile(ref handle.Ref, file.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                                byte[] header = new byte[0x60];
                                handle.Get.Read(out long got, 0, header, ReadOption.None).ThrowIfFailure();
                                if (got == header.Length && Encoding.ASCII.GetString(header,0,4) == "NSO0")
                                    builds[file.Name] = Convert.ToHexString(header,0x40,16).ToLowerInvariant();
                            }
                        }
                    }
                    // 解包后要占的字节：清单里本包内容的原始 NCA 大小之和（nsz / xcz 的 NCZ 比文件大，启动器空间预算按它算）
                    long contentBytes = m.ContentEntries.Where(c => Where.ContainsKey(Convert.ToHexString(c.NcaId).ToLowerInvariant())).Sum(c => c.Size);
                    // 本包在这个文件里的各 NCA 的 content ID（任天堂按内容算的哈希）：导入按它与文件大小定原件身份，不再整份读一遍算 SHA-256（玩家反馈「只是添加也要跑几分钟」）
                    string[] contentIds = m.ContentEntries.Select(c => Convert.ToHexString(c.NcaId).ToLowerInvariant()).Where(Where.ContainsKey).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                    packages.Add(new { titleId=m.TitleId.ToString("X16"),
                        baseId=(kind == "base" ? m.TitleId : m.ApplicationTitleId).ToString("X16"),
                        version=m.TitleVersion.Version, type=kind, name, englishName, display, builds, guestIsa, icon, controls, contentBytes, contentIds });
                }
            }
            if (packages.Count == 0) throw new IOException("No application metadata");
            json.WriteLine(JsonSerializer.Serialize(new { schema=1, packages })); json.Flush();
            return 0;
        } catch (UsageError u) {
            // 我们自己的用法 / 参数错（如 --title-keys 指的路径不在）不是「容器读不出」，不混进退出码 3：
            //   调用方按 3 认「这个包解不开」，把自己的用法错误说成玩家的密钥问题就是误判（10-28 #633）
            Console.Error.WriteLine("🔴 " + u.Message); return 2;
        } catch (Exception e) {
            // 这一句必须留在输出里：pack/jobs/library.py 按「could not be decrypted」/「Check keys」认「读不出」，退出码 3 是调用方契约。
            //   10-28 #633：原先只有这一句、原因全丢——缺密钥 / 缺票据 / 容器损坏 / 文件被截断在普查日志里长得一模一样，
            //   6 款只能笼统记「疑密钥 / 票据」。现在把分类码与原文追加在后面：契约不变，原因可查、能照做。
            Console.Error.WriteLine("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.");
            var (code, message) = Explain(e);
            Console.Error.WriteLine($"【原因 {code}】{message}");
            if (Trace()) Console.Error.WriteLine(e.ToString());
            return 3;
        }
    }

    static byte[] InspectRead(IFileSystem fs, string path, int limit) {
        using var file = new UniqueRef<IFile>();
        fs.OpenFile(ref file.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
        file.Get.GetSize(out long size).ThrowIfFailure();
        if (size < 0 || size > limit) throw new IOException("Invalid metadata length");
        byte[] bytes = new byte[size];
        file.Get.Read(out long got, 0, bytes, ReadOption.None).ThrowIfFailure();
        if (got != size) throw new IOException("Incomplete metadata");
        return bytes;
    }
}
