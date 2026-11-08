// The VP9 coefficient counts NVDEC writes back (Ryujinx.Graphics.Nvdec.Vp9 Detokenize.DecodeCoefs → Vp9BackwardUpdates.Coef / EobBranch).
// The guest driver adapts the next frame's coefficient probabilities from them; 11-07 they were incremented in defensive copies and stayed 0
// (GRID Autosport's opening movie: every frame after a keyframe failed to decode, all-zero YUV = a green screen).
// Input: an 8x8 keyframe, one tile, 4x4 transforms only (TransformMode 0), all probabilities 0, tile data all zero bytes.
// Expected, from the VP9 decoding process alone: a boolean decoder over all-zero data reads 0 for every bool. The 64x64 / 32x32 / 16x16 levels lie
//   past the 1x1 mode-info frame on both axes, so they split without reading; the 8x8 block reads partition NONE, skip 0, DC modes. Its four luma 4x4
//   blocks and one 4x4 block per chroma plane each start at band 0, context 0 (no neighbour has a nonzero coefficient) and read EOB at once:
//   eob_branch[4x4][Y][intra][0][0] = 4, coef[...][Y][...][0][0][EOB_MODEL_TOKEN] = 4; the same for UV with 2; every other coefficient count 0.
using System;
using Ryujinx.Graphics.Nvdec.Vp9;
using Ryujinx.Graphics.Video;

static class P
{
    static int fails;
    static void Eq(string what, long want, long got) { Console.WriteLine($"{(want == got ? "ok  " : "FAIL")} {what}: want {want}, got {got}"); if (want != got) fails++; }

    static int Main()
    {
        var dec = new Decoder();
        ISurface outp = dec.CreateSurface(8, 8);
        var info = new Vp9PictureInfo { IsKeyFrame = true, TransformMode = 0, LastReference = outp, GoldenReference = outp, AltReference = outp };
        byte[] bits = new byte[64];
        var mvs = new Vp9MvRef[16];
        bool ok = dec.Decode(ref info, outp, bits, ReadOnlySpan<Vp9MvRef>.Empty, mvs);
        Eq("decoded", 1, ok ? 1 : 0);
        ref Vp9BackwardUpdates c = ref info.BackwardUpdateCounts;
        long coefAll = 0, eobAll = 0;
        for (int t = 0; t < 4; t++) for (int p = 0; p < 2; p++) for (int r = 0; r < 2; r++) for (int b = 0; b < 6; b++) for (int x = 0; x < 6; x++)
        { eobAll += c.EobBranch[t][p][r][b][x]; for (int k = 0; k < 4; k++) coefAll += c.Coef[t][p][r][b][x][k]; }
        Eq("eob_branch 4x4 Y intra band0 ctx0", 4, c.EobBranch[0][0][0][0][0]);
        Eq("eob_branch 4x4 UV intra band0 ctx0", 2, c.EobBranch[0][1][0][0][0]);
        Eq("coef 4x4 Y intra band0 ctx0 EOB_MODEL", 4, c.Coef[0][0][0][0][0][3]);
        Eq("coef 4x4 UV intra band0 ctx0 EOB_MODEL", 2, c.Coef[0][1][0][0][0][3]);
        Eq("eob_branch total", 6, eobAll);
        Eq("coef total", 6, coefAll);
        Console.WriteLine(fails == 0 ? "vp9_coef_counts: all green" : $"vp9_coef_counts: {fails} red");
        return fails == 0 ? 0 : 1;
    }
}
