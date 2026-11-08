namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    /// <summary>
    /// S2Arm: a cached program indexed at boot but not materialized.
    /// </summary>
    /// <remarks>
    /// Boot only reads each program's guest stage code (needed to index it by code, deduplicated and shared with the lookup tables)
    /// and remembers where its record is. The specialization state, program info and host program are read from the cache files
    /// the first time a lookup reaches the program's group (<see cref="ShaderSpecializationList"/>). Materializing all programs at
    /// boot kept ~320 MB of managed objects resident for 22k programs (Animal Crossing), most never used in a session, and took
    /// ~7.7 s before the first frame; on iPhone the GC heap shares a few hundred MB of low address space.
    /// </remarks>
    class S2ALazyProgram
    {
        public readonly DiskCacheHostStorage Storage;
        public readonly GpuContext Context;
        public readonly int ProgramIndex;
        public readonly ulong DataOffset;
        public readonly ulong Timestamp;
        public readonly bool IsCompute;

        /// <summary>
        /// S2Arm: guest code index of each active stage in the boot-time shared guest cache (-1 = stage not present), indexed like
        /// <see cref="CachedShaderProgram.Shaders"/> (0 = vertex A, 1 = vertex, 2 = tessellation control, 3 = tessellation evaluation,
        /// 4 = geometry, 5 = fragment; compute uses 0).
        /// </summary>
        /// <remarks>
        /// 帧率能耗线 10-24（GC）：原先每个程序常驻一个 6 槽 GuestCodeAndCbData?[]（每槽两个 byte[] 引用，大多只有顶点 + 片元），
        /// 马车8 2.5 万个数组共 30 万指针槽，加重 gen2 标记与读盘段卡表扫描。改存下标（无引用），要用时由 <see cref="GuestShaders"/> 临时拼出。
        /// 提前热读好的部分也不再挂在本对象上（DiskCacheHostStorage 的旁表），本对象常驻时只剩 Storage / Context 两个引用
        /// </remarks>
        private S2AStageIndices _stages;

        /// <summary>
        /// Guest code of each active stage (built on demand from the shared guest cache; not retained).
        /// </summary>
        public GuestCodeAndCbData?[] GuestShaders => Storage.S2AGuestShaders(_stages, IsCompute);

        /// <summary>S2A：已实化（成功与否都算）；之后提前热不再给它读（持 _lazyLock 读写）。</summary>
        internal bool Done;

        /// <summary>
        /// S2A：实化时宿主二进制不在（客体代码 / 特化状态仍可读）。这种条目先只登记，等运行时状态真的匹配到它时才算一次
        /// 「作废 / 首遇现编」并报红——同组里没被选中的特化变体不是作废（见 <see cref="ShaderSpecializationList"/>）。
        /// </summary>
        internal bool HostMissing;

        /// <summary>S2A：本局已经为这条缺宿主二进制的条目报过一次红（同一程序不重复报）。</summary>
        internal bool ReportedMissingHost;

        public S2ALazyProgram(DiskCacheHostStorage storage, GpuContext context, int programIndex, ulong dataOffset, ulong timestamp, bool isCompute, S2AStageIndices stages)
        {
            Storage = storage;
            Context = context;
            ProgramIndex = programIndex;
            DataOffset = dataOffset;
            Timestamp = timestamp;
            IsCompute = isCompute;
            _stages = stages;
        }

        /// <summary>
        /// Reads the program from the cache files and creates its host program.
        /// </summary>
        /// <returns>The program, or null if it can't be used (it is then compiled on demand like an uncached shader)</returns>
        public CachedShaderProgram Materialize()
        {
            return Storage.S2AMaterialize(this);
        }
    }

    /// <summary>
    /// S2Arm: guest code indices of the six stages (-1 = none), stored inline (no references).
    /// </summary>
    struct S2AStageIndices
    {
        private int _s0, _s1, _s2, _s3, _s4, _s5;

        public static S2AStageIndices None => new() { _s0 = -1, _s1 = -1, _s2 = -1, _s3 = -1, _s4 = -1, _s5 = -1 };

        public int this[int stage]
        {
            readonly get => stage switch { 0 => _s0, 1 => _s1, 2 => _s2, 3 => _s3, 4 => _s4, _ => _s5 };
            set { switch (stage) { case 0: _s0 = value; break; case 1: _s1 = value; break; case 2: _s2 = value; break; case 3: _s3 = value; break; case 4: _s4 = value; break; default: _s5 = value; break; } }
        }
    }
}
