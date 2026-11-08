using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory.Range;
using System;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A（#723 P1）：负缓存提问面的运行时实现——把 MemoryManager / GpuRegionHandle 接到 S2AShaderFaultCache 的接口上。
    /// 缓存本身不引用 Ryujinx 类型（可单文件编译测试），这一层才引用。
    /// </summary>
    internal sealed class S2AFaultHostOf : IS2AFaultHost
    {
        private readonly MemoryManager _memoryManager;

        public S2AFaultHostOf(MemoryManager memoryManager)
        {
            _memoryManager = memoryManager;
        }

        /// <summary>先读代数号再翻译：读到的代数号不变 ⇒ 翻译结果不变（同 0008 的用法）。</summary>
        public int MapGen => Volatile.Read(ref _memoryManager.S2AMapGen);

        public ulong TranslatePage(ulong page) => _memoryManager.Translate(page);

        public IS2AFaultWatch Arm(ulong page, int lo, int hi)
        {
            ulong pa = _memoryManager.Translate(page);

            // 未映射页没有物理地址可跟踪：条目靠映射代数号 + 重翻译判失效（页一旦被映射，物理地址必与记录时的 MaxValue 不同）
            if (pa == MemoryManager.PteUnmapped || !_memoryManager.Physical.IsMapped(pa)) return null;

            GpuRegionHandle handle = _memoryManager.Physical.BeginTracking(new MultiRange(pa, MemoryManager.PageSize), ResourceKind.None);
            // Ryujinx 的 RegionHandle 新建即脏（RegionHandle.cs「Dirty = mapped」）：这里 Reprotect 一次清掉初始脏位并把页保护成只读，之后一写才标脏。
            // 不清的话条目一记进去就按「页被写过」作废（10-28 冷缓存真局：命中 0、每次派发解两遍）。同 ShaderCache.S2AVerify 的用法。
            // 顺序：先 Reprotect 再记内容——Reprotect 之后的写会再把句柄标脏，记下的内容就是「没被写过时」的内容。
            handle.Reprotect();
            return new S2AFaultWatchOf(handle, _memoryManager.Physical, pa + (ulong)lo, hi - lo);
        }
    }

    /// <summary>
    /// S2A：GpuRegionHandle 的薄包装 + 解码器读过的字节区间的内容哈希。
    /// 页脏时 Rearm：先 Reprotect（清脏、重新武装）再重算哈希，与武装时相同 ⇒ 同值重写或共页别处被改，条目仍有效。
    /// </summary>
    internal sealed class S2AFaultWatchOf : IS2AFaultWatch
    {
        private readonly GpuRegionHandle _handle;
        private readonly PhysicalMemory _physical;
        private readonly ulong _address;
        private readonly int _size;
        private readonly ulong _hash;

        public S2AFaultWatchOf(GpuRegionHandle handle, PhysicalMemory physical, ulong address, int size)
        {
            _handle = handle;
            _physical = physical;
            _address = address;
            _size = size;
            _hash = Hash();
        }

        public bool Dirty => _handle.Dirty;

        public bool Rearm()
        {
            _handle.Reprotect();
            return Hash() == _hash;
        }

        public void Dispose() => _handle.Dispose();

        /// <summary>FNV-1a 64（区间最多一页，取码失败的页不超过 256 个）。</summary>
        private ulong Hash()
        {
            ReadOnlySpan<byte> bytes = _physical.GetSpan(_address, _size);
            ulong h = 14695981039346656037UL;
            foreach (byte b in bytes)
            {
                h ^= b;
                h *= 1099511628211UL;
            }
            return h;
        }
    }
}
