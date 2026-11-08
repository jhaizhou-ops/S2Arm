// NCZ（nsz / xcz 里的压缩 NCA，公开格式：github.com/nicoboss/nsz）还原成原 NCA 的只读存储，交给 LibHac 照常按 NCA 解。
// 格式：前 0x4000 字节 = 原 NCA 头（加密态，原样）；0x4000 起「NCZSECTN」+ u64 段数 + 每段 0x40（u64 偏移、u64 长度、u64 加密类型、u64 填充、16 字节密钥、16 字节计数器）；
//   其后要么「NCZBLOCK」分块（u8 版本、u8 类型、u8 保留、u8 块大小指数、u32 块数、u64 解压后总长、u32×块数 各块压缩长度；压缩长度 = 块长的块原样存），
//   要么一整条 zstd 流。解压出的是 NCA 0x4000 之后的明文；加密类型 3（AES-CTR）/ 4（BKTR，同样按 CTR 加了外层）的段要用该段密钥重新加密回原样，
//   计数器 = 段计数器高 8 字节 + 偏移 / 16（大端），与 NCA 本身的 CTR 口径一致；类型 1（不加密）与段外的字节原样。
// 读法：分块模式按块随机读；整流模式只能顺序解，按需往前解压、还原后写进临时文件，读到哪解到哪（只解 exefs 时只解开头一小段）。
//   同一内容在一次运行里只建一个共享实例（多线程读加锁），每次打开给一个不持有它的视图，LibHac 释放视图不影响共享实例；临时文件进程退出时删。
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using LibHac;
using LibHac.Fs;
using ZstdSharp;
using Path = System.IO.Path;

sealed class NczCore {
    readonly struct Sect { public readonly long Off, Size, Type; public readonly byte[] Key, Ctr; public Sect(long o, long s, long t, byte[] k, byte[] c) { Off = o; Size = s; Type = t; Key = k; Ctr = c; } }
    const long HeadLen = 0x4000;    // NCZ 里原样存的前段（nsz UNCOMPRESSABLE_HEADER_SIZE）
    const long NcaHeadLen = 0xC00;  // NCA 头本身：段最早从这里开始
    readonly IStorage src; readonly Sect[] sects; readonly object mu = new();
    readonly long dataAt;   // 源里压缩数据起点（整流：zstd 流起点；分块：第一块起点）
    readonly long blockSize; readonly long[] blockAt, blockLen;   // 分块模式
    public readonly long Size;   // 还原后的 NCA 总长
    // 整流模式：已解到 NCA 偏移 have（从 HeadLen 起），解出的还原数据写在临时文件 tmp（文件偏移 = NCA 偏移 − HeadLen）
    DecompressionStream zs; FileStream tmp; string tmpPath; long have = HeadLen;
    static readonly List<NczCore> Live = new();
    // 整流还原的临时文件放哪：解包时由 Program 设成输出目录所在的目录（与产物同盘：大游戏十几 GB，不压系统盘；产物在外置盘时也一样）；没设用系统临时目录
    public static string TempDir;

    public NczCore(IStorage source, string name) {
        src = source; src.GetSize(out long srcLen).ThrowIfFailure();
        byte[] h = Read(HeadLen, 16);
        if (System.Text.Encoding.ASCII.GetString(h, 0, 8) != "NCZSECTN") throw new InvalidDataException($"{name}：0x4000 处不是 NCZSECTN，不是 NCZ");
        long n = BitConverter.ToInt64(h, 8); if (n <= 0 || n > 1 << 20) throw new InvalidDataException($"{name}：NCZ 段数 {n} 不合理");
        byte[] t = Read(HeadLen + 16, (int)(n * 0x40)); sects = new Sect[n]; long end = HeadLen;
        for (int i = 0; i < n; i++) {
            int b = i * 0x40; sects[i] = new Sect(BitConverter.ToInt64(t, b), BitConverter.ToInt64(t, b + 8), BitConverter.ToInt64(t, b + 16), t[(b + 32)..(b + 48)], t[(b + 48)..(b + 64)]);
            // 段可以从 NCA 头（0xC00 = 头 0x400 + 4 个文件系统头各 0x200）之后就开始，不必在 0x4000 之后：小 NCA（DLC / 元数据）首段常在 0xC00。
            //   nsz 照样只从 0x4000 起压缩，[段首, 0x4000) 那部分随原 NCA 头原样存在前 0x4000 字节里（ReadAt 直接读、Encrypt 只管 0x4000 之后），
            //   10-29 c1029c：七龙珠 电光炸裂 3 份 DLC（首段 3072 / 98304）原先在这里被判坏，盘点读不出、成了孤立的一款解包红
            if (sects[i].Off < NcaHeadLen || sects[i].Size < 0) throw new InvalidDataException($"{name}：第 {i} 段偏移 / 长度不合理（{sects[i].Off} / {sects[i].Size}）");
            end = Math.Max(end, sects[i].Off + sects[i].Size);
        }
        // 段表唯一的不变式是「排序后各段不重叠」（都能落进 NCA 的地址空间）。**总长不能按段长之和推算**：
        //   nsz 的 BlockCompressor 在首段之前会插一个「头部到首段之间」的间隙 partition 一起压缩，但它**不写进 NCZSECTN**
        //   （BlockCompressor.py: 写头只用 len(sections)，间隙只进压缩用的 partitions），所以 0x4000 + Σ段长 会比真实总长小，
        //   按它校验会把 nsz 自己产出的合法包判成「段表损坏」。10-28 维护方实测：首段 off=0x5000 的合成 NCZ，main 读得出、本改动读不出。
        var order = new int[n]; for (int i = 0; i < n; i++) order[i] = i;
        Array.Sort(order, (a, b) => sects[a].Off.CompareTo(sects[b].Off));
        for (int k = 1; k < n; k++) {
            Sect prev = sects[order[k - 1]], cur = sects[order[k]];
            if (cur.Off < prev.Off + prev.Size)
                throw new InvalidDataException($"{name}：第 {order[k - 1]} 段与第 {order[k]} 段重叠（{prev.Off}+{prev.Size} > {cur.Off}），段表损坏");
        }
        long p = HeadLen + 16 + n * 0x40; byte[] m = Read(p, 8);
        if (System.Text.Encoding.ASCII.GetString(m) == "NCZBLOCK") {
            byte[] bh = Read(p + 8, 16); int exp = bh[3]; long nb = BitConverter.ToUInt32(bh, 4); long dsz = BitConverter.ToInt64(bh, 8);
            if (exp < 12 || exp > 32 || nb <= 0) throw new InvalidDataException($"{name}：NCZBLOCK 块大小指数 {exp} / 块数 {nb} 不合理");
            blockSize = 1L << exp; byte[] lens = Read(p + 24, (int)(nb * 4)); blockAt = new long[nb]; blockLen = new long[nb];
            long at = p + 24 + nb * 4; for (int i = 0; i < nb; i++) {
                blockAt[i] = at; blockLen[i] = BitConverter.ToUInt32(lens, i * 4); at += blockLen[i];
                // 单块压缩长度不可能超过块大小的量级：离谱的值（uint 上限 / 越界）当损坏报出来，不去分配几十 GB 的数组
                if (blockLen[i] < 0 || blockLen[i] > blockSize + 0x1000) throw new InvalidDataException($"{name}：第 {i} 块压缩长度 {blockLen[i]} 不合理（块大小 {blockSize}）");
            }
            if (dsz < 0) throw new InvalidDataException($"{name}：NCZBLOCK 解压后总长 {dsz} 不合理");
            Size = HeadLen + dsz; dataAt = blockAt[0];
            if (blockAt[nb - 1] + blockLen[nb - 1] > srcLen) throw new InvalidDataException($"{name}：NCZ 块数据超出文件末尾（末块 {blockAt[nb - 1]}+{blockLen[nb - 1]} > {srcLen}，文件被截断）");
        } else {
            // 整流：原 NCA 总长 = 段的最大末尾。解压流 = 「[0x4000, 首段) 的间隙」+ 各段**顺序拼接**（间隙不在段表里，
            //   但上游把它一起压进了流），所以 Fill() 从 0x4000 起顺序解压写出，间隙自然落到正确位置
            dataAt = p; Size = end;
        }
        if (dataAt > srcLen) throw new InvalidDataException($"{name}：NCZ 头比文件还长（文件被截断）");
    }

    byte[] Read(long off, int len) { byte[] b = new byte[len]; src.Read(off, b).ThrowIfFailure(); return b; }

    // NCA 偏移 [at, at + buf.Length) 的明文还原成原 NCA 字节（就地）
    void Encrypt(long at, Span<byte> buf) {
        foreach (Sect s in sects) {
            if (s.Type != 3 && s.Type != 4) continue;
            long a = Math.Max(at, s.Off), z = Math.Min(at + buf.Length, s.Off + s.Size); if (z <= a) continue;
            using Aes aes = Aes.Create(); aes.Key = s.Key;
            long blk0 = a >> 4, nblk = ((z + 15) >> 4) - blk0; byte[] ctr = new byte[nblk * 16], ks = new byte[nblk * 16];
            for (long k = 0; k < nblk; k++) {
                Array.Copy(s.Ctr, 0, ctr, k * 16, 8); ulong v = (ulong)(blk0 + k);
                for (int j = 0; j < 8; j++) ctr[k * 16 + 15 - j] = (byte)(v >> (8 * j));
            }
            aes.EncryptEcb(ctr, ks, PaddingMode.None);
            int skip = (int)(a - (blk0 << 4));
            for (long q = a; q < z; q++) buf[(int)(q - at)] ^= ks[skip + (q - a)];
        }
    }

    public void ReadAt(long off, Span<byte> dst) {
        if (off < 0 || off + dst.Length > Size) throw new ArgumentOutOfRangeException(nameof(off), $"NCZ 读越界：{off}+{dst.Length} > {Size}");
        int done = 0;
        if (off < HeadLen) { int k = (int)Math.Min(dst.Length, HeadLen - off); src.Read(off, dst[..k]).ThrowIfFailure(); done = k; }
        if (done == dst.Length) return;
        long at = off + done; Span<byte> rest = dst[done..];
        if (blockAt != null) { ReadBlocks(at, rest); return; }
        lock (mu) {
            Fill(at + rest.Length);
            tmp.Position = at - HeadLen; int got = 0;
            while (got < rest.Length) { int r = tmp.Read(rest[got..]); if (r <= 0) throw new EndOfStreamException("NCZ 临时文件读不全"); got += r; }
        }
    }

    // 整流：顺序解压到 NCA 偏移 want，边解边还原、写进临时文件
    void Fill(long want) {
        if (want <= have) return;
        if (zs == null) {
            tmpPath = Path.Combine(TempDir ?? Path.GetTempPath(), $"nx_unpack_ncz_{Environment.ProcessId}_{Guid.NewGuid():N}.nca");
            tmp = new FileStream(tmpPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1 << 20, FileOptions.DeleteOnClose);
            lock (Live) Live.Add(this);
            zs = new DecompressionStream(new StorageReadStream(src, dataAt), 1 << 22);
        }
        byte[] buf = new byte[4 << 20];
        while (have < want) {
            int n = zs.Read(buf, 0, (int)Math.Min(buf.Length, Size - have));
            if (n <= 0) throw new EndOfStreamException($"NCZ 解压在 NCA 偏移 {have} 处提前结束（应到 {Size}；文件被截断？）");
            Encrypt(have, buf.AsSpan(0, n)); tmp.Position = have - HeadLen; tmp.Write(buf, 0, n); have += n;
        }
    }

    // 分块：按块解，块内还原后拷出（不缓存：exefs / 资源按块随机读，块默认 1 MB 级）
    void ReadBlocks(long at, Span<byte> dst) {
        long rel = at - HeadLen; int done = 0;
        using var dec = new Decompressor();
        while (done < dst.Length) {
            long bi = (rel + done) / blockSize; long bStart = bi * blockSize, bLen = Math.Min(blockSize, Size - HeadLen - bStart);
            byte[] raw = Read(blockAt[bi], (int)blockLen[bi]);
            byte[] plain = blockLen[bi] >= bLen ? raw : dec.Unwrap(raw).ToArray();
            if (plain.Length < bLen) throw new InvalidDataException($"NCZ 第 {bi} 块解出 {plain.Length} 字节，应为 {bLen}");
            Encrypt(HeadLen + bStart, plain.AsSpan(0, (int)bLen));
            int from = (int)(rel + done - bStart), k = (int)Math.Min(dst.Length - done, bLen - from);
            plain.AsSpan(from, k).CopyTo(dst[done..]); done += k;
        }
    }

    public static void CleanupAll() { lock (Live) { foreach (NczCore c in Live) { c.zs?.Dispose(); c.tmp?.Dispose(); } Live.Clear(); } }

    // 源存储的顺序读流（zstd 解压器的输入）
    sealed class StorageReadStream : Stream {
        readonly IStorage s; long pos, len;
        public StorageReadStream(IStorage st, long start) { s = st; pos = start; s.GetSize(out len).ThrowIfFailure(); }
        public override int Read(byte[] buffer, int offset, int count) {
            int n = (int)Math.Min(count, len - pos); if (n <= 0) return 0;
            s.Read(pos, buffer.AsSpan(offset, n)).ThrowIfFailure(); pos += n; return n;
        }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => len; public override long Position { get => pos; set => throw new NotSupportedException(); }
        public override void Flush() { } public override long Seek(long o, SeekOrigin r) => throw new NotSupportedException();
        public override void SetLength(long v) => throw new NotSupportedException(); public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
    }
}

// 共享实例上的只读视图（不持有、不释放共享实例）
sealed class NczStorage : IStorage {
    readonly NczCore core; public NczStorage(NczCore c) { core = c; }
    public override Result Read(long offset, Span<byte> destination) { core.ReadAt(offset, destination); return Result.Success; }
    public override Result Write(long offset, ReadOnlySpan<byte> source) => ResultFs.UnsupportedOperation.Log();
    public override Result Flush() => Result.Success;
    public override Result SetSize(long size) => ResultFs.UnsupportedOperation.Log();
    public override Result GetSize(out long size) { size = core.Size; return Result.Success; }
    public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer) => ResultFs.UnsupportedOperation.Log();
}
