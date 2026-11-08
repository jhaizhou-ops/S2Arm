// NSO 装载（游戏 main 模块）：解 LZ4 段 → 一块连续映像（代码 / 只读 / 数据 + bss），读 MOD0 → 动态段 → 符号表与重定位。
// 只做跑游戏解码函数要的那部分：RELATIVE / GLOB_DAT / JUMP_SLOT / ABS64 四种重定位 + RELR 压缩相对重定位（展开成 RELATIVE，加数取槽里原值），导出符号按名字查，未定义的导入交给调用方给桩地址。
// 格式与 Python 侧 translator/uepak.py nso_image、原生层 runtime/src/loader.c 同一份公开布局（NSO0 头 0x100 字节、MOD0、Elf64_Dyn / Rela / Sym）。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace S2Arm.GameDec
{
    sealed class Nso
    {
        public byte[] Image = Array.Empty<byte>();
        public ulong TextEnd, RoOff, DataOff, Mod0, EhFrameHdr;
        public readonly Dictionary<string, ulong> Exports = new(StringComparer.Ordinal);
        public readonly List<(ulong Off, uint Type, string Sym, bool Defined, ulong Value, long Addend)> Relocs = new();

        const uint DT_NULL = 0, DT_PLTRELSZ = 2, DT_HASH = 4, DT_STRTAB = 5, DT_SYMTAB = 6, DT_RELA = 7, DT_RELASZ = 8, DT_STRSZ = 10, DT_SYMENT = 11, DT_JMPREL = 23, DT_RELRSZ = 35, DT_RELR = 36, DT_RELRENT = 37;
        public const uint R_ABS64 = 257, R_GLOB_DAT = 1025, R_JUMP_SLOT = 1026, R_RELATIVE = 1027;

        static uint U32(ReadOnlySpan<byte> b, ulong o) => BinaryPrimitives.ReadUInt32LittleEndian(b[(int)o..]);
        static int I32(ReadOnlySpan<byte> b, ulong o) => BinaryPrimitives.ReadInt32LittleEndian(b[(int)o..]);
        static ulong U64(ReadOnlySpan<byte> b, ulong o) => BinaryPrimitives.ReadUInt64LittleEndian(b[(int)o..]);

        public static Nso Load(string path)
        {
            byte[] d = File.ReadAllBytes(path);
            if (d.Length < 0x100 || Encoding.ASCII.GetString(d, 0, 4) != "NSO0") throw new InvalidDataException($"{path} 不是 NSO（魔数不是 NSO0）");
            uint flags = U32(d, 0xc);
            var seg = new (uint File, uint Mem, uint Size)[3];
            for (int i = 0; i < 3; i++) seg[i] = (U32(d, (ulong)(0x10 + i * 0x10)), U32(d, (ulong)(0x14 + i * 0x10)), U32(d, (ulong)(0x18 + i * 0x10)));
            uint bss = U32(d, 0x3c);
            ulong end = seg[2].Mem + (ulong)seg[2].Size + bss;
            var n = new Nso { Image = new byte[(end + 0xfff) & ~0xffful], TextEnd = seg[0].Mem + seg[0].Size, RoOff = seg[1].Mem, DataOff = seg[2].Mem };
            for (int i = 0; i < 3; i++)
            {
                uint csz = U32(d, (ulong)(0x60 + i * 4));
                var src = new ReadOnlySpan<byte>(d, (int)seg[i].File, (int)((flags >> i & 1) != 0 ? csz : seg[i].Size));
                var dst = new Span<byte>(n.Image, (int)seg[i].Mem, (int)seg[i].Size);
                if ((flags >> i & 1) != 0) Lz4Block(src, dst); else src.CopyTo(dst);
            }
            n.ParseDynamic();
            return n;
        }

        // LZ4 块格式解压（NSO 段的压缩方式）；长度必须正好对上
        static void Lz4Block(ReadOnlySpan<byte> s, Span<byte> d)
        {
            int si = 0, di = 0;
            while (si < s.Length)
            {
                int tok = s[si++], lit = tok >> 4;
                if (lit == 15) { int b; do { b = s[si++]; lit += b; } while (b == 255); }
                s.Slice(si, lit).CopyTo(d[di..]); si += lit; di += lit;
                if (si >= s.Length) break;
                int off = s[si] | s[si + 1] << 8; si += 2;
                int ml = tok & 15;
                if (ml == 15) { int b; do { b = s[si++]; ml += b; } while (b == 255); }
                ml += 4;
                if (off == 0 || off > di) throw new InvalidDataException("NSO 段 LZ4 数据损坏（回指越界）");
                for (int k = 0; k < ml; k++) d[di + k] = d[di - off + k];
                di += ml;
            }
            if (di != d.Length) throw new InvalidDataException($"NSO 段 LZ4 解出 {di} 字节，头里写的是 {d.Length}");
        }

        void ParseDynamic()
        {
            var b = (ReadOnlySpan<byte>)Image;
            Mod0 = U32(b, 4);
            if (Encoding.ASCII.GetString(Image, (int)Mod0, 4) != "MOD0") throw new InvalidDataException("main 没有 MOD0");
            ulong dyn = (ulong)((long)Mod0 + I32(b, Mod0 + 4));
            EhFrameHdr = (ulong)((long)Mod0 + I32(b, Mod0 + 16));
            ulong rela = 0, relasz = 0, jmprel = 0, pltsz = 0, symtab = 0, strtab = 0, syment = 24, hash = 0, relr = 0, relrsz = 0, relrent = 8;
            for (ulong o = dyn; ; o += 16)
            {
                ulong tag = U64(b, o), val = U64(b, o + 8);
                if (tag == DT_NULL) break;
                switch (tag)
                {
                    case DT_RELA: rela = val; break; case DT_RELASZ: relasz = val; break; case DT_JMPREL: jmprel = val; break; case DT_PLTRELSZ: pltsz = val; break;
                    case DT_SYMTAB: symtab = val; break; case DT_STRTAB: strtab = val; break; case DT_SYMENT: syment = val; break; case DT_HASH: hash = val; break;
                    case DT_RELR: relr = val; break; case DT_RELRSZ: relrsz = val; break; case DT_RELRENT: relrent = val; break;
                }
            }
            ulong nsym = hash != 0 ? U32(b, hash + 4) : strtab > symtab ? (strtab - symtab) / syment : 0;
            string Name(uint off) { int s = (int)(strtab + off), e = s; while (Image[e] != 0) e++; return Encoding.UTF8.GetString(Image, s, e - s); }
            var syms = new (string Name, ushort Shndx, ulong Value)[nsym];
            for (ulong i = 0; i < nsym; i++)
            {
                ulong o = symtab + i * syment;
                syms[i] = (Name(U32(b, o)), BinaryPrimitives.ReadUInt16LittleEndian(b[(int)(o + 6)..]), U64(b, o + 8));
                if (syms[i].Shndx != 0 && syms[i].Value != 0 && syms[i].Name.Length > 0) Exports[syms[i].Name] = syms[i].Value;
            }
            foreach (var (start, size) in new[] { (rela, relasz), (jmprel, pltsz) })
                for (ulong o = start; o < start + size; o += 24)
                {
                    ulong off = U64(b, o), info = U64(b, o + 8); long add = (long)U64(b, o + 16);
                    uint type = (uint)info, si = (uint)(info >> 32);
                    if (type == R_RELATIVE) { Relocs.Add((off, type, "", true, 0, add)); continue; }
                    if (type != R_GLOB_DAT && type != R_JUMP_SLOT && type != R_ABS64) throw new InvalidDataException($"main 有不认识的重定位类型 {type}（偏移 {off:x}）");
                    var s = syms[si];
                    Relocs.Add((off, type, s.Name, s.Shndx != 0, s.Value, add));
                }
            // DT_RELR（11-05 普查 c1105_r4 轩辕剑柒 main 用它，原先整款抛异常、天眼出包 rc=1）：同原生层 runtime/src/loader.c 与公开 ELF 规范——
            //   偶数字 = 槽偏移（改它，游标移到下一字）；奇数字 = 位图，第 b 位（b = 1..63）= 游标后第 b−1 字也是槽，处理完游标前移 63 字。槽 += 装载基址，即加数取槽里原值的 RELATIVE
            if (relr != 0 && relrent != 8) throw new InvalidDataException($"main 的 DT_RELRENT 是 {relrent}，不是 8");
            ulong where = 0; bool have = false;
            for (ulong o = relr; o < relr + relrsz; o += 8)
            {
                ulong e = U64(b, o);
                if ((e & 1) == 0) { Relocs.Add((e, R_RELATIVE, "", true, 0, (long)U64(b, e))); where = e + 8; have = true; continue; }
                if (!have) throw new InvalidDataException($"main 的 DT_RELR 位图项前没有起点（表内偏移 {o - relr:x}）");
                for (int k = 1; k < 64; k++) if ((e >> k & 1) != 0) { ulong at = where + (ulong)(k - 1) * 8; Relocs.Add((at, R_RELATIVE, "", true, 0, (long)U64(b, at))); }
                where += 63 * 8;
            }
        }
    }
}
