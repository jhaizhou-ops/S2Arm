// S2ASeen 单测。期望按已知 sha256 前 16 位手写（t_seen.sh 先用 shasum 独立核这三个常量）：
//   "abc" → ba7816bf8f01cfea（键表两行：aaaa… / bbbb…）、"x" → 2d711642b726b044（表里没有 → code: 兜底）、"y" → a1fce4363854ff88（表里一行：aaaa…，与 abc 共键）
using System;
using System.IO;
using System.Linq;
using System.Text;
using Ryujinx.Graphics.Gpu.Shader;

static class T
{
    static int n, bad;
    static void Expect(string what, string want, string got) { n++; bool ok = want == got; if (!ok) bad++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {want} → 真结果 {got}"); }
    static byte[] B(string s) => Encoding.ASCII.GetBytes(s);

    static int Main(string[] a)
    {
        string d = a[0], table = Path.Combine(d, "guest_key.tsv"), seen = Path.Combine(d, "wire", "0100ABCD00000000", "seen_shaders.tsv");
        File.WriteAllText(table, "# 客体代码\t键\nba7816bf8f01cfea\taaaaaaaaaaaaaaaa\nba7816bf8f01cfea\tbbbbbbbbbbbbbbbb\na1fce4363854ff88\taaaaaaaaaaaaaaaa\n");
        string Seen() => File.Exists(seen) ? string.Join(" ", File.ReadAllLines(seen)) : "（无文件）";

        S2ASeen.NoteCode(B("abc"));
        Expect("① 没 Open 不记", "（无文件）", Seen());

        Expect("② Open 成功（建 wire/<程序号>/）", "null", S2ASeen.Open(table, seen) ?? "null");
        Expect("② 键表条数（按客体哈希）", "2", S2ASeen.TableCount.ToString());
        S2ASeen.NoteCode(B("abc")); S2ASeen.NoteCode(B("x")); S2ASeen.NoteCode(B("y")); S2ASeen.NoteCode(B("abc")); S2ASeen.NoteCode(Array.Empty<byte>());
        Expect("③ 一码多键全写、表外写 code:、共键与重复不重写、空代码不记", "aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb code:2d711642b726b044", Seen());
        Expect("③ 本进程计数（键 / code:）", "2/1", $"{S2ASeen.Counts.Keys}/{S2ASeen.Counts.Misses}");

        // 下一局：重新 Open（已有行读进来去重），同样的代码不再追加
        Expect("④ 再 Open", "null", S2ASeen.Open(table, seen) ?? "null");
        S2ASeen.NoteCode(B("abc")); S2ASeen.NoteCode(B("x"));
        Expect("④ 跨局去重：文件不变", "aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb code:2d711642b726b044", Seen());

        Expect("⑤ 坏表（哈希列不是十六进制）→ 返回错误、不记", "错", S2ASeen.Open(WriteBad(d), seen) != null ? "错" : "没报错");
        S2ASeen.NoteCode(B("z"));
        Expect("⑤ 坏表后不记", "aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb code:2d711642b726b044", Seen());

        Console.WriteLine($"seen：{n} 项，失败 {bad}");
        return bad == 0 ? 0 : 1;
    }

    static string WriteBad(string d) { string p = Path.Combine(d, "bad.tsv"); File.WriteAllText(p, "zzzzzzzzzzzzzzzz\taaaaaaaaaaaaaaaa\n"); return p; }
}
