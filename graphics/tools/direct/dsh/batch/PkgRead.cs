// 着色器包与 shader_map.tsv 的读法：整份出库（Build.cs）与出包 Vulkan 库工具（graphics/tools/direct/vklib/VkLib.cs 经 <Compile Include> 编进去）共用这一份，
//   两边永远读同一种格式（#783、#1419 直连缺陷线审 2：原先 VkLib 里是 Build.Records / Translate / LoadTables 取法的一份副本）。
// 着色器包 <阶段>*.bin：一串以 "BTCDBTCD" 起头的记录；记录 +0x28 = 控制段字节数、+0x2c = 代码字节数，代码从 +0x38 起、控制段紧随其后。
// shader_map.tsv：包文件名 \t 记录序号 \t … \t 键 \t …；≥ 5 列且包文件以 .bin 结尾的行才是一条记录。
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

static class PkgRead
{
    static readonly byte[] Sep = Encoding.ASCII.GetBytes("BTCDBTCD");

    /// <summary>包文件切成记录：以分隔符起头、到下一个分隔符为止</summary>
    internal static List<byte[]> Records(byte[] d)
    {
        var o = new List<byte[]>(); int p = d.AsSpan().IndexOf(Sep);
        while (p >= 0) { int q = d.AsSpan(p + 1).IndexOf(Sep); q = q < 0 ? d.Length : q + p + 1; o.Add(d[p..q]); p = q < d.Length ? q : -1; }
        return o;
    }

    // 同 Records 的切法，按块读（包超过一个数组放得下的长度时用：Pokopia ps_motorassetre.bin 3.9 GB，File.ReadAllBytes 抛「文件超 2 GB」）：每条记录从一个 BTCDBTCD 起到下一个之前（第一个之前的字节丢弃）。块尾留 7 字节等下一块，分隔符跨块也认得出；
    //   与整读版逐字节同（草稿区对拍：真实包 + 人造重叠 / 跨块分隔符，块 64 字节到 64 MB）
    internal static List<byte[]> RecordsStream(string path, int block)
    {
        ReadOnlySpan<byte> sep = "BTCDBTCD"u8; var o = new List<byte[]>(); var cur = new MemoryStream(); bool started = false;
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan);
        byte[] buf = new byte[block]; int keep = 0;
        while (true)
        {
            int n = fs.Read(buf, keep, buf.Length - keep), total = keep + n; bool eof = n == 0;
            if (total == 0) break;
            // w = 本块里还没写进 cur 的起点，s = 下一次找分隔符的起点（找到后从它的下一个字节接着找，同整读版：重叠的分隔符也切开）
            var span = buf.AsSpan(0, total); int w = 0, s = 0, q;
            while ((q = span[s..].IndexOf(sep)) >= 0)
            {
                q += s;
                if (started) { cur.Write(span[w..q]); o.Add(cur.ToArray()); cur.SetLength(0); }
                started = true; w = q; s = q + 1;
            }
            int safe = eof ? total : Math.Max(w, total - (sep.Length - 1));
            if (started) cur.Write(span[w..safe]);
            keep = total - safe; Buffer.BlockCopy(buf, safe, buf, 0, keep);
            if (eof) break;
        }
        if (started) o.Add(cur.ToArray());
        return o;
    }

    /// <summary>记录头里写的长度装得下：至少 0x38 字节，代码 + 控制段不越过记录末尾（不满足时 Split 会越界抛异常）</summary>
    internal static bool Fits(byte[] rec) => rec.Length >= 0x38 && 0x38L + BitConverter.ToUInt32(rec, 0x2c) + BitConverter.ToUInt32(rec, 0x28) <= rec.Length;

    /// <summary>记录里的代码与控制段（不核长度，调用方先 Fits）</summary>
    internal static (byte[] Code, byte[] Ctl) Split(byte[] rec)
    {
        uint nctl = BitConverter.ToUInt32(rec, 0x28), ncode = BitConverter.ToUInt32(rec, 0x2c);
        return (rec[0x38..(0x38 + (int)ncode)], rec[(0x38 + (int)ncode)..(0x38 + (int)(ncode + nctl))]);
    }

    /// <summary>按行带换行符原样（同 Python open(..., 'rb') 逐行）</summary>
    internal static IEnumerable<byte[]> ReadRawLines(string path)
    {
        var d = File.ReadAllBytes(path); int s = 0;
        for (int i = 0; i < d.Length; i++) if (d[i] == (byte)'\n') { yield return d[s..(i + 1)]; s = i + 1; }
        if (s < d.Length) yield return d[s..];
    }

    /// <summary>shader_map.tsv 逐行：原样字节与按 \t 切开的列</summary>
    internal static IEnumerable<(byte[] Raw, string[] C)> MapLines(string path)
    {
        foreach (var raw in ReadRawLines(path)) yield return (raw, Encoding.UTF8.GetString(raw).TrimEnd('\n').Split('\t'));
    }

    /// <summary>这一行是不是着色器包里的一条记录（键 c[3]、包文件 c[0]、序号 c[1]）</summary>
    internal static bool IsRecord(string[] c) => c.Length > 4 && c[0].EndsWith(".bin", StringComparison.Ordinal);
}
