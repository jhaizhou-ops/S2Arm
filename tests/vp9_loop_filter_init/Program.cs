// VP9 loop filter thresholds on the NVDEC path (Ryujinx.Graphics.Nvdec.Vp9 Decoder.Decode builds a fresh Vp9Common per frame).
// libvpx sets them once per decoder in vp9_loop_filter_init (vp9/common/vp9_loopfilter.c): update_sharpness fills lim / mblim
// for every level, and hev_thr[lvl] = lvl >> 4. The C# port had no such step: HevThr stayed 0 and, at sharpness 0, Lim / Mblim
// too, so the deblocking filter almost never fired (P4G cutscenes: 835 of 838 shown frames differed from libvpx).
// Expected values below are libvpx's formulas, written out independently of the C# code.
using System;
using Ryujinx.Graphics.Nvdec.Vp9;
using Ryujinx.Graphics.Nvdec.Vp9.Types;
using LoopFilter = Ryujinx.Graphics.Nvdec.Vp9.LoopFilter;

static class P
{
    static int fails, checks;

    static void Eq(string what, int want, int got)
    {
        checks++;
        if (want != got)
        {
            if (fails++ < 20) Console.WriteLine($"FAIL {what}: want {want}, got {got}");
        }
    }

    static int Lim(int lvl, int sharp)
    {
        int b = lvl >> ((sharp > 0 ? 1 : 0) + (sharp > 4 ? 1 : 0));
        if (sharp > 0 && b > 9 - sharp) b = 9 - sharp;
        return Math.Max(b, 1);
    }

    static int Main()
    {
        // The state Decoder.Decode starts from before the fix: a fresh Vp9Common and only LoopFilterFrameInit.
        var before = new Vp9Common();
        LoopFilter.LoopFilterFrameInit(ref before, 32);
        Console.WriteLine($"without LoopFilterInit, sharpness 0: lim[32]={before.LfInfo.Lfthr[32].Lim[0]} mblim[32]={before.LfInfo.Lfthr[32].Mblim[0]} hev[32]={before.LfInfo.Lfthr[32].HevThr[0]} (libvpx: {Lim(32, 0)} {2 * 34 + Lim(32, 0)} 2)");

        for (int sharp = 0; sharp <= 7; sharp++)
        {
            var cm = new Vp9Common();
            cm.Lf.SharpnessLevel = sharp;
            cm.Lf.FilterLevel = 32;
            LoopFilter.LoopFilterInit(ref cm);              // as Decoder.Decode now does
            LoopFilter.LoopFilterFrameInit(ref cm, 32);
            for (int lvl = 0; lvl <= LoopFilter.MaxLoopFilter; lvl++)
            {
                ref LoopFilterThresh t = ref cm.LfInfo.Lfthr[lvl];
                for (int i = 0; i < 16; i++)
                {
                    Eq($"sharpness {sharp} level {lvl} lim[{i}]", Lim(lvl, sharp), t.Lim[i]);
                    Eq($"sharpness {sharp} level {lvl} mblim[{i}]", 2 * (lvl + 2) + Lim(lvl, sharp), t.Mblim[i]);
                    Eq($"sharpness {sharp} level {lvl} hev_thr[{i}]", lvl >> 4, t.HevThr[i]);
                }
            }
        }

        Console.WriteLine(fails == 0 ? $"vp9_loop_filter_init: all green ({checks} checks)" : $"vp9_loop_filter_init: {fails} of {checks} red");
        return fails == 0 ? 0 : 1;
    }
}
