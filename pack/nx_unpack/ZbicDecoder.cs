// ZBIC 解压（S2Arm 自写）：Switch 22.0.0 起 NSO 段可用的 zstd 变体（NSO 标志 bit 7）。
//   与标准 zstd（RFC 8878）只差两处：
//   ① 帧魔数是 "ZBIC"（小端 0x4349425A）——公开事实：switchbrew.org/wiki/22.0.0（Loader 一节）；
//   ② FSE 表头（归一化计数，RFC 8878 §4.1.1 那一段）改用二进制插值编码（BIC）写——switchbrew 只说「换成 BIC 版本」，
//      编码规则（下面 ReadCounts 注释里那几条）事实取自 Atmosphère / kinnay zbic 的 zstd.c（GPL-2.0），代码自写，未照搬结构、命名与常量表。
//   其余（帧 / 块 / 字面量 / Huffman / 序列 / FSE 解码 / XXH64 校验）照 RFC 8878 自写，行为对齐 facebook/zstd 1.5.x 解码器（BSD 许可，只作行为参照）。
//   两处 BIC 用到：三张序列表（字面长度 / 偏移 / 匹配长度）的 FSE_Compressed 模式，以及 Huffman 权重的 FSE 压缩表头。
// 接口：ZbicDecoder.Decompress(数据, 期望长度) → 解出的字节；数据坏 / 不是 ZBIC 帧 / 长度不符一律抛 InvalidDataException，不猜不崩。
using System;
using System.Buffers.Binary;
using System.IO;

static class ZbicDecoder {
    public const uint Magic = 0x4349425A;          // "ZBIC"
    const uint ZstdMagic = 0xFD2FB528;             // 标准 zstd：明确报「不是 ZBIC」
    const int BlockMax = 128 << 10;                // RFC 8878 §3.1.1.2.3 Block_Maximum_Size 上限

    static Exception Bad(string m) => new InvalidDataException(m);

    // 解出全部帧，总长必须等于 expected（NSO 段头里写的大小）
    public static byte[] Decompress(ReadOnlySpan<byte> src, int expected) {
        if (expected < 0) throw Bad("期望长度为负");
        var dst = new byte[expected];
        int n = Decompress(src, dst);
        if (n != expected) throw Bad($"解出 0x{n:x} 字节，期望 0x{expected:x}");
        return dst;
    }

    public static int Decompress(ReadOnlySpan<byte> src, Span<byte> dst) {
        int ip = 0, op = 0, frames = 0;
        while (ip < src.Length) {
            if (src.Length - ip < 4) throw Bad($"偏移 0x{ip:x} 处剩 {src.Length - ip} 字节，不够一个帧魔数");
            uint m = BinaryPrimitives.ReadUInt32LittleEndian(src[ip..]);
            if (m == Magic) { var f = new Frame(); op += f.Run(src, ref ip, dst, op); frames++; }
            else if ((m & 0xFFFFFFF0) == 0x184D2A50) {    // 可跳过帧（RFC 8878 §3.1.2）
                if (src.Length - ip < 8) throw Bad("可跳过帧头截断");
                long len = BinaryPrimitives.ReadUInt32LittleEndian(src[(ip + 4)..]);
                if (len > src.Length - ip - 8) throw Bad("可跳过帧越出数据");
                ip += 8 + (int)len;
            } else if (m == ZstdMagic) throw Bad($"偏移 0x{ip:x} 是标准 zstd 帧（魔数 28 B5 2F FD），不是 ZBIC");
            else throw Bad($"偏移 0x{ip:x} 不认识的帧魔数 0x{m:x8}（ZBIC 是 5A 42 49 43）");
        }
        if (frames == 0) throw Bad("没有 ZBIC 帧");
        return op;
    }

    // ---------------- 倒序比特流（RFC 8878 §4.1：从末字节最高的 1 往前读） ----------------
    ref struct BackBits {
        readonly ReadOnlySpan<byte> b;
        public long Pos;   // 还没读的比特数；读过头为负（读到的补 0）
        public BackBits(ReadOnlySpan<byte> s) {
            b = s;
            if (s.Length == 0 || s[^1] == 0) throw Bad("比特流为空或末字节为 0（缺结束标记）");
            Pos = 8L * (s.Length - 1) + (31 - System.Numerics.BitOperations.LeadingZeroCount((uint)s[^1]));
        }
        // 比特 [from, from+n) 的值，from ≥ 0、n ≤ 56
        ulong At(long from, int n) {
            int i = (int)(from >> 3), sh = (int)(from & 7); ulong v;
            if (i + 8 <= b.Length) v = BinaryPrimitives.ReadUInt64LittleEndian(b[i..]);
            else { v = 0; for (int k = 0; k < 8 && i + k < b.Length; k++) v |= (ulong)b[i + k] << (8 * k); }
            return (v >> sh) & ((1UL << n) - 1);
        }
        public ulong Peek(int n) {
            if (n == 0) return 0;
            long from = Pos - n;
            if (from >= 0) return At(from, n);
            if (Pos <= 0) return 0;
            return At(0, (int)Pos) << (int)(n - Pos);
        }
        public ulong Read(int n) { ulong v = Peek(n); Pos -= n; return v; }
    }

    // ---------------- FSE 解码表 ----------------
    sealed class Fse {
        public int Log; public byte[] Sym; public byte[] Bits; public ushort[] Base;
        public static Fse Build(short[] norm, int maxSym, int log) {
            int size = 1 << log; var t = new Fse { Log = log, Sym = new byte[size], Bits = new byte[size], Base = new ushort[size] };
            var next = new int[maxSym + 1]; int high = size - 1;
            for (int s = 0; s <= maxSym; s++) {
                if (norm[s] == -1) { t.Sym[high--] = (byte)s; next[s] = 1; }   // 「小于 1」的概率：放表尾，各占一格
                else next[s] = norm[s];
            }
            int pos = 0, step = (size >> 1) + (size >> 3) + 3, mask = size - 1;
            for (int s = 0; s <= maxSym; s++)
                for (int k = 0; k < norm[s]; k++) { t.Sym[pos] = (byte)s; do pos = (pos + step) & mask; while (pos > high); }
            if (pos != 0) throw Bad("FSE 表铺不满（归一化计数不自洽）");
            for (int u = 0; u < size; u++) {
                int s = t.Sym[u], x = next[s]++;
                int nb = log - (31 - System.Numerics.BitOperations.LeadingZeroCount((uint)x));
                t.Bits[u] = (byte)nb; t.Base[u] = (ushort)((x << nb) - size);
            }
            return t;
        }
        public static Fse Rle(byte s) => new Fse { Log = 0, Sym = new[] { s }, Bits = new byte[1], Base = new ushort[1] };
    }

    // ---------------- BIC 归一化计数表头 ----------------
    // 编码规则（事实取自 Atmosphère zstd.c 的 FSE_readNCount_bic，GPL-2.0；代码自写）：
    //   · 首字节：低 7 位 = 后面跟的载荷字节数 n，最高位 = 「低概率」标志 lp；表头共占 1+n 字节，且必须短于可用数据（严格小于）。
    //   · 载荷是一个混合进制大数，从最后一个载荷字节往前读入：累加器不足 2^40 且还有字节就「乘 256 加下一字节」补足；
    //     每取一位「r = acc mod M、acc = acc div M」之后再补足。依次取：最大符号值 − 1（M = 52）、表位数 − 5（M = 8）、
    //     末项累计值的低位 L（M = 2^表位数）。末项累计值 = lp ? 最大符号值 + L + 2 : L + 1。
    //   · 累计表 cum[0..P]（P = 大于最大符号值的最小 2 的幂，须 ≤ 128）：cum[0] = 0，cum[P] = 末项累计值，
    //     中间值按区间二分递归求：区间 [lo, hi]（hi − lo ≥ 2）、mid = (lo + hi) / 2，先序、先右半再左半；
    //     cum[lo] == cum[hi] 时区间内全取 cum[lo]（不读数），否则 cum[mid] = cum[lo] + 取一位（M = cum[hi] − cum[lo] + 1）。
    //     整棵树之后还有一步：cum[1] ≠ 0 时再取一位（M = cum[1] + 1），值不用。
    //   · 符号 s 的计数 = cum[s+1] − cum[s] − lp（−1 = 「小于 1」的概率）；|计数| 之和须等于 2^表位数，载荷须恰好读完。
    ref struct Digits {
        readonly ReadOnlySpan<byte> p; int left; ulong acc;
        public Digits(ReadOnlySpan<byte> payload) { p = payload; left = payload.Length; acc = 0; Fill(); }
        void Fill() { while (left > 0 && acc < (1UL << 40)) acc = (acc << 8) | p[--left]; }
        public ulong Take(ulong m) { ulong r = acc % m; acc /= m; Fill(); return r; }
        public int Left => left;
    }

    static void Split(int lo, int hi, int[] cum, ref Digits d) {
        if (hi - lo < 2) return;
        if (cum[lo] == cum[hi]) { for (int k = lo + 1; k < hi; k++) cum[k] = cum[lo]; return; }
        if (cum[hi] < cum[lo]) throw Bad("BIC 表头：累计计数倒退");
        int mid = (lo + hi) >> 1;
        cum[mid] = cum[lo] + (int)d.Take((ulong)(cum[hi] - cum[lo] + 1));
        Split(mid, hi, cum, ref d);
        Split(lo, mid, cum, ref d);
    }

    // 返回表头字节数；norm[0..maxSym]、maxSym、log 写出
    static int ReadCounts(ReadOnlySpan<byte> src, int symLimit, int logLimit, short[] norm, out int maxSym, out int log) {
        if (src.Length == 0) throw Bad("BIC 表头：没有数据");
        int n = src[0] & 0x7F, lp = src[0] >> 7;
        if (n + 1 >= src.Length) throw Bad("BIC 表头越出数据");
        var d = new Digits(src.Slice(1, n));
        maxSym = (int)d.Take(52) + 1;
        if (maxSym > symLimit) throw Bad($"BIC 表头：最大符号 {maxSym} 超过上限 {symLimit}");
        log = (int)d.Take(8) + 5;
        if (log > logLimit) throw Bad($"BIC 表头：表位数 {log} 超过上限 {logLimit}");
        int total = 1 << log, last = (int)d.Take((ulong)total);
        int top = lp != 0 ? maxSym + last + 2 : last + 1;
        int P = 1; while (P <= maxSym) P <<= 1;
        if (P > 128) throw Bad("BIC 表头：符号数过多");
        var cum = new int[P + 1]; cum[P] = top;
        Split(0, P, cum, ref d);
        if (cum[1] != 0) d.Take((ulong)cum[1] + 1);
        int sum = 0;
        for (int s = 0; s <= maxSym; s++) {
            int c = cum[s + 1] - cum[s] - lp;
            if (c < -1) throw Bad("BIC 表头：计数为负");
            norm[s] = (short)c; sum += c < 0 ? 1 : c;
        }
        if (sum != total) throw Bad($"BIC 表头：计数和 {sum} ≠ 2^{log}");
        if (d.Left != 0) throw Bad("BIC 表头：载荷没读完");
        return n + 1;
    }

    // ---------------- 序列码表（RFC 8878 §3.1.1.3.2.1） ----------------
    static readonly int[] LLBase = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536 };
    static readonly byte[] LLBits = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16 };
    static readonly int[] MLBase = { 3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,
                                     35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539 };
    static readonly byte[] MLBits = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                                      1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16 };
    // 预定义分布（RFC 8878 §3.1.1.3.2.2）
    static readonly Fse LLDef = Fse.Build(new short[] { 4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1 }, 35, 6);
    static readonly Fse MLDef = Fse.Build(new short[] { 1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1 }, 52, 6);
    static readonly Fse OFDef = Fse.Build(new short[] { 1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1 }, 28, 5);

    // ---------------- 帧 ----------------
    sealed class Frame {
        byte[] hSym, hLen; int hBits;          // 上一张 Huffman 表（Treeless 字面量复用）
        Fse ll, of, ml;                        // 上一组序列表（Repeat 模式复用）
        int r1 = 1, r2 = 4, r3 = 8;            // 重复偏移初值（RFC 8878 §3.1.2.5）
        readonly byte[] lit = new byte[BlockMax];
        readonly short[] norm = new short[256];

        public int Run(ReadOnlySpan<byte> src, ref int ip, Span<byte> dst, int start) {
            int p = ip + 4;
            if (p >= src.Length) throw Bad("帧头截断");
            int fhd = src[p++];
            int fcsFlag = fhd >> 6, single = (fhd >> 5) & 1, check = (fhd >> 2) & 1, didFlag = fhd & 3;
            if ((fhd & 8) != 0) throw Bad("帧头保留位非 0");
            long window = 0;
            if (single == 0) {
                if (p >= src.Length) throw Bad("帧头截断");
                int wd = src[p++], wlog = 10 + (wd >> 3); long b = 1L << wlog; window = b + (b >> 3) * (wd & 7);
            }
            int didSize = new[] { 0, 1, 2, 4 }[didFlag];
            if (src.Length - p < didSize) throw Bad("帧头截断");
            uint did = 0; for (int k = 0; k < didSize; k++) did |= (uint)src[p + k] << (8 * k); p += didSize;
            if (did != 0) throw Bad($"帧要字典 {did}（ZBIC NSO 段不该带字典，没有可用的字典）");
            int fcsSize = fcsFlag == 0 ? single : 1 << fcsFlag;
            if (src.Length - p < fcsSize) throw Bad("帧头截断");
            long fcs = -1;
            if (fcsSize > 0) { ulong v = 0; for (int k = 0; k < fcsSize; k++) v |= (ulong)src[p + k] << (8 * k); fcs = fcsSize == 2 ? (long)v + 256 : (long)v; p += fcsSize; }
            if (single != 0) window = fcs;
            int blockMax = (int)Math.Min(window, BlockMax);
            int op = start;
            while (true) {
                if (src.Length - p < 3) throw Bad("块头截断");
                int h = src[p] | src[p + 1] << 8 | src[p + 2] << 16; p += 3;
                int last = h & 1, type = (h >> 1) & 3, size = h >> 3;
                if (type == 3) throw Bad("块类型为保留值 3");
                if (size > blockMax) throw Bad($"块大小 {size} 超过上限 {blockMax}");
                if (type == 0) {
                    if (src.Length - p < size) throw Bad("原样块截断");
                    if (dst.Length - op < size) throw Bad("输出超出期望长度");
                    src.Slice(p, size).CopyTo(dst[op..]); p += size; op += size;
                } else if (type == 1) {
                    if (p >= src.Length) throw Bad("RLE 块截断");
                    if (dst.Length - op < size) throw Bad("输出超出期望长度");
                    dst.Slice(op, size).Fill(src[p]); p += 1; op += size;
                } else {
                    if (src.Length - p < size) throw Bad("压缩块截断");
                    int got = Block(src.Slice(p, size), dst, op, start);
                    if (got > blockMax) throw Bad("块解出超过块上限");
                    p += size; op += got;
                }
                if (last != 0) break;
            }
            if (fcs >= 0 && op - start != fcs) throw Bad($"帧解出 {op - start} 字节，帧头记 {fcs}");
            if (check != 0) {
                if (src.Length - p < 4) throw Bad("校验和截断");
                uint want = BinaryPrimitives.ReadUInt32LittleEndian(src[p..]); p += 4;
                uint got = (uint)XxHash64(dst.Slice(start, op - start));
                if (got != want) throw Bad($"帧校验和不符（XXH64 低 32 位 0x{got:x8}，帧里 0x{want:x8}）");
            }
            ip = p;
            return op - start;
        }

        // 压缩块：字面量段 + 序列段，解进 dst[op..]，返回字节数
        int Block(ReadOnlySpan<byte> b, Span<byte> dst, int op, int frameStart) {
            int used = Literals(b, out int nLit);
            int p = used;
            if (p >= b.Length) throw Bad("压缩块缺序列段");
            int nSeq = b[p++];
            if (nSeq >= 128) {
                if (nSeq < 255) { if (p >= b.Length) throw Bad("序列数截断"); nSeq = ((nSeq - 128) << 8) + b[p++]; }
                else { if (b.Length - p < 2) throw Bad("序列数截断"); nSeq = b[p] + (b[p + 1] << 8) + 0x7F00; p += 2; }
            }
            int o = op;
            if (nSeq == 0) {
                if (p != b.Length) throw Bad("无序列的块尾部有多余字节");
                if (dst.Length - o < nLit) throw Bad("输出超出期望长度");
                lit.AsSpan(0, nLit).CopyTo(dst[o..]); return nLit;
            }
            if (p >= b.Length) throw Bad("序列模式字节截断");
            int modes = b[p++];
            if ((modes & 3) != 0) throw Bad("序列模式保留位非 0");
            p += Table(b[p..], (modes >> 6) & 3, 35, 9, LLDef, ref ll, "字面长度");
            p += Table(b[p..], (modes >> 4) & 3, 31, 8, OFDef, ref of, "偏移");
            p += Table(b[p..], (modes >> 2) & 3, 52, 9, MLDef, ref ml, "匹配长度");
            var br = new BackBits(b[p..]);
            int sL = (int)br.Read(ll.Log), sO = (int)br.Read(of.Log), sM = (int)br.Read(ml.Log);
            int li = 0;
            for (int i = 0; i < nSeq; i++) {
                int lc = ll.Sym[sL], mc = ml.Sym[sM], oc = of.Sym[sO];
                if (lc > 35 || mc > 52 || oc > 31) throw Bad("序列码越界");
                long ov = (1L << oc) + (long)br.Read(oc);
                int mlen = MLBase[mc] + (int)br.Read(MLBits[mc]);
                int llen = LLBase[lc] + (int)br.Read(LLBits[lc]);
                long off;
                if (ov > 3) { off = ov - 3; r3 = r2; r2 = r1; r1 = (int)Math.Min(off, int.MaxValue); }
                else {
                    int idx = (int)ov - 1 + (llen == 0 ? 1 : 0);   // 0 = r1，1 = r2，2 = r3，3 = r1 − 1
                    if (idx == 0) off = r1;
                    else {
                        off = idx == 1 ? r2 : idx == 2 ? r3 : r1 - 1;
                        if (idx != 1) r3 = r2;
                        r2 = r1; r1 = (int)off;
                    }
                }
                if (i + 1 < nSeq) {   // 状态更新次序：字面长度、匹配长度、偏移
                    sL = ll.Base[sL] + (int)br.Read(ll.Bits[sL]);
                    sM = ml.Base[sM] + (int)br.Read(ml.Bits[sM]);
                    sO = of.Base[sO] + (int)br.Read(of.Bits[sO]);
                }
                if (llen > nLit - li) throw Bad("序列要的字面量超过字面量段");
                if ((long)llen + mlen > dst.Length - o) throw Bad("输出超出期望长度");
                lit.AsSpan(li, llen).CopyTo(dst[o..]); li += llen; o += llen;
                if (off <= 0 || off > o - frameStart) throw Bad($"匹配偏移 {off} 越过帧开头");
                int from = o - (int)off;
                if (off >= mlen) dst.Slice(from, mlen).CopyTo(dst[o..]);
                else for (int k = 0; k < mlen; k++) dst[o + k] = dst[from + k];
                o += mlen;
            }
            if (br.Pos != 0) throw Bad("序列比特流没恰好读完");
            int rest = nLit - li;
            if (dst.Length - o < rest) throw Bad("输出超出期望长度");
            lit.AsSpan(li, rest).CopyTo(dst[o..]); o += rest;
            return o - op;
        }

        int Table(ReadOnlySpan<byte> b, int mode, int symLimit, int logLimit, Fse def, ref Fse slot, string name) {
            switch (mode) {
                case 0: slot = def; return 0;
                case 1:
                    if (b.Length < 1) throw Bad($"{name} RLE 符号截断");
                    if (b[0] > symLimit) throw Bad($"{name} RLE 符号越界");
                    slot = Fse.Rle(b[0]); return 1;
                case 2: {
                    int n = ReadCounts(b, symLimit, logLimit, norm, out int maxSym, out int log);
                    slot = Fse.Build(norm, maxSym, log); return n;
                }
                default:
                    if (slot == null) throw Bad($"{name} 表要复用上一张，但本帧还没有");
                    return 0;
            }
        }

        // 字面量段（RFC 8878 §3.1.1.3.1），解进 lit，返回段长
        int Literals(ReadOnlySpan<byte> b, out int n) {
            if (b.Length < 1) throw Bad("字面量段截断");
            int b0 = b[0], type = b0 & 3, sf = (b0 >> 2) & 3;
            if (type < 2) {
                int hs = sf == 1 ? 2 : sf == 3 ? 3 : 1;
                if (b.Length < hs) throw Bad("字面量头截断");
                n = hs == 1 ? b0 >> 3 : hs == 2 ? (b0 >> 4) + (b[1] << 4) : (b0 >> 4) + (b[1] << 4) + (b[2] << 12);
                if (n > BlockMax) throw Bad("字面量超过块上限");
                if (type == 0) {
                    if (b.Length - hs < n) throw Bad("原样字面量截断");
                    b.Slice(hs, n).CopyTo(lit); return hs + n;
                }
                if (b.Length - hs < 1) throw Bad("RLE 字面量截断");
                lit.AsSpan(0, n).Fill(b[hs]); return hs + 1;
            }
            int hsz = sf < 2 ? 3 : sf + 2, streams = sf == 0 ? 1 : 4;
            if (b.Length < hsz) throw Bad("字面量头截断");
            int regen, csize;
            if (hsz == 3) { int v = b0 | b[1] << 8 | b[2] << 16; regen = (v >> 4) & 0x3FF; csize = (v >> 14) & 0x3FF; }
            else if (hsz == 4) { uint v = BinaryPrimitives.ReadUInt32LittleEndian(b); regen = (int)((v >> 4) & 0x3FFF); csize = (int)(v >> 18); }
            else { ulong v = BinaryPrimitives.ReadUInt32LittleEndian(b) | (ulong)b[4] << 32; regen = (int)((v >> 4) & 0x3FFFF); csize = (int)((v >> 22) & 0x3FFFF); }
            if (regen > BlockMax) throw Bad("字面量超过块上限");
            if (b.Length - hsz < csize) throw Bad("压缩字面量截断");
            var c = b.Slice(hsz, csize); int t = 0;
            if (type == 2) t = Tree(c);
            else if (hSym == null) throw Bad("字面量要复用上一张 Huffman 表，但本帧还没有");
            c = c[t..];
            if (streams == 1) Stream(c, lit.AsSpan(0, regen));
            else {
                if (c.Length < 6) throw Bad("Huffman 跳转表截断");
                int s1 = c[0] | c[1] << 8, s2 = c[2] | c[3] << 8, s3 = c[4] | c[5] << 8, s4 = c.Length - 6 - s1 - s2 - s3;
                if (s4 < 1) throw Bad("Huffman 四流长度不自洽");
                int seg = (regen + 3) / 4, lastSeg = regen - 3 * seg;
                if (lastSeg < 0) throw Bad("Huffman 四流：字面量太少");
                var d = c[6..];
                Stream(d[..s1], lit.AsSpan(0, seg)); d = d[s1..];
                Stream(d[..s2], lit.AsSpan(seg, seg)); d = d[s2..];
                Stream(d[..s3], lit.AsSpan(2 * seg, seg)); d = d[s3..];
                Stream(d, lit.AsSpan(3 * seg, lastSeg));
            }
            n = regen; return hsz + csize;
        }

        void Stream(ReadOnlySpan<byte> s, Span<byte> outp) {
            var br = new BackBits(s); int mb = hBits;
            for (int i = 0; i < outp.Length; i++) { int v = (int)br.Peek(mb); outp[i] = hSym[v]; br.Pos -= hLen[v]; }
            if (br.Pos != 0) throw Bad("Huffman 流没恰好读完");
        }

        // Huffman 树描述（RFC 8878 §4.2.1），返回字节数
        int Tree(ReadOnlySpan<byte> c) {
            if (c.Length < 1) throw Bad("Huffman 树描述截断");
            int hb = c[0], nw; var w = new byte[256];
            if (hb < 128) {   // 权重用 FSE 压缩：表头是 BIC
                if (c.Length - 1 < hb) throw Bad("Huffman 权重截断");
                var z = c.Slice(1, hb);
                int hn = ReadCounts(z, 255, 6, norm, out int maxSym, out int log);
                var t = Fse.Build(norm, maxSym, log);
                var br = new BackBits(z[hn..]);
                int a = (int)br.Read(log), bb = (int)br.Read(log); nw = 0;
                while (true) {   // 两个状态交替出符号，比特读过头时由另一个状态出最后一个（RFC 8878 §4.2.1.2）
                    if (nw >= 255) throw Bad("Huffman 权重过多");
                    w[nw++] = t.Sym[a]; a = t.Base[a] + (int)br.Read(t.Bits[a]);
                    if (br.Pos < 0) { if (nw >= 255) throw Bad("Huffman 权重过多"); w[nw++] = t.Sym[bb]; break; }
                    if (nw >= 255) throw Bad("Huffman 权重过多");
                    w[nw++] = t.Sym[bb]; bb = t.Base[bb] + (int)br.Read(t.Bits[bb]);
                    if (br.Pos < 0) { if (nw >= 255) throw Bad("Huffman 权重过多"); w[nw++] = t.Sym[a]; break; }
                }
                hb += 1;
            } else {
                nw = hb - 127; int bytes = (nw + 1) / 2;
                if (c.Length - 1 < bytes) throw Bad("Huffman 权重截断");
                for (int i = 0; i < nw; i++) w[i] = (byte)(i % 2 == 0 ? c[1 + i / 2] >> 4 : c[1 + i / 2] & 15);
                hb = 1 + bytes;
            }
            long sum = 0; var rank = new int[13];
            for (int i = 0; i < nw; i++) { if (w[i] > 12) throw Bad("Huffman 权重 > 12"); rank[w[i]]++; if (w[i] > 0) sum += 1L << (w[i] - 1); }
            if (sum == 0) throw Bad("Huffman 权重全 0");
            int maxBits = 64 - System.Numerics.BitOperations.LeadingZeroCount((ulong)sum);   // highbit(sum)+1
            if (maxBits > 12) throw Bad("Huffman 最长码超过 12 位");
            long rest = (1L << maxBits) - sum;
            if ((rest & (rest - 1)) != 0) throw Bad("Huffman 权重和不是 2 的幂的余量");
            int lastW = 64 - System.Numerics.BitOperations.LeadingZeroCount((ulong)rest);
            w[nw] = (byte)lastW; rank[lastW]++; int ns = nw + 1;
            if (rank[1] < 2 || (rank[1] & 1) != 0) throw Bad("Huffman 权重 1 的符号数须为不小于 2 的偶数");
            int size = 1 << maxBits; var sym = new byte[size]; var len = new byte[size]; int pos = 0;
            for (int wt = 1; wt <= maxBits; wt++)
                for (int s = 0; s < ns; s++) if (w[s] == wt) {
                    int span = 1 << (wt - 1);
                    if (pos + span > size) throw Bad("Huffman 表溢出");
                    sym.AsSpan(pos, span).Fill((byte)s); len.AsSpan(pos, span).Fill((byte)(maxBits + 1 - wt)); pos += span;
                }
            if (pos != size) throw Bad("Huffman 表不满");
            hSym = sym; hLen = len; hBits = maxBits;
            return hb;
        }
    }

    // ---------------- XXH64（种子 0；规格 github.com/Cyan4973/xxHash doc/xxhash_spec.md，自写） ----------------
    const ulong P1 = 0x9E3779B185EBCA87, P2 = 0xC2B2AE3D27D4EB4F, P3 = 0x165667B19E3779F9, P4 = 0x85EBCA77C2B2AE63, P5 = 0x27D4EB2F165667C5;
    static ulong Rot(ulong x, int r) => (x << r) | (x >> (64 - r));
    static ulong Round(ulong acc, ulong lane) => Rot(acc + lane * P2, 31) * P1;
    static ulong Merge(ulong h, ulong v) => (h ^ Round(0, v)) * P1 + P4;
    public static ulong XxHash64(ReadOnlySpan<byte> d) {
        int i = 0, n = d.Length; ulong h;
        if (n >= 32) {
            ulong v1 = unchecked(P1 + P2), v2 = P2, v3 = 0, v4 = unchecked(0 - P1);
            for (; i + 32 <= n; i += 32) {
                v1 = Round(v1, BinaryPrimitives.ReadUInt64LittleEndian(d[i..])); v2 = Round(v2, BinaryPrimitives.ReadUInt64LittleEndian(d[(i + 8)..]));
                v3 = Round(v3, BinaryPrimitives.ReadUInt64LittleEndian(d[(i + 16)..])); v4 = Round(v4, BinaryPrimitives.ReadUInt64LittleEndian(d[(i + 24)..]));
            }
            h = Rot(v1, 1) + Rot(v2, 7) + Rot(v3, 12) + Rot(v4, 18);
            h = Merge(h, v1); h = Merge(h, v2); h = Merge(h, v3); h = Merge(h, v4);
        } else h = P5;
        h += (ulong)n;
        for (; i + 8 <= n; i += 8) h = Rot(h ^ Round(0, BinaryPrimitives.ReadUInt64LittleEndian(d[i..])), 27) * P1 + P4;
        if (i + 4 <= n) { h = Rot(h ^ (BinaryPrimitives.ReadUInt32LittleEndian(d[i..]) * P1), 23) * P2 + P3; i += 4; }
        for (; i < n; i++) h = Rot(h ^ (d[i] * P5), 11) * P1;
        h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
        return h;
    }
}
