// NCZ 还原单测：期望值 = 合成的「原 NCA」字节本身（随机生成，不经被测代码）。
// 原 NCA：0x4000 字节头 + 段 0（不加密，0x4000–0x9000）+ 段 1（AES-CTR，0x9000–0x2F123，长度不是 16 的倍数）+ 段 2（AES-CTR，另一把钥匙，到末尾）。
// NCZ 里存的是 0x4000 之后的明文：本测试自己按 NCA 的 CTR 口径（计数器高 8 字节 + 偏移 / 16 大端）逐块算密钥流解出明文，再用 zstd 压，按格式拼头。
// 用例：① 整流顺序读全份 ② 整流先读尾部再读头部（乱序，触发按需解压）③ 分块（含一块原样存）随机读 ④ 截断的 NCZ 读到尾部报错不出假数据
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using LibHac.Fs;
using ZstdSharp;

static class T {
    static int fails, checks;
    static void Check(bool ok, string what) { checks++; if (!ok) fails++; Console.WriteLine($"{(ok ? "通" : "不通")} {what}"); }

    const int Head = 0x4000;
    record Sec(long Off, long Size, long Type, byte[] Key, byte[] Ctr);

    static byte[] Keystream(byte[] key, byte[] ctr, long off, int len) {   // 从 NCA 偏移 off 起 len 字节的 CTR 密钥流（逐块单独算）
        using var aes = Aes.Create(); aes.Key = key; var ks = new byte[len];
        for (int i = 0; i < len;) {
            long blk = (off + i) >> 4; byte[] c = new byte[16]; Array.Copy(ctr, c, 8);
            for (int j = 0; j < 8; j++) c[15 - j] = (byte)((ulong)blk >> (8 * j));
            byte[] e = aes.EncryptEcb(c, PaddingMode.None); int k = (int)((off + i) & 15);
            for (; k < 16 && i < len; k++, i++) ks[i] = e[k];
        }
        return ks;
    }

    static byte[] Plain(byte[] nca, Sec[] secs) {   // 原 NCA 0x4000 之后 → 明文
        byte[] p = nca[Head..];
        foreach (var s in secs.Where(s => s.Type == 3)) {
            byte[] ks = Keystream(s.Key, s.Ctr, s.Off, (int)s.Size);
            for (long q = 0; q < s.Size; q++) if (s.Off + q >= Head) p[s.Off - Head + q] ^= ks[q];   // 段在 0x4000 之前的部分随 NCA 头原样存，不进明文流
        }
        return p;
    }

    static byte[] SectHeader(Sec[] secs) {
        var m = new MemoryStream(); var w = new BinaryWriter(m);
        w.Write("NCZSECTN"u8.ToArray()); w.Write((long)secs.Length);
        foreach (var s in secs) { w.Write(s.Off); w.Write(s.Size); w.Write(s.Type); w.Write(0L); w.Write(s.Key); w.Write(s.Ctr); }
        return m.ToArray();
    }

    static byte[] Solid(byte[] nca, Sec[] secs) {
        using var c = new Compressor(3);
        return nca[..Head].Concat(SectHeader(secs)).Concat(c.Wrap(Plain(nca, secs)).ToArray()).ToArray();
    }

    static byte[] Blocks(byte[] nca, Sec[] secs, int exp, int rawBlock) {   // 第 rawBlock 块原样存（压缩长度 = 块长）
        byte[] p = Plain(nca, secs); int bs = 1 << exp, nb = (p.Length + bs - 1) / bs;
        using var c = new Compressor(3); var parts = new byte[nb][];
        for (int i = 0; i < nb; i++) { byte[] b = p[(i * bs)..Math.Min(p.Length, (i + 1) * bs)]; byte[] z = c.Wrap(b).ToArray(); parts[i] = i == rawBlock || z.Length >= b.Length ? b : z; }   // nsz 写入端规矩：压缩后不比原块小就原样存
        var m = new MemoryStream(); var w = new BinaryWriter(m);
        w.Write("NCZBLOCK"u8.ToArray()); w.Write((byte)2); w.Write((byte)1); w.Write((byte)0); w.Write((byte)exp); w.Write((uint)nb); w.Write((long)p.Length);
        foreach (var x in parts) w.Write((uint)x.Length);
        foreach (var x in parts) w.Write(x);
        return nca[..Head].Concat(SectHeader(secs)).Concat(m.ToArray()).ToArray();
    }

    static byte[] ReadAll(IStorage s, long size, int chunk) { byte[] o = new byte[size]; for (long p = 0; p < size; p += chunk) s.Read(p, o.AsSpan((int)p, (int)Math.Min(chunk, size - p))).ThrowIfFailure(); return o; }

    static int Main() {
        var rnd = new Random(26); byte[] nca = new byte[0x4C567]; rnd.NextBytes(nca);
        byte[] k1 = new byte[16], k2 = new byte[16], c1 = new byte[16], c2 = new byte[16]; rnd.NextBytes(k1); rnd.NextBytes(k2); rnd.NextBytes(c1); rnd.NextBytes(c2);
        Sec[] secs = { new(Head, 0x5000, 1, new byte[16], new byte[16]), new(0x9000, 0x26123, 3, k1, c1), new(0x2F123, nca.Length - 0x2F123, 3, k2, c2) };
        // 不加密段（段 0）放一段全零，确认压缩真起作用（不是原样存）
        Array.Clear(nca, Head, 0x5000);

        byte[] solid = Solid(nca, secs);
        var a = new NczStorage(new NczCore(new MemoryStorage(solid), "solid"));
        a.GetSize(out long sz).ThrowIfFailure();
        Check(sz == nca.Length, $"整流：还原后长度 {sz} = 原 NCA {nca.Length}");
        Check(solid.Length < nca.Length, $"整流：NCZ {solid.Length} 字节 < 原 {nca.Length}（真的压了）");
        Check(ReadAll(a, sz, 0x1234).SequenceEqual(nca), "整流：按 0x1234 一段顺序读全份 = 原 NCA 逐字节");

        var b = new NczStorage(new NczCore(new MemoryStorage(solid), "solid2"));
        byte[] tail = new byte[0x777], mid = new byte[0x2345], head = new byte[0x4010];
        b.Read(nca.Length - tail.Length, tail).ThrowIfFailure(); b.Read(0x8FF7, mid).ThrowIfFailure(); b.Read(0, head).ThrowIfFailure();
        Check(tail.SequenceEqual(nca[^tail.Length..]) && mid.SequenceEqual(nca[0x8FF7..(0x8FF7 + mid.Length)]) && head.SequenceEqual(nca[..head.Length]),
              "整流：先读尾部、再读跨段边界的中段、再读跨 0x4000 的头部（乱序）都 = 原 NCA");

        byte[] blk = Blocks(nca, secs, 14, 3);
        var c = new NczStorage(new NczCore(new MemoryStorage(blk), "block"));
        c.GetSize(out long sz2).ThrowIfFailure();
        bool ok = sz2 == nca.Length;
        foreach (var (off, len) in new[] { (0x2F100L, 0x50), (0x4000L, 0x10), (0x40000L, 0x9000), ((long)nca.Length - 5, 5), (0x3FF0L, 0x4020) }) {
            byte[] x = new byte[len]; c.Read(off, x).ThrowIfFailure(); ok &= x.SequenceEqual(nca[(int)off..(int)(off + len)]);
        }
        Check(ok && ReadAll(c, sz2, 0x3001).SequenceEqual(nca), "分块（块 16 KB、第 3 块原样存）：随机读五处 + 全份 = 原 NCA");

        byte[] cut = solid[..(solid.Length - 200)];
        var d = new NczStorage(new NczCore(new MemoryStorage(cut), "cut")); string err = "";
        try { byte[] x = new byte[16]; d.Read(nca.Length - 16, x).ThrowIfFailure(); } catch (Exception e) { err = e.GetType().Name; }
        Check(err != "", $"截断的整流 NCZ 读尾部：报错（{(err == "" ? "没报错" : err)}），不出假数据");

        // ⑤ 首段前有间隙：nsz 的 BlockCompressor 在首段之前会插一个「NCA 头到首段之间」的间隙 partition 一起压缩，
        //   但它只进压缩用的 partitions、**不写进 NCZSECTN**（写头只用 len(sections)）。所以 [0x4000, 首段) 不属于任何段，
        //   仍必须逐字节还原；总长也不能按「0x4000 + 段长之和」推算（会比真实总长小，把合法包判成段表损坏）。
        //   10-28 维护方实测：首段 off=0x5000 的合成 NCZ，main 读得出、按段长之和校验的版本读不出。
        byte[] gapNca = new byte[0x3C123]; rnd.NextBytes(gapNca);
        Sec[] gapSecs = { new(0x5000, 0x10000, 3, k1, c1), new(0x15000, gapNca.Length - 0x15000, 3, k2, c2) };
        var g = new NczStorage(new NczCore(new MemoryStorage(Solid(gapNca, gapSecs)), "gap"));
        g.GetSize(out long szg).ThrowIfFailure();
        Check(szg == gapNca.Length, $"首段前 0x1000 间隙：还原后长度 {szg} = 原 NCA {gapNca.Length}");
        Check(ReadAll(g, szg, 0x2000).SequenceEqual(gapNca), "首段前 0x1000 间隙：全份逐字节 = 原 NCA（间隙不在段表里也要还原）");

        // ⑥ 段重叠：段表唯一的不变式（排序后各段不重叠）被破坏 → 构造时就报错，不去读错位数据
        Sec[] overSecs = { new(Head, 0x2000, 3, k1, c1), new(0x5000, 0x2000, 3, k2, c2) };
        string errOv = "";
        try { var o = new NczStorage(new NczCore(new MemoryStorage(Solid(nca, overSecs)), "overlap")); } catch (Exception e) { errOv = e.GetType().Name + "：" + e.Message; }
        Check(errOv.Contains("重叠"), $"段重叠（0x4000+0x2000 > 0x5000）：构造时报错（{(errOv == "" ? "没报错" : errOv.Split('\n')[0])}）");

        // ⑦ 首段从 NCA 头之后（0xC00）就开始（10-29 c1029c 七龙珠 DLC：首段 3072 / 98304）：[0xC00, 0x4000) 随头原样存，0x4000 起照常压缩还原。
        //   期望：整流 / 分块都逐字节还原原 NCA；首段在 0xC00 之前（落进 NCA 头里，不可能的段表）照旧报「不合理」
        byte[] smallNca = new byte[0x24000]; rnd.NextBytes(smallNca);
        Sec[] smallSecs = { new(0xC00, 0x18000, 3, k1, c1), new(0x18C00, smallNca.Length - 0x18C00, 3, k2, c2) };
        var sm = new NczStorage(new NczCore(new MemoryStorage(Solid(smallNca, smallSecs)), "small")); sm.GetSize(out long szs).ThrowIfFailure();
        Check(szs == smallNca.Length && ReadAll(sm, szs, 0x1800).SequenceEqual(smallNca), $"首段从 0xC00 开始（整流）：长度 {szs} = {smallNca.Length}、全份逐字节 = 原 NCA");
        var smb = new NczStorage(new NczCore(new MemoryStorage(Blocks(smallNca, smallSecs, 14, 1)), "small-blk")); smb.GetSize(out long szsb).ThrowIfFailure();
        Check(szsb == smallNca.Length && ReadAll(smb, szsb, 0x2345).SequenceEqual(smallNca), "首段从 0xC00 开始（分块）：全份逐字节 = 原 NCA");
        string errHd = "";
        try { new NczCore(new MemoryStorage(Solid(smallNca, new Sec[] { new(0x800, 0x1000, 1, new byte[16], new byte[16]), new(0x1800, smallNca.Length - 0x1800, 3, k2, c2) })), "inhead"); } catch (Exception e) { errHd = e.Message; }
        Check(errHd.Contains("不合理"), $"首段在 0xC00 之前（落进 NCA 头）：报错（{(errHd == "" ? "没报错" : errHd)}）");

        // 同一内容多份择一（CopyPick，10-26 泡泡龙4 卡带 + 坏的 NSP 两份本体）：期望按规则手算——第一份通过的；都不过取最后一份；一份不校验
        int calls = 0;
        var p1 = CopyPick.Pick(3, i => { calls++; return i != 0; });
        Check(p1.Pick == 1 && p1.Bad.SequenceEqual(new[] { 0 }) && calls == 2, $"多份：第 0 份坏、第 1 份好 → 用第 1 份、点名第 0 份、第 2 份不再校验（选 {p1.Pick}，校验 {calls} 次）");
        var p2 = CopyPick.Pick(2, i => i == 0 ? true : throw new InvalidOperationException());
        Check(p2.Pick == 0 && p2.Bad.Count == 0, "多份：第 0 份就好 → 用第 0 份（后面抛异常的不碰）");
        var p3 = CopyPick.Pick(3, i => i == 1 ? throw new IOException("坏块") : false);
        Check(p3.Pick == 2 && p3.Bad.SequenceEqual(new[] { 0, 1, 2 }), "多份：都不过（含抛异常）→ 照旧用最后一份、三份都点名");
        calls = 0; var p4 = CopyPick.Pick(1, i => { calls++; return false; });
        Check(p4.Pick == 0 && calls == 0, "只有一份：不校验，直接用");
        // 多程序合集按序号挑内容（ProgramPick，11-06 索尼克×夏特 世代重启：本体清单两支 Program + 两份 Control，序号 1 原先没解包）。
        //   合成清单（清单顺序）：Program 序号 0、Program 序号 1；Control 序号 1 排在序号 0 前面（顺序不代表序号）。期望按 Ryujinx GetNcaByType 手算
        int[] prog = { 0, 1 }, ctrl = { 1, 0 };
        Check(ProgramPick.Pick(2, i => prog[i], 1) == 1, "多程序：要序号 1 的 Program → 清单第 2 份（下标 1）");
        Check(ProgramPick.Pick(2, i => ctrl[i], 0) == 1, "多程序：要序号 0 的 Control，清单里它排第 2 → 下标 1（不是第一份）");
        Check(ProgramPick.Pick(2, i => ctrl[i], 1) == 0, "多程序：要序号 1 的 Control → 下标 0");
        Check(ProgramPick.Pick(2, i => prog[i], 2) == -1, "多程序：要包里没有的序号 2 → -1（调用方报红）");
        calls = 0; Check(ProgramPick.Pick(1, i => { calls++; return 5; }, 0) == 0 && calls == 0, "单程序：只有一份、要序号 0 → 不读序号直接用第一份");
        Check(ProgramPick.Pick(2, i => i == 0 ? throw new IOException("头读不出") : 0, 0) == 1, "多程序：第一份头读不出（异常）→ 不算序号 0，用第二份");
        Check(ProgramPick.Pick(0, i => 0, 0) == -1, "清单里没有这类内容 → -1");
        Check(ProgramPick.Count(new[] { 0, 1 }) == 2 && ProgramPick.Count(new[] { 1, 0, 3 }) == 2 && ProgramPick.Count(new[] { 1 }) == 0 && ProgramPick.Count(new[] { 0, -1 }) == 1,
            "支数 = 序号从 0 起连续段：{0,1}→2、{1,0,3}→2、{1}→0、{0,读不出}→1");
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} nx_unpack NCZ：{checks} 项，不通 {fails}");
        NczCore.CleanupAll();
        return fails == 0 ? 0 : 1;
    }
}
