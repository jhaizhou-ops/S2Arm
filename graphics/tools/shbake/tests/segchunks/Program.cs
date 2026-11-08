// 免解读缓存分块存储（Ryujinx.Graphics.Gpu.Engine.GPFifo.S2AOpChunks，块在原生内存）单测。操作 20 字节（同 GPFifoProcessor.S2AOp），一块 65536 条 = 1310720 B。
// 期望全按条数手算：托管分配用本线程 GC.GetAllocatedBytesForCurrentThread 量（放满应为 0），原生字节由 NativeBytes 报（= 块数 × 1310720）。
using System;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;

struct Op { public byte Kind; public bool IsLast; public int Index, Method, Sub, Count; }

static class P
{
    static int n, bad;
    static void Expect(string what, long want, long got) { n++; bool ok = want == got; if (!ok) bad++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {want} → 真结果 {got}"); }
    static void Within(string what, long lo, long hi, long got) { n++; bool ok = got >= lo && got <= hi; if (!ok) bad++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {lo}–{hi} → 真结果 {got}"); }
    static long A() => GC.GetAllocatedBytesForCurrentThread();
    const int Cap = 1 << 20, Chunk = 1 << 16, OpB = 20;
    const long ChunkB = (long)Chunk * OpB;   // 1310720

    static int Main()
    {
        // 预热（JIT / 泛型实例化本身的分配不算进下面）
        { var w = new S2AOpChunks<Op>(Chunk); w.Reserve(1); w.Span(0, 1)[0].Index = 1; w.Clear(); }

        // ① 新建不分配块：只有块表（16 个引用）
        long a0 = A(); var c = new S2AOpChunks<Op>(Cap); long d1 = A() - a0;
        Expect("① 新建后已分配块数", 0, c.AllocatedChunks);
        Within("① 新建的托管分配（字节，块表 + 对象头，远小于一块）", 0, 1024, d1);

        // ② 每段 64 条放满 1M 条：分配正好 16 块（每块 1310720 B + 数组头 ≤ 64 B），没有别的垃圾
        a0 = A(); int segs = 0;
        while (c.Reserve(64) >= 0) segs++;
        long d2 = A() - a0;
        Expect("② 64 条一段放满 1M 条的段数", Cap / 64, segs);
        Expect("② 已分配块数", 16, c.AllocatedChunks);
        Expect("② 放满的托管分配（字节，块在原生内存）", 0, d2);
        Expect("② 原生字节（= 16 × 1310720）", 16 * ChunkB, c.NativeBytes);

        // ③ 段不跨块：清空后先放 65000 条（起点 0），再放 1000 条——本块只剩 536 条放不下，起点 = 65536；一块整段 65536 条放得下，65537 条回 -1
        c.Clear();
        Expect("③ 第一段起点", 0, c.Reserve(65000));
        Expect("③ 放不下的第二段从下一块开头", 65536, c.Reserve(1000));
        Expect("③ 超过一块的段回 -1", -1, c.Reserve(Chunk + 1));
        c.Span(65536, 1000)[999].Index = 7; Expect("③ 跨块读写落在第 2 块偏移 999", 7, c.Span(65536 + 999, 1)[0].Index);

        // ④ 清空后重新放满：零新分配（块复用）
        c.Clear(); a0 = A(); while (c.Reserve(64) >= 0) { } long d4 = A() - a0;
        Expect("④ 清空后重新放满的托管分配（字节）", 0, d4);

        // 反证：旧写法（一整块，从 2048 条起翻倍到 1M，Array.Resize）放满 1M 条——每次翻倍都新分配、旧区成垃圾：2048×20×(1+2+…+512) ≈ 40 MiB
        a0 = A(); Op[] old = Array.Empty<Op>(); int pos = 0;
        for (int i = 0; i < Cap / 64; i++) { if (pos + 64 > old.Length) Array.Resize(ref old, Math.Min(Cap, Math.Max(pos + 64, Math.Max(2048, old.Length * 2)))); pos += 64; }
        long dOld = A() - a0;
        Within("反证：旧写法放满 1M 条的托管分配（字节，2048×20×1023 ≈ 41.9 MB）", 2048L * OpB * 1023, 2048L * OpB * 1023 + 4096, dOld);
        Console.WriteLine($"{(bad == 0 ? "✓" : "✗")} S2A.SegChunksTest：{n} 项，失败 {bad}（放满 1M 条：新写法托管分配 {d2 / 1048576.0:F1} MB、原生 {c.NativeBytes / 1048576.0:F1} MB；旧写法托管 {dOld / 1048576.0:F1} MB）");
        return bad == 0 ? 0 : 1;
    }
}
