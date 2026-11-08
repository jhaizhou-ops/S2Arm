using System;

namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// S2A（帧率能耗线 10-22，巫师3 换场景分配方案 B）：渲染器租出的一段上传内存（原生、共享给 GPU）。
    /// Gpu 层转贴图格式 / 线程渲染器传缓冲数据时直接写进 <see cref="Span"/>，再交给 ITexture.S2ASetData / IRenderer.S2ASetBufferData，
    /// 渲染器拿它当暂存、用完收回——不经托管数组（换场景帧 GPU 模拟线程几十 MB 分配），也省一次托管 → 暂存的拷贝。
    /// 只能交一次；不交要 IRenderer.S2ADropUpload 退租。值类型，排进线程渲染器命令队列不分配
    /// </summary>
    public readonly struct S2AUploadLease
    {
        public readonly nint Ptr;
        public readonly int Size;
        public readonly uint Id;

        public S2AUploadLease(nint ptr, int size, uint id)
        {
            Ptr = ptr;
            Size = size;
            Id = id;
        }

        public unsafe Span<byte> Span => new((void*)Ptr, Size);
    }
}
