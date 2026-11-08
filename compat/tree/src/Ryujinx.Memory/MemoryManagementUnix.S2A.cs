using System.Runtime.InteropServices;
using static Ryujinx.Memory.MemoryManagerUnixHelper;

namespace Ryujinx.Memory
{
    static partial class MemoryManagementUnix
    {
        // S2A：私有匿名内存块放宿主窗口尾部（原生层 s2a_tail_map，10-24 异度神剑3 低区耗尽：GC 只能用低区，没有簿记表的大户挪尾部）。
        // 尾部放不下时原生层自己退回普通映射；主程序没有这个导出（Ryujinx 自己的测试 / 别的宿主）就照原样 mmap。JIT 与共享内存不走这里
        private static unsafe class S2ATail
        {
            public static readonly delegate* unmanaged<ulong, int, int, nint> Map;
            public static readonly delegate* unmanaged<nint, ulong, int, void> Unmap;
            public static readonly delegate* unmanaged<nint, int> Has;
            public const int UserRyujinx = 1;   // S2A_TAIL_RYU

            static S2ATail()
            {
                nint h = NativeLibrary.GetMainProgramHandle();
                if (NativeLibrary.TryGetExport(h, "s2a_tail_map", out nint m) && NativeLibrary.TryGetExport(h, "s2a_tail_unmap", out nint u) && NativeLibrary.TryGetExport(h, "s2a_tail_has", out nint x))
                {
                    Map = (delegate* unmanaged<ulong, int, int, nint>)m;
                    Unmap = (delegate* unmanaged<nint, ulong, int, void>)u;
                    Has = (delegate* unmanaged<nint, int>)x;
                }
            }

            public static bool InTail(nint p) => Has != null && Has(p) != 0;
        }

        // 宿主尾部策略的私有入口：只在原允许的类别（非 JIT、非 shared）且三个导出齐全时选用。
        // 返回 false = 本策略不适用，调用方走原 Unix mmap；返回 true 后即便 ptr 为 0 也不再回落，失败按原路径报错。
        private static unsafe bool TryAllocateS2A(ulong size, MmapProts prot, bool forJit, bool shared, out nint ptr)
        {
            ptr = nint.Zero;

            if (forJit || shared || S2ATail.Map == null)
            {
                return false;
            }

            ptr = S2ATail.Map(size, S2ATail.UserRyujinx, (int)prot);
            return true;
        }

        // 释放按实际归属路由：调用过宿主 Map 不等于返回地址落在尾部，仍以宿主 s2a_tail_has 判定。
        private static bool TryUnmapS2A(nint address, ulong size)
        {
            if (!S2ATail.InTail(address))
            {
                return false;
            }

            unsafe
            {
                S2ATail.Unmap(address, size, S2ATail.UserRyujinx);
            }

            return true;
        }
    }
}
