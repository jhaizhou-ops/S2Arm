// GAL 调用流录像：录制端运行时（对象 / 缓冲稳定编号、帧窗口、到顶停录、窗口开录时的「状态重建序幕」）。
// 生成的 GalRecLayer.cs（RecordingRenderer / RecordingPipeline / GuardedWindow）在每个 GAL 调用处调这里。
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading;

namespace RyuJudge.GalRec
{
    /// <summary>对象方法的操作码（手写；GAL 接口方法的操作码见生成的 GalOps）。每条记录体第一个字段是 u32 对象编号。</summary>
    public static class ObjOps
    {
        public const uint CreateTextureScaled = 0x2F0;
        public const uint TexCopyTo1 = 0x300, TexCopyTo2 = 0x301, TexCopyTo3 = 0x302, TexCopyToBuffer = 0x303, TexCreateView = 0x304;
        public const uint TexGetData = 0x305, TexGetDataLayerLevel = 0x306, TexSetData = 0x307, TexSetDataLayerLevel = 0x308, TexSetDataRegion = 0x309;
        public const uint TexSetStorage = 0x30A, TexRelease = 0x30B;
        public const uint ProgCheckLink = 0x310, ProgGetBinary = 0x311, ProgDispose = 0x312;
        public const uint SamplerDispose = 0x318;
        public const uint CounterFlush = 0x320, CounterReserve = 0x321, CounterSetInvalid = 0x322, CounterDispose = 0x323;
        public const uint ArrSetSamplers = 0x328, ArrSetTextures = 0x329, ArrSetImages = 0x32A, ArrDispose = 0x32B;

        public static readonly Dictionary<uint, string> Names = new()
        {
            [CreateTextureScaled] = "IRenderer.CreateTexture(TextureCreateInfo,float)",
            [TexCopyTo1] = "ITexture.CopyTo(ITexture,int,int)", [TexCopyTo2] = "ITexture.CopyTo(ITexture,int,int,int,int)",
            [TexCopyTo3] = "ITexture.CopyTo(ITexture,Extents2D,Extents2D,bool)", [TexCopyToBuffer] = "ITexture.CopyTo(BufferRange,int,int,int)",
            [TexCreateView] = "ITexture.CreateView", [TexGetData] = "ITexture.GetData()", [TexGetDataLayerLevel] = "ITexture.GetData(int,int)",
            [TexSetData] = "ITexture.SetData(data)", [TexSetDataLayerLevel] = "ITexture.SetData(data,int,int)", [TexSetDataRegion] = "ITexture.SetData(data,int,int,Rectangle)",
            [TexSetStorage] = "ITexture.SetStorage", [TexRelease] = "ITexture.Release",
            [ProgCheckLink] = "IProgram.CheckProgramLink", [ProgGetBinary] = "IProgram.GetBinary", [ProgDispose] = "IProgram.Dispose",
            [SamplerDispose] = "ISampler.Dispose",
            [CounterFlush] = "ICounterEvent.Flush", [CounterReserve] = "ICounterEvent.ReserveForHostAccess", [CounterSetInvalid] = "ICounterEvent.Invalid=", [CounterDispose] = "ICounterEvent.Dispose",
            [ArrSetSamplers] = "ITextureArray.SetSamplers", [ArrSetTextures] = "ITextureArray.SetTextures", [ArrSetImages] = "IImageArray.SetImages", [ArrDispose] = "I*Array.Dispose",
            [GalRecFormat.OpFrame] = "FRAME", [GalRecFormat.OpPrologueBegin] = "PROLOGUE_BEGIN", [GalRecFormat.OpPrologueEnd] = "PROLOGUE_END",
            [GalRecFormat.OpCounterResult] = "COUNTER_RESULT", [GalRecFormat.OpStop] = "STOP", [GalRecFormat.OpNote] = "NOTE",
        };
    }

    public interface IRecObj
    {
        uint Id { get; }
    }

    public sealed class GalRecorder : IDisposable
    {
        readonly Stream _f; // S2A：只算哈希模式下为 Stream.Null
        readonly long _maxBytes;
        readonly Func<bool> _inWindow;
        public long Bytes, Records, PrologueRecords, Prologues;
        public bool Stopped;
        bool _wasRecording;
        uint _nextId = 1;
        readonly object _lk = new(); // 多线程后端下录制调用可能来自渲染线程与客体线程（后台回写），全部串行
        ulong _nextBuf = 1;
        internal IRenderer Inner;

        sealed class Live
        {
            public uint Op;
            public byte[] Payload;
            public object Obj;
            public bool IsView;
        }

        readonly SortedDictionary<uint, Live> _live = new();
        readonly Dictionary<ulong, (BufferHandle inner, int size)> _bufs = new();
        readonly SortedDictionary<ulong, (uint op, byte[] payload)> _bufCreate = new();
        readonly Dictionary<(uint op, ulong key), (long seq, byte[] payload)> _state = new();
        readonly Dictionary<(uint id, int index, uint op), (long seq, byte[] payload)> _arrays = new();
        long _seq;

        // ---- 当前管线状态影子（开窗序幕末尾补齐用）----
        // 「设状态」调用分三种：
        //  · 整值型（SetDepthTest / SetProgram / SetRenderTargets …）：一次调用就是完整状态 → _state 按 (操作码, 前导下标字节) 记最后一次；
        //  · 按绑定号增量型（SetUniformBuffers / SetStorageBuffers）：Gpu 层每次只传变了的绑定（例：支持缓冲只在建缓冲时绑一次绑定 0），
        //    只记最后一次整组调用会丢掉早先设过、之后没再动的绑定 → _binds 按 (操作码, 绑定号) 逐条记；
        //  · 按下标数组型（SetScissors / SetViewports / SetRenderTargetColorMasks / SetVertexAttribs / SetVertexBuffers / SetTransformFeedbackBuffers）：
        //    渲染器对「比上次短的数组」可能只改前 N 个、也可能把个数一起改 → _spans 记逐下标最后值（合并数组）+ 最后一次原样调用，
        //    序幕先写合并数组再写最后一次，两种语义下结果都等于录制端当前状态。
        readonly Dictionary<(uint op, int binding), (long seq, BufferAssignment a)> _binds = new();
        readonly Dictionary<uint, SpanShadow> _spans = new();

        sealed class SpanShadow
        {
            public long Seq;
            public int ElemSize;
            public byte[] Merged = Array.Empty<byte>();
            public byte[] Last;
            public int LastCount;
        }

        /// <summary>回归对照用：真 = 旧行为（增量 / 数组型也只记最后一次整组调用、序幕按发生先后写），只给 --galrec-legacy-state 用。</summary>
        public static bool LegacyState;

        public long PrologueBytes, PrologueStateRecords, PrologueStateBytes;

        /// <param name="path">录像文件</param>
        /// <param name="maxBytes">字节上限，到顶写 STOP 并停录</param>
        /// <param name="inWindow">当前是否在录制窗口内（复用裁判的帧窗口：S2A_GALREC_FRAMES 或 SetJudgeWindow）</param>
        /// <param name="opNames">操作码 → 名字表，写进文件头，读端核对</param>
        /// <param name="caps">录制时交给 Gpu 层的能力表（Gpu 层按它特化着色器、选转换路径；回放端能力表不同就拒放）</param>
        public GalRecorder(string path, long maxBytes, Func<bool> inWindow, IReadOnlyDictionary<uint, string> opNames, Capabilities caps)
        {
            _f = HashOnly ? Stream.Null : new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20); // S2A：只算哈希时不建文件
            _maxBytes = maxBytes;
            _inWindow = inWindow;
            ArrayBufferWriter<byte> h = new();
            W.U64(h, GalRecFormat.Magic);
            W.U32(h, GalRecFormat.Version);
            W.Str(h, GalOps.SignatureHash);
            W.Bytes(h, CapsIO.Bytes(caps));
            W.U32(h, (uint)opNames.Count);
            foreach ((uint op, string name) in opNames)
            {
                W.U32(h, op);
                W.Str(h, name);
            }

            _f.Write(h.WrittenSpan);
            Bytes = h.WrittenCount;
        }

        // ---------------- 编号 ----------------
        public uint NewId() => Interlocked.Increment(ref _nextId) - 1;

        static ulong Raw(BufferHandle h) => Unsafe.As<BufferHandle, ulong>(ref h);
        static BufferHandle Handle(ulong v) => Unsafe.As<ulong, BufferHandle>(ref v);

        public BufferHandle NewBuffer(BufferHandle inner, int size, uint op, ArrayBufferWriter<byte> payloadNoRet)
        {
            lock (_lk)
            {
                ulong id = _nextBuf++;
                _bufs[id] = (inner, size);
                W.U64(payloadNoRet, id);
                _bufCreate[id] = (op, payloadNoRet.WrittenSpan.ToArray());
                return Handle(id);
            }
        }

        public void DeleteBuffer(BufferHandle h)
        {
            lock (_lk)
            {
                _bufs.Remove(Raw(h));
                _bufCreate.Remove(Raw(h));
            }
        }

        public BufferHandle In(BufferHandle h)
        {
            lock (_lk) return _bufs.TryGetValue(Raw(h), out (BufferHandle inner, int size) b) ? b.inner : h;
        }
        public BufferRange In(BufferRange r) => new(In(r.Handle), r.Offset, r.Size, r.Write);

        public BufferRange[] In(ReadOnlySpan<BufferRange> s)
        {
            BufferRange[] a = new BufferRange[s.Length];
            for (int i = 0; i < s.Length; i++) a[i] = In(s[i]);
            return a;
        }

        public BufferAssignment[] In(ReadOnlySpan<BufferAssignment> s)
        {
            BufferAssignment[] a = new BufferAssignment[s.Length];
            for (int i = 0; i < s.Length; i++) a[i] = new BufferAssignment(s[i].Binding, In(s[i].Range));
            return a;
        }

        public VertexBufferDescriptor[] In(ReadOnlySpan<VertexBufferDescriptor> s)
        {
            VertexBufferDescriptor[] a = new VertexBufferDescriptor[s.Length];
            for (int i = 0; i < s.Length; i++) a[i] = new VertexBufferDescriptor(In(s[i].Buffer), s[i].Stride, s[i].Divisor);
            return a;
        }

        public static int SumSize(ReadOnlySpan<BufferRange> s)
        {
            int n = 0;
            foreach (BufferRange r in s) n += r.Size;
            return n;
        }

        public static uint IdOf(object o) => o is IRecObj r ? r.Id : 0;

        public static ITexture U(ITexture t) => t is RecTexture r ? r.Inner : t;
        public static ISampler U(ISampler t) => t is RecSampler r ? r.Inner : t;
        public static IProgram U(IProgram t) => t is RecProgram r ? r.Inner : t;
        public static ICounterEvent U(ICounterEvent t) => t is RecCounter r ? r.Inner : t;
        public static ITextureArray U(ITextureArray t) => t is RecArray r ? r.InnerT : t;
        public static IImageArray U(IImageArray t) => t is RecArray r ? r.InnerI : t;

        public static ITexture[] U(ReadOnlySpan<ITexture> s)
        {
            ITexture[] a = new ITexture[s.Length];
            for (int i = 0; i < s.Length; i++) a[i] = U(s[i]);
            return a;
        }

        public static ISampler[] U(ISampler[] s)
        {
            if (s == null) return null;
            ISampler[] a = new ISampler[s.Length];
            for (int i = 0; i < s.Length; i++) a[i] = U(s[i]);
            return a;
        }

        public static void Ids(IBufferWriter<byte> w, ReadOnlySpan<ITexture> s)
        {
            W.U32(w, (uint)s.Length);
            foreach (ITexture t in s) W.U32(w, IdOf(t));
        }

        public static void Ids(IBufferWriter<byte> w, ISampler[] s)
        {
            W.U32(w, (uint)(s?.Length ?? 0));
            if (s != null) foreach (ISampler t in s) W.U32(w, IdOf(t));
        }

        // ---------------- 对象登记 ----------------
        public T Register<T>(T wrapper, uint op, ArrayBufferWriter<byte> payloadWithRet, bool isView = false) where T : IRecObj
        {
            lock (_lk)
            {
                _live[wrapper.Id] = new Live { Op = op, Payload = payloadWithRet.WrittenSpan.ToArray(), Obj = wrapper, IsView = isView };
                return wrapper;
            }
        }

        public void Unregister(uint id)
        {
            lock (_lk)
            {
                _live.Remove(id);
                List<(uint, int, uint)> dead = new();
                foreach ((uint id, int index, uint op) k in _arrays.Keys) if (k.id == id) dead.Add(k);
                foreach ((uint, int, uint) k in dead) _arrays.Remove(k);
            }
        }

        // ---------------- 记录 ----------------
        /// <summary>
        /// 开始一条记录。先做「是否进了录制窗口」的判定（进窗口时写序幕）——必须在本次调用登记新对象之前，
        /// 否则序幕会把正在创建的对象也重建一次（回放端同一编号建两遍）。
        /// </summary>
        public ArrayBufferWriter<byte> Begin()
        {
            lock (_lk)
            {
                Recording();
                return new ArrayBufferWriter<byte>(64);
            }
        }

        bool Recording()
        {
            bool rec = !Stopped && _inWindow();
            if (rec && !_wasRecording)
            {
                _wasRecording = true;
                WritePrologue();
            }
            else if (!rec)
            {
                _wasRecording = false;
            }

            return rec && !Stopped;
        }

        /// <summary>只算哈希、不写文件（命令流复用第 2 级统计 S2A_SEG_STATS=1）：每条记录的操作码与参数（对象为稳定编号）累加进 SegHash，Gpu 层按段清零 / 读取。</summary>
        public static bool HashOnly;
        public static ulong SegHash;

        void WriteRaw(uint op, ReadOnlySpan<byte> payload)
        {
            if (HashOnly)
            {
                ulong h = (SegHash ^ op) * 0x100000001b3UL;
                for (int i = 0; i < payload.Length; i++) h = (h ^ payload[i]) * 0x100000001b3UL;
                SegHash = h;
                return;
            }

            if (Stopped)
            {
                return;
            }

            if (_maxBytes > 0 && Bytes + 8 + payload.Length > _maxBytes)
            {
                Stopped = true;
                Span<byte> s = stackalloc byte[16];
                BitConverter.TryWriteBytes(s, GalRecFormat.OpStop);
                BitConverter.TryWriteBytes(s[4..], 8u);
                BitConverter.TryWriteBytes(s[8..], (ulong)Bytes);
                _f.Write(s);
                _f.Flush();
                return;
            }

            Span<byte> hdr = stackalloc byte[8];
            BitConverter.TryWriteBytes(hdr, op);
            BitConverter.TryWriteBytes(hdr[4..], (uint)payload.Length);
            _f.Write(hdr);
            _f.Write(payload);
            Bytes += 8 + payload.Length;
            Records++;
        }

        /// <summary>写一条记录。stateKeyBytes ≥ 0 表示这是管线 / 窗口「设状态」调用：按 (操作码, 前 stateKeyBytes 字节) 记住最后一次，供窗口开录时重建。</summary>
        public void Emit(uint op, ArrayBufferWriter<byte> p, int stateKeyBytes = -1)
        {
            lock (_lk)
            {
                if (stateKeyBytes >= 0)
                {
                    ReadOnlySpan<byte> b = p.WrittenSpan;
                    ulong key = 0;
                    for (int i = 0; i < Math.Min(stateKeyBytes, Math.Min(8, b.Length)); i++) key |= (ulong)b[i] << (8 * i);
                    _state[(op, key)] = (_seq++, b.ToArray());
                }

                if (Recording())
                {
                    WriteRaw(op, p.WrittenSpan);
                }
            }
        }

        /// <summary>SetUniformBuffers / SetStorageBuffers：按绑定号逐条更新影子（payload 里的缓冲是录像编号）。</summary>
        public void EmitBindings(uint op, ArrayBufferWriter<byte> p, ReadOnlySpan<BufferAssignment> s)
        {
            lock (_lk)
            {
                long seq = _seq++;
                foreach (BufferAssignment a in s) _binds[(op, a.Binding)] = (seq, a);
                if (LegacyState) _state[(op, 0)] = (seq, p.WrittenSpan.ToArray());
                if (Recording())
                {
                    WriteRaw(op, p.WrittenSpan);
                }
            }
        }

        /// <summary>按下标数组型设状态：逐下标合并 + 记最后一次原样调用。</summary>
        public void EmitSpan<T>(uint op, ArrayBufferWriter<byte> p, ReadOnlySpan<T> s) where T : unmanaged
        {
            lock (_lk)
            {
                long seq = _seq++;
                if (!_spans.TryGetValue(op, out SpanShadow sh)) _spans[op] = sh = new SpanShadow { ElemSize = Unsafe.SizeOf<T>() };
                ReadOnlySpan<byte> b = System.Runtime.InteropServices.MemoryMarshal.AsBytes(s);
                if (b.Length > sh.Merged.Length) Array.Resize(ref sh.Merged, b.Length);
                b.CopyTo(sh.Merged);
                sh.Seq = seq;
                sh.Last = p.WrittenSpan.ToArray();
                sh.LastCount = s.Length;
                if (LegacyState) _state[(op, 0)] = (seq, sh.Last);
                if (Recording())
                {
                    WriteRaw(op, p.WrittenSpan);
                }
            }
        }

        /// <summary>序幕里状态的依赖顺序：程序 → 渲染目标 → 固定功能 → 顶点输入 → 缓冲绑定 → 贴图 / 图像 → 窗口。同类按发生先后。</summary>
        static int StateRank(uint op) => op switch
        {
            GalOps.IPipeline_SetProgram => 0,
            GalOps.IPipeline_SetRenderTargets => 1,
            GalOps.IPipeline_SetVertexAttribs or GalOps.IPipeline_SetVertexBuffers or GalOps.IPipeline_SetIndexBuffer => 3,
            GalOps.IPipeline_SetUniformBuffers or GalOps.IPipeline_SetStorageBuffers or GalOps.IPipeline_SetTransformFeedbackBuffers => 4,
            GalOps.IPipeline_SetTextureAndSampler or GalOps.IPipeline_SetImage or GalOps.IPipeline_SetImageArray or GalOps.IPipeline_SetImageArraySeparate
                or GalOps.IPipeline_SetTextureArray or GalOps.IPipeline_SetTextureArraySeparate => 5,
            >= 0x201 and < 0x300 => 6,
            _ => 2,
        };

        /// <summary>数组内容（按 数组编号 + 下标）记住最后一次，供重建。</summary>
        public void EmitArray(uint op, uint id, int index, ArrayBufferWriter<byte> p)
        {
            lock (_lk)
            {
                _arrays[(id, index, op)] = (_seq++, p.WrittenSpan.ToArray());
                if (Recording())
                {
                    WriteRaw(op, p.WrittenSpan);
                }
            }
        }

        public void Frame(ulong frame)
        {
            lock (_lk)
            {
                ArrayBufferWriter<byte> p = Begin();
                W.U64(p, frame);
                if (Recording())
                {
                    WriteRaw(GalRecFormat.OpFrame, p.WrittenSpan);
                }
            }
        }

        public void Note(string text)
        {
            lock (_lk)
            {
                ArrayBufferWriter<byte> p = Begin();
                W.Str(p, text);
                if (Recording())
                {
                    WriteRaw(GalRecFormat.OpNote, p.WrittenSpan);
                }
            }
        }

        public void CounterResult(uint id, ulong value)
        {
            lock (_lk)
            {
                ArrayBufferWriter<byte> p = Begin();
                W.U32(p, id);
                W.U64(p, value);
                if (Recording())
                {
                    WriteRaw(GalRecFormat.OpCounterResult, p.WrittenSpan);
                }
            }
        }

        /// <summary>
        /// 窗口开录序幕：按编号重建所有活着的缓冲 / 对象（原创建记录），再把缓冲 / 非视图贴图的当前内容从渲染器读回写成 SetData，
        /// 再写数组内容与「设状态」调用的最后一次值（按发生先后）。
        /// </summary>
        void WritePrologue()
        {
            Prologues++;
            long before = Records, bytesBefore = Bytes;
            WriteRaw(GalRecFormat.OpPrologueBegin, ReadOnlySpan<byte>.Empty);

            foreach ((ulong id, (uint op, byte[] payload)) in _bufCreate)
            {
                WriteRaw(op, payload);
            }

            foreach ((uint id, Live l) in _live)
            {
                WriteRaw(l.Op, l.Payload);
            }

            // 内容：缓冲
            foreach ((ulong id, (BufferHandle inner, int size)) in _bufs)
            {
                if (size <= 0 || Inner == null) continue;
                try
                {
                    using PinnedSpan<byte> d = Inner.GetBufferData(inner, 0, size);
                    ArrayBufferWriter<byte> p = Begin();
                    W.U64(p, id);
                    W.I32(p, 0);
                    W.Bytes(p, d.Get());
                    WriteRaw(GalOps.IRenderer_SetBufferData, p.WrittenSpan);
                }
                catch (Exception)
                {
                }
            }

            // 内容：非视图贴图
            foreach ((uint id, Live l) in _live)
            {
                if (l.IsView || l.Obj is not RecTexture t) continue;
                try
                {
                    using PinnedSpan<byte> d = t.Inner.GetData();
                    ArrayBufferWriter<byte> p = Begin();
                    W.U32(p, id);
                    W.Bytes(p, d.Get());
                    WriteRaw(ObjOps.TexSetData, p.WrittenSpan);
                }
                catch (Exception)
                {
                }
            }

            // 数组内容（资源内容的一部分，排在所有状态之前）
            List<(long seq, uint op, byte[] payload)> arr = new();
            foreach (((uint id, int index, uint op) k, (long seq, byte[] payload) v) in _arrays) if (_live.ContainsKey(k.id)) arr.Add((v.seq, k.op, v.payload));
            arr.Sort((a, b) => a.seq.CompareTo(b.seq));
            foreach ((long _, uint op, byte[] payload) in arr)
            {
                WriteRaw(op, payload);
            }

            // 当前管线 / 窗口状态影子
            long r0 = Records, b0 = Bytes;
            List<(int rank, long seq, int sub, uint op, byte[] payload)> st = new();
            if (LegacyState)
            {
                foreach (((uint op, ulong key) k, (long seq, byte[] payload) v) in _state) st.Add((0, v.seq, 0, k.op, v.payload));
            }
            else
            {
                foreach (((uint op, ulong key) k, (long seq, byte[] payload) v) in _state) st.Add((StateRank(k.op), v.seq, 0, k.op, v.payload));
                // 增量绑定：每个操作码合成一次调用，含全部当前绑定（按绑定号升序；指向已删缓冲的不写，录制端那个绑定已悬空，回放会计缺引用）
                Dictionary<uint, List<(int binding, long seq, BufferAssignment a)>> byOp = new();
                foreach (((uint op, int binding) k, (long seq, BufferAssignment a) v) in _binds)
                {
                    if (Raw(v.a.Range.Handle) != 0 && !_bufs.ContainsKey(Raw(v.a.Range.Handle))) continue;
                    if (!byOp.TryGetValue(k.op, out var l)) byOp[k.op] = l = new();
                    l.Add((k.binding, v.seq, v.a));
                }

                foreach ((uint op, var l) in byOp)
                {
                    l.Sort((a, b) => a.binding.CompareTo(b.binding));
                    BufferAssignment[] a = new BufferAssignment[l.Count];
                    long seq = 0;
                    for (int i = 0; i < l.Count; i++) { a[i] = l[i].a; seq = Math.Max(seq, l[i].seq); }
                    ArrayBufferWriter<byte> p = new(16 + a.Length * Unsafe.SizeOf<BufferAssignment>());
                    W.Span<BufferAssignment>(p, a);
                    st.Add((StateRank(op), seq, 0, op, p.WrittenSpan.ToArray()));
                }

                // 数组型：合并数组比最后一次长时先写合并数组，再写最后一次原样调用
                foreach ((uint op, SpanShadow sh) in _spans)
                {
                    int mergedCount = sh.ElemSize == 0 ? 0 : sh.Merged.Length / sh.ElemSize;
                    if (mergedCount > sh.LastCount)
                    {
                        ArrayBufferWriter<byte> p = new(4 + sh.Merged.Length);
                        W.U32(p, (uint)mergedCount); // 同 W.Span 的格式：个数 + 元素原始字节
                        sh.Merged.CopyTo(p.GetSpan(sh.Merged.Length));
                        p.Advance(sh.Merged.Length);
                        st.Add((StateRank(op), sh.Seq, 0, op, p.WrittenSpan.ToArray()));
                    }

                    st.Add((StateRank(op), sh.Seq, 1, op, sh.Last));
                }
            }

            st.Sort((a, b) => a.rank != b.rank ? a.rank.CompareTo(b.rank) : a.seq != b.seq ? a.seq.CompareTo(b.seq) : a.sub.CompareTo(b.sub));
            foreach ((int _, long _, int _, uint op, byte[] payload) in st)
            {
                WriteRaw(op, payload);
            }

            PrologueStateRecords += Records - r0;
            PrologueStateBytes += Bytes - b0;
            WriteRaw(GalRecFormat.OpPrologueEnd, ReadOnlySpan<byte>.Empty);
            PrologueRecords += Records - before;
            PrologueBytes += Bytes - bytesBefore;
        }

        public void Flush()
        {
            lock (_lk) _f.Flush();
        }

        // ---- 帧标记走渲染命令流（多线程渲染后端下录像器在渲染线程上，帧号必须与命令同序）----
        readonly System.Collections.Concurrent.ConcurrentQueue<ulong> _pendingFrames = new();
        /// <summary>录像器看到的当前帧（随 PreFrame 命令推进；帧窗口按它判）。</summary>
        public ulong CurrentFrame;
        public bool HaveFrame;

        /// <summary>GPU 线程：帧号变了，排一个帧号，随后调 IRenderer.PreFrame（经多线程后端与命令同序到达录像层）。</summary>
        public void QueueFrame(ulong frame) => _pendingFrames.Enqueue(frame);

        /// <summary>录像层收到 PreFrame：取出排队的帧号，推进当前帧并写 FRAME 记录。</summary>
        public void PreFrameMark()
        {
            if (_pendingFrames.TryDequeue(out ulong f))
            {
                lock (_lk)
                {
                    CurrentFrame = f;
                    HaveFrame = true;
                }

                Frame(f);
            }
        }

        public void Dispose()
        {
            lock (_lk)
            {
                _f.Flush();
                _f.Dispose();
            }
        }
    }

    // ================= 对象包装：编号 + 记录对象方法调用 =================
    public sealed class RecTexture : ITexture, IRecObj
    {
        public readonly ITexture Inner;
        readonly GalRecorder _r;
        public uint Id { get; }
        public RecTexture(GalRecorder r, ITexture inner, uint id) { _r = r; Inner = inner; Id = id; }
        public int Width => Inner.Width;
        public int Height => Inner.Height;

        ArrayBufferWriter<byte> P() { ArrayBufferWriter<byte> p = new(64); W.U32(p, Id); return p; }

        public void CopyTo(ITexture destination, int firstLayer, int firstLevel)
        {
            var p = P(); W.U32(p, GalRecorder.IdOf(destination)); W.I32(p, firstLayer); W.I32(p, firstLevel); _r.Emit(ObjOps.TexCopyTo1, p);
            Inner.CopyTo(GalRecorder.U(destination), firstLayer, firstLevel);
        }

        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel)
        {
            var p = P(); W.U32(p, GalRecorder.IdOf(destination)); W.I32(p, srcLayer); W.I32(p, dstLayer); W.I32(p, srcLevel); W.I32(p, dstLevel); _r.Emit(ObjOps.TexCopyTo2, p);
            Inner.CopyTo(GalRecorder.U(destination), srcLayer, dstLayer, srcLevel, dstLevel);
        }

        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter)
        {
            var p = P(); W.U32(p, GalRecorder.IdOf(destination)); W.Blit(p, srcRegion); W.Blit(p, dstRegion); W.Bool(p, linearFilter); _r.Emit(ObjOps.TexCopyTo3, p);
            Inner.CopyTo(GalRecorder.U(destination), srcRegion, dstRegion, linearFilter);
        }

        public void CopyTo(BufferRange range, int layer, int level, int stride)
        {
            var p = P(); W.Blit(p, range); W.I32(p, layer); W.I32(p, level); W.I32(p, stride); _r.Emit(ObjOps.TexCopyToBuffer, p);
            Inner.CopyTo(_r.In(range), layer, level, stride);
        }

        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel)
        {
            var p = P(); W.Blit(p, info); W.I32(p, firstLayer); W.I32(p, firstLevel);
            ITexture v = Inner.CreateView(info, firstLayer, firstLevel);
            uint id = _r.NewId();
            W.U32(p, id);
            RecTexture t = new(_r, v, id);
            _r.Register(t, ObjOps.TexCreateView, p, isView: true);
            _r.Emit(ObjOps.TexCreateView, p);
            return t;
        }

        public PinnedSpan<byte> GetData()
        {
            var p = P();
            PinnedSpan<byte> d = Inner.GetData();
            W.Digest(p, d.Get());
            _r.Emit(ObjOps.TexGetData, p);
            return d;
        }

        public PinnedSpan<byte> GetData(int layer, int level)
        {
            var p = P(); W.I32(p, layer); W.I32(p, level);
            PinnedSpan<byte> d = Inner.GetData(layer, level);
            W.Digest(p, d.Get());
            _r.Emit(ObjOps.TexGetDataLayerLevel, p);
            return d;
        }

        public void SetData(MemoryOwner<byte> data)
        {
            var p = P(); W.Bytes(p, data.Span); _r.Emit(ObjOps.TexSetData, p);
            Inner.SetData(data);
        }

        public void SetData(MemoryOwner<byte> data, int layer, int level)
        {
            var p = P(); W.Bytes(p, data.Span); W.I32(p, layer); W.I32(p, level); _r.Emit(ObjOps.TexSetDataLayerLevel, p);
            Inner.SetData(data, layer, level);
        }

        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region)
        {
            var p = P(); W.Bytes(p, data.Span); W.I32(p, layer); W.I32(p, level); W.Blit(p, region); _r.Emit(ObjOps.TexSetDataRegion, p);
            Inner.SetData(data, layer, level, region);
        }

        public void SetStorage(BufferRange buffer)
        {
            var p = P(); W.Blit(p, buffer); _r.Emit(ObjOps.TexSetStorage, p);
            Inner.SetStorage(_r.In(buffer));
        }

        public void Release()
        {
            var p = P(); _r.Emit(ObjOps.TexRelease, p);
            _r.Unregister(Id);
            Inner.Release();
        }
    }

    public sealed class RecSampler : ISampler, IRecObj
    {
        public readonly ISampler Inner;
        readonly GalRecorder _r;
        public uint Id { get; }
        public RecSampler(GalRecorder r, ISampler inner, uint id) { _r = r; Inner = inner; Id = id; }

        public void Dispose()
        {
            var p = _r.Begin(); W.U32(p, Id); _r.Emit(ObjOps.SamplerDispose, p);
            _r.Unregister(Id);
            Inner?.Dispose();
        }
    }

    public sealed class RecProgram : IProgram, IRecObj
    {
        public readonly IProgram Inner;
        readonly GalRecorder _r;
        public uint Id { get; }
        public RecProgram(GalRecorder r, IProgram inner, uint id) { _r = r; Inner = inner; Id = id; }

        public ProgramLinkStatus CheckProgramLink(bool blocking)
        {
            var p = _r.Begin(); W.U32(p, Id); W.Bool(p, blocking);
            ProgramLinkStatus s = Inner.CheckProgramLink(blocking);
            W.I32(p, (int)s);
            _r.Emit(ObjOps.ProgCheckLink, p);
            return s;
        }

        public byte[] GetBinary()
        {
            var p = _r.Begin(); W.U32(p, Id);
            byte[] b = Inner.GetBinary();
            W.Digest(p, b ?? Array.Empty<byte>());
            _r.Emit(ObjOps.ProgGetBinary, p);
            return b;
        }

        public void Dispose()
        {
            var p = _r.Begin(); W.U32(p, Id); _r.Emit(ObjOps.ProgDispose, p);
            _r.Unregister(Id);
            Inner?.Dispose();
        }
    }

    public sealed class RecCounter : ICounterEvent, IRecObj
    {
        public readonly ICounterEvent Inner;
        readonly GalRecorder _r;
        public uint Id { get; }
        public RecCounter(GalRecorder r, ICounterEvent inner, uint id) { _r = r; Inner = inner; Id = id; }

        public bool Invalid
        {
            get => Inner?.Invalid ?? false;
            set
            {
                var p = _r.Begin(); W.U32(p, Id); W.Bool(p, value); _r.Emit(ObjOps.CounterSetInvalid, p);
                if (Inner != null) Inner.Invalid = value;
            }
        }

        public bool ReserveForHostAccess()
        {
            var p = _r.Begin(); W.U32(p, Id);
            bool b = Inner?.ReserveForHostAccess() ?? false;
            W.Bool(p, b);
            _r.Emit(ObjOps.CounterReserve, p);
            return b;
        }

        public void Flush()
        {
            var p = _r.Begin(); W.U32(p, Id); _r.Emit(ObjOps.CounterFlush, p);
            Inner?.Flush();
        }

        public void Dispose()
        {
            var p = _r.Begin(); W.U32(p, Id); _r.Emit(ObjOps.CounterDispose, p);
            Inner?.Dispose();
        }
    }

    public sealed class RecArray : ITextureArray, IImageArray, IRecObj
    {
        public readonly ITextureArray InnerT;
        public readonly IImageArray InnerI;
        readonly GalRecorder _r;
        public uint Id { get; }
        public RecArray(GalRecorder r, ITextureArray t, IImageArray i, uint id) { _r = r; InnerT = t; InnerI = i; Id = id; }

        public void SetSamplers(int index, ISampler[] samplers)
        {
            var p = _r.Begin(); W.U32(p, Id); W.I32(p, index); GalRecorder.Ids(p, samplers); _r.EmitArray(ObjOps.ArrSetSamplers, Id, index, p);
            InnerT.SetSamplers(index, GalRecorder.U(samplers));
        }

        public void SetTextures(int index, ITexture[] textures)
        {
            var p = _r.Begin(); W.U32(p, Id); W.I32(p, index); GalRecorder.Ids(p, textures); _r.EmitArray(ObjOps.ArrSetTextures, Id, index, p);
            InnerT.SetTextures(index, GalRecorder.U(textures));
        }

        public void SetImages(int index, ITexture[] images)
        {
            var p = _r.Begin(); W.U32(p, Id); W.I32(p, index); GalRecorder.Ids(p, images); _r.EmitArray(ObjOps.ArrSetImages, Id, index, p);
            InnerI.SetImages(index, GalRecorder.U(images));
        }

        public void Dispose()
        {
            var p = _r.Begin(); W.U32(p, Id); _r.Emit(ObjOps.ArrDispose, p);
            _r.Unregister(Id);
            InnerT?.Dispose();
            if (!ReferenceEquals(InnerT, InnerI)) InnerI?.Dispose();
        }
    }
}
