using Ryujinx.Common;
using Ryujinx.Graphics.Shader;
using Silk.NET.Vulkan;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>
    /// S2A（F1）：全局访存越出宿主绑定窗口的记录缓冲（着色器侧合同见 <see cref="S2AStorageOobRecord"/>）。
    /// 每个带记录绑定的宿主程序分到一段（宿主可见、一致内存），描述符偏移选段；程序在某个命令缓冲里用过，
    /// 这一段就作为该命令缓冲的依赖（IAuto），命令缓冲的栅栏完成时（CommandBufferPool 回收）读一次计数，
    /// 计数比上次多就按程序哈希打【红】：每个程序前 32 次检出逐条打，之后只在第 2^k 次打；全进程另按同一规则限次。
    /// 红行在回收路径上只入队，由线程池输出（回收持 CommandBufferPool 锁，不在锁里同步写 stderr）。
    /// 不加任何等待、不跳 draw；只有用过这些程序的命令缓冲在结束前多一个「着色器写 → 主机读」内存屏障。
    /// 缺省关：只在 S2A_SSBO_OOB_DIAG=1 且设备未启用 robustBufferAccess 时创建（VulkanRenderer），否则着色器里没有记录绑定。
    /// </summary>
    sealed class S2AStorageOobRecorder : IDisposable
    {
        private const int RegionsPerPage = 1024;
        private const int ReportEachUpTo = 32;

        /// <summary>诊断开关：启动 extra s2arm.diag_ssbo_oob（安卓）或环境变量 S2A_SSBO_OOB_DIAG=1。</summary>
        public static bool DiagnosticsRequested => Environment.GetEnvironmentVariable("S2A_SSBO_OOB_DIAG") == "1";

        private readonly VulkanRenderer _gd;
        private readonly int _stride;
        private readonly List<BufferHolder> _pages = [];
        private readonly Stack<int> _free = new();
        private readonly Lock _lock = new();
        private readonly bool[] _hostReadBarrier = new bool[CommandBufferPool.MaxCommandBuffers];
        private readonly ConcurrentQueue<string> _pendingLines = new();
        private int _allocated;
        private int _detections;
        private int _drainScheduled;

        /// <summary>
        /// 共用丢弃段（第一页第 0 段）：分不到自己的段时程序的记录绑定指向它，越界写落在这里、不读回、不报红，
        /// 免得记录绑定沿用上一个程序的段、把检出算到别人头上。
        /// </summary>
        public S2AStorageOobRegion Discard { get; }

        private S2AStorageOobRecorder(VulkanRenderer gd, int stride)
        {
            _gd = gd;
            _stride = stride;

            // 第一页在渲染器初始化时建好（程序可能在后台线程创建）；之后不够时才在分配锁里加页
            if (TryAddPage())
            {
                _allocated = 1;
                Discard = CreateRegion(0, isDiscard: true);
            }
        }

        /// <summary>建记录器；第一页（含丢弃段）建不出来时返回 null，渲染器按「记录关」报能力，着色器不声明记录绑定。</summary>
        public static S2AStorageOobRecorder TryCreate(VulkanRenderer gd, ulong minStorageBufferOffsetAlignment)
        {
            // 段长是描述符偏移的对齐量的整数倍，且装得下着色器写的字数
            int alignment = (int)Math.Max(1UL, minStorageBufferOffsetAlignment);
            int bytes = S2AStorageOobRecord.Words * sizeof(uint);
            int stride = (bytes + alignment - 1) / alignment * alignment;

            S2AStorageOobRecorder recorder = new(gd, stride);

            if (recorder.Discard == null)
            {
                recorder.Dispose();
                Console.Error.WriteLine("[gpu] 【红】存储缓冲越界记录：记录缓冲建不出来，本局越界记录关闭（钳位不受影响）");
                return null;
            }

            Console.Error.WriteLine("[gpu] 【黄】存储缓冲越界记录已开（S2A_SSBO_OOB_DIAG=1）：片元 / 计算着色器多一个可写记录缓冲，本局帧率 / 像素读数不作数");
            return recorder;
        }

        private unsafe bool TryAddPage()
        {
            int size = RegionsPerPage * _stride;
            BufferHolder page = _gd.BufferManager.Create(_gd, size, baseType: BufferAllocationType.HostMapped);

            if (page == null || page.Map(0, size) == nint.Zero)
            {
                page?.Dispose();
                return false;
            }

            new Span<byte>((void*)page.Map(0, size), size).Clear();
            _pages.Add(page);

            return true;
        }

        /// <summary>给一个宿主程序分一段并清零；分不到（加页失败）时给共用丢弃段（不读回、不报红）。</summary>
        public S2AStorageOobRegion Allocate()
        {
            lock (_lock)
            {
                int index;

                if (_free.Count != 0)
                {
                    index = _free.Pop();
                }
                else
                {
                    index = _allocated;

                    if (index / RegionsPerPage >= _pages.Count && !TryAddPage())
                    {
                        return Discard;
                    }

                    _allocated++;
                }

                return CreateRegion(index, isDiscard: false);
            }
        }

        private unsafe S2AStorageOobRegion CreateRegion(int index, bool isDiscard)
        {
            BufferHolder holder = _pages[index / RegionsPerPage];
            int offset = index % RegionsPerPage * _stride;
            nint pointer = holder.Map(0, RegionsPerPage * _stride) + offset;

            // 段只在没有任何命令缓冲引用时才回收，清零时 GPU 不会再写它
            new Span<byte>((void*)pointer, _stride).Clear();

            return new S2AStorageOobRegion(this, index, holder.GetBuffer(), offset, _stride, pointer, isDiscard);
        }

        internal void Release(int index)
        {
            lock (_lock)
            {
                _free.Push(index);
            }
        }

        internal void RequestHostReadBarrier(int commandBufferIndex)
        {
            _hostReadBarrier[commandBufferIndex] = true;
        }

        /// <summary>
        /// 命令缓冲结束前调用（渲染通道外）：这个命令缓冲里用过带记录的程序时，插一个着色器写 → 主机读的内存屏障，
        /// 让栅栏完成后主机能读到计数（Vulkan 规范：栅栏本身不保证设备写对主机可见）。
        /// </summary>
        public unsafe void InsertHostReadBarrier(CommandBufferScoped cbs)
        {
            if (!_hostReadBarrier[cbs.CommandBufferIndex])
            {
                return;
            }

            _hostReadBarrier[cbs.CommandBufferIndex] = false;

            MemoryBarrier barrier = new()
            {
                SType = StructureType.MemoryBarrier,
                SrcAccessMask = AccessFlags.ShaderWriteBit,
                DstAccessMask = AccessFlags.HostReadBit,
            };

            _gd.Api.CmdPipelineBarrier(
                cbs.CommandBuffer,
                PipelineStageFlags.AllCommandsBit,
                PipelineStageFlags.HostBit,
                0,
                1,
                in barrier,
                0,
                null,
                0,
                null);
        }

        private static bool Sampled(int count) => count <= ReportEachUpTo || (count & (count - 1)) == 0;

        // 在命令缓冲回收路径上（持 CommandBufferPool 锁）调用：只做限次与格式化，输出交给线程池
        internal void Report(S2AStorageOobRegion region, uint count, uint delta, int detection, ReadOnlySpan<uint> words)
        {
            if (!Sampled(detection))
            {
                return;
            }

            // 全进程限次：按「过了每程序限次的检出」计数，同样前 32 条逐条、之后第 2^k 条
            int line = Interlocked.Increment(ref _detections);

            if (!Sampled(line))
            {
                return;
            }

            uint info = words[S2AStorageOobRecord.WordInfo];
            uint kind = (info >> S2AStorageOobRecord.KindShift) & 7;
            int stage = (int)((info >> S2AStorageOobRecord.StageShift) & 0xF);
            int cbSlot = (int)((info >> S2AStorageOobRecord.CbSlotShift) & 0xFF);
            int cbOffset = (int)(info & 0xFFFF);

            ulong hashLow = words[S2AStorageOobRecord.WordHash] | ((ulong)words[S2AStorageOobRecord.WordHash + 1] << 32);
            ulong hashHigh = words[S2AStorageOobRecord.WordHash + 2] | ((ulong)words[S2AStorageOobRecord.WordHash + 3] << 32);

            string access = ((kind & S2AStorageOobRecord.KindMultiTarget) != 0 ? "多目标" : "单目标") + (kind & 3) switch
            {
                S2AStorageOobRecord.KindStore => "写",
                S2AStorageOobRecord.KindAtomic => "原子",
                _ => "读",
            };

            string stageName = stage < (int)ShaderStage.Count ? ((ShaderStage)stage).ToString() : stage.ToString();

            _pendingLines.Enqueue(
                $"[gpu] 【红】存储缓冲访存越出宿主绑定窗口：程序 {new Hash128(hashLow, hashHigh)} 阶段 {stageName} {access} " +
                $"基址 c{cbSlot}[0x{cbOffset * 4:X}]；首个越界：客体地址低 32 位 0x{words[S2AStorageOobRecord.WordAddressLow]:X8} " +
                $"窗口内偏移 0x{words[S2AStorageOobRecord.WordOffset]:X8} 窗口 0x{(ulong)words[S2AStorageOobRecord.WordWindowLength] * 4:X} 字节 " +
                $"着色器读到的描述符 0x{words[S2AStorageOobRecord.WordBaseHigh]:X8}{words[S2AStorageOobRecord.WordBaseLow]:X8}+0x{words[S2AStorageOobRecord.WordSize]:X}；" +
                $"新增 {delta} 次、累计 {count} 次（该程序第 {detection} 次检出，宿主程序段 {region.Index}，全进程第 {line} 条）；" +
                "越界读按 0、写和原子丢弃，与 Maxwell 真机读写真实客体内存不同");

            if (Interlocked.Exchange(ref _drainScheduled, 1) == 0)
            {
                ThreadPool.UnsafeQueueUserWorkItem(static recorder => recorder.Drain(), this, preferLocal: false);
            }
        }

        private void Drain()
        {
            do
            {
                Volatile.Write(ref _drainScheduled, 0);

                while (_pendingLines.TryDequeue(out string line))
                {
                    Console.Error.WriteLine(line);
                }
            }
            while (!_pendingLines.IsEmpty && Interlocked.Exchange(ref _drainScheduled, 1) == 0);
        }

        public void Dispose()
        {
            lock (_lock)
            {
                foreach (BufferHolder page in _pages)
                {
                    page.Dispose();
                }

                _pages.Clear();
            }
        }
    }

    /// <summary>
    /// S2A（F1）：一个宿主程序的记录段。作为命令缓冲依赖登记（每个命令缓冲一次），栅栏完成回收时读计数并报红；
    /// 程序释放且没有命令缓冲再引用它时，段还给记录器。丢弃段（<see cref="S2AStorageOobRecorder.Discard"/>）不登记、不读回、不归还。
    /// </summary>
    sealed class S2AStorageOobRegion : IAuto
    {
        private readonly S2AStorageOobRecorder _recorder;
        private readonly nint _pointer;
        private readonly bool _isDiscard;
        private readonly BitMap _cbOwnership = new(CommandBufferPool.MaxCommandBuffers);
        private int _referenceCount = 1;
        private uint _lastCount;
        private int _detections;

        public int Index { get; }
        public Auto<DisposableBuffer> Buffer { get; }
        public int Offset { get; }
        public int Size { get; }

        internal S2AStorageOobRegion(S2AStorageOobRecorder recorder, int index, Auto<DisposableBuffer> buffer, int offset, int size, nint pointer, bool isDiscard)
        {
            _recorder = recorder;
            _isDiscard = isDiscard;
            Index = index;
            Buffer = buffer;
            Offset = offset;
            Size = size;
            _pointer = pointer;
        }

        /// <summary>程序在这个命令缓冲里用到时调用（描述符更新时）；每个命令缓冲只登记一次。</summary>
        public void Use(CommandBufferScoped cbs)
        {
            if (!_isDiscard && _cbOwnership.Set(cbs.CommandBufferIndex))
            {
                cbs.AddDependant(this);
                _recorder.RequestHostReadBarrier(cbs.CommandBufferIndex);
            }
        }

        public bool HasCommandBufferDependency(CommandBufferScoped cbs)
        {
            return _cbOwnership.IsSet(cbs.CommandBufferIndex);
        }

        public void IncrementReferenceCount()
        {
            Interlocked.Increment(ref _referenceCount);
        }

        public void DecrementReferenceCount(int cbIndex)
        {
            _cbOwnership.Clear(cbIndex);
            Check();
            DecrementReferenceCount();
        }

        public void DecrementReferenceCount()
        {
            if (Interlocked.Decrement(ref _referenceCount) == 0)
            {
                _recorder.Release(Index);
            }
        }

        /// <summary>程序释放时调用；之后由最后一个引用它的命令缓冲完成时归还。</summary>
        public void Release()
        {
            if (!_isDiscard)
            {
                DecrementReferenceCount();
            }
        }

        private unsafe void Check()
        {
            uint* words = (uint*)_pointer;
            uint count = Volatile.Read(ref words[S2AStorageOobRecord.WordCount]);

            if (count == _lastCount)
            {
                return;
            }

            // 首个越界的详情由同一次调用在计数之后写，最后写信息字；还没写完（那次调用所在的命令缓冲仍在执行）就等下次完成再读
            if ((Volatile.Read(ref words[S2AStorageOobRecord.WordInfo]) & S2AStorageOobRecord.InfoValid) == 0)
            {
                return;
            }

            Span<uint> snapshot = stackalloc uint[S2AStorageOobRecord.Words];

            for (int i = 0; i < snapshot.Length; i++)
            {
                snapshot[i] = Volatile.Read(ref words[i]);
            }

            uint delta = count - _lastCount;
            _lastCount = count;

            _recorder.Report(this, count, delta, ++_detections, snapshot);
        }
    }
}
