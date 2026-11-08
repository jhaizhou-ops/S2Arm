// 屏蔽词系统数据验证器：<目录> empty|real
//   empty（合成数据）：每个 ac_* / trie_* 经 AhoCorasick.Import、table_similar_form_nx 经 SimilarFormTable.Import 都返回 true 且恰好读完；
//     词典结构里根节点在（失配树 Bp 只有根：ToPos(0)=0、ToNodeId(0)=0、Enclose(0)=-1），节点集对任意下标 Rank1=0；256 个字节值逐个喂 Match 回调 0 次；
//     ProfanityFilter 检查 / 屏蔽每条字符串：不抛异常、判「无屏蔽词」、文本原样；含 @ 的对照串按 @ 规则（与词典无关）判有。
//   real（真机数据）：同一套 Import 全过（验证器本身没写错的对照）；常见英文脏词命中与否如实报，不当判据；trie_* 不是 Ryujinx 读的格式，按 AhoCorasick 试读只报不判。
// 期望值来自 Ryujinx 源码语义（compat/tree/src/Ryujinx.Horizon/Sdk/Ngc/），不来自合成器。输出「期望 → 真结果」对位表，任一不符退出 1。
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Fs;
using Ryujinx.Horizon.Sdk.Ngc;
using Ryujinx.Horizon.Sdk.Ngc.Detail;
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using NgReader = Ryujinx.Horizon.Sdk.Ngc.Detail.BinaryReader;

static class Program
{
    static int _ok, _bad;
    static readonly List<string> _info = new();

    static void Check(string name, string expect, string actual, bool ok)
    {
        if (ok) _ok++; else _bad++;
        Console.WriteLine($"{(ok ? "通" : "不通")} {name}：{expect} → {actual}");
    }

    static byte[] Gunzip(string path)
    {
        using MemoryStream input = new(File.ReadAllBytes(path));
        using GZipStream gz = new(input, CompressionMode.Decompress);
        using MemoryStream output = new();
        gz.CopyTo(output);
        return output.ToArray();
    }

    // Import 成功且恰好读完：整段 true、少最后 1 字节就 false（读取量由前缀决定，少一字节仍成功 = 有没读到的尾巴）
    static (bool Full, bool Exact) ImportAc(byte[] d)
    {
        NgReader r = new(d);
        bool full = new AhoCorasick().Import(ref r);
        NgReader t = new(d.AsSpan(0, Math.Max(0, d.Length - 1)));
        return (full, full && !new AhoCorasick().Import(ref t));
    }

    static (bool Full, bool Exact) ImportTable(byte[] d)
    {
        NgReader r = new(d);
        bool full = new SimilarFormTable().Import(ref r);
        NgReader t = new(d.AsSpan(0, Math.Max(0, d.Length - 1)));
        return (full, full && !new SimilarFormTable().Import(ref t));
    }

    static bool CountMatch(ReadOnlySpan<byte> text, int s, int e, int node, ref int n)
    {
        n++;
        return true;
    }

    // 照 AhoCorasick.Import 的顺序逐个读出各结构（同一个读取器），拿到节点集与失配树查根
    static string RootProbe(byte[] d)
    {
        NgReader r = new(d);
        CompressedArray wl = new(), mi = new();
        SparseSet wm = new(), mm = new(), nodes = new();
        Bp bp = new();
        if (!wl.Import(ref r) || !wm.Import(ref r) || !mi.Import(ref r) || !mm.Import(ref r) || !r.Read(out uint npc) || !nodes.Import(ref r) || !bp.Import(ref r))
        {
            return "逐结构读失败";
        }

        int maxRank = 0;
        for (long i = 0; i < 256L * Math.Max(1u, npc) + 8; i++)
        {
            maxRank = Math.Max(maxRank, nodes.Rank1(i));
        }

        return $"ToPos(0)={bp.ToPos(0)} ToNodeId(0)={bp.ToNodeId(0)} Enclose(0)={bp.Enclose(0)} 节点集最大 Rank1={maxRank} 词集 Has(0..255)={Enumerable.Range(0, 256).Count(i => wm.Has(i))}";
    }

    sealed class DirFs : IFsClient
    {
        private readonly string _dir;
        public DirFs(string dir) { _dir = dir; }
        private string Map(string p) => Path.Combine(_dir, p[(p.IndexOf(":/", StringComparison.Ordinal) + 2)..]);
        public Result QueryMountSystemDataCacheSize(out long size, ulong dataId) { size = 0; return Result.Success; }
        public Result MountSystemData(string mountName, ulong dataId) => dataId == 0x100000000000823UL && Directory.Exists(_dir) ? Result.Success : FsResult.TargetNotFound;
        public Result OpenFile(out FileHandle handle, string path, OpenMode openMode)
        {
            string p = Map(path);
            handle = new FileHandle(p);
            return File.Exists(p) ? Result.Success : FsResult.PathNotFound;
        }
        public Result ReadFile(FileHandle handle, long offset, Span<byte> destination)
        {
            byte[] d = File.ReadAllBytes((string)handle.Value);
            d.AsSpan((int)offset, Math.Min(destination.Length, d.Length - (int)offset)).CopyTo(destination);
            return Result.Success;
        }
        public Result GetFileSize(out long size, FileHandle handle) { size = new FileInfo((string)handle.Value).Length; return Result.Success; }
        public void CloseFile(FileHandle handle) { }
        public void Unmount(string mountName) { }
    }

    static readonly string[] Words =
    [
        "", "Hunter", "ハンター", "モンスターハンター", "テスト太郎", "名前", "猫", "hello world", "John Smith",
        "fuck", "FUCK you", "shit", "Ｆｕｃｋ", "f u c k", "|-|unter vv", "😀🎮", "0123456789",
    ];
    const string AtControl = "a@b";
    static readonly string[] DirtyProbe = ["fuck", "shit"];

    static int Main(string[] args)
    {
        if (args.Length != 2 || (args[1] != "empty" && args[1] != "real"))
        {
            Console.Error.WriteLine("用法：NgWordVerify <目录> empty|real");
            return 2;
        }

        string dir = args[0];
        bool empty = args[1] == "empty";
        string[] files = Directory.GetFiles(dir).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).ToArray();
        string[] acs = files.Where(f => f.StartsWith("ac_", StringComparison.Ordinal)).ToArray();
        string[] tries = files.Where(f => f.StartsWith("trie_", StringComparison.Ordinal)).ToArray();

        // 1. 各词典 Import
        int acOk = 0, acExact = 0;
        foreach (string f in acs)
        {
            (bool full, bool exact) = ImportAc(Gunzip(Path.Combine(dir, f)));
            acOk += full ? 1 : 0;
            acExact += exact ? 1 : 0;
            if (!full) Console.WriteLine($"    {f} Import 失败");
        }
        Check($"ac_* 经 AhoCorasick.Import（{acs.Length} 个）", $"{acs.Length} 个 true", $"{acOk} 个 true", acs.Length > 0 && acOk == acs.Length);
        if (empty)
        {
            Check("ac_* 恰好读完（少 1 字节即失败）", $"{acs.Length} 个", $"{acExact} 个", acExact == acs.Length);
        }
        else
        {
            _info.Add($"真数据 ac_* 恰好读完 {acExact}/{acs.Length} 个");
        }

        (bool tf, bool te) = ImportTable(Gunzip(Path.Combine(dir, "table_similar_form_nx")));
        Check("table_similar_form_nx 经 SimilarFormTable.Import", "true", tf ? "true" : "false", tf);
        if (empty) Check("table_similar_form_nx 恰好读完", "是", te ? "是" : "否", te);

        int trOk = 0, trGz = 0;
        foreach (string f in tries)
        {
            byte[] d;
            try { d = Gunzip(Path.Combine(dir, f)); } catch (InvalidDataException) { continue; }
            trGz++;
            trOk += ImportAc(d).Exact ? 1 : 0;
        }
        if (empty)
        {
            Check($"trie_*（占位，同一份空词典）经 AhoCorasick.Import 且恰好读完（{tries.Length} 个）", $"{tries.Length} 个", $"{trOk} 个", tries.Length > 0 && trOk == tries.Length);
        }
        else
        {
            _info.Add($"真数据 trie_* 按 gzip + AhoCorasick 试读、能 gzip 解开 {trGz}/{tries.Length} 个、按 AhoCorasick 恰好读完 {trOk}/{tries.Length} 个（Ryujinx 不读它们，只报不判）");
        }

        // 2. 合成数据：根节点在、匹配永不命中
        if (empty)
        {
            HashSet<string> probes = acs.Concat(tries).Select(f => RootProbe(Gunzip(Path.Combine(dir, f)))).ToHashSet();
            string want = "ToPos(0)=0 ToNodeId(0)=0 Enclose(0)=-1 节点集最大 Rank1=0 词集 Has(0..255)=0";
            Check($"根节点与空节点集（{acs.Length + tries.Length} 个词典）", want, string.Join(" | ", probes), probes.Count == 1 && probes.Contains(want));

            byte[] all = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray();
            int hits = 0;
            foreach (string f in acs)
            {
                byte[] d = Gunzip(Path.Combine(dir, f));
                NgReader r = new(d);
                AhoCorasick ac = new();
                ac.Import(ref r);
                ac.Match<int>(all, CountMatch, ref hits);
                ac.Match<int>(Encoding.UTF8.GetBytes(@"\bfuck\b ハンター \b"), CountMatch, ref hits);
                if (ac.GetWordList().Length != 0) hits++;
            }
            Check($"Match 回调次数（{acs.Length} 个词典 × 256 个字节值 + 1 条混合串）+ 词表非空数", "0", hits.ToString(), hits == 0);
        }

        // 3. ProfanityFilter 整条路径
        using ProfanityFilter pf = new(new DirFs(dir));
        Result init = pf.Initialize();
        Check("ProfanityFilter.Initialize", "成功", init.IsSuccess ? "成功" : $"0x{init.ErrorCode:x}", init.IsSuccess);
        pf.GetContentVersion(out uint ver);
        if (empty) Check("GetContentVersion（version.dat 大端）", "1", ver.ToString(), ver == 1);

        ProfanityFilterOption[] opts =
        [
            new(SkipMode.SkipAtSignCheck, MaskMode.Overwrite, ProfanityFilterFlags.None, 0),
            new(SkipMode.SkipAtSignCheck, MaskMode.ReplaceByOneCharacter, ProfanityFilterFlags.MatchNormalizedFormKC | ProfanityFilterFlags.MatchSimilarForm, 0),
        ];
        uint[] regions = [0u, 0xFFFFu];
        int calls = 0, flagged = 0, masked = 0, changed = 0, threw = 0, otherFail = 0;
        List<string> bad = new();
        SortedSet<string> utf8Fail = new();
        // 结果码：失败只允许 InvalidUtf8Encoding（Utf8Text 解不了的输入，在查词典之前就返回，与数据无关；两种数据下应是同一批字符串）
        void Code(Result rc, string what)
        {
            if (rc == NgcResult.InvalidUtf8Encoding) utf8Fail.Add(what);
            else if (rc.IsFailure) { otherFail++; bad.Add($"{what} 结果 0x{rc.ErrorCode:x}"); }
        }
        foreach (string w in Words)
        {
            foreach (ProfanityFilterOption o in opts)
            {
                foreach (uint rm in regions)
                {
                    calls++;
                    try
                    {
                        byte[] utf8 = Encoding.UTF8.GetBytes(w);
                        Result rc = pf.CheckProfanityWords(out uint mask, [.. utf8, 0], rm, o);
                        Code(rc, $"检查「{w}」");
                        if (mask != 0) { flagged++; bad.Add($"检查「{w}」区域 0x{rm:x} → 0x{mask:x}"); }

                        byte[] buf = [.. utf8, 0];
                        rc = pf.MaskProfanityWordsInText(out int count, buf, rm, o);
                        Code(rc, $"屏蔽「{w}」选项 {o.Flags}");
                        if (count != 0) { masked++; bad.Add($"屏蔽「{w}」区域 0x{rm:x} → {count} 处"); }
                        if (!buf.AsSpan(0, utf8.Length).SequenceEqual(utf8)) changed++;
                    }
                    catch (Exception e)
                    {
                        threw++;
                        bad.Add($"「{w}」抛 {e.GetType().Name}：{e.Message}");
                    }
                }
            }
        }

        Check("检查 / 屏蔽的失败结果码（除 InvalidUtf8Encoding 外）", "0 个", $"{otherFail} 个", otherFail == 0);
        _info.Add($"返回 InvalidUtf8Encoding 的调用（输入类，与词典无关）：{(utf8Fail.Count == 0 ? "无" : string.Join("、", utf8Fail))}");
        if (empty)
        {
            foreach (string b in bad.Take(10)) Console.WriteLine("    " + b);
            Check($"检查 + 屏蔽（{Words.Length} 条字符串 × {opts.Length} 种选项 × {regions.Length} 种区域 = {calls} 组，每组 2 个调用）",
                "0 判有 / 0 处屏蔽 / 0 改文本 / 0 异常", $"{flagged} 判有 / {masked} 处屏蔽 / {changed} 改文本 / {threw} 异常",
                flagged == 0 && masked == 0 && changed == 0 && threw == 0);
        }
        else
        {
            Check($"真数据下检查 + 屏蔽不抛异常（{calls} 组）", "0 异常", $"{threw} 异常", threw == 0);
            _info.Add($"真数据下同一批 {calls} 组：检查判有 {flagged} 组、屏蔽有命中 {masked} 组（词典在起作用，合成数据下的 0 不是检查没跑）");
            foreach (string w in DirtyProbe)
            {
                pf.CheckProfanityWords(out uint m, [.. Encoding.UTF8.GetBytes(w), 0], 0xFFFF, opts[0]);
                _info.Add($"真数据检查常见英文脏词（第 {Array.IndexOf(DirtyProbe, w) + 1} 个，全区域）：{(m != 0 ? $"命中（掩码 0x{m:x}）" : "未命中")}");
            }
        }

        // @ 对照：含 @ 一律判有（ProfanityFilter.CheckProfanityWordsImpl 的 IsIncludesAtSign，与词典无关），证明检查路径真在跑
        pf.CheckProfanityWords(out uint at, [.. Encoding.UTF8.GetBytes(AtControl), 0], 0xFFFF, opts[0]);
        Check($"对照「{AtControl}」全区域检查（@ 规则）", "0xffff", $"0x{at:x}", at == 0xFFFF);

        foreach (string s in _info) Console.WriteLine("  信息 " + s);
        Console.WriteLine(_bad == 0 ? $"✓ 屏蔽词数据验证（{args[1]}，{files.Length} 个文件）全过：{_ok} 项" : $"✗ 屏蔽词数据验证（{args[1]}）{_bad} 项不通 / {_ok + _bad}");
        return _bad == 0 ? 0 : 1;
    }
}
