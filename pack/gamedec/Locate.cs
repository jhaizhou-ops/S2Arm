// 在游戏 main 映像里定位自带解码器：规则逐条照 runtime/src/oodle_tool.c（s2a_oodle_locate / s2a_oodle_pick，Octopath 0、宝可梦 Z-A、双人成行、猎天使魔女3 已核），
//   两边改一处要同改一处。LZ5 按导出名 LZ5_decompress_safe（勇者斗恶龙 XI S）。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;

namespace S2Arm.GameDec
{
    sealed class Locate
    {
        public ulong Decompress, DecSome, Msn, Create;
        public int NDecompress = -1, NDecSome = -1, NMsn = -1, NCreate = -1;
        readonly Nso _m;
        Locate(Nso m) { _m = m; }

        uint W(ulong pc) => BinaryPrimitives.ReadUInt32LittleEndian(_m.Image.AsSpan((int)pc));

        ulong EhRead(ref ulong o, int enc, ulong ehs)
        {
            var b = _m.Image.AsSpan(); ulong at = o, v; int fmt = enc & 0xF, app = enc & 0x70;
            if (fmt == 0x3) { v = BinaryPrimitives.ReadUInt32LittleEndian(b[(int)at..]); o += 4; }
            else if (fmt == 0xB) { v = (ulong)(long)BinaryPrimitives.ReadInt32LittleEndian(b[(int)at..]); o += 4; }
            else if (fmt == 0x4) { v = BinaryPrimitives.ReadUInt64LittleEndian(b[(int)at..]); o += 8; }
            else throw new InvalidOperationException($".eh_frame_hdr 编码 {enc:x} 不认识");
            return app == 0x10 ? v + at : app == 0x30 ? v + ehs : v;
        }

        // 含 off 的函数的 [起点, 终点)（终点 = 表里下一个起点，没有则代码段末）
        (ulong, ulong) Span(ulong off)
        {
            ulong ehs = _m.EhFrameHdr, o = ehs + 4; var b = _m.Image;
            int penc = b[ehs + 1], cenc = b[ehs + 2], tenc = b[ehs + 3];
            EhRead(ref o, penc, ehs); ulong n = EhRead(ref o, cenc, ehs), best = 0, next = _m.TextEnd;
            for (ulong i = 0; i < n; i++) { ulong s = EhRead(ref o, tenc, ehs); EhRead(ref o, tenc, ehs); if (s <= off && s > best) best = s; if (s > off && s < next) next = s; }
            return (best, next);
        }
        ulong FuncStart(ulong off) => Span(off).Item1;
        ulong FuncEnd(ulong f) => Span(f).Item2;

        // 只读段里整串（前一字节 NUL）出现的位置；withNul = 连结尾 NUL 一起比（整串），否则只比前缀
        List<ulong> FindStrs(string lit, bool withNul)
        {
            var pat = Encoding.ASCII.GetBytes(lit + (withNul ? "\0" : "")); var r = new List<ulong>();
            var ro = _m.Image.AsSpan((int)_m.RoOff, (int)(_m.DataOff - _m.RoOff));
            for (int at = 0; r.Count < 8;)
            {
                int k = ro[at..].IndexOf(pat); if (k < 0) break;
                int p = at + k; if (p > 0 && ro[p - 1] == 0) r.Add(_m.RoOff + (ulong)p);
                at = p + pat.Length;
            }
            return r;
        }

        // 代码段里用 adrp+add 取 strs 中任一地址的函数起点（去重）
        List<ulong> RefFuncs(List<ulong> strs)
        {
            var fns = new List<ulong>();
            for (ulong pc = 0; pc + 4 <= _m.TextEnd; pc += 4)
            {
                uint w = W(pc);
                if ((w & 0x9F000000) != 0x90000000) continue;
                long imm = (long)(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)); if ((imm & (1 << 20)) != 0) imm -= 1 << 21;
                ulong page = (pc & ~0xFFFul) + (ulong)(imm << 12);
                for (ulong k = 1; k < 8 && pc + 4 * k + 4 <= _m.TextEnd; k++)
                {
                    uint w2 = W(pc + 4 * k);
                    if ((w2 & 0xFF800000) != 0x91000000 || ((w2 >> 5) & 31) != (w & 31)) continue;
                    ulong a = page + ((w2 >> 10) & 0xFFF);
                    if (strs.Contains(a)) { ulong f = FuncStart(pc + 4 * k); if (!fns.Contains(f) && fns.Count < 8) fns.Add(f); }
                    break;
                }
            }
            return fns;
        }

        bool Calls(ulong f, ulong target)
        {
            ulong e = FuncEnd(f);
            for (ulong pc = f; pc + 4 <= e; pc += 4)
            {
                uint w = W(pc);
                if ((w & 0xFC000000) != 0x94000000 && (w & 0xFC000000) != 0x14000000) continue;
                long imm = w & 0x3FFFFFF; if ((imm & (1 << 25)) != 0) imm -= 1 << 26;
                if ((ulong)((long)pc + imm * 4) == target) return true;
            }
            return false;
        }

        // 构造解码器魔数 0xabadf00dc0cac01a（movk xN, #0xf00d, lsl #32 紧接 movk xN, #0xabad, lsl #48）的函数
        List<ulong> MagicFuncs()
        {
            var fns = new List<ulong>();
            for (ulong pc = 4; pc + 4 <= _m.TextEnd; pc += 4)
            {
                uint w = W(pc), w0 = W(pc - 4);
                if ((w & 0xFFE00000) != 0xF2E00000 || ((w >> 5) & 0xFFFF) != 0xabad) continue;
                if ((w0 & 0xFFE00000) != 0xF2C00000 || ((w0 >> 5) & 0xFFFF) != 0xf00d || (w0 & 31) != (w & 31)) continue;
                ulong f = FuncStart(pc); if (!fns.Contains(f) && fns.Count < 8) fns.Add(f);
            }
            return fns;
        }

        List<ulong> DropCallers(List<ulong> fns) => fns.FindAll(f => f != DecSome && !Calls(f, DecSome));

        const string Name = "OodleLZ_Decompress";
        public static Locate Run(Nso m)
        {
            var L = new Locate(m);
            var s = L.FindStrs(Name, true);
            if (s.Count > 0) { var f = L.RefFuncs(s); L.NDecompress = f.Count; if (f.Count == 1) L.Decompress = f[0]; }
            var e1 = L.FindStrs("OODLE ERROR : 1000 calls without progress!\n", true);
            var e2 = L.FindStrs("OODLE ERROR : you didn't give me enough window!\n", true);
            if (e1.Count > 0 && e2.Count > 0)
            {
                var f1 = L.RefFuncs(e1); var f2 = L.RefFuncs(e2); L.NDecSome = 0;
                foreach (var a in f1) foreach (var b in f2) if (a == b) { L.DecSome = a; L.NDecSome++; }
                if (L.NDecSome != 1) L.DecSome = 0;
            }
            if (L.DecSome == 0) return L;   // 没有 DecodeSome 就没法剔内联，后两项不算
            var e3 = L.FindStrs("OODLE ERROR : " + Name + ": asked to decode Legacy", false);
            if (e3.Count > 0) { var f = L.DropCallers(L.RefFuncs(e3)); L.NMsn = f.Count; if (f.Count == 1) L.Msn = f[0]; }
            var c = L.DropCallers(L.MagicFuncs()); L.NCreate = c.Count; if (c.Count == 1) L.Create = c[0];
            return L;
        }

        // 1 = 调公开入口 OodleLZ_Decompress；2 = Decoder 三件套；0 = 认不出（why 说原因）；-1 = 两条规则不一致
        public int Pick(out string why)
        {
            if (Decompress != 0)
            {
                if (DecSome != 0 && !Calls(Decompress, DecSome)) { why = $"规则 1 认出的 {Name}（main+{Decompress:x}）没有调用 DecodeSome（main+{DecSome:x}），两条规则不一致"; return -1; }
                why = DecSome != 0 ? $"规则 1（独立整串 \"{Name}\" 的唯一引用函数），且它调用了规则 2 认出的 DecodeSome" : $"规则 1（独立整串 \"{Name}\" 的唯一引用函数）";
                return 1;
            }
            if (DecSome != 0 && Msn != 0 && Create != 0) { why = "规则 2（这款没有公开入口 OodleLZ_Decompress：自己调 Decoder 三件套 MemorySizeNeeded → Create → DecodeSome）"; return 2; }
            if (NDecompress == -1 && NDecSome == -1) { why = $"main 的只读段里既没有 \"{Name}\" 整串、也没有 Oodle 自己的错误消息——这款没把 Oodle 链进 main"; return 0; }
            why = $"候选数：{Name} {NDecompress}、DecodeSome {NDecSome}、MemorySizeNeeded {NMsn}、Create {NCreate}（各要恰好 1；-1 = 没有特征串）";
            return 0;
        }
    }
}
