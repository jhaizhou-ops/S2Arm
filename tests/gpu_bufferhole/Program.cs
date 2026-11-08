// 计算存储缓冲带空洞多段单测（BotW qbotw8e READY+68.3s：GPU 虚址含未映射洞的多段缓冲
//   在 BufferCache.GetBuffer 里对 PteUnmapped 子段 FindOverlap(ulong.MaxValue) 得空，
//   subBuffer.SynchronizeMemory 空解引用 → GPU run 线程 NRE → 整会话崩）。
// 被测：compat/tree/src/Ryujinx.Graphics.Gpu/Memory/BufferCache.cs 的 GetBuffer(MultiRange)。
// 复现：GPU VA 映射-洞-映射三段 → TranslateAndCreateMultiBuffers（建缓冲时按同一哨兵跳过洞段，
//   见 CreateMultiRangeBuffer / UpdateVirtualBufferDependencies）→ GetBufferRangeAligned：
//   修前 NRE；修后跳过洞段正常返回。全映射两段为负对照，修前修后都绿。
// 全部用真 GpuContext / PhysicalMemory / MemoryManager / BufferCache / CPU 跟踪内存；渲染器是桩。
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Shader;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using System;

static class Program
{
    static int _pass;
    static int _fail;

    static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}{(detail.Length > 0 ? "：" + detail : "")}");
    }

    static int Main()
    {
        var ctx = new GpuContext(new NullRenderer(default), null);

        // guest 物理内存：真 CPU 跟踪管理器 + 后端块；guest PA 0x100000 起映射到块内偏移 0
        const ulong CpuMemSize = 0x200000;
        using var backing = new MemoryBlock(CpuMemSize);
        var cpuMem = new Ryujinx.Cpu.Jit.MemoryManager(backing, CpuMemSize);
        cpuMem.Map(0x100000, 0x0, 0x20000, MemoryMapFlags.None);

        var phys = new PhysicalMemory(ctx, cpuMem);
        var gmm = new MemoryManager(phys, CpuMemSize);

        BufferStage StorageStage() => BufferStageUtils.ComputeStorage(BufferUsageFlags.None);

        // ① 带洞多段：GPU VA [0x4000,0x8000) 映射、[0x8000,0xC000) 未映射洞、[0xC000,0x10000) 映射
        //   （两段 PA 也不连续：真实三路 MultiRange，与 GetPhysicalRegions 产物一致）
        gmm.Map(0x100000, 0x4000, 0x4000, PteKind.Pitch);
        gmm.Map(0x108000, 0xC000, 0x4000, PteKind.Pitch);

        MultiRange holey = phys.BufferCache.TranslateAndCreateMultiBuffers(gmm, 0x4000, 0xC000, StorageStage());
        Check("带洞虚址翻成 3 子段且中段是 PteUnmapped",
            holey.Count == 3 && holey.GetSubRange(1).Address == MemoryManager.PteUnmapped, holey.ToString());

        // 崩的就是这一句：GetBuffer(MultiRange) 对每个子段 FindOverlap 后直接解引用
        bool threw = false;
        try
        {
            phys.BufferCache.GetBufferRangeAligned(holey, StorageStage(), write: true);
        }
        catch (NullReferenceException)
        {
            threw = true;
        }
        Check("带洞多段提交绑定不抛", !threw);

        // ② 负对照：全映射但物理不连续的两段——多段路径本身修前修后都该绿
        gmm.Map(0x110000, 0x14000, 0x4000, PteKind.Pitch);
        gmm.Map(0x118000, 0x18000, 0x4000, PteKind.Pitch);

        MultiRange mapped2 = phys.BufferCache.TranslateAndCreateMultiBuffers(gmm, 0x14000, 0x8000, StorageStage());
        Check("全映射两段负对照子段数", mapped2.Count == 2, mapped2.ToString());

        bool threw2 = false;
        try
        {
            phys.BufferCache.GetBufferRangeAligned(mapped2, StorageStage(), write: true);
        }
        catch (NullReferenceException)
        {
            threw2 = true;
        }
        Check("全映射两段提交绑定不抛", !threw2);

        // ③ 负对照：洞在末尾——绑定尺寸越过映射尾（QMD 描述符信任尺寸的真实来路之一）
        gmm.Map(0x120000, 0x1C000, 0x4000, PteKind.Pitch);
        MultiRange tailHole = phys.BufferCache.TranslateAndCreateMultiBuffers(gmm, 0x1C000, 0x8000, StorageStage());
        Check("尾洞多段子段结构", tailHole.Count == 2 && tailHole.GetSubRange(1).Address == MemoryManager.PteUnmapped, tailHole.ToString());

        bool threw3 = false;
        try
        {
            phys.BufferCache.GetBufferRangeAligned(tailHole, StorageStage(), write: true);
        }
        catch (NullReferenceException)
        {
            threw3 = true;
        }
        Check("尾洞多段提交绑定不抛", !threw3);

        Console.WriteLine($"gpu_bufferhole：{_pass} 过 {_fail} 挂");
        return _fail == 0 ? 0 : 1;
    }
}
