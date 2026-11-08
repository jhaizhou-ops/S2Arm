// 遍统计（诊断，NXGAL_PSTAT=1，缺省关）的 C# 入口：GPFIFO 命令段交给渲染器原生侧统计（graphics/metal/gal_pstat.m）。渲染遍那一半全在原生侧，不经这里
using System;
using System.Runtime.InteropServices;

namespace NxGal
{
    public static unsafe class NxPassStat
    {
        public static readonly bool On = Environment.GetEnvironmentVariable("NXGAL_PSTAT") == "1";
        [DllImport(N.Lib)] static extern void nxgal_pstat_seg(ulong* ranges, int n, ulong total);

        // ranges：n 对（CPU 地址, 长度）；n < 0 = 段没法统计（只计字节）。任意线程可调
        public static void Segment(ulong* ranges, int n, ulong total) => nxgal_pstat_seg(ranges, n, total);
    }
}
