// Native VP9 vs the managed decoder on real NVDEC jobs captured on a device (S2A_NVDEC_VP9_CAPTURE records, layout in
// docs/设计_原生VP9/phase1_results.md). Each job goes through (a) the native path pieces exactly as Vp9NativePath uses them
// (Vp9NativeHeader, Vp9SlotMap, VpxVp9Backend over the patched libvpx) and (b) the managed decoder; Y/U/V of the visible
// picture, the MV write buffer and the counts must be byte-identical on every job.
// Usage: Vp9NativeParity <capture dir> <libs2a_vpx.dylib>
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Nvdec;
using Ryujinx.Graphics.Nvdec.Vpx;
using Ryujinx.Graphics.Video;

static unsafe class P
{
    static ulong Fnv(ulong h, ReadOnlySpan<byte> s) { foreach (byte b in s) h = (h ^ b) * 0x100000001b3UL; return h; }
    static ulong Plane(nint p, int stride, int w, int h) { ulong x = 0xcbf29ce484222325UL; for (int y = 0; y < h; y++) x = Fnv(x, new ReadOnlySpan<byte>((byte*)p + (long)y * stride, w)); return x; }

    static int Main(string[] a)
    {
        string cap = a[0], dylib = a[1];
        NativeLibrary.SetDllImportResolver(typeof(VpxVp9Backend).Assembly, (name, asm, path) => name == "s2a_vpx" ? NativeLibrary.Load(dylib) : 0);
        var backend = new VpxVp9Backend();
        var slots = new Vp9SlotMap();
        var managed = new Ryujinx.Graphics.Nvdec.Vp9.Decoder();
        var surfaces = new Dictionary<uint, ISurface>();
        byte[] frame = new byte[16 << 20];
        byte[] nMvA = [], nMvB = [], counts = new byte[VpxVp9Backend.CountsSize];
        Vp9MvRef[] mPrev = [], mCur = [];
        bool active = false;
        int jobs = 0, native = 0, picOk = 0, mvOk = 0, cntOk = 0, firstBad = -1;
        var reasons = new Dictionary<string, int>();
        for (int j = 0; ; j++)
        {
            string path = Path.Combine(cap, $"frame_{j:D6}.bin");
            if (!File.Exists(path)) break;
            jobs++;
            byte[] r = File.ReadAllBytes(path);
            int nPic = BitConverter.ToInt32(r, 12), nEnt = BitConverter.ToInt32(r, 16), nReg = BitConverter.ToInt32(r, 20), nTile = BitConverter.ToInt32(r, 24);
            byte[] pic = r.AsSpan(32, nPic).ToArray(), reg = r.AsSpan(32 + nPic + nEnt, nReg).ToArray(), tiles = r.AsSpan(32 + nPic + nEnt + nReg, nTile).ToArray();
            var guestProbs = MemoryMarshal.Read<Ryujinx.Graphics.Nvdec.Types.Vp9.EntropyProbs>(r.AsSpan(32 + nPic, nEnt));
            Vp9EntropyProbs fc = default;
            guestProbs.Convert(ref fc);
            byte[] probs = MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref fc, 1)).ToArray();
            uint flags = BitConverter.ToUInt32(pic, 104);
            int W(int i) => BitConverter.ToUInt16(pic, 72 + 8 * i);
            int H(int i) => BitConverter.ToUInt16(pic, 74 + 8 * i);
            uint L(int i) => BitConverter.ToUInt32(reg, 8 * i);
            uint C(int i) => BitConverter.ToUInt32(reg, 8 * i + 4);
            bool usePrev = (flags & 1) == 0 && (flags & 8) == 0 && (flags & 4) == 0 && (flags & 32) == 0 && (flags & 16) != 0 && (flags & 2) == 0;
            int mi = ((W(3) + 7) >> 3) * ((H(3) + 7) >> 3);

            // ---- managed ----
            ISurface Get(int i) { uint off = L(i); if (!surfaces.TryGetValue(off, out var s) || s.Width != W(i) || s.Height != H(i)) surfaces[off] = s = managed.CreateSurface(W(i), H(i)); return s; }
            var info = new Vp9PictureInfo
            {
                LastReference = Get(0), GoldenReference = Get(1), AltReference = Get(2),
                IsKeyFrame = (flags & 1) != 0, IntraOnly = (flags & 32) != 0, UsePrevInFindMvRefs = usePrev,
                LoopFilterLevel = pic[112], LoopFilterSharpnessLevel = pic[113], BaseQIndex = pic[114],
                YDcDeltaQ = pic[115], UvAcDeltaQ = pic[116], UvDcDeltaQ = pic[117], Lossless = pic[118] != 0,
                TransformMode = pic[119], AllowHighPrecisionMv = pic[120] != 0, InterpFilter = pic[121], ReferenceMode = pic[122],
                CompFixedRef = (sbyte)pic[123], Log2TileCols = pic[126], Log2TileRows = pic[127], SegmentEnabled = pic[128] != 0, ModeRefDeltaEnabled = pic[228] != 0,
            };
            for (int i = 0; i < 4; i++) { info.RefFrameSignBias[i] = (sbyte)pic[108 + i]; info.RefDeltas[i] = (sbyte)pic[229 + i]; }
            for (int i = 0; i < 2; i++) { info.ModeDeltas[i] = (sbyte)pic[233 + i]; info.CompVarRef[i] = (sbyte)pic[124 + i]; }
            info.Entropy = MemoryMarshal.Read<Vp9EntropyProbs>(probs);
            if (mCur.Length != mi) { mCur = new Vp9MvRef[mi]; mPrev = new Vp9MvRef[mi]; }
            ISurface outp = Get(3);
            managed.Decode(ref info, outp, tiles, usePrev ? mPrev : ReadOnlySpan<Vp9MvRef>.Empty, mCur);
            (ulong, ulong, ulong) mPic = (Plane(outp.YPlane.Pointer, outp.Stride, outp.Width, outp.Height), Plane(outp.UPlane.Pointer, outp.UvStride, outp.UvWidth, outp.UvHeight), Plane(outp.VPlane.Pointer, outp.UvStride, outp.UvWidth, outp.UvHeight));
            ulong mMv = Fnv(0xcbf29ce484222325UL, MemoryMarshal.AsBytes(mCur.AsSpan()));
            ulong mCnt = Fnv(0xcbf29ce484222325UL, MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref info.BackwardUpdateCounts, 1)));
            (mPrev, mCur) = (mCur, mPrev);

            // ---- native, as Vp9NativePath does it ----
            var input = new Vp9NativeInput
            {
                LastWidth = W(0), LastHeight = H(0), GoldenWidth = W(1), GoldenHeight = H(1), AltWidth = W(2), AltHeight = H(2), Width = W(3), Height = H(3),
                KeyFrame = (flags & 1) != 0, IntraOnly = (flags & 32) != 0,
                SignBias1 = (sbyte)pic[109], SignBias2 = (sbyte)pic[110], SignBias3 = (sbyte)pic[111],
                FilterLevel = pic[112], Sharpness = pic[113], BaseQIndex = pic[114], YDcDeltaQ = pic[115], UvAcDeltaQ = pic[116], UvDcDeltaQ = pic[117],
                Lossless = pic[118] != 0, TxMode = pic[119], AllowHighPrecisionMv = pic[120] != 0, InterpFilter = pic[121], ReferenceMode = pic[122],
                Log2TileCols = pic[126], Log2TileRows = pic[127], SegmentationEnabled = pic[128] != 0, ModeRefDeltaEnabled = pic[228] != 0,
                RefDelta0 = (sbyte)pic[229], RefDelta1 = (sbyte)pic[230], RefDelta2 = (sbyte)pic[231], RefDelta3 = (sbyte)pic[232], ModeDelta0 = (sbyte)pic[233], ModeDelta1 = (sbyte)pic[234],
                BitDepth = (int)((BitConverter.ToUInt32(pic, 240) >> 1) & 0xf),
                LastLuma = L(0), LastChroma = C(0), GoldenLuma = L(1), GoldenChroma = C(1), AltLuma = L(2), AltChroma = C(2), OutLuma = L(3), OutChroma = C(3),
            };
            if (!active && input.KeyFrame) { active = true; slots.Reset(); }
            string reason = null;
            if (!active) reason = "waiting for key frame";
            Span<int> refIdx = stackalloc int[3];
            int target = -1;
            reason ??= Vp9NativeHeader.Check(input) ?? slots.Resolve(input, refIdx, out target);
            if (nMvA.Length != mi * 16) { nMvA = new byte[mi * 16]; nMvB = new byte[mi * 16]; }
            if (reason == null)
            {
                int len = Vp9NativeHeader.Write(input, refIdx, target, tiles, frame);
                var p = new Vp9NativeParams { IntraFrame = input.KeyFrame || input.IntraOnly ? 1 : 0, TxMode = input.TxMode, ReferenceMode = input.ReferenceMode, CompFixedRef = (sbyte)pic[123], CompVarRef0 = (sbyte)pic[124], CompVarRef1 = (sbyte)pic[125], UsePrevFrameMvs = usePrev ? 1 : 0 };
                var res = backend.Decode(frame.AsSpan(0, len), probs, p, usePrev ? nMvA : ReadOnlySpan<byte>.Empty, nMvB, counts, out var np, out string err);
                if (res == Vp9NativeResult.Decoded)
                {
                    native++;
                    slots.Commit(input, input.KeyFrame ? -1 : target);
                    int uw = (np.Width + 1) >> 1, uh = (np.Height + 1) >> 1;
                    bool sp = mPic == (Plane(np.Y, np.YStride, np.Width, np.Height), Plane(np.U, np.UvStride, uw, uh), Plane(np.V, np.UvStride, uw, uh));
                    bool sm = mMv == Fnv(0xcbf29ce484222325UL, nMvB);
                    bool sc = mCnt == Fnv(0xcbf29ce484222325UL, counts);
                    picOk += sp ? 1 : 0; mvOk += sm ? 1 : 0; cntOk += sc ? 1 : 0;
                    if (!(sp && sm && sc) && firstBad < 0) firstBad = j;
                    (nMvA, nMvB) = (nMvB, nMvA);
                }
                else reason = $"{res} {err}";
            }
            if (reason != null) { active = false; slots.Reset(); reasons[reason] = reasons.GetValueOrDefault(reason) + 1; }
        }
        Console.WriteLine($"jobs={jobs} native={native} picture={picOk} mvs={mvOk} counts={cntOk} first_mismatch={firstBad}");
        foreach (var kv in reasons) Console.WriteLine($"fallback {kv.Value}: {kv.Key}");
        return jobs == native && picOk == native && mvOk == native && cntOk == native ? 0 : 1;
    }
}
