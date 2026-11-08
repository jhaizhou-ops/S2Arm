// 缓冲表合并窗口一致性单测（BotW 8E/9000/9400 generic READY+~70s NRE 根修）：
//   CreateBufferAligned 合并分支先 _buffers.RemoveRange 旧缓冲；新缓冲要等 CreateBufferAligned(...)
//   返回后外层才 _buffers.Add，而里面先做拷贝/同步/NotifyBuffersModified/RecreateMultiRangeBuffers——
//   RecreateMultiRangeBuffers → 嵌套 CreateMultiRangeBuffer → 对同段地址 CreateBuffer 命中这个空窗，
//   另建出一个物理缓冲；外层再 Add → 「互不重叠」的缓冲表出现重叠项，表不变量破，
//   之后 UpdateVirtualBufferDependencies / GetBuffer 对「已映射但查不到缓冲」的子段拿空 → NRE
//   （9400 顶帧 UpdateVirtualBufferDependencies；9000 顶帧 GetBuffer ← GetBufferRangeAligned）。
// 复现：拷贝式多段缓冲（非 64KB 对齐两段，无 sparseBinding 的拷贝路径）+ 与其次子段重叠的
//   64KB 对齐合并，两条合并路径各演一遍（4 参对齐重载 / 3 参页对齐重载——同一空窗两处）。
// 断言：① 全程不抛；② _buffers 两两不重叠；③ 每个多段缓冲的已映射子段都能查到
//   完整覆盖它的物理缓冲（UpdateVirtualBufferDependencies / GetBuffer 的契约）；
//   ④ 「已映射但无缓冲」的查找走显式异常（带地址/大小），不是 NullReferenceException、不是静默。
// 全部用真 GpuContext / PhysicalMemory / MemoryManager / BufferCache / CPU 跟踪内存；渲染器是桩。
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Graphics.Shader;
using System;
using System.Reflection;
using System.Text;
using Buffer = Ryujinx.Graphics.Gpu.Memory.Buffer;

static class Program
{
    static int _pass;
    static int _fail;

    static readonly FieldInfo BuffersF = typeof(BufferCache).GetField("_buffers", BindingFlags.NonPublic | BindingFlags.Instance);
    static readonly FieldInfo MrbF = typeof(BufferCache).GetField("_multiRangeBuffers", BindingFlags.NonPublic | BindingFlags.Instance);

    static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}{(detail.Length > 0 ? "：" + detail : "")}");
    }

    // 表不变量：① 物理缓冲两两不重叠（NonOverlappingRangeList 的契约）；② 每个多段缓冲的
    // 已映射子段，FindOverlap 必得一个完整覆盖它的物理缓冲——不空、不只有部分覆盖。
    static (int problems, string detail) TableProblems(BufferCache cache)
    {
        var bufs = (NonOverlappingRangeList<Buffer>)BuffersF.GetValue(cache);
        var mrbs = (MultiRangeList<MultiRangeBuffer>)MrbF.GetValue(cache);

        int problems = 0;
        var detail = new StringBuilder();
        int n = 0;

        Buffer prev = null;
        foreach (Buffer b in bufs)
        {
            if (prev != null && b.Address < prev.EndAddress)
            {
                problems++;
                detail.Append($"重叠 0x{prev.Address:X}+0x{prev.Size:X}∩0x{b.Address:X}+0x{b.Size:X};");
            }
            prev = b;
            n++;
        }

        int m = 0;
        foreach (MultiRangeBuffer mrb in mrbs)
        {
            for (int i = 0; i < mrb.Range.Count; i++)
            {
                MemoryRange sr = mrb.Range.GetSubRange(i);

                if (sr.Address == MemoryManager.PteUnmapped)
                {
                    continue;
                }

                Buffer b = bufs.FindOverlap(sr.Address, sr.Size);

                if (b == null || !b.FullyContains(sr.Address, sr.Size))
                {
                    problems++;
                    detail.Append($"多段子段 0x{sr.Address:X}+0x{sr.Size:X} 无完整物理缓冲（{(b == null ? "空" : $"0x{b.Address:X}+0x{b.Size:X}")}）;");
                }
            }
            m++;
        }

        return (problems, $"物理缓冲 {n} 个 / 多段缓冲 {m} 个{detail}");
    }

    static int Main()
    {
        var ctx = new GpuContext(new NullRenderer(default), null);

        // guest 物理内存：真 CPU 跟踪管理器 + 后端块；guest PA 0x100000 起映射到块内偏移 0
        const ulong CpuMemSize = 0x400000;
        using var backing = new MemoryBlock(CpuMemSize);
        var cpuMem = new Ryujinx.Cpu.Jit.MemoryManager(backing, CpuMemSize);
        cpuMem.Map(0x100000, 0x0, 0x200000, MemoryMapFlags.None);

        var phys = new PhysicalMemory(ctx, cpuMem);
        var gmm = new MemoryManager(phys, CpuMemSize);

        BufferStage StorageStage() => BufferStageUtils.ComputeStorage(BufferUsageFlags.None);

        // ① 64KB 对齐重载合并路径（与真机崩溃同一条路）：拷贝式多段缓冲 M
        //   （[0x100000,0x4000) + [0x208000,0x4000)，次子段非 64KB 对齐 → 拷贝式），
        //   再发起覆盖 M 次子段的 64KB 对齐合并 [0x200000,0x220000)。
        //   修前：合并空窗里嵌套重建 M 会对 [0x208000,0x4000) 另建物理缓冲，外层再 Add → 重叠。
        gmm.Map(0x100000, 0x4000, 0x4000, PteKind.Pitch);
        gmm.Map(0x208000, 0x8000, 0x4000, PteKind.Pitch);

        MultiRange r1 = phys.BufferCache.TranslateAndCreateMultiBuffers(gmm, 0x4000, 0x8000, StorageStage());
        Check("多段缓冲：两段非连续物理", r1.Count == 2, r1.ToString());

        bool threw1 = false;
        try
        {
            phys.BufferCache.CreateBuffer(0x208000, 0x18000, StorageStage(), BufferCache.SparseBufferAlignmentSize);
        }
        catch (Exception e)
        {
            threw1 = true;
            Console.WriteLine($"  64KB 对齐合并抛 {e.GetType().Name}: {e.Message}");
        }
        Check("64KB 对齐合并不抛", !threw1);

        var (p1, d1) = TableProblems(phys.BufferCache);
        Check("64KB 对齐合并后表一致", p1 == 0, d1);

        // ② 页对齐重载合并路径（同一空窗的另一处）：多段缓冲 N 次子段 [0x228000,0x4000)，
        //   发起 3 参 CreateBuffer 合并成 [0x220000,0x240000)（两端都 64KB 对齐才触发重建）。
        gmm.Map(0x110000, 0x14000, 0x4000, PteKind.Pitch);
        gmm.Map(0x228000, 0x18000, 0x4000, PteKind.Pitch);

        MultiRange r2 = phys.BufferCache.TranslateAndCreateMultiBuffers(gmm, 0x14000, 0x8000, StorageStage());
        Check("第二个多段缓冲：两段非连续物理", r2.Count == 2, r2.ToString());

        bool threw2 = false;
        try
        {
            phys.BufferCache.CreateBuffer(0x220000, 0x20000, StorageStage());
        }
        catch (Exception e)
        {
            threw2 = true;
            Console.WriteLine($"  页对齐合并抛 {e.GetType().Name}: {e.Message}");
        }
        Check("页对齐合并不抛", !threw2);

        var (p2, d2) = TableProblems(phys.BufferCache);
        Check("页对齐合并后表一致", p2 == 0, d2);

        // ③ 「已映射但无缓冲」的查找报红：显式异常（带地址/大小），不是 NRE、不静默、不返回假缓冲
        Exception ex = null;
        try
        {
            phys.BufferCache.SynchronizeBufferRange(new MultiRange(0x500000, 0x4000));
        }
        catch (Exception e)
        {
            ex = e;
        }
        Check("无缓冲区间同步抛显式异常", ex != null && ex is not NullReferenceException,
            ex == null ? "没抛" : $"{ex.GetType().Name}: {ex.Message}");

        Console.WriteLine($"gpu_bufrecreate：{_pass} 过 {_fail} 挂");
        return _fail == 0 ? 0 : 1;
    }
}
