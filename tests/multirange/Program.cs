// MultiRange.SliceOverlapsWith 单测：与 Slice(...).OverlapsWith(...) 逐例等价；多段时零分配（旧写法有分配，反证）
using Ryujinx.Memory.Range;
using System;
using System.Collections.Generic;

const ulong Inv = ulong.MaxValue;
var storages = new List<MultiRange>
{
    new MultiRange(0x10000, 0x3000),
    new MultiRange(new[] { new MemoryRange(0x10000, 0x1000), new MemoryRange(0x40000, 0x2000) }),
    new MultiRange(new[] { new MemoryRange(0x10000, 0x1000), new MemoryRange(Inv, 0x1000), new MemoryRange(0x80000, 0x1000) }),
    new MultiRange(new[] { new MemoryRange(0x20000, 0x800), new MemoryRange(0x21000, 0x800), new MemoryRange(0x30000, 0x1000), new MemoryRange(0x50000, 0x1800) }),
};
var others = new List<MultiRange>
{
    new MultiRange(0x10000, 1), new MultiRange(0x10fff, 1), new MultiRange(0x11000, 0x100), new MultiRange(0x40800, 0x10), new MultiRange(0x41fff, 4),
    new MultiRange(0x80000, 0x10), new MultiRange(0x30000, 0x1000), new MultiRange(0x50000, 0x2000), new MultiRange(0x0, 0x8000),
    new MultiRange(new[] { new MemoryRange(0x5000, 0x100), new MemoryRange(0x40400, 0x10) }),
    new MultiRange(new[] { new MemoryRange(0x21400, 0x100), new MemoryRange(0x90000, 0x10) }),
};
int n = 0, bad = 0, yes = 0;
foreach (var s in storages)
{
    ulong total = 0; for (int i = 0; i < s.Count; i++) total += s.GetSubRange(i).Size;
    for (ulong off = 0; off < total; off += 0x200)
        for (ulong size = 0x200; off + size <= total; size += 0x200)
            foreach (var o in others)
            {
                bool want = s.Slice(off, size).OverlapsWith(o), got = s.SliceOverlapsWith(off, size, o);
                n++; if (want) yes++;
                if (want != got) { bad++; if (bad <= 5) Console.WriteLine($"不等：存储 {s.Count} 段 off=0x{off:x} size=0x{size:x} → 期望 {want} 实得 {got}"); }
            }
}
Console.WriteLine($"等价：比 {n} 例（其中重叠 {yes} 例），不等 {bad} 例");
var m = storages[3]; var q = others[6]; bool sink = false;
for (int i = 0; i < 100; i++) { sink ^= m.SliceOverlapsWith(0x800, 0x1000, q); sink ^= m.Slice(0x800, 0x1000).OverlapsWith(q); }
long a0 = GC.GetAllocatedBytesForCurrentThread();
for (int i = 0; i < 10000; i++) sink ^= m.SliceOverlapsWith(0x800, 0x1000, q);
long a1 = GC.GetAllocatedBytesForCurrentThread();
for (int i = 0; i < 10000; i++) sink ^= m.Slice(0x800, 0x1000).OverlapsWith(q);
long a2 = GC.GetAllocatedBytesForCurrentThread();
Console.WriteLine($"多段 1 万次分配：新写法 {a1 - a0} B，旧写法 Slice+OverlapsWith {a2 - a1} B（{sink}）");
bool ok = bad == 0 && n > 1000 && yes > 0 && yes < n && a1 - a0 == 0 && a2 - a1 > 0;
Console.WriteLine(ok ? "multirange 单测全过" : "multirange 单测有不通");
return ok ? 0 : 1;
