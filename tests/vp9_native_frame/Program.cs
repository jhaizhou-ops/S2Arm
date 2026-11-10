// Native VP9 frame building, C# (Ryujinx.Graphics.Nvdec Vp9NativeFrame.cs: Vp9NativeHeader + Vp9SlotMap, what the game runs)
// against C (android/codecs/vpxbench/hdr.c, which the phone benchmark and the libvpx hook were validated with): the same random
// NVDEC job sequences, with the native-active / fallback rules of Vp9NativePath, must give the same fallback decisions, the same
// refreshed slot and byte-identical frames (uncompressed header + stand-in byte + tile data).
// Usage: Vp9NativeFrameCheck <hdrcheck binary> <work dir>
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using Ryujinx.Graphics.Nvdec;

static class P
{
    const int Sequences = 40, JobsPerSequence = 400;

    static int Main(string[] a)
    {
        string tool = a[0], dir = a[1];
        int fails = 0, compared = 0, native = 0, fallback = 0, waiting = 0, keys = 0, intra = 0, inPlace = 0;
        for (int seq = 0; seq < Sequences; seq++)
        {
            var rnd = new Random(1000 + seq);
            bool Rare() => rnd.Next(500) == 0;   // one injected invalid field in about 500 draws
            var input = new MemoryStream();
            var expected = new List<(byte status, int target, byte[] frame)>();
            var slots = new Vp9SlotMap();
            bool active = false;
            (int w, int h)[] sizes = [(1920, 1080), (1280, 720), (350, 198), (64, 64), (960, 544)];
            var size = sizes[rnd.Next(sizes.Length)];
            uint[] pool = [0x1000, 0x2400, 0x3800, 0x4c00, 0x6000, 0x7400, 0x8800, 0x9c00];   // 8 surfaces, as many as slots
            var recent = new List<(uint luma, int w, int h)>();
            for (int j = 0; j < JobsPerSequence; j++)
            {
                byte[] pic = new byte[256], sf = new byte[32];
                bool key = j == 0 || rnd.Next(40) == 0, intraOnly = !key && rnd.Next(60) == 0;
                if (rnd.Next(60) == 0) size = sizes[rnd.Next(sizes.Length)];
                keys += key ? 1 : 0;
                intra += intraOnly ? 1 : 0;
                uint flags = (key ? 1u : 0) | (intraOnly ? 32u : 0) | (rnd.Next(2) == 0 ? 16u : 0);
                BitConverter.TryWriteBytes(pic.AsSpan(104), flags);
                // references: offsets recently written, with the size they were written at (sometimes a stale size or an unknown offset)
                for (int r = 0; r < 3; r++)
                {
                    var (luma, w, h) = recent.Count > 0 ? recent[rnd.Next(Math.Min(recent.Count, 6))] : (pool[0], size.w, size.h);
                    if (Rare()) luma = 0xf000;
                    BitConverter.TryWriteBytes(pic.AsSpan(72 + 8 * r), (ushort)w);
                    BitConverter.TryWriteBytes(pic.AsSpan(74 + 8 * r), (ushort)h);
                    BitConverter.TryWriteBytes(sf.AsSpan(8 * r), luma);
                    BitConverter.TryWriteBytes(sf.AsSpan(8 * r + 4), luma + 0x800);
                }
                // output: a surface no reference uses (decoding in place only as a rare injected case)
                uint outLuma;
                do outLuma = pool[rnd.Next(pool.Length)];
                while (outLuma == BitConverter.ToUInt32(sf, 0) || outLuma == BitConverter.ToUInt32(sf, 8) || outLuma == BitConverter.ToUInt32(sf, 16));
                if (Rare()) { outLuma = BitConverter.ToUInt32(sf, 0); inPlace++; }
                BitConverter.TryWriteBytes(pic.AsSpan(72 + 24), (ushort)size.w);
                BitConverter.TryWriteBytes(pic.AsSpan(74 + 24), (ushort)size.h);
                BitConverter.TryWriteBytes(sf.AsSpan(24), outLuma);
                BitConverter.TryWriteBytes(sf.AsSpan(28), outLuma + 0x800);
                for (int i = 1; i < 4; i++) pic[108 + i] = (byte)(Rare() ? 2 : rnd.Next(2));
                pic[112] = (byte)(Rare() ? 64 + rnd.Next(5) : rnd.Next(64));
                pic[113] = (byte)(Rare() ? 8 : rnd.Next(8));
                pic[114] = (byte)(rnd.Next(10) == 0 ? 0 : rnd.Next(256));
                for (int i = 115; i <= 117; i++) pic[i] = (byte)(rnd.Next(3) != 0 ? 0 : Rare() ? 16 + rnd.Next(240) : rnd.Next(16));
                bool lossless = pic[114] == 0 && pic[115] == 0 && pic[116] == 0 && pic[117] == 0;
                pic[118] = (byte)(Rare() ? (lossless ? 0 : 1) : (lossless ? 1 : 0));
                pic[119] = (byte)(Rare() ? 5 : rnd.Next(5));
                pic[120] = (byte)rnd.Next(2);
                pic[121] = (byte)(Rare() ? 5 : rnd.Next(5));
                pic[122] = (byte)(Rare() ? 3 : rnd.Next(3));
                Vp9NativeHeader.TileRange(size.w, out int minCols, out int maxCols);
                pic[126] = (byte)(Rare() ? maxCols + 1 : minCols + rnd.Next(maxCols - minCols + 1));
                pic[127] = (byte)(Rare() ? 3 : rnd.Next(3));
                pic[128] = (byte)(Rare() ? 1 : 0);
                pic[228] = (byte)rnd.Next(2);
                for (int i = 229; i <= 234; i++) pic[i] = (byte)(sbyte)(Rare() ? 70 : rnd.Next(-63, 64));
                BitConverter.TryWriteBytes(pic.AsSpan(240), (uint)((Rare() ? 10 : rnd.Next(2) * 8) << 1));
                byte[] tiles = new byte[rnd.Next(1, 64)];
                rnd.NextBytes(tiles);

                input.Write(pic);
                input.Write(sf);
                input.Write(BitConverter.GetBytes((uint)tiles.Length));
                input.Write(tiles);

                // C#: the rules of Vp9NativePath.TryDecode, with every decode succeeding
                var p = Input(pic, sf);
                if (!active && !p.KeyFrame)
                {
                    expected.Add((2, 0, null));
                    waiting++;
                    continue;
                }
                if (!active)
                {
                    active = true;
                    slots.Reset();
                }
                Span<int> refIdx = stackalloc int[3];
                int target = -1;
                string reason = Vp9NativeHeader.Check(p) ?? slots.Resolve(p, refIdx, out target);
                if (reason != null)
                {
                    expected.Add((1, 0, null));
                    recent.Clear();
                    active = false;
                    slots.Reset();
                    fallback++;
                    continue;
                }
                byte[] frame = new byte[tiles.Length + Vp9NativeHeader.MaxHeaderBytes];
                int len = Vp9NativeHeader.Write(p, refIdx, target, tiles, frame);
                slots.Commit(p, p.KeyFrame ? -1 : target);
                expected.Add((0, p.KeyFrame ? -1 : target, frame[..len]));
                if (p.KeyFrame) recent.Clear();   // a key frame refreshes every slot
                recent.RemoveAll(x => x.luma == outLuma);
                recent.Insert(0, (outLuma, size.w, size.h));
                native++;
            }

            string inPath = Path.Combine(dir, $"seq{seq}.in"), outPath = Path.Combine(dir, $"seq{seq}.out");
            File.WriteAllBytes(inPath, input.ToArray());
            using (var c = Process.Start(tool, [inPath, outPath])!)
            {
                c.WaitForExit();
                if (c.ExitCode != 0) { Console.WriteLine($"FAIL hdrcheck exit {c.ExitCode}"); return 1; }
            }
            var got = new BinaryReader(File.OpenRead(outPath));
            for (int j = 0; j < expected.Count; j++)
            {
                compared++;
                var (status, target, frame) = expected[j];
                byte s = got.ReadByte();
                string what = $"sequence {seq} job {j}";
                if (s != status) { if (fails++ < 20) Console.WriteLine($"FAIL {what}: status C# {status}, C {s}"); if (s == 0) { got.ReadInt32(); got.ReadBytes(got.ReadInt32()); } continue; }
                if (status != 0) continue;
                int t = got.ReadInt32();
                byte[] f = got.ReadBytes(got.ReadInt32());
                if (t != target || !f.AsSpan().SequenceEqual(frame))
                {
                    if (fails++ < 20) Console.WriteLine($"FAIL {what}: target C# {target} C {t}; frame {(f.AsSpan().SequenceEqual(frame) ? "same" : $"differs (C# {frame.Length} B, C {f.Length} B)")}");
                }
            }
        }
        Console.WriteLine($"jobs {compared}: native {native}, fallback {fallback}, waiting for key {waiting} (key frames {keys}, intra-only {intra}, in-place {inPlace})");
        Console.WriteLine(fails == 0 ? "vp9_native_frame: all green" : $"vp9_native_frame: {fails} red");
        return fails == 0 && native > 0 && fallback > 0 ? 0 : 1;
    }

    // PictureInfo bytes -> Vp9NativeInput, field for field as Vp9NativePath.Input reads the PictureInfo struct.
    static Vp9NativeInput Input(byte[] b, byte[] sf)
    {
        int W(int i) => BitConverter.ToUInt16(b, 72 + 8 * i);
        int H(int i) => BitConverter.ToUInt16(b, 74 + 8 * i);
        uint L(int i) => BitConverter.ToUInt32(sf, 8 * i);
        uint C(int i) => BitConverter.ToUInt32(sf, 8 * i + 4);
        uint flags = BitConverter.ToUInt32(b, 104);
        return new Vp9NativeInput
        {
            LastWidth = W(0), LastHeight = H(0), GoldenWidth = W(1), GoldenHeight = H(1), AltWidth = W(2), AltHeight = H(2), Width = W(3), Height = H(3),
            KeyFrame = (flags & 1) != 0, IntraOnly = (flags & 32) != 0,
            SignBias1 = (sbyte)b[109], SignBias2 = (sbyte)b[110], SignBias3 = (sbyte)b[111],
            FilterLevel = b[112], Sharpness = b[113], BaseQIndex = b[114], YDcDeltaQ = b[115], UvAcDeltaQ = b[116], UvDcDeltaQ = b[117],
            Lossless = b[118] != 0, TxMode = b[119], AllowHighPrecisionMv = b[120] != 0, InterpFilter = b[121], ReferenceMode = b[122],
            Log2TileCols = b[126], Log2TileRows = b[127], SegmentationEnabled = b[128] != 0, ModeRefDeltaEnabled = b[228] != 0,
            RefDelta0 = (sbyte)b[229], RefDelta1 = (sbyte)b[230], RefDelta2 = (sbyte)b[231], RefDelta3 = (sbyte)b[232],
            ModeDelta0 = (sbyte)b[233], ModeDelta1 = (sbyte)b[234],
            BitDepth = (int)((BitConverter.ToUInt32(b, 240) >> 1) & 0xf),
            LastLuma = L(0), LastChroma = C(0), GoldenLuma = L(1), GoldenChroma = C(1), AltLuma = L(2), AltChroma = C(2), OutLuma = L(3), OutChroma = C(3),
        };
    }
}
