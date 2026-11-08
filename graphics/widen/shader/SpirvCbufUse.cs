// 通用宽屏 · 着色器常量读取分析：从 SPIR-V 读出每个常量缓冲绑定读了哪些 vec4 下标。
// 用途：判一次绘制是否真读了被改写的矩阵（界面层视口按 k 放宽还是原宽居中），以及录像核对的覆盖口径。
// Ryujinx 翻译出的常量缓冲是 `struct { vec4 data[N]; }` 的 Uniform 变量，读法是 OpAccessChain %var %int_0 %下标 [%分量]；
// 下标是常量就记下标，不是常量（或整块加载 / 其他用法）就记「动态」——动态按整段绑定区间算。建程序时调用一次，不在每帧路径上。
using System;
using System.Collections.Generic;

namespace S2Arm.Gfx.Widen
{
    public sealed class CbufUse
    {
        public int Binding;
        public int Set;
        public bool Dynamic;
        int[] _idx = Array.Empty<int>();   // 常量下标，升序去重（建程序时定，之后只读）

        public ReadOnlySpan<int> Indices => _idx;
        public bool Contains(int i) => Array.BinarySearch(_idx, i) >= 0;
        public void Add(int i)
        {
            int p = Array.BinarySearch(_idx, i);
            if (p >= 0) return;
            p = ~p;
            var n = new int[_idx.Length + 1];
            Array.Copy(_idx, n, p); n[p] = i; Array.Copy(_idx, p, n, p + 1, _idx.Length - p);
            _idx = n;
        }

        /// <summary>这块绑定区间（缓冲内偏移 off，长 size）里，着色器会读的字节范围是否与 [lo, hi) 相交。零分配。</summary>
        public bool Reads(int off, int size, int lo, int hi)
        {
            if (Dynamic) return lo < off + size && off < hi;
            int a = Math.Max(0, (lo - off) >> 4), b = Math.Min((hi - off - 1) >> 4, (size - 1) >> 4);
            if (b < a) return false;
            int p = Array.BinarySearch(_idx, a);
            if (p < 0) p = ~p;
            return p < _idx.Length && _idx[p] <= b;
        }

        /// <summary>[lo, hi)（16 字节对齐、整个在绑定区间里）覆盖的每个 vec4 着色器都会读（动态下标的按会读算）。零分配。</summary>
        public bool ReadsAll(int off, int lo, int hi)
        {
            if (Dynamic) return true;
            for (int i = (lo - off) >> 4; i <= (hi - off - 1) >> 4; i++) if (!Contains(i)) return false;
            return true;
        }
    }

    public static class SpirvCbufUse
    {
        const int OpName = 5, OpExtInst = 12, OpConstant = 43, OpVariable = 59, OpAccessChain = 65, OpInBoundsAccessChain = 66, OpDecorate = 71;
        const int DecBinding = 33, DecSet = 34, StorageUniform = 2;

        // 这些指令里出现变量号不算「读」：名字、装饰、入口接口表、执行模式、变量声明、常量字面量、行号
        static bool NoIdUse(int op) => op is OpName or 6 or 8 or 15 or 16 or OpConstant or OpVariable or OpDecorate or 72;

        /// <summary>返回各常量缓冲绑定的读取情况；不是合法 SPIR-V 返回 null。</summary>
        public static List<CbufUse> Analyze(ReadOnlySpan<byte> spv)
        {
            if (spv.Length < 20 || (spv.Length & 3) != 0) return null;
            ReadOnlySpan<uint> w = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(spv);
            if (w[0] != 0x07230203) return null;
            var binding = new Dictionary<uint, int>();
            var descriptorSet = new Dictionary<uint, int>();
            var consts = new Dictionary<uint, int>();
            var uniforms = new Dictionary<uint, CbufUse>();
            // 第一遍：装饰、常量、Uniform 变量
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) return null;
                if (op == OpExtInst && n < 5) return null;
                if (op == OpDecorate && n >= 4 && w[i + 2] == DecBinding) binding[w[i + 1]] = (int)w[i + 3];
                else if (op == OpDecorate && n >= 4 && w[i + 2] == DecSet) descriptorSet[w[i + 1]] = (int)w[i + 3];
                else if (op == OpConstant && n == 4) consts[w[i + 2]] = (int)w[i + 3];
                else if (op == OpVariable && n >= 4 && w[i + 3] == StorageUniform) uniforms[w[i + 2]] = new CbufUse();
                i += n;
            }
            foreach (var kv in uniforms)
            {
                kv.Value.Binding = binding.TryGetValue(kv.Key, out int b) ? b : -1;
                kv.Value.Set = descriptorSet.TryGetValue(kv.Key, out int s) ? s : -1;
            }
            // 第二遍：访问链与其他用法
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (op == OpAccessChain || op == OpInBoundsAccessChain)
                {
                    if (n >= 4 && uniforms.TryGetValue(w[i + 3], out CbufUse u))
                    {
                        if (n >= 6 && consts.TryGetValue(w[i + 5], out int idx) && idx >= 0) u.Add(idx);
                        else u.Dynamic = true;
                    }
                }
                else if (!NoIdUse(op))
                {
                    // 变量被直接加载、复制或当参数传：保守按动态；只排除已知不是 ID 的 ExtInst 指令字面量。
                    for (int j = 1; j < n; j++)
                    {
                        if (op == OpExtInst && j == 4) continue;   // LiteralExtInstInteger，不是变量号
                        if (uniforms.TryGetValue(w[i + j], out CbufUse u)) { u.Dynamic = true; break; }
                    }
                }
                i += n;
            }
            return new List<CbufUse>(uniforms.Values);
        }

        /// <summary>顶点着色器的 gl_Position.w 是否处处写常量 1.0（= 2D / 全屏通道，不是透视）。用于自查：画到放宽目标、
        /// 又没读到改写矩阵、且 w 不恒为 1 的绘制 = 会被横向拉伸的透视绘制（判据红点）。无法判断时返回 false。</summary>
        public static bool PositionWIsOne(ReadOnlySpan<byte> spv)
        {
            if (spv.Length < 20 || (spv.Length & 3) != 0) return false;
            ReadOnlySpan<uint> w = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(spv);
            if (w[0] != 0x07230203) return false;
            const int OpTypeFloat = 22, OpTypePointer = 32, OpStore = 62, OpMemberDecorate = 72, DecBuiltIn = 11, BuiltInPosition = 0, StorageOutput = 3;
            var floatTypes = new HashSet<uint>(); var one = new HashSet<uint>();
            var blockTypes = new HashSet<uint>(); var posVars = new HashSet<uint>(); var blockVars = new HashSet<uint>();
            var ptrTo = new Dictionary<uint, uint>(); var wPtrs = new HashSet<uint>(); var posPtrs = new HashSet<uint>();
            var consts = new Dictionary<uint, int>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) return false;
                if (op == OpTypeFloat && n >= 3 && w[i + 2] == 32) floatTypes.Add(w[i + 1]);
                else if (op == OpConstant && n == 4) { consts[w[i + 2]] = (int)w[i + 3]; if (floatTypes.Contains(w[i + 1]) && w[i + 3] == 0x3f800000) one.Add(w[i + 2]); }
                else if (op == OpMemberDecorate && n >= 5 && w[i + 2] == 0 && w[i + 3] == DecBuiltIn && w[i + 4] == BuiltInPosition) blockTypes.Add(w[i + 1]);
                else if (op == OpDecorate && n >= 4 && w[i + 2] == DecBuiltIn && w[i + 3] == BuiltInPosition) posVars.Add(w[i + 1]);
                else if (op == OpTypePointer && n == 4 && w[i + 2] == StorageOutput) ptrTo[w[i + 1]] = w[i + 3];
                else if (op == OpVariable && n >= 4 && w[i + 3] == StorageOutput && ptrTo.TryGetValue(w[i + 1], out uint t) && blockTypes.Contains(t)) blockVars.Add(w[i + 2]);
                else if (op == OpAccessChain || op == OpInBoundsAccessChain)
                {
                    uint b = w[i + 3];
                    // 块变量：%var %int_0 %int_3；独立变量：%var %int_3
                    if (blockVars.Contains(b) && n >= 5 && consts.TryGetValue(w[i + 4], out int m0) && m0 == 0)
                    {
                        if (n == 6 && consts.TryGetValue(w[i + 5], out int c)) { if (c == 3) wPtrs.Add(w[i + 2]); }   // x / y / z 分量写入不影响
                        else posPtrs.Add(w[i + 2]);
                    }
                    else if (posVars.Contains(b) && n == 5)
                    {
                        if (!consts.TryGetValue(w[i + 4], out int c)) posPtrs.Add(w[i + 2]); else if (c == 3) wPtrs.Add(w[i + 2]);
                    }
                }
                else if (op == OpStore && n >= 3)
                {
                    uint ptr = w[i + 1], val = w[i + 2];
                    if (wPtrs.Contains(ptr)) { if (!one.Contains(val)) return false; }
                    else if (posPtrs.Contains(ptr) || posVars.Contains(ptr)) return false;   // 整个 vec4 写入：按透视算
                }
                i += n;
            }
            return wPtrs.Count > 0;
        }
    }
}
