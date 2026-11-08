using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Gpu.Engine.Compute;
using Ryujinx.Graphics.Gpu.Engine.Dma;
using Ryujinx.Graphics.Gpu.Engine.InlineToMemory;
using Ryujinx.Graphics.Gpu.Engine.Threed;
using Ryujinx.Graphics.Gpu.Engine.Twod;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Gpu.Engine.GPFifo
{
    /// <summary>
    /// Represents a GPU General Purpose FIFO command processor.
    /// </summary>
    /// <summary>S2A：免解读缓存长段自适应的统计（收局日志读；GPFifoProcessor 是 internal）</summary>
    public static class S2ASegStats
    {
        /// <summary>长段总数、其中跳过哈希直接解读的数、进入跳过期的次数</summary>
        public static long LongTotal, LongSkipped, SkipRounds;
    }

    class GPFifoProcessor : IDisposable
    {
        private const int MacrosCount = 0x80;
        private const int MacroIndexMask = MacrosCount - 1;

        private const int LoadInlineDataMethodOffset = 0x6d;
        private const int UniformBufferUpdateDataMethodOffset = 0x8e4;

        private readonly GpuChannel _channel;

        /// <summary>
        /// Channel memory manager.
        /// </summary>
        public MemoryManager MemoryManager => _channel.MemoryManager;

        /// <summary>
        /// Channel texture manager.
        /// </summary>
        public TextureManager TextureManager => _channel.TextureManager;

        /// <summary>
        /// 3D Engine.
        /// </summary>
        public ThreedClass ThreedClass => _3dClass;

        /// <summary>
        /// Internal GPFIFO state.
        /// </summary>
        private struct DmaState
        {
            public int Method;
            public int SubChannel;
            public int MethodCount;
            public bool NonIncrementing;
            public bool IncrementOnce;
        }

        private DmaState _state;

        // ---- S2A：免解读缓存（命令流复用第 1 级）----
        // 解读（DMA 状态机 + 两条快路径的判断）只依赖段内容与段开始时的 _state，是纯函数：键 = 内容哈希 + 长度 + 起始 _state。
        // 第一次照常解读并把产生的操作按序记下（方法写入 / 内联数据整块 / 常量缓冲整块）与结束 _state；之后同键直接按记录调同样的 Send / LoadInlineData / ConstantBufferUpdate，
        // 参数值从本段的字里取（内容相同），GPU 地址按本段基址重算（同内容的段常在不同地址：命令环）。解读中抛异常的段不进缓存。
        private struct S2AOp
        {
            public byte Kind; // 0 方法写入（值取本段第 Index 个字），1 内联数据整块，2 常量缓冲整块，3 立即数方法写入（值在 Count）
            public bool IsLast;
            public int Index, Method, Sub, Count;
        }

        private struct S2ASeg
        {
            public int Len;
            public DmaState Start, End;
            public int OpStart, OpCount; // 操作序列在 _s2aOps（分块存储）里的全局位置
        }

        // 零分配（10-20 帧率能耗线：动森岛上稳态渲染线程分配的 96% 是录段时 new S2ASeg + ToArray，约每帧 14 段、每段 930 B）：
        // 段是值类型、字典按上限一次分配好；操作序列追加进一块预分配的环形区，区满或段数到上限整表清空（与原上限清空同义，旧区里的记录随之作废）。
        private const int S2ASegMinLen = 8, S2ASegCap = 32768, S2AArenaOps = 1 << 20; // 区 1M 条操作 ≈ 20 MB（原 ToArray 存满上限约 30 MB）
        // 按需增长（10-24 异度神剑3 真机 OOM）：原先每个 GPU 通道构造时一次分配整块区 + 32768 项字典，约 23 MB 进大对象堆；
        // 游戏开 10 个通道大对象堆即 190 MB，第 11 次开通道在构造函数里撞 OutOfMemoryException。改为用到才分配、翻倍增长到上限，
        // 只在热身期分配，到顶后与原来一样零分配；没用过的通道只占空表。
        // 分块存储（帧率能耗线 10-24）：上面按需「翻倍增长」每次 Array.Resize 都新分配并丢掉旧区，长到 52.4 万 / 104.9 万条时各新分配 10 / 20 MiB——
        //   丝之歌测试机2 MARK 后第 5900 / 6108 帧（相隔 208 帧，是区随入缓存的段增多分两次翻倍，不是单段录制）各新分配 10485784 / 20971544 B，
        //   占 MARK 后 60 秒托管分配 39.6 MB 的 31 MB，分配闸门红。改为 16 块 × 6.5 万条（每块 1.25 MiB），用到哪块才分配哪块，长大不拷贝、不产生垃圾；
        //   一段不跨块（段长上限 = 录制上限 = 一块），段的 OpStart 是全局位置（高位块号、低 16 位块内偏移）；满了照旧整表清空，块留着复用。没用过的通道只占块表（16 个引用）
        private const int S2AChunkOps = S2AOpChunks<S2AOp>.ChunkOps;
        private readonly Dictionary<ulong, S2ASeg> _s2aSegs = new();
        private readonly S2AOpChunks<S2AOp> _s2aOps = new(S2AArenaOps);
        private Span<S2AOp> S2AOps(int start, int count) => _s2aOps.Span(start, count);
        // S2A：两次准入——段第一次未命中只把键记进这张直接映射表（哈希高 16 位定位，64K 项、只分配一次），照常解读、不记录不入缓存；
        // 同一键再次未命中才记录入缓存。只出现一次的段（内联常量数据等）若每次都入缓存，旧库实测动森岛上 60 秒托管分配 468 MB（稳态的 97%）。
        private const int S2ASeenBits = 16;
        private ulong[] _s2aSeen;
        // S2A：记录用定长数组（帧率能耗线 10-24）。原先是可增长的 List<S2AOp>，单段操作越多越往上翻倍（操作多过区的段本来就不进缓存，白长）。
        //   改成定长 S2ARecCap 条（原生内存，第一次录段时才分配；不录段的通道零占用）：超了置溢出、这段不进缓存（核对时算不一致），录制期间零托管分配。超过 6.5 万条操作的段不再走免解读缓存（长段另有命中率自适应）
        private const int S2ARecCap = S2AChunkOps;   // 录制上限 = 一块：录下的段一定放得进一块
        private readonly S2AOpChunks<S2AOp> _s2aRecStore = new(S2ARecCap);
        private bool _s2aRecReady;
        private int _s2aRecN;
        private bool _s2aRecOn, _s2aRecOver;

        private static bool S2AStateEq(in DmaState a, in DmaState b) =>
            a.Method == b.Method && a.SubChannel == b.SubChannel && a.MethodCount == b.MethodCount && a.NonIncrementing == b.NonIncrementing && a.IncrementOnce == b.IncrementOnce;

        private static ulong S2AHash(ReadOnlySpan<int> words, in DmaState st)
        {
            ulong h = 0xcbf29ce484222325UL ^ (ulong)words.Length;
            h = (h ^ (uint)st.Method) * 0x100000001b3UL;
            h = (h ^ (uint)st.SubChannel) * 0x100000001b3UL;
            h = (h ^ (uint)st.MethodCount) * 0x100000001b3UL;
            h = (h ^ (st.NonIncrementing ? 1UL : 0) ^ (st.IncrementOnce ? 2UL : 0)) * 0x100000001b3UL;
            ReadOnlySpan<ulong> q = MemoryMarshal.Cast<int, ulong>(words);
            for (int i = 0; i < q.Length; i++)
            {
                h = (h ^ q[i]) * 0x100000001b3UL;
                h ^= h >> 29;
            }

            if ((words.Length & 1) != 0)
            {
                h = (h ^ (uint)words[^1]) * 0x100000001b3UL;
            }

            return h;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void S2ARecOp(byte kind, int index, int method, int sub, int count, bool isLast)
        {
            if (!_s2aRecOn) return;
            if (_s2aRecN < S2ARecCap) _s2aRecStore.Span(_s2aRecN++, 1)[0] = new S2AOp { Kind = kind, Index = index, Method = method, Sub = sub, Count = count, IsLast = isLast };
            else _s2aRecOver = true;
        }

        // S2A：等价核对（S2A_SEGCHECK=1，诊断）：命中时不回放，照常解读并重新记录，与缓存里的记录逐条比、结束状态比；不一致计数并打前 5 条。执行走原解读，结果本身不受影响
        private static readonly bool S2ASegCheck = Environment.GetEnvironmentVariable("S2A_SEGCHECK") == "1";

        // S2A：长段按实测命中率自适应。每段都要整段算哈希才能查缓存；长段（≥ S2ALongLen 个字）在有的游戏里几乎从不重复
        // （10-21 暗黑3：每帧 GPFIFO 约 3 MB，段内容与前 2 帧相同 0.0% 字节；Mac 采样 S2AHash 占 GPU 模拟线程忙时约 15%），整段哈希是白算。
        // 做法：完整处理一个测量窗口（S2ALongWin 个长段）计命中；命中率低于 1/8 就接下来 S2ALongSkip 个长段不算哈希、直接逐字解读（与不用缓存同语义），
        // 期满再量一窗。已入缓存的段跳过期间不清，能命中的游戏（动森等）测量窗口里照样命中、保持开启。短段照旧。S2A_SEG_ADAPT=0 关（恒算哈希）
        private const int S2ALongLen = 512, S2ALongWin = 256, S2ALongSkip = 2048;
        private static readonly bool S2ASegAdapt = Environment.GetEnvironmentVariable("S2A_SEG_ADAPT") != "0";
        private int _s2aLongTried, _s2aLongHit, _s2aLongSkipLeft;

        private static long _s2aCheckHits, _s2aCheckBad;
        private static readonly bool S2ASegCorrupt = Environment.GetEnvironmentVariable("S2A_SEGCHECK_CORRUPT") == "1";

        private void S2ACheckHit(ulong baseGpuVa, ReadOnlySpan<int> cb, in S2ASeg seg)
        {
            if (!_s2aRecReady) { _s2aRecStore.Reserve(S2ARecCap); _s2aRecReady = true; }   // 第一次录段才分配录制块
            _s2aRecN = 0; _s2aRecOver = false; _s2aRecOn = true;
            try
            {
                ProcessCore(baseGpuVa, cb);
            }
            finally
            {
                _s2aRecOn = false;
            }

            ReadOnlySpan<S2AOp> want = S2AOps(seg.OpStart, seg.OpCount), got = _s2aRecStore.Span(0, _s2aRecN);
            bool ok = !_s2aRecOver && want.Length == got.Length && S2AStateEq(seg.End, _state);
            for (int i = 0; ok && i < want.Length; i++)
            {
                ok = want[i].Kind == got[i].Kind && want[i].IsLast == got[i].IsLast && want[i].Index == got[i].Index && want[i].Method == got[i].Method && want[i].Sub == got[i].Sub && want[i].Count == got[i].Count;
            }

            _s2aCheckHits++;
            if (!ok && ++_s2aCheckBad <= 5)
            {
                Console.Error.WriteLine($"[段缓存] 【红】等价核对不一致：段长 {cb.Length}，记录 {want.Length} 条 / 重解 {got.Length} 条，区位 {seg.OpStart}");
            }

            if ((_s2aCheckHits & 0xffff) == 0)
            {
                Console.Error.WriteLine($"[段缓存] 等价核对：命中 {_s2aCheckHits}，不一致 {_s2aCheckBad}");
            }
        }

        private void S2AReplay(ulong baseGpuVa, ReadOnlySpan<int> cb, in S2ASeg seg)
        {
            ReadOnlySpan<S2AOp> ops = S2AOps(seg.OpStart, seg.OpCount);
            for (int i = 0; i < ops.Length; i++)
            {
                ref readonly S2AOp op = ref ops[i];
                switch (op.Kind)
                {
                    case 0:
                        Send(baseGpuVa + (ulong)op.Index * 4, op.Method, cb[op.Index], op.Sub, op.IsLast);
                        break;
                    case 3:
                        Send(baseGpuVa + (ulong)op.Index * 4, op.Method, op.Count, op.Sub, true);
                        break;
                    case 1:
                        ReadOnlySpan<int> data = cb.Slice(op.Index, op.Count);
                        if (op.Sub == 0)
                        {
                            _3dClass.LoadInlineData(data);
                        }
                        else if (op.Sub == 1)
                        {
                            _computeClass.LoadInlineData(data);
                        }
                        else
                        {
                            _i2mClass.LoadInlineData(data);
                        }

                        break;
                    case 2:
                        { long s2aCb0 = S2AAllocTrace.Begin(); _3dClass.ConstantBufferUpdate(cb.Slice(op.Index, op.Count)); S2AAllocTrace.End(0x30_0000, s2aCb0); } // S2A：渲染线程分配拆账
                        break;
                }
            }

            _state = seg.End;
            long s2aA0 = S2AAllocTrace.Begin(); // S2A：渲染线程分配拆账
            _3dClass.FlushUboDirty();
            S2AAllocTrace.End(0x30_0001, s2aA0);
        }

        private readonly ThreedClass _3dClass;
        private readonly ComputeClass _computeClass;
        private readonly InlineToMemoryClass _i2mClass;
        private readonly TwodClass _2dClass;
        private readonly DmaClass _dmaClass;

        private readonly GPFifoClass _fifoClass;

        /// <summary>
        /// Creates a new instance of the GPU General Purpose FIFO command processor.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="channel">Channel that the GPFIFO processor belongs to</param>
        public GPFifoProcessor(GpuContext context, GpuChannel channel)
        {
            _channel = channel;

            _fifoClass = new GPFifoClass(context, this);
            _3dClass = new ThreedClass(context, channel, _fifoClass);
            _computeClass = new ComputeClass(context, channel, _3dClass);
            _i2mClass = new InlineToMemoryClass(context, channel);
            _2dClass = new TwodClass(channel);
            _dmaClass = new DmaClass(context, channel, _3dClass);
        }

        /// <summary>
        /// Processes a command buffer.
        /// </summary>
        /// <param name="baseGpuVa">Base GPU virtual address of the command buffer</param>
        /// <param name="commandBuffer">Command buffer</param>
        public void Process(ulong baseGpuVa, ReadOnlySpan<int> commandBuffer)
        {
            if (commandBuffer.Length < S2ASegMinLen) // S2A：免解读缓存（短段直接解读）
            {
                ProcessCore(baseGpuVa, commandBuffer);
                return;
            }

            bool isLong = commandBuffer.Length >= S2ALongLen;
            if (isLong && S2ASegAdapt)
            {
                S2ASegStats.LongTotal++;
                if (_s2aLongSkipLeft > 0)
                {
                    _s2aLongSkipLeft--;
                    S2ASegStats.LongSkipped++;
                    ProcessCore(baseGpuVa, commandBuffer);
                    return;
                }

                if (++_s2aLongTried >= S2ALongWin)
                {
                    // 窗口满：命中率 < 1/8 进入跳过期
                    if (_s2aLongHit * 8 < _s2aLongTried)
                    {
                        _s2aLongSkipLeft = S2ALongSkip;
                        S2ASegStats.SkipRounds++;
                    }

                    _s2aLongTried = 0;
                    _s2aLongHit = 0;
                }
            }

            ulong key = S2AHash(commandBuffer, _state);
            DmaState start = _state;

            if (_s2aSegs.TryGetValue(key, out S2ASeg seg) && seg.Len == commandBuffer.Length && S2AStateEq(seg.Start, start))
            {
                if (isLong)
                {
                    _s2aLongHit++;
                }

                if (S2ASegCheck)
                {
                    S2ACheckHit(baseGpuVa, commandBuffer, in seg);
                    return;
                }

                S2AReplay(baseGpuVa, commandBuffer, in seg);
                return;
            }

            _s2aSeen ??= new ulong[1 << S2ASeenBits];
            ref ulong seen = ref _s2aSeen[(int)(key >> (64 - S2ASeenBits))];
            if (seen != key)
            {
                seen = key;
                ProcessCore(baseGpuVa, commandBuffer);
                return;
            }

            if (!_s2aRecReady) { _s2aRecStore.Reserve(S2ARecCap); _s2aRecReady = true; }   // 第一次录段才分配录制块
            _s2aRecN = 0; _s2aRecOver = false; _s2aRecOn = true;

            try
            {
                ProcessCore(baseGpuVa, commandBuffer);
            }
            finally
            {
                _s2aRecOn = false;
            }

            int nOps = _s2aRecN;
            if (_s2aRecOver || nOps > S2AArenaOps)
            {
                return; // 一段的操作多过录制上限 / 整块区：不进缓存（照常解读过了）
            }

            int opStart = _s2aOps.Reserve(nOps);   // 本块剩下的放不下就从下一块开头（一段不跨块）；区满回 -1
            if (_s2aSegs.Count >= S2ASegCap || opStart < 0)
            {
                _s2aOps.Clear();
                opStart = _s2aOps.Reserve(nOps);
                if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_0006, 1); // S2A：拆账诊断（清空次数）
                _s2aSegs.Clear();
            }


            if (S2AAllocTrace.On) S2AAllocTrace.Raw(_s2aSegs.ContainsKey(key) ? 0x40_0005 : 0x40_0007, 1); // S2A：拆账诊断（覆盖已有键 / 新键）

            long s2aR0 = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0; // S2A：渲染线程分配拆账（段）
            _s2aRecStore.Span(0, nOps).CopyTo(S2AOps(opStart, nOps));
            if (S2ASegCorrupt && nOps > 0) S2AOps(opStart, 1)[0].Index ^= 1; // S2A：核对器正对照（故意改坏记录）
            _s2aSegs[key] = new S2ASeg { Len = commandBuffer.Length, Start = start, End = _state, OpStart = opStart, OpCount = nOps };
            if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_0004, S2AAllocTrace.Now() - s2aR0);
        }

        /// <summary>
        /// S2A: 原 Process 主体（逐字解读），解读中顺带给免解读缓存记录操作。
        /// </summary>
        private void ProcessCore(ulong baseGpuVa, ReadOnlySpan<int> commandBuffer)
        {
            for (int index = 0; index < commandBuffer.Length; index++)
            {
                int command = commandBuffer[index];

                ulong gpuVa = baseGpuVa + (ulong)index * 4;

                if (_state.MethodCount != 0)
                {
                    if (TryFastI2mBufferUpdate(commandBuffer, ref index))
                    {
                        continue;
                    }

                    S2ARecOp(0, index, _state.Method, _state.SubChannel, 0, _state.MethodCount <= 1); // S2A：免解读缓存记录
                    Send(gpuVa, _state.Method, command, _state.SubChannel, _state.MethodCount <= 1);

                    if (!_state.NonIncrementing)
                    {
                        _state.Method++;
                    }

                    if (_state.IncrementOnce)
                    {
                        _state.NonIncrementing = true;
                    }

                    _state.MethodCount--;
                }
                else
                {
                    CompressedMethod meth = Unsafe.As<int, CompressedMethod>(ref command);

                    if (TryFastUniformBufferUpdate(meth, commandBuffer, index))
                    {
                        index += meth.MethodCount;
                        continue;
                    }

                    switch (meth.SecOp)
                    {
                        case SecOp.IncMethod:
                        case SecOp.NonIncMethod:
                        case SecOp.OneInc:
                            _state.Method = meth.MethodAddress;
                            _state.SubChannel = meth.MethodSubchannel;
                            _state.MethodCount = meth.MethodCount;
                            _state.IncrementOnce = meth.SecOp == SecOp.OneInc;
                            _state.NonIncrementing = meth.SecOp == SecOp.NonIncMethod;
                            break;
                        case SecOp.ImmdDataMethod:
                            S2ARecOp(3, index, meth.MethodAddress, meth.MethodSubchannel, meth.ImmdData, true); // S2A：立即数方法，值在 Count 里
                            Send(gpuVa, meth.MethodAddress, meth.ImmdData, meth.MethodSubchannel, true);
                            break;
                    }
                }
            }

            long s2aA0 = S2AAllocTrace.Begin(); // S2A：渲染线程分配拆账
            _3dClass.FlushUboDirty();
            S2AAllocTrace.End(0x30_0001, s2aA0);
        }

        /// <summary>
        /// Tries to perform a fast Inline-to-Memory data update.
        /// If successful, all data will be copied at once, and <see cref="DmaState.MethodCount"/>
        /// command buffer entries will be consumed.
        /// </summary>
        /// <param name="commandBuffer">Command buffer where the data is contained</param>
        /// <param name="offset">Offset at <paramref name="commandBuffer"/> where the data is located, auto-incremented on success</param>
        /// <returns>True if the fast copy was successful, false otherwise</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private bool TryFastI2mBufferUpdate(ReadOnlySpan<int> commandBuffer, ref int offset)
        {
            if (_state.Method == LoadInlineDataMethodOffset && _state.NonIncrementing && _state.SubChannel <= 2)
            {
                int availableCount = commandBuffer.Length - offset;
                int consumeCount = Math.Min(_state.MethodCount, availableCount);

                ReadOnlySpan<int> data = commandBuffer.Slice(offset, consumeCount);

                S2ARecOp(1, offset, 0, _state.SubChannel, consumeCount, false); // S2A：免解读缓存记录

                if (_state.SubChannel == 0)
                {
                    _3dClass.LoadInlineData(data);
                }
                else if (_state.SubChannel == 1)
                {
                    _computeClass.LoadInlineData(data);
                }
                else /* if (_state.SubChannel == 2) */
                {
                    _i2mClass.LoadInlineData(data);
                }

                offset += consumeCount - 1;
                _state.MethodCount -= consumeCount;

                return true;
            }

            return false;
        }

        /// <summary>
        /// Tries to perform a fast constant buffer data update.
        /// If successful, all data will be copied at once, and <see cref="CompressedMethod.MethodCount"/> + 1
        /// command buffer entries will be consumed.
        /// </summary>
        /// <param name="meth">Compressed method to be checked</param>
        /// <param name="commandBuffer">Command buffer where <paramref name="meth"/> is contained</param>
        /// <param name="offset">Offset at <paramref name="commandBuffer"/> where <paramref name="meth"/> is located</param>
        /// <returns>True if the fast copy was successful, false otherwise</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private bool TryFastUniformBufferUpdate(CompressedMethod meth, ReadOnlySpan<int> commandBuffer, int offset)
        {
            int availableCount = commandBuffer.Length - offset;

            if (meth.MethodAddress == UniformBufferUpdateDataMethodOffset &&
                meth.MethodCount < availableCount &&
                meth.SecOp == SecOp.NonIncMethod)
            {
                S2ARecOp(2, offset + 1, 0, 0, meth.MethodCount, false); // S2A：免解读缓存记录
                long s2aA0 = S2AAllocTrace.Begin(); _3dClass.ConstantBufferUpdate(commandBuffer.Slice(offset + 1, meth.MethodCount)); S2AAllocTrace.End(0x30_0000, s2aA0); // S2A：渲染线程分配拆账

                return true;
            }

            return false;
        }

        /// <summary>
        /// Sends a uncompressed method for processing by the graphics pipeline.
        /// </summary>
        /// <param name="gpuVa">GPU virtual address where the command word is located</param>
        /// <param name="meth">Method to be processed</param>
        private void Send(ulong gpuVa, int offset, int argument, int subChannel, bool isLastCall)
        {
            if (S2AAllocTrace.On) // S2A：渲染线程分配拆账
            {
                long a0 = S2AAllocTrace.Begin();
                try
                {
                    SendCore(gpuVa, offset, argument, subChannel, isLastCall);
                }
                finally
                {
                    S2AAllocTrace.End(offset >= 0xe00 ? 0x10_0000 | ((offset >> 1) & MacroIndexMask) : (subChannel << 16) | (offset * 4), a0);
                }

                return;
            }

            SendCore(gpuVa, offset, argument, subChannel, isLastCall);
        }

        private void SendCore(ulong gpuVa, int offset, int argument, int subChannel, bool isLastCall)
        {
            if (offset < 0x60)
            {
                _fifoClass.Write(offset * 4, argument);
            }
            else if (offset < 0xe00)
            {
                offset *= 4;

                switch (subChannel)
                {
                    case 0:
                        _3dClass.Write(offset, argument);
                        break;
                    case 1:
                        _computeClass.Write(offset, argument);
                        break;
                    case 2:
                        _i2mClass.Write(offset, argument);
                        break;
                    case 3:
                        _2dClass.Write(offset, argument);
                        break;
                    case 4:
                        _dmaClass.Write(offset, argument);
                        break;
                }
            }
            else
            {
                IDeviceState state = subChannel switch
                {
                    0 => _3dClass,
                    3 => _2dClass,
                    _ => null,
                };

                if (state != null)
                {
                    int macroIndex = (offset >> 1) & MacroIndexMask;

                    if ((offset & 1) != 0)
                    {
                        _fifoClass.MmePushArgument(macroIndex, gpuVa, argument);
                    }
                    else
                    {
                        _fifoClass.MmeStart(macroIndex, argument);
                    }

                    if (isLastCall)
                    {
                        _fifoClass.CallMme(macroIndex, state);

                        _3dClass.PerformDeferredDraws();
                    }
                }
            }
        }

        /// <summary>
        /// Writes data directly to the state of the specified class.
        /// </summary>
        /// <param name="classId">ID of the class to write the data into</param>
        /// <param name="offset">State offset in bytes</param>
        /// <param name="value">Value to be written</param>
        public void Write(ClassId classId, int offset, int value)
        {
            switch (classId)
            {
                case ClassId.Threed:
                    _3dClass.Write(offset, value);
                    break;
                case ClassId.Compute:
                    _computeClass.Write(offset, value);
                    break;
                case ClassId.InlineToMemory:
                    _i2mClass.Write(offset, value);
                    break;
                case ClassId.Twod:
                    _2dClass.Write(offset, value);
                    break;
                case ClassId.Dma:
                    _dmaClass.Write(offset, value);
                    break;
                case ClassId.GPFifo:
                    _fifoClass.Write(offset, value);
                    break;
            }
        }

        /// <summary>
        /// Sets the shadow ram control value of all sub-channels.
        /// </summary>
        /// <param name="control">New shadow ram control value</param>
        public void SetShadowRamControl(int control)
        {
            _3dClass.SetShadowRamControl(control);
        }

        /// <summary>
        /// Forces a full host state update by marking all state as modified,
        /// and also requests all GPU resources in use to be rebound.
        /// </summary>
        public void ForceAllDirty()
        {
            _3dClass.ForceStateDirty();
            _channel.BufferManager.Rebind();
            _channel.TextureManager.Rebind();
        }

        /// <summary>
        /// Perform any deferred draws.
        /// </summary>
        public void PerformDeferredDraws()
        {
            _3dClass.PerformDeferredDraws();
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _3dClass.Dispose();
            }
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }
    }
}
