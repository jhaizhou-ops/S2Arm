using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Gpu.Engine.GPFifo
{
    /// <summary>
    /// S2A（帧率能耗线 10-24）：免解读缓存的操作序列分块存储，块放原生内存。
    /// 原先是一整块托管数组按需「翻倍增长」，每次 Array.Resize 新分配并丢掉旧区：丝之歌测试机2 MARK 后长到 52.4 万 / 104.9 万条时各新分配 10 / 20 MiB
    /// （silksong_1024091722_2 第 5900 / 6108 帧），占 MARK 后 60 秒托管分配 39.6 MB 的 31 MB，分配闸门红；就算改成托管分块，热身期长出来的块（每块 1.25 MiB，
    /// 大于 85 KB 进大对象堆）照样计入托管分配、推 gen2。操作是纯值类型，这里改成定长块（ChunkOps 条）、用到哪块才 NativeMemory.AllocZeroed 哪块：
    /// 托管分配为 0、不进 GC 堆；长大不拷贝；一段不跨块（段长上限 = 一块）；Clear 只回到开头，块留着复用；对象回收时终结器还块（通道关掉不漏）。
    /// 位置是全局下标：高位块号、低 ChunkBits 位块内偏移。单测：graphics/tools/shbake/tests/segchunks（S2A.SegChunksTest）。
    /// </summary>
    internal sealed unsafe class S2AOpChunks<T> where T : unmanaged
    {
        public const int ChunkBits = 16, ChunkOps = 1 << ChunkBits;
        private readonly nint[] _chunks;
        private int _pos;

        public S2AOpChunks(int capacityOps) => _chunks = new nint[(capacityOps + ChunkOps - 1) >> ChunkBits];

        ~S2AOpChunks()
        {
            for (int i = 0; i < _chunks.Length; i++)
            {
                if (_chunks[i] != 0) { NativeMemory.Free((void*)_chunks[i]); _chunks[i] = 0; }
            }
        }

        /// <summary>已分配的块数（单测 / 诊断）。</summary>
        public int AllocatedChunks { get { int n = 0; foreach (nint c in _chunks) { if (c != 0) n++; } return n; } }

        /// <summary>已分配的原生字节（单测 / 诊断）。</summary>
        public long NativeBytes => (long)AllocatedChunks * ChunkOps * sizeof(T);

        /// <summary>预留 n 条连续位置，返回起点；本块剩下的放不下就从下一块开头放；n 超过一块或区满回 -1（调用方 Clear 后重来）。</summary>
        public int Reserve(int n)
        {
            if (n < 0 || n > ChunkOps) return -1;
            if ((_pos & (ChunkOps - 1)) + n > ChunkOps) _pos = ((_pos >> ChunkBits) + 1) << ChunkBits;
            int c = _pos >> ChunkBits;
            if (c >= _chunks.Length) return -1;
            if (_chunks[c] == 0) _chunks[c] = (nint)NativeMemory.AllocZeroed((nuint)ChunkOps, (nuint)sizeof(T));
            int start = _pos; _pos += n; return start;
        }

        public void Clear() => _pos = 0;

        public Span<T> Span(int start, int count) => new((T*)_chunks[start >> ChunkBits] + (start & (ChunkOps - 1)), count);
    }
}
