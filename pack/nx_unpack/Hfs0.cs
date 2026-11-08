// 卡带镜像（xci / xcz）的安全分区自己解 HFS0，不经 LibHac 的 Xci.OpenPartition（Sha256PartitionFileSystem 读文件时核 HFS0 记的「前段哈希」，对不上就整份读不了）。
//   11-01 生死格斗沙滩排球3 绯红 整合版：安全分区 120 个文件里 30 个（整合进来的 DLC，成对的 .cnmt.nca + 内容 .nca）前段哈希与 HFS0 表不符，文件本身完整
//   （头声明的末端 = 文件长度），c1029c / 盘点都报 2002-4643 解不开。前段哈希只覆盖每个文件开头 hashTargetSize 字节（NCA 头），内容的完整性另有 NCA 分段哈希把关；
//   对不上的由调用方改核 NCA 头签名（Index）。布局：XCI 头 0x130 u64 根 HFS0 位置；HFS0 = 'HFS0'、u32 文件数、u32 串表长、4 字节；每项 0x40 字节：
//   u64 偏移（相对数据区）、u64 大小、u32 名字在串表的偏移、u32 前段哈希长度、8 字节、32 字节 SHA-256；数据区紧跟串表。
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

static partial class P {
    sealed record HfsEntry(string Name, long Offset, long Size, bool HashOk);

    static byte[] ReadAt(FileStream fh, long off, int n) {
        if (off < 0 || n < 0 || off + n > fh.Length) throw new InvalidDataException($"HFS0 读越界：{off:x} + {n:x} > 文件长 {fh.Length:x}");
        byte[] b = new byte[n]; fh.Position = off; fh.ReadExactly(b); return b;
    }

    static List<HfsEntry> ParseHfs0(FileStream fh, long off, bool verify) {
        byte[] h = ReadAt(fh, off, 16);
        if (h[0] != 'H' || h[1] != 'F' || h[2] != 'S' || h[3] != '0') throw new InvalidDataException($"{off:x} 处不是 HFS0");
        int n = BitConverter.ToInt32(h, 4), strsz = BitConverter.ToInt32(h, 8);
        if (n < 0 || n > 65536 || strsz < 0 || strsz > (1 << 24)) throw new InvalidDataException($"HFS0 表头不合理：文件 {n} 个、串表 {strsz} 字节");
        byte[] ents = ReadAt(fh, off + 16, n * 0x40), strs = ReadAt(fh, off + 16 + n * 0x40L, strsz);
        long data = off + 16 + n * 0x40L + strsz; var outl = new List<HfsEntry>();
        for (int i = 0; i < n; i++) {
            int e = i * 0x40; long o = BitConverter.ToInt64(ents, e), sz = BitConverter.ToInt64(ents, e + 8);
            int so = BitConverter.ToInt32(ents, e + 0x10), hts = BitConverter.ToInt32(ents, e + 0x14);
            if (so < 0 || so >= strsz) throw new InvalidDataException($"HFS0 第 {i} 项名字偏移 {so} 超出串表");
            int z = Array.IndexOf(strs, (byte)0, so); string name = Encoding.UTF8.GetString(strs, so, (z < 0 ? strsz : z) - so);
            bool ok = true;
            if (verify && hts > 0) ok = data + o + hts <= fh.Length && SHA256.HashData(ReadAt(fh, data + o, hts)).AsSpan().SequenceEqual(ents.AsSpan(e + 0x20, 32));
            outl.Add(new HfsEntry(name, data + o, sz, ok));
        }
        return outl;
    }

    // → 安全分区里每个文件：名字、在镜像里的绝对偏移、大小、前段哈希对不对
    static List<HfsEntry> SecureEntries(string src) {
        using var fh = File.OpenRead(src);
        long root = BitConverter.ToInt64(ReadAt(fh, 0x130, 8), 0);
        var sec = ParseHfs0(fh, root, false).Find(e => e.Name == "secure") ?? throw new InvalidDataException("根 HFS0 里没有 secure 分区");
        return ParseHfs0(fh, sec.Offset, true);
    }
}
