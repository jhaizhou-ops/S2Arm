// 顶点着色器位置求值（10-23 原画框外推的写侧来历位）：外推语义只对铺满整张画布的那一遍成立，八方2 存档菜单模糊链在一张图集里按子块画
// （位置 = 单位四边形顶点 × 常量里的子块矩形），视口 / 剪刀都是整画布，只有几何能分出「子块」。包装层在候选外推笔上用 CPU 把各顶点的 gl_Position.x / w 算出来，
// 看是否铺满画布（WidenPipeline.GeomCovers）。手机上程序走包里的预编二进制、没有 SPIR-V，所以出包时把顶点着色器（去掉调试名、deflate 压缩）存进 widen_pos.bin。
// 求值 = 解释执行整支顶点着色器：直线代码、分支 / OpPhi / OpSwitch、函数调用、循环（步数上限）都走；认不出的指令、读存储缓冲 / 贴图 / 别的输入得到「未知」，
// 未知值参与的运算结果也未知——只要写进 gl_Position.x / w 的值不依赖未知就算得出；分支条件未知、位置依赖未知、步数超限 = 判不出（LastFail 写原因）。
// 输入：顶点属性原始位（location / 分量）、内建量（顶点号等）、常量缓冲字（绑定号 + 字节偏移；偏移按 Offset / ArrayStride 装饰算，Ryujinx 常量缓冲 = struct { vec4 [N] }）。
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    /// <summary>求值时的输入：属性原始位、内建量、常量缓冲字（读不到返回 false = 未知）。</summary>
    public interface IPosEnv
    {
        bool Attr(int location, int lane, out uint bits);
        uint Builtin(uint builtIn);
        bool Ubo(int binding, int byteOffset, out uint bits);
        /// <summary>调用方要求立刻停（例：读不到输入、结果必然判不出），解释执行在下一步返回失败、不再往下算。</summary>
        bool Stop => false;
    }

    /// <summary>位置文件 widen_pos.bin（出包时 shbake 写、与 widen.idx 同目录）：u32 "WPOS"、u32 版本 2、u32 条数；每条 u64 顶点阶段键（改写后 SPIR-V 的键，同 widen.idx）、
    /// i64 字节偏移、i32 字节数（按键排序）；之后是各条 deflate 压缩的顶点着色器。运行时只读索引，着色器按需读（程序第一次出现在候选外推笔上时）。</summary>
    public sealed class PosFile
    {
        public const uint Magic = 0x534f5057, Version = 2;   // "WPOS"
        public const string FileName = "widen_pos.bin";
        readonly string _path; readonly Dictionary<ulong, (long Off, int Len)> _idx = new(); readonly long _data; readonly object _lock = new();
        PosFile(string path, long data) { _path = path; _data = data; }
        public int Count => _idx.Count;
        public static void Write(string path, IEnumerable<KeyValuePair<ulong, byte[]>> items)
        {
            var list = new List<KeyValuePair<ulong, byte[]>>(items); list.Sort((a, b) => a.Key.CompareTo(b.Key));
            using var w = new BinaryWriter(File.Create(path));
            w.Write(Magic); w.Write(Version); w.Write(list.Count); long off = 0;
            foreach (var (k, v) in list) { w.Write(k); w.Write(off); w.Write(v.Length); off += v.Length; }
            foreach (var (_, v) in list) w.Write(v);
        }
        public static PosFile Open(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
            using var r = new BinaryReader(File.OpenRead(path));
            if (r.ReadUInt32() != Magic || r.ReadUInt32() != Version) return null;
            int n = r.ReadInt32(); long data = 12 + (long)n * 20; var f = new PosFile(path, data);
            for (int i = 0; i < n; i++) { ulong k = r.ReadUInt64(); long o = r.ReadInt64(); int l = r.ReadInt32(); f._idx[k] = (o, l); }
            return f;
        }
        public bool Has(ulong key) => _idx.ContainsKey(key);
        // 解析结果按键缓存（同一顶点着色器被多个程序共用只解析一次；解析失败也记 null）；文件只打开一次、之后按偏移读
        readonly Dictionary<ulong, SpirvPosSlice> _parsed = new(); Microsoft.Win32.SafeHandles.SafeFileHandle _fh;
        public SpirvPosSlice Get(ulong key)
        {
            if (!_idx.TryGetValue(key, out var e)) return null;
            lock (_lock)
            {
                if (_parsed.TryGetValue(key, out SpirvPosSlice got)) return got;
                _fh ??= File.OpenHandle(_path, FileMode.Open, FileAccess.Read, FileShare.Read);
                byte[] b = new byte[e.Len];
                if (RandomAccess.Read(_fh, b, _data + e.Off) != e.Len) throw new EndOfStreamException($"{_path} 键 {key:x16} 截断");
                SpirvPosSlice s = SpirvPosSlice.FromPacked(b);
                _parsed[key] = s;
                return s;
            }
        }
    }

    public sealed class SpirvPosSlice
    {
        const int OpExtInstImport = 11, OpExtInst = 12, OpTypeVoid = 19, OpTypeVector = 23, OpTypeMatrix = 24, OpTypeArray = 28, OpTypeRuntimeArray = 29,
            OpTypeStruct = 30, OpTypePointer = 32, OpTypeFunction = 33, OpConstantTrue = 41, OpConstantFalse = 42, OpConstant = 43, OpConstantComposite = 44, OpConstantNull = 46,
            OpFunction = 54, OpFunctionParameter = 55, OpFunctionEnd = 56, OpFunctionCall = 57, OpVariable = 59, OpLoad = 61, OpStore = 62, OpAccessChain = 65, OpInBoundsAccessChain = 66,
            OpDecorate = 71, OpMemberDecorate = 72, OpVectorShuffle = 79, OpCompositeConstruct = 80, OpCompositeExtract = 81, OpCompositeInsert = 82, OpCopyObject = 83,
            OpConvertFToU = 109, OpConvertFToS = 110, OpConvertSToF = 111, OpConvertUToF = 112, OpBitcast = 124, OpSNegate = 126, OpFNegate = 127, OpIAdd = 128, OpFAdd = 129,
            OpISub = 130, OpFSub = 131, OpIMul = 132, OpFMul = 133, OpUDiv = 134, OpSDiv = 135, OpFDiv = 136, OpVectorTimesScalar = 142, OpLogicalOr = 166, OpLogicalAnd = 167, OpLogicalNot = 168, OpSelect = 169,
            OpIEqual = 170, OpINotEqual = 171, OpUGreaterThan = 172, OpSGreaterThan = 173, OpUGreaterThanEqual = 174, OpSGreaterThanEqual = 175, OpULessThan = 176, OpSLessThan = 177,
            OpULessThanEqual = 178, OpSLessThanEqual = 179, OpFOrdEqual = 180, OpFOrdNotEqual = 182, OpFOrdLessThan = 184, OpFOrdGreaterThan = 186, OpFOrdLessThanEqual = 188,
            OpFOrdGreaterThanEqual = 190, OpShiftRightLogical = 194, OpShiftRightArithmetic = 195, OpShiftLeftLogical = 196, OpBitwiseOr = 197, OpBitwiseXor = 198, OpBitwiseAnd = 199, OpNot = 200,
            OpPhi = 245, OpLoopMerge = 246, OpSelectionMerge = 247, OpLabel = 248, OpBranch = 249, OpBranchConditional = 250, OpSwitch = 251, OpKill = 252, OpReturn = 253, OpReturnValue = 254, OpUnreachable = 255;
        const uint DecBuiltIn = 11, DecLocation = 30, DecBinding = 33, DecArrayStride = 6, DecOffset = 35, BuiltInPosition = 0, ScInput = 1, ScUniform = 2, ScOutput = 3, ScPrivate = 6, ScFunction = 7;
        const int MaxSteps = 200000;

        /// <summary>出包用的压缩字节（FromPacked 读回）。</summary>
        public byte[] Packed { get; private set; }
        /// <summary>最近一次 Eval 判不出的原因（诊断用）。</summary>
        public string LastFail;

        readonly Dictionary<uint, uint[]> _types = new();                 // 类型 id → 指令字
        readonly Dictionary<uint, uint[]> _const = new();                 // 常量 id → 各分量位（展平）
        readonly Dictionary<uint, uint> _ctype = new();                   // 常量 id → 类型
        readonly Dictionary<uint, (uint Ptr, uint Sc)> _vars = new();
        readonly Dictionary<uint, uint> _loc = new(), _bind = new(), _builtin = new(), _stride = new();
        readonly Dictionary<(uint S, uint M), uint> _memBuiltin = new(), _memOff = new();
        sealed class Fn { public uint Id; public readonly List<uint> Params = new(); public readonly List<uint[]> Vars = new(); public readonly Dictionary<uint, List<uint[]>> Blocks = new(); public uint First; }
        readonly Dictionary<uint, Fn> _fns = new();
        uint _entry, _glsl;

        /// <summary>出包 / 现翻：顶点着色器原 SPIR-V → 可求值的对象（只核模块结构，能否算出位置到求值时才知道）；不是顶点着色器返回 null。</summary>
        public static SpirvPosSlice Extract(byte[] spv, out string why)
        {
            why = null;
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) { why = "不是 SPIR-V"; return null; }
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) { why = "不是 SPIR-V"; return null; }
            // 去掉调试指令（OpSource* / OpName / OpMemberName / OpString / OpLine / OpNoLine / OpModuleProcessed）再压缩
            var o = new List<uint>(w.Length); o.AddRange(w.AsSpan(0, 5).ToArray());
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) { why = "指令长度坏"; return null; }
                if (op is not (3 or 4 or 5 or 6 or 7 or 8 or 317 or 330)) o.AddRange(w.AsSpan(i, n).ToArray());
                i += n;
            }
            var s = FromWords(o.ToArray(), out why); if (s == null) return null;
            using var ms = new MemoryStream();
            using (var z = new DeflateStream(ms, CompressionLevel.Optimal, true)) z.Write(MemoryMarshal.AsBytes(CollectionsMarshal.AsSpan(o)));
            s.Packed = ms.ToArray();
            return s;
        }

        public static SpirvPosSlice FromPacked(byte[] packed)
        {
            try
            {
                using var z = new DeflateStream(new MemoryStream(packed), CompressionMode.Decompress); using var ms = new MemoryStream(); z.CopyTo(ms);
                var s = FromWords(MemoryMarshal.Cast<byte, uint>(ms.ToArray()).ToArray(), out _); if (s != null) s.Packed = packed; return s;
            }
            catch (InvalidDataException) { return null; }
        }

        static SpirvPosSlice FromWords(uint[] w, out string why)
        {
            why = null; var s = new SpirvPosSlice(); Fn f = null; List<uint[]> blk = null;
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) { why = "指令长度坏"; return null; }
                uint[] ins = w.AsSpan(i, n).ToArray(); i += n;
                if (f != null)
                {
                    if (op == OpFunctionEnd) { s._fns[f.Id] = f; f = null; blk = null; continue; }
                    if (op == OpFunctionParameter) { f.Params.Add(ins[2]); continue; }
                    if (op == OpLabel) { blk = new List<uint[]>(); f.Blocks[ins[1]] = blk; if (f.First == 0) f.First = ins[1]; continue; }
                    if (op == OpVariable) { s._vars[ins[2]] = (ins[1], ins[3]); f.Vars.Add(ins); continue; }
                    blk?.Add(ins); continue;
                }
                switch (op)
                {
                    case 15: if (ins[1] == 0 && s._entry == 0) s._entry = ins[2]; break;   // OpEntryPoint Vertex
                    case OpExtInstImport: if (n >= 3 && ins[2] == 0x4c534c47u) s._glsl = ins[1]; break;   // "GLSL.std.450"
                    case OpFunction: f = new Fn { Id = ins[2] }; break;
                    case OpConstant: s._const[ins[2]] = ins.AsSpan(3).ToArray(); s._ctype[ins[2]] = ins[1]; break;
                    case OpConstantTrue: s._const[ins[2]] = new uint[] { 1 }; s._ctype[ins[2]] = ins[1]; break;
                    case OpConstantFalse: case OpConstantNull: s._const[ins[2]] = new uint[s.Flat(ins[1])]; s._ctype[ins[2]] = ins[1]; break;
                    case OpConstantComposite: { var l = new List<uint>(); for (int j = 3; j < ins.Length; j++) l.AddRange(s._const.TryGetValue(ins[j], out uint[] c) ? c : new uint[1]); s._const[ins[2]] = l.ToArray(); s._ctype[ins[2]] = ins[1]; break; }
                    case OpVariable: s._vars[ins[2]] = (ins[1], ins[3]); break;
                    case OpDecorate:
                        if (n >= 4) { if (ins[2] == DecLocation) s._loc[ins[1]] = ins[3]; else if (ins[2] == DecBinding) s._bind[ins[1]] = ins[3]; else if (ins[2] == DecBuiltIn) s._builtin[ins[1]] = ins[3]; else if (ins[2] == DecArrayStride) s._stride[ins[1]] = ins[3]; }
                        break;
                    case OpMemberDecorate: if (n >= 5) { if (ins[3] == DecBuiltIn) s._memBuiltin[(ins[1], ins[2])] = ins[4]; else if (ins[3] == DecOffset) s._memOff[(ins[1], ins[2])] = ins[4]; } break;
                    default: if (op is >= OpTypeVoid and <= OpTypeFunction) s._types[ins[1]] = ins; break;
                }
            }
            if (s._entry == 0 || !s._fns.ContainsKey(s._entry)) { why = "没有顶点入口"; return null; }
            return s;
        }

        // ---------- 类型 ----------
        /// <summary>类型展平后的 32 位分量数（标量 1、向量 n、矩阵 列×行、数组 长×元素、结构体 各成员之和；不认识的按 1）。</summary>
        int Flat(uint t)
        {
            if (!_types.TryGetValue(t, out uint[] ty)) return 1;
            switch ((int)(ty[0] & 0xffff))
            {
                case OpTypeVector: return (int)ty[3];
                case OpTypeMatrix: return (int)ty[3] * Flat(ty[2]);
                case OpTypeArray: return (_const.TryGetValue(ty[3], out uint[] c) ? (int)Math.Min(c[0], 4096u) : 1) * Flat(ty[2]);
                case OpTypeStruct: { int s = 0; for (int j = 2; j < ty.Length; j++) s += Flat(ty[j]); return s; }
                default: return 1;
            }
        }
        uint Pointee(uint ptrType) => _types.TryGetValue(ptrType, out uint[] t) && (t[0] & 0xffff) == OpTypePointer ? t[3] : 0;
        /// <summary>沿路径的展平分量偏移与末端类型。</summary>
        bool FlatOffset(uint t, ReadOnlySpan<int> path, out int off, out uint tEnd)
        {
            off = 0; tEnd = t;
            foreach (int ix in path)
            {
                if (!_types.TryGetValue(tEnd, out uint[] ty) || ix < 0) return false;
                switch ((int)(ty[0] & 0xffff))
                {
                    case OpTypeStruct: if (2 + ix >= ty.Length) return false; for (int j = 0; j < ix; j++) off += Flat(ty[2 + j]); tEnd = ty[2 + ix]; break;
                    case OpTypeArray: case OpTypeRuntimeArray: case OpTypeMatrix: off += ix * Flat(ty[2]); tEnd = ty[2]; break;
                    case OpTypeVector: if (ix >= ty[3]) return false; off += ix; tEnd = ty[2]; break;
                    default: return false;
                }
            }
            return true;
        }
        /// <summary>常量缓冲 / 支持缓冲：沿路径按 Offset / ArrayStride 装饰算字节偏移。</summary>
        bool ByteOffset(uint t, int[] path, out int off)
        {
            off = 0; uint tEnd = t;
            foreach (int ix in path)
            {
                if (!_types.TryGetValue(tEnd, out uint[] ty) || ix < 0) return false;
                switch ((int)(ty[0] & 0xffff))
                {
                    case OpTypeStruct: if (2 + ix >= ty.Length || !_memOff.TryGetValue((tEnd, (uint)ix), out uint mo)) return false; off += (int)mo; tEnd = ty[2 + ix]; break;
                    case OpTypeArray: case OpTypeRuntimeArray: if (!_stride.TryGetValue(tEnd, out uint st)) return false; off += ix * (int)st; tEnd = ty[2]; break;
                    case OpTypeVector: off += ix * 4; tEnd = ty[2]; break;
                    default: return false;
                }
            }
            return true;
        }

        // ---------- 求值 ----------
        static readonly uint[] Unknown = new uint[0];   // 未知值（读不到 / 认不出的指令），参与运算结果也未知
        readonly struct Ptr { public readonly uint Var; public readonly int[] Path; public Ptr(uint v, int[] p) { Var = v; Path = p; } }   // Path = null：下标未知
        sealed class St { public IPosEnv Env; public readonly Dictionary<uint, uint[]> Mem = new(); public readonly HashSet<(uint, int)> Unk = new(); public int Steps; public string Fail; }
        // 复用存储（10-23 巫师3：每条指令结果 / 每次调用的字典都新建，新几何那帧 7.7–35 万字节）：一次 Eval 里租的值数组 / 下标数组按长度进池、Eval 结束全部还；
        //   常量（_const）与 Unknown 从不进池。调用帧按深度复用（值 / 类型 / 指针三张表 + 参数缓冲），不建闭包。单线程用（宽屏层在编码线程上调）
        const int PoolMax = 64;
        readonly Stack<uint[]>[] _upool = new Stack<uint[]>[PoolMax + 1]; readonly List<uint[]> _uRent = new();
        readonly Stack<int[]>[] _ipool = new Stack<int[]>[PoolMax + 1]; readonly List<int[]> _iRent = new();
        readonly St _st = new();
        readonly List<Frame> _frames = new();
        uint[] Rent(int n)
        {
            if (n <= 0) return Array.Empty<uint>();
            if (n > PoolMax) return new uint[n];
            var p = _upool[n] ??= new Stack<uint[]>(); uint[] a = p.Count > 0 ? p.Pop() : new uint[n]; _uRent.Add(a); return a;
        }
        uint[] RentZero(int n) { uint[] a = Rent(n); Array.Clear(a); return a; }
        int[] RentI(int n)
        {
            if (n <= 0) return Array.Empty<int>();
            if (n > PoolMax) return new int[n];
            var p = _ipool[n] ??= new Stack<int[]>(); int[] a = p.Count > 0 ? p.Pop() : new int[n]; _iRent.Add(a); return a;
        }
        void ReturnAll()
        {
            foreach (uint[] a in _uRent) _upool[a.Length].Push(a);
            foreach (int[] a in _iRent) _ipool[a.Length].Push(a);
            _uRent.Clear(); _iRent.Clear();
        }
        sealed class Frame
        {
            public SpirvPosSlice S; public readonly Dictionary<uint, uint[]> Val = new(); public readonly Dictionary<uint, uint> Ty = new(); public readonly Dictionary<uint, Ptr> Ptr = new();
            public uint[] Get(uint id) => Val.TryGetValue(id, out uint[] v) ? v : S._const.TryGetValue(id, out uint[] c) ? c : null;
            public uint TypeOf(uint id) => Ty.TryGetValue(id, out uint t) ? t : S._ctype.TryGetValue(id, out uint c) ? c : 0;
        }
        Frame FrameAt(int depth)
        {
            while (_frames.Count <= depth) _frames.Add(new Frame { S = this });
            Frame f = _frames[depth]; f.Val.Clear(); f.Ty.Clear(); f.Ptr.Clear(); return f;
        }

        /// <summary>按输入算一个顶点的 gl_Position.x / w；判不出返回 false（原因在 LastFail）。</summary>
        public bool Eval(IPosEnv env, out float x, out float w)
        {
            x = 0; w = 1;
            try { return EvalCore(env, out x, out w); }
            finally { ReturnAll(); }
        }
        bool EvalCore(IPosEnv env, out float x, out float w)
        {
            x = 0; w = 1;
            St st = _st; st.Env = env; st.Mem.Clear(); st.Unk.Clear(); st.Steps = 0; st.Fail = null;
            foreach (var kv in _vars) if (kv.Value.Sc is ScPrivate or ScOutput) st.Mem[kv.Key] = RentZero(Flat(Pointee(kv.Value.Ptr)));
            Call(st, _fns[_entry], FrameAt(0), 0);
            LastFail = st.Fail;
            if (st.Fail != null) return false;
            foreach (var kv in _vars)
            {
                if (kv.Value.Sc != ScOutput) continue;
                uint t = Pointee(kv.Value.Ptr); int baseOff = -1;
                if (_builtin.TryGetValue(kv.Key, out uint bi) && bi == BuiltInPosition) baseOff = 0;
                else if (_types.TryGetValue(t, out uint[] ty) && (ty[0] & 0xffff) == OpTypeStruct)
                    for (int m = 0; m + 2 < ty.Length; m++) if (_memBuiltin.TryGetValue((t, (uint)m), out uint mb) && mb == BuiltInPosition) { Span<int> mp = stackalloc int[1]; mp[0] = m; FlatOffset(t, mp, out baseOff, out _); break; }
                if (baseOff < 0) continue;
                uint[] mem = st.Mem[kv.Key];
                if (baseOff + 3 >= mem.Length) { LastFail = "位置输出越界"; return false; }
                if (st.Unk.Contains((kv.Key, baseOff)) || st.Unk.Contains((kv.Key, baseOff + 3))) { LastFail = "位置依赖未知值"; return false; }
                x = BitConverter.UInt32BitsToSingle(mem[baseOff]); w = BitConverter.UInt32BitsToSingle(mem[baseOff + 3]);
                return true;
            }
            LastFail = "没有位置输出"; return false;
        }

        // fr：调用方已把实参（值进 Val、指针进 Ptr）填好的这一层帧（FrameAt(depth)）
        uint[] Call(St st, Fn f, Frame fr, int depth)
        {
            var val = fr.Val; var vty = fr.Ty; var ptr = fr.Ptr;
            uint[] Get(uint id) => fr.Get(id);
            foreach (uint[] v in f.Vars)
            {
                int n = Flat(Pointee(v[1])); var m = RentZero(n);
                if (v.Length > 4 && Get(v[4]) is { } init && init != Unknown) Array.Copy(init, m, Math.Min(n, init.Length));
                st.Mem[v[2]] = m; for (int k = 0; k < n; k++) st.Unk.Remove((v[2], k));
            }
            uint label = f.First, prev = 0;
            while (true)
            {
                if (!f.Blocks.TryGetValue(label, out var blk)) { st.Fail = "跳到不存在的块"; return null; }
                uint next = 0; bool done = false; uint[] ret = null;
                foreach (uint[] ins in blk)
                {
                    if (++st.Steps > MaxSteps) { st.Fail = "步数超限"; return null; }
                    if (st.Env.Stop) { st.Fail = "调用方要求停"; return null; }
                    int op = (int)(ins[0] & 0xffff);
                    if (ins.Length >= 3 && op is not (OpStore or OpSelectionMerge or OpLoopMerge or OpBranch or OpBranchConditional or OpSwitch or OpReturn or OpReturnValue)) vty[ins[2]] = ins[1];
                    switch (op)
                    {
                        case OpSelectionMerge: case OpLoopMerge: break;
                        case OpPhi:
                            val[ins[2]] = Unknown;
                            for (int j = 3; j + 1 < ins.Length; j += 2) if (ins[j + 1] == prev) { val[ins[2]] = Get(ins[j]) ?? Unknown; break; }
                            break;
                        case OpBranch: next = ins[1]; break;
                        case OpBranchConditional: { uint[] c = Get(ins[1]); if (c == null || c == Unknown) { st.Fail = "分支条件未知"; return null; } next = c[0] != 0 ? ins[2] : ins[3]; break; }
                        case OpSwitch:
                        {
                            uint[] c = Get(ins[1]); if (c == null || c == Unknown) { st.Fail = "分支条件未知"; return null; }
                            next = ins[2]; for (int j = 3; j + 1 < ins.Length; j += 2) if (ins[j] == c[0]) { next = ins[j + 1]; break; }
                            break;
                        }
                        case OpReturn: done = true; break;
                        case OpReturnValue: done = true; ret = Get(ins[1]) ?? Unknown; break;
                        case OpKill: case OpUnreachable: st.Fail = "顶点着色器里有 OpKill / OpUnreachable"; return null;
                        case OpFunctionCall:
                        {
                            if (!_fns.TryGetValue(ins[3], out Fn cf)) { val[ins[2]] = Unknown; break; }
                            Frame cfr = FrameAt(depth + 1);
                            for (int j = 4; j < ins.Length; j++)
                            {
                                uint aid = ins[j]; int pi = j - 4; if (pi >= cf.Params.Count) break; uint pid = cf.Params[pi];
                                if (ptr.TryGetValue(aid, out Ptr pp)) cfr.Ptr[pid] = pp; else if (_vars.ContainsKey(aid)) cfr.Ptr[pid] = new Ptr(aid, Array.Empty<int>()); else cfr.Val[pid] = Get(aid) ?? Unknown;
                            }
                            uint[] r = Call(st, cf, cfr, depth + 1); if (st.Fail != null) return null; val[ins[2]] = r ?? Unknown; break;
                        }
                        case OpAccessChain: case OpInBoundsAccessChain:
                        {
                            Ptr b = ptr.TryGetValue(ins[3], out Ptr pb) ? pb : new Ptr(ins[3], Array.Empty<int>());
                            if (b.Path == null) { ptr[ins[2]] = b; break; }
                            var path = RentI(b.Path.Length + ins.Length - 4); b.Path.CopyTo(path, 0); bool unk = false;
                            for (int j = 4; j < ins.Length; j++) { uint[] c = Get(ins[j]); if (c == null || c == Unknown) { unk = true; break; } path[b.Path.Length + j - 4] = (int)c[0]; }
                            ptr[ins[2]] = new Ptr(b.Var, unk ? null : path);
                            break;
                        }
                        case OpLoad:
                        {
                            Ptr p = ptr.TryGetValue(ins[3], out Ptr pp) ? pp : new Ptr(ins[3], Array.Empty<int>());
                            val[ins[2]] = p.Path == null ? Unknown : Read(st, p, ins[1]); break;
                        }
                        case OpStore:
                        {
                            Ptr p = ptr.TryGetValue(ins[1], out Ptr pp) ? pp : new Ptr(ins[1], Array.Empty<int>());
                            uint[] v = Get(ins[2]) ?? Unknown;
                            if (p.Path == null) { if (st.Mem.TryGetValue(p.Var, out uint[] m)) for (int k = 0; k < m.Length; k++) st.Unk.Add((p.Var, k)); break; }   // 下标未知：整个变量作未知
                            Write(st, p, v); break;
                        }
                        default:
                            if (ins.Length >= 3 && op != OpVariable) val[ins[2]] = Compute(op, ins, fr);
                            break;
                    }
                    if (done || next != 0) break;
                }
                if (done) return ret;
                if (next == 0) { st.Fail = "块没有结尾"; return null; }
                prev = label; label = next;
            }
        }

        uint[] Read(St st, Ptr p, uint resultType)
        {
            if (!_vars.TryGetValue(p.Var, out var v)) return Unknown;
            int n = Flat(resultType);
            if (v.Sc is ScFunction or ScPrivate or ScOutput)
            {
                if (!st.Mem.TryGetValue(p.Var, out uint[] m) || !FlatOffset(Pointee(v.Ptr), p.Path, out int off, out _) || off + n > m.Length) return Unknown;
                for (int k = 0; k < n; k++) if (st.Unk.Contains((p.Var, off + k))) return Unknown;
                var r = Rent(n); Array.Copy(m, off, r, 0, n); return r;
            }
            if (v.Sc == ScInput)
            {
                if (_builtin.TryGetValue(p.Var, out uint bi)) { var b1 = Rent(1); b1[0] = st.Env.Builtin(bi); return b1; }
                if (!_loc.TryGetValue(p.Var, out uint loc) || !FlatOffset(Pointee(v.Ptr), p.Path, out int off, out _)) return Unknown;
                var r = Rent(n); for (int l = 0; l < n; l++) if (!st.Env.Attr((int)loc, off + l, out r[l])) return Unknown;
                return r;
            }
            if (v.Sc == ScUniform && _bind.TryGetValue(p.Var, out uint bind))
            {
                if (!ByteOffset(Pointee(v.Ptr), p.Path, out int off)) return Unknown;
                var r = Rent(n); for (int l = 0; l < n; l++) if (!st.Env.Ubo((int)bind, off + l * 4, out r[l])) return Unknown;
                return r;
            }
            return Unknown;   // 存储缓冲 / 贴图 / 别的
        }

        void Write(St st, Ptr p, uint[] v)
        {
            if (!_vars.TryGetValue(p.Var, out var vi) || vi.Sc is not (ScFunction or ScPrivate or ScOutput) || !st.Mem.TryGetValue(p.Var, out uint[] m)) return;   // 写别处不影响位置
            if (!FlatOffset(Pointee(vi.Ptr), p.Path, out int off, out uint t)) return;
            int n = Flat(t);
            for (int k = 0; k < n && off + k < m.Length; k++)
            {
                if (v == Unknown || k >= v.Length) { st.Unk.Add((p.Var, off + k)); m[off + k] = 0; }
                else { st.Unk.Remove((p.Var, off + k)); m[off + k] = v[k]; }
            }
        }

        uint[] Compute(int o, uint[] i, Frame fr)
        {
            uint t = i[1]; int n = Flat(t);
            uint[] V(uint id) => fr.Get(id);
            uint TypeOf(uint id) => fr.TypeOf(id);
            static bool U(uint[] a) => a == null || a == Unknown;
            switch (o)
            {
                case OpCopyObject: case OpBitcast: return V(i[3]) ?? Unknown;
                case OpCompositeExtract:
                {
                    uint[] a = V(i[3]); if (U(a)) return Unknown;
                    var path = RentI(i.Length - 4); for (int j = 4; j < i.Length; j++) path[j - 4] = (int)i[j];
                    uint at = TypeOf(i[3]); int off;
                    if (at != 0) { if (!FlatOffset(at, path, out off, out _)) return Unknown; } else off = path[0];
                    if (off + n > a.Length) return Unknown;
                    var r = Rent(n); Array.Copy(a, off, r, 0, n); return r;
                }
                case OpCompositeInsert:
                {
                    uint[] obj = V(i[3]), a = V(i[4]); if (U(obj) || U(a)) return Unknown;
                    var path = RentI(i.Length - 5); for (int j = 5; j < i.Length; j++) path[j - 5] = (int)i[j];
                    if (!FlatOffset(t, path, out int off, out _) || off + obj.Length > a.Length) return Unknown;
                    var r = Rent(a.Length); Array.Copy(a, r, a.Length); Array.Copy(obj, 0, r, off, obj.Length); return r;
                }
                case OpCompositeConstruct: { int tot = 0; for (int j = 3; j < i.Length; j++) { uint[] a = V(i[j]); if (U(a)) return Unknown; tot += a.Length; } var r = Rent(tot); int at2 = 0; for (int j = 3; j < i.Length; j++) { uint[] a = V(i[j]); Array.Copy(a, 0, r, at2, a.Length); at2 += a.Length; } return r; }
                case OpVectorShuffle:
                {
                    uint[] a = V(i[3]), b = V(i[4]); if (U(a) || U(b)) return Unknown;
                    var r = Rent(i.Length - 5); for (int j = 5; j < i.Length; j++) { uint s = i[j]; r[j - 5] = s < a.Length ? a[s] : s - a.Length < b.Length ? b[s - a.Length] : 0; } return r;
                }
                case OpSelect:
                {
                    uint[] c = V(i[3]), a = V(i[4]), b = V(i[5]); if (U(c)) return Unknown;
                    if (c.Length == 1) return (c[0] != 0 ? a : b) ?? Unknown;
                    if (U(a) || U(b)) return Unknown;
                    var r = Rent(n); for (int l = 0; l < n; l++) r[l] = c[Math.Min(l, c.Length - 1)] != 0 ? a[Math.Min(l, a.Length - 1)] : b[Math.Min(l, b.Length - 1)]; return r;
                }
            }
            uint[] A, B, C;
            if (o == OpExtInst) { if (i.Length < 6 || i[3] != _glsl) return Unknown; A = V(i[5]); B = i.Length > 6 ? V(i[6]) : null; C = i.Length > 7 ? V(i[7]) : null; }
            else { A = V(i[3]); B = i.Length > 4 ? V(i[4]) : null; C = i.Length > 5 ? V(i[5]) : null; }
            if (U(A) || B == Unknown || C == Unknown) return Unknown;
            var res = Rent(n);
            for (int l = 0; l < n; l++)
            {
                uint a = A[Math.Min(l, A.Length - 1)], b = B != null && B.Length > 0 ? B[Math.Min(l, B.Length - 1)] : 0, c = C != null && C.Length > 0 ? C[Math.Min(l, C.Length - 1)] : 0;
                float fa = BitConverter.UInt32BitsToSingle(a), fb = BitConverter.UInt32BitsToSingle(b), fc = BitConverter.UInt32BitsToSingle(c);
                static uint F(float f) => BitConverter.SingleToUInt32Bits(f);
                switch (o)
                {
                    case OpFAdd: res[l] = F(fa + fb); break; case OpFSub: res[l] = F(fa - fb); break; case OpFMul: res[l] = F(fa * fb); break; case OpFDiv: res[l] = F(fa / fb); break;
                    case OpFNegate: res[l] = F(-fa); break; case OpSNegate: res[l] = (uint)-(int)a; break; case OpNot: res[l] = ~a; break;
                    case OpIAdd: res[l] = a + b; break; case OpISub: res[l] = a - b; break; case OpIMul: res[l] = a * b; break;
                    case OpUDiv: res[l] = b == 0 ? 0 : a / b; break;
                    case OpSDiv:
                        if (b == 0 || (a == 0x80000000u && b == 0xffffffffu)) return Unknown;
                        res[l] = unchecked((uint)((int)a / (int)b)); break;
                    case OpVectorTimesScalar: res[l] = F(fa * BitConverter.UInt32BitsToSingle(B[0])); break;
                    case OpConvertFToU: res[l] = float.IsNaN(fa) || fa <= 0 ? 0 : fa >= 4294967295f ? uint.MaxValue : (uint)fa; break;
                    case OpConvertFToS: res[l] = float.IsNaN(fa) ? 0 : (uint)(int)Math.Clamp(fa, int.MinValue, int.MaxValue); break;
                    case OpConvertSToF: res[l] = F((int)a); break; case OpConvertUToF: res[l] = F(a); break;
                    case OpLogicalOr: res[l] = a != 0 || b != 0 ? 1u : 0; break; case OpLogicalAnd: res[l] = a != 0 && b != 0 ? 1u : 0; break; case OpLogicalNot: res[l] = a == 0 ? 1u : 0; break;
                    case OpIEqual: res[l] = a == b ? 1u : 0; break; case OpINotEqual: res[l] = a != b ? 1u : 0; break;
                    case OpUGreaterThan: res[l] = a > b ? 1u : 0; break; case OpSGreaterThan: res[l] = (int)a > (int)b ? 1u : 0; break;
                    case OpUGreaterThanEqual: res[l] = a >= b ? 1u : 0; break; case OpSGreaterThanEqual: res[l] = (int)a >= (int)b ? 1u : 0; break;
                    case OpULessThan: res[l] = a < b ? 1u : 0; break; case OpSLessThan: res[l] = (int)a < (int)b ? 1u : 0; break;
                    case OpULessThanEqual: res[l] = a <= b ? 1u : 0; break; case OpSLessThanEqual: res[l] = (int)a <= (int)b ? 1u : 0; break;
                    case OpFOrdEqual: res[l] = fa == fb ? 1u : 0; break; case OpFOrdNotEqual: res[l] = !float.IsNaN(fa) && !float.IsNaN(fb) && fa != fb ? 1u : 0; break;
                    case OpFOrdLessThan: res[l] = fa < fb ? 1u : 0; break; case OpFOrdGreaterThan: res[l] = fa > fb ? 1u : 0; break;
                    case OpFOrdLessThanEqual: res[l] = fa <= fb ? 1u : 0; break; case OpFOrdGreaterThanEqual: res[l] = fa >= fb ? 1u : 0; break;
                    case OpShiftRightLogical: res[l] = a >> (int)(b & 31); break; case OpShiftRightArithmetic: res[l] = (uint)((int)a >> (int)(b & 31)); break; case OpShiftLeftLogical: res[l] = a << (int)(b & 31); break;
                    case OpBitwiseOr: res[l] = a | b; break; case OpBitwiseXor: res[l] = a ^ b; break; case OpBitwiseAnd: res[l] = a & b; break;
                    case OpExtInst:
                        switch (i[4])
                        {
                            case 50: res[l] = F(MathF.FusedMultiplyAdd(fa, fb, fc)); break;   // Fma
                            case 37: case 79: res[l] = F(MathF.Min(fa, fb)); break; case 40: case 80: res[l] = F(MathF.Max(fa, fb)); break;
                            case 43: case 81: res[l] = F(MathF.Min(MathF.Max(fa, fb), fc)); break;
                            case 4: res[l] = F(MathF.Abs(fa)); break; case 1: res[l] = F(MathF.Round(fa)); break; case 2: res[l] = F(MathF.Round(fa, MidpointRounding.ToEven)); break;
                            case 3: res[l] = F(MathF.Truncate(fa)); break; case 8: res[l] = F(MathF.Floor(fa)); break; case 9: res[l] = F(MathF.Ceiling(fa)); break; case 10: res[l] = F(fa - MathF.Floor(fa)); break;
                            case 6: res[l] = F(MathF.Sign(fa)); break; case 31: res[l] = F(MathF.Sqrt(fa)); break; case 32: res[l] = F(1f / MathF.Sqrt(fa)); break;
                            case 38: res[l] = Math.Min(a, b); break; case 39: res[l] = (uint)Math.Min((int)a, (int)b); break; case 41: res[l] = Math.Max(a, b); break; case 42: res[l] = (uint)Math.Max((int)a, (int)b); break;
                            case 46: res[l] = F(fa + (fb - fa) * fc); break;   // FMix
                            case 13: res[l] = F(MathF.Sin(fa)); break; case 14: res[l] = F(MathF.Cos(fa)); break;
                            default: return Unknown;
                        }
                        break;
                    default: return Unknown;
                }
            }
            return res;
        }
    }
}
