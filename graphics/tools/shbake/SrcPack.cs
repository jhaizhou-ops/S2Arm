// S2Arm 抽取的着色器字节：<抽取目录>/src/*.pk，每个抽取进程一份追加写的大文件（graphics/tools/shbake/srcpack.py 头注，格式与它同一份）。
//   记录 = u16 键长 | 键（ASCII）| u32 控制段长 | u32 机器码长 | 控制段 | 机器码（小端）；同键多条取第一条；写到一半的尾巴不认。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace S2A.ShBake
{
    public static class SrcPack
    {
        /// <summary>读全部：键 → (机器码, 控制段)。按文件名排序逐个顺序读，同键取第一条</summary>
        public static Dictionary<string, (byte[] Code, byte[] Ctl)> ReadAll(string xdir)
        {
            var o = new Dictionary<string, (byte[], byte[])>(StringComparer.Ordinal);
            string dir = Path.Combine(xdir, "src");
            if (!Directory.Exists(dir)) return o;
            foreach (string p in Directory.EnumerateFiles(dir, "*.pk").OrderBy(x => x, StringComparer.Ordinal))
            {
                byte[] d = File.ReadAllBytes(p); int i = 0;
                while (i + 2 <= d.Length)
                {
                    int kl = BinaryPrimitives.ReadUInt16LittleEndian(d.AsSpan(i)); int h = i + 2 + kl + 8;
                    if (h > d.Length) break;
                    string key = Encoding.ASCII.GetString(d, i + 2, kl);
                    int cl = (int)BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(i + 2 + kl)), dl = (int)BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(i + 6 + kl));
                    if ((long)h + cl + dl > d.Length) break;
                    o.TryAdd(key, (d[(h + cl)..(h + cl + dl)], d[h..(h + cl)]));
                    i = h + cl + dl;
                }
            }
            return o;
        }

        /// <summary>追加写一条（自测造夹具用；生产写端是 srcpack.py）</summary>
        public static void Append(string xdir, string key, byte[] code, byte[] ctl)
        {
            string dir = Path.Combine(xdir, "src"); Directory.CreateDirectory(dir);
            using var f = new FileStream(Path.Combine(dir, "selftest.pk"), FileMode.Append, FileAccess.Write);
            byte[] kb = Encoding.ASCII.GetBytes(key); Span<byte> b = stackalloc byte[4];
            BinaryPrimitives.WriteUInt16LittleEndian(b, (ushort)kb.Length); f.Write(b[..2]); f.Write(kb);
            BinaryPrimitives.WriteUInt32LittleEndian(b, (uint)ctl.Length); f.Write(b);
            BinaryPrimitives.WriteUInt32LittleEndian(b, (uint)code.Length); f.Write(b);
            f.Write(ctl); f.Write(code);
        }
    }
}
