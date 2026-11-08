// ZBIC 压缩的 NSO 在解包时就地解成「段不压缩」的 NSO（#769：FS SDK 22.x 起 eShop 游戏的 main 标志带 0x80，段是任天堂改造的 zstd「ZBIC」）。
//   下游全部读 exefs/ 里的 NSO：改写器、着色器抽取、宽屏扫描、运行时 Ryujinx.LibHac 都只认 LZ4（标志 0–2 位）或不压缩——
//   在这里解一次、写成不压缩段，下游一处不用改，兜底路径（运行时 LibHac 0.21 不认 ZBIC）也一并覆盖。LZ4 的 NSO 原样不动（不改别的款的阶段键）。
//   解压用本目录 ZbicDecoder.cs（S2Arm 自写，RFC 8878 + BIC 表头；11-04 换掉 ezhevita.ZstdSharp.Zbic，那份 BIC 部分出处有疑）。
//   标志位：0–2 = 三个段压缩，3–5 = 段哈希校验（SHA-256，存解压后的哈希，解完照样有效、保留），0x40 原样保留，0x80 = 压缩方式是 ZBIC（不是 LZ4）。别的位不认识 → 报错，不猜。
using System;
using System.IO;
using System.Security.Cryptography;

static class NsoZbic {
    public const uint Zbic = 0x80;
    const uint Bit6 = 0x40;   // Switch 2 新出现、与段解码无关（Eden-NS2 加载器只认 0–5 位与 0x80；塞尔达 时之笛 main 0xff、raiders main 0x7f；同 direct_profile 等读取方，main 0e5e402c7）
    const uint Known = 0x3F | Bit6 | Zbic;
    // 头：0x0C 标志；段头 0x10 / 0x20 / 0x30 = { 文件偏移, 内存偏移, 解压后大小 }；0x60 起三个段在文件里的（压缩）大小；0xA0 起三个段的 SHA-256
    static readonly int[] SegHdr = { 0x10, 0x20, 0x30 };

    // 不是 NSO / 不带 ZBIC：原样返回。带 ZBIC：返回段不压缩的新 NSO（标志去掉 0–2 位与 0x80，哈希位保留）。
    public static byte[] Normalize(byte[] v, string name) {
        if (v.Length < 0x100 || v[0] != 'N' || v[1] != 'S' || v[2] != 'O' || v[3] != '0') return v;
        uint flags = BitConverter.ToUInt32(v, 0x0C);
        if ((flags & ~Known) != 0)
            throw new InvalidDataException($"{name}：NSO 标志 0x{flags:x} 里有不认识的位 0x{flags & ~Known:x}（认得 LZ4 0–2 位、哈希 3–5 位、0x40、ZBIC 0x80），压缩方式不明不解");
        if ((flags & Zbic) == 0) return v;
        var seg = new byte[3][]; int first = v.Length;
        for (int i = 0; i < 3; i++) {
            int off = (int)BitConverter.ToUInt32(v, SegHdr[i]), size = (int)BitConverter.ToUInt32(v, SegHdr[i] + 8), fsz = (int)BitConverter.ToUInt32(v, 0x60 + 4 * i);
            if (off < 0x100 || fsz < 0 || (long)off + fsz > v.Length) throw new InvalidDataException($"{name}：NSO 段 {i} 越出文件（偏移 0x{off:x}、长 0x{fsz:x}、文件 0x{v.Length:x}）");
            first = Math.Min(first, off); var raw = new ReadOnlySpan<byte>(v, off, fsz);
            if ((flags >> i & 1) != 0) {
                byte[] o; try { o = ZbicDecoder.Decompress(raw, size); } catch (InvalidDataException e) { throw new InvalidDataException($"{name}：NSO 段 {i} 的 ZBIC 数据解不开（{e.Message}）", e); }
                seg[i] = o;
            } else {
                if (fsz != size) throw new InvalidDataException($"{name}：NSO 段 {i} 不压缩但文件大小 0x{fsz:x} ≠ 段大小 0x{size:x}");
                seg[i] = raw.ToArray();
            }
            if ((flags >> (3 + i) & 1) != 0 && !SHA256.HashData(seg[i]).AsSpan().SequenceEqual(new ReadOnlySpan<byte>(v, 0xA0 + 0x20 * i, 0x20)))
                throw new InvalidDataException($"{name}：NSO 段 {i} 解出后的 SHA-256 与头里的不符（文件损坏或被改过）");
        }
        // 新布局：头 + 原头后到第一个段之前的内容（模块名等）+ 三个段依次紧排
        int at = first; long total = at; foreach (var s in seg) total += s.Length;
        var n = new byte[total]; Array.Copy(v, 0, n, 0, first);
        for (int i = 0; i < 3; i++) {
            BitConverter.TryWriteBytes(new Span<byte>(n, SegHdr[i], 4), (uint)at); BitConverter.TryWriteBytes(new Span<byte>(n, 0x60 + 4 * i, 4), (uint)seg[i].Length);
            seg[i].CopyTo(n, at); at += seg[i].Length;
        }
        BitConverter.TryWriteBytes(new Span<byte>(n, 0x0C, 4), flags & ~(Zbic | 0x7u));
        return n;
    }
}
