// 通用宽屏 · 界面层越界顶点推到屏幕边：原生宽目标上，读到改写后 16:9 投影的绘制（界面层）按原尺寸居中；可游戏会把遮罩 / 黑幕 / 转场面板
// 故意画得比 16:9 画布宽（顶点在画布外），居中后两侧就盖不到屏幕边（动森圆形转场：画布外 ±1.15 的黑板居中后两侧各露约 70 像素）。
// 这里改顶点着色器：main 每次返回前读回 gl_Position，横向 NDC t = x / w 在画布边上或画布外（t² > 门限²）就整体外推 sign(t)·外推量·w——画布边上的顶点落到屏幕边、画布内的顶点不动。
// 门限² = ((1 − 3‰)/k)²、外推量 = 1 − 1/k 不烘进着色器，从支持缓冲 s2a_widen.y / .x 读（浮点位；10-20 从 s2a_flags.y / .z 迁出——那两位是 0044 贴图非归一化位图，两边互相覆盖）：所有程序一律这样改，各机型同一份、能离线预编；
// 包装层只在判定为「原生宽目标 + 读改写矩阵 + 纯色 / ≤8×8 小图」的绘制时把这两个值写成非零，其余绘制写 0（外推量 0 = 原样）。只挪位置、不动贴图坐标，所以贴图内容会被横向拉伸——采样大贴图（含横向平铺）的绘制一律不推。
// 横向收缩量 s2a_widen.z（10-21）：先 x ×= (1 − z) 再判画布边、外推。没读改写矩阵、要按原尺寸居中的界面层（原生宽目标上 CenterNative）若只采纯色 / 小图，
// 包装层改发全宽视口、z = 1 − 1/k：画布内顶点的屏幕位置与「视口收进中间」逐点相同（数学等价），画布边上的顶点落到屏幕边——全屏黑底 / 压暗遮罩铺满宽屏，不留两侧残影。z = 0 时乘 1.0，逐位不变。
// 识别：BuiltIn Position 可以是 gl_PerVertex 块成员（Ryujinx 形态，按分量写），也可以是独立输出变量；两种都在返回前整体读回再写。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public static class SpirvEdgePush
    {
        const int OpTypeBool = 20, OpTypeInt = 21, OpTypeFloat = 22, OpTypeVector = 23, OpTypePointer = 32, OpConstant = 43, OpFunction = 54, OpVariable = 59,
            OpLoad = 61, OpStore = 62, OpAccessChain = 65, OpDecorate = 71, OpMemberDecorate = 72, OpCompositeExtract = 81, OpCompositeInsert = 82,
            OpFAdd = 129, OpFSub = 131, OpFMul = 133, OpFDiv = 136, OpSelect = 169, OpLogicalOr = 166, OpLogicalAnd = 167, OpFOrdLessThan = 184, OpFOrdGreaterThan = 186, OpReturn = 253, OpFunctionEnd = 56,
            OpEntryPoint = 15, OpTypeStruct = 30, OpBitcast = 124, OpFNegate = 127;
        const uint DecBuiltIn = 11, DecBinding = 33, BuiltInPosition = 0, StorageOutput = 3, StorageUniform = 2, ExecVertex = 0;

        /// <summary>片元着色器采样的贴图绑定号（UniformConstant 存储的图像 / 采样图像变量的 Binding 装饰，数组型也算）。外推只用于「看不出拉伸」的元素：采样的贴图都很小（纯色 / 渐变底）或不采样。</summary>
        public static int[] SampledBindings(byte[] spv)
        {
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) return Array.Empty<int>();
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) return Array.Empty<int>();
            const int OpTypeImage = 25, OpTypeSampledImage = 27, OpTypeArray = 28, OpTypeRuntimeArray = 29; const uint DecBinding = 33, StorageUniformConstant = 0;
            var img = new HashSet<uint>(); var ptrs = new Dictionary<uint, uint>(); var bind = new Dictionary<uint, uint>(); var res = new List<int>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) break;
                if (op is OpTypeImage or OpTypeSampledImage) img.Add(w[i + 1]);
                else if (op is OpTypeArray or OpTypeRuntimeArray && img.Contains(w[i + 2])) img.Add(w[i + 1]);
                else if (op == OpTypePointer && n >= 4 && w[i + 2] == StorageUniformConstant && img.Contains(w[i + 3])) ptrs[w[i + 1]] = w[i + 3];
                else if (op == OpDecorate && n >= 4 && w[i + 2] == DecBinding) bind[w[i + 1]] = w[i + 3];
                else if (op == OpVariable && n >= 4 && ptrs.ContainsKey(w[i + 1]) && bind.TryGetValue(w[i + 2], out uint bb)) res.Add((int)bb);
                i += n;
            }
            return res.ToArray();
        }

        // support_buffer 的 s2a_widen（ivec4，字段登记归画幅线）：x = 外推量、y = 门限²、z = 横向收缩量（浮点位）。
        // 新布局后面追加 render_scale_y；连续脏区经过它时包装层会跟踪覆写，绘制前重发外推参数。
        // 0066 布局共 10 个成员（下标 9），10-21 点大小运行时化（0093）在它前面插 s2a_point 后 11 个（下标 10）。按「最后一个」认，新旧录像都对；
        // 少于 MinMembers 个成员的是 0066 之前没有 s2a_widen 的布局（最后一个是 s2a_flags），不改
        public const int MinMembers = 10, ParamThreshold2 = 1, ParamPush = 0, ParamShrink = 2;

        /// <summary>改顶点着色器：main 每个返回点前按 support_buffer.s2a_widen.y / .x（门限²、外推量，浮点位）把画布边外的顶点外推。参数全走支持缓冲，着色器与屏幕无关，
        /// 各机型共用一份、可离线预编；包装层逐次绘制写这两个值（不推的绘制写 0：外推量 0 = 原样）。不是顶点着色器 / 找不到 gl_Position / 支持缓冲没有 s2a_widen 成员返回 null；returns = 插了几处。</summary>
        public static byte[] Patch(byte[] spv, out int returns)
        {
            returns = 0;
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) return null;
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) return null;
            uint bound = w[3], entry = 0, posVar = 0, posBlock = 0, posMember = uint.MaxValue, fl = 0, i32 = 0, bl = 0, v4 = 0, pOutV4 = 0, firstFn = 0, sbVar = 0, pUniI32 = 0;
            var vars = new Dictionary<uint, (uint Type, uint Sc)>(); var ptrs = new Dictionary<uint, (uint Sc, uint Pointee)>(); var posDecorated = new HashSet<uint>();
            var memberPos = new Dictionary<uint, uint>(); var consts = new Dictionary<(uint T, uint V), uint>(); var vecs = new Dictionary<uint, (uint C, uint N)>();
            var structs = new Dictionary<uint, uint[]>(); var binding0 = new HashSet<uint>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) return null;
                switch (op)
                {
                    case OpEntryPoint: if (n >= 3 && w[i + 1] == ExecVertex && entry == 0) entry = w[i + 2]; break;
                    case OpDecorate:
                        if (n >= 4 && w[i + 2] == DecBuiltIn && w[i + 3] == BuiltInPosition) posDecorated.Add(w[i + 1]);
                        else if (n >= 4 && w[i + 2] == DecBinding && w[i + 3] == 0) binding0.Add(w[i + 1]);
                        break;
                    case OpMemberDecorate: if (n >= 5 && w[i + 3] == DecBuiltIn && w[i + 4] == BuiltInPosition) memberPos[w[i + 1]] = w[i + 2]; break;
                    case OpTypeFloat: if (n >= 3 && w[i + 2] == 32 && fl == 0) fl = w[i + 1]; break;
                    case OpTypeInt: if (n >= 4 && w[i + 2] == 32 && w[i + 3] == 1 && i32 == 0) i32 = w[i + 1]; break;
                    case OpTypeBool: if (bl == 0) bl = w[i + 1]; break;
                    case OpTypeVector: if (n >= 4) vecs[w[i + 1]] = (w[i + 2], w[i + 3]); break;
                    case OpTypeStruct: structs[w[i + 1]] = w.AsSpan(i + 2, n - 2).ToArray(); break;
                    case OpTypePointer: if (n >= 4) ptrs[w[i + 1]] = (w[i + 2], w[i + 3]); break;
                    case OpConstant: if (n == 4) consts.TryAdd((w[i + 1], w[i + 3]), w[i + 2]); break;
                    case OpVariable: if (n >= 4) vars[w[i + 2]] = (w[i + 1], w[i + 3]); break;
                    case OpFunction: if (firstFn == 0) firstFn = (uint)i; break;
                }
                i += n;
            }
            if (entry == 0 || fl == 0 || i32 == 0 || firstFn == 0) return null;
            foreach (var kv in vecs) if (kv.Value.C == fl && kv.Value.N == 4) { v4 = kv.Key; break; }
            if (v4 == 0) return null;
            foreach (var kv in ptrs) if (kv.Value.Sc == StorageOutput && kv.Value.Pointee == v4) { pOutV4 = kv.Key; break; }
            foreach (var kv in ptrs) if (kv.Value.Sc == StorageUniform && kv.Value.Pointee == i32) { pUniI32 = kv.Key; break; }
            foreach (var kv in vars)
            {
                if (kv.Value.Sc != StorageOutput || !ptrs.TryGetValue(kv.Value.Type, out var pt)) continue;
                if (posDecorated.Contains(kv.Key) && pt.Pointee == v4) { posVar = kv.Key; break; }
                if (memberPos.TryGetValue(pt.Pointee, out uint m)) { posVar = kv.Key; posBlock = pt.Pointee; posMember = m; break; }
            }
            // support_buffer：绑定 0 的 Uniform 变量，s2a_widen 是 ivec4。
            int paramMember = -1;
            foreach (var kv in vars)
                if (kv.Value.Sc == StorageUniform && binding0.Contains(kv.Key) && ptrs.TryGetValue(kv.Value.Type, out var pt) && structs.TryGetValue(pt.Pointee, out uint[] mem)
                    && mem.Length >= MinMembers && vecs.TryGetValue(mem[ParamMember(mem.Length)], out var mv) && mv.C == i32 && mv.N == 4) { sbVar = kv.Key; paramMember = ParamMember(mem.Length); break; }
            if (posVar == 0 || sbVar == 0) return null;

            // 缺的类型 / 常量补在第一个函数前（新 id 从 bound 起）
            var decl = new List<uint>();
            void Emit(int op, params uint[] a) { decl.Add((uint)((a.Length + 1) << 16 | op)); decl.AddRange(a); }
            uint New() => bound++;
            if (bl == 0) { bl = New(); Emit(OpTypeBool, bl); }
            if (pOutV4 == 0) { pOutV4 = New(); Emit(OpTypePointer, pOutV4, StorageOutput, v4); }
            if (pUniI32 == 0) { pUniI32 = New(); Emit(OpTypePointer, pUniI32, StorageUniform, i32); }
            uint I(uint v) { if (consts.TryGetValue((i32, v), out uint id)) return id; id = New(); Emit(OpConstant, i32, id, v); consts[(i32, v)] = id; return id; }
            uint cMember = posBlock != 0 ? I(posMember) : 0, cP = I((uint)paramMember), cE = I(ParamThreshold2), cD = I(ParamPush), cZ = I(ParamShrink);
            uint c0; { uint bits = 0; if (!consts.TryGetValue((fl, bits), out c0)) { c0 = New(); Emit(OpConstant, fl, c0, bits); } }
            uint c1; { uint bits = 0x3f800000; if (!consts.TryGetValue((fl, bits), out c1)) { c1 = New(); Emit(OpConstant, fl, c1, bits); } }
            uint cScr; { uint bits = BitConverter.SingleToUInt32Bits(Screen2); if (!consts.TryGetValue((fl, bits), out cScr)) { cScr = New(); Emit(OpConstant, fl, cScr, bits); } }
            uint cBand; { uint bits = BitConverter.SingleToUInt32Bits(BandRatio2); if (!consts.TryGetValue((fl, bits), out cBand)) { cBand = New(); Emit(OpConstant, fl, cBand, bits); } }

            // main 里每个 OpReturn 前插入：取参数、读回、算、写回
            var outw = new List<uint>(w.Length + decl.Count + 64);
            outw.AddRange(w.AsSpan(0, (int)firstFn).ToArray()); outw.AddRange(decl);
            bool inMain = false;
            for (int i = (int)firstFn; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (op == OpFunction) inMain = w[i + 2] == entry;
                if (op == OpReturn && inMain)
                {
                    void E(int o, params uint[] a) { outw.Add((uint)((a.Length + 1) << 16 | o)); outw.AddRange(a); }
                    uint pe = New(), ei = New(), e2 = New(), pd = New(), di = New(), d = New(), nd = New(), pz = New(), zi = New(), z = New(), sc = New();
                    E(OpAccessChain, pUniI32, pe, sbVar, cP, cE); E(OpLoad, i32, ei, pe); E(OpBitcast, fl, e2, ei);
                    E(OpAccessChain, pUniI32, pd, sbVar, cP, cD); E(OpLoad, i32, di, pd); E(OpBitcast, fl, d, di); E(OpFNegate, fl, nd, d);
                    E(OpAccessChain, pUniI32, pz, sbVar, cP, cZ); E(OpLoad, i32, zi, pz); E(OpBitcast, fl, z, zi); E(OpFSub, fl, sc, c1, z);
                    uint pp = posVar;
                    if (posBlock != 0) { pp = New(); E(OpAccessChain, pOutV4, pp, posVar, cMember); }
                    uint v = New(), x0 = New(), x = New(), ww = New(), t = New(), t2 = New(), big = New(), neg = New(), sd = New(), sh = New(), shz = New(), x2 = New(), v2 = New();
                    E(OpLoad, v4, v, pp);
                    // 先横向收缩：x × (1 − z)（z = 0 时乘 1.0，逐位不变）
                    E(OpCompositeExtract, fl, x0, v, 0); E(OpFMul, fl, x, x0, sc); E(OpCompositeExtract, fl, ww, v, 3);
                    E(OpFDiv, fl, t, x, ww); E(OpFMul, fl, t2, t, t);
                    // 推哪些顶点：收缩时（z > 0，原尺寸居中层）画布边上及外一律推；不收缩时只推落在 16:9 边界窄带 [门限, 门限 × 带宽比] 里的
                    //（贴着画布边的遮罩 / 底；边界外侧是游戏自己排在两侧的元素，不动——10-23 jhz 实机暗黑3 怒气液体 / 血条被推离 HUD）
                    // 只推屏幕内的（t² < (1 − 3‰)²，同门限容差，11-05）：已在屏幕边上及外的顶点不缺覆盖，挪了只让插值的采样坐标整体错开（裁剪空间全屏三角形 (−1, 3)：旷野之息光照合成左移 70 列、林克一深一浅两份）
                    uint over = New(), lim = New(), inb = New(), zp = New(), ok = New(), ons = New(), ok2 = New();
                    E(OpFOrdGreaterThan, bl, over, t2, e2); E(OpFMul, fl, lim, e2, cBand); E(OpFOrdLessThan, bl, inb, t2, lim);
                    E(OpFOrdGreaterThan, bl, zp, z, c0); E(OpLogicalOr, bl, ok, zp, inb); E(OpFOrdLessThan, bl, ons, t2, cScr); E(OpLogicalAnd, bl, ok2, ok, ons); E(OpLogicalAnd, bl, big, over, ok2);
                    E(OpFOrdLessThan, bl, neg, t, c0);
                    E(OpSelect, fl, sd, neg, nd, d); E(OpFMul, fl, sh, sd, ww); E(OpSelect, fl, shz, big, sh, c0);
                    E(OpFAdd, fl, x2, x, shz); E(OpCompositeInsert, v4, v2, x2, v, 0);
                    E(OpStore, pp, v2);
                    returns++;
                }
                if (op == OpFunctionEnd) inMain = false;
                for (int j = 0; j < n; j++) outw.Add(w[i + j]);
                i += n;
            }
            if (returns == 0) return null;
            outw[3] = bound;
            return MemoryMarshal.AsBytes(outw.ToArray().AsSpan()).ToArray();
        }

        // 新布局在 s2a_widen 后追加 render_scale_y；旧录像仍以最后一个成员为参数。
        internal static int ParamMember(int members) => members > WidenShaders.RenderScaleYMember ? WidenShaders.RenderScaleYMember - 1 : members - 1;

        /// <summary>包装层每次绘制写进 s2a_widen.y / .x 的两个值（外推开）：门限² = ((1 − 3‰)/k)²（画布边上及外，容差约 3 个画布单位），外推量 = 1 − 1/k。外推关 = (0, 0)。</summary>
        /// <summary>不收缩时推的窄带上沿 ÷ 门限，平方：((1 + 3‰) / (1 − 3‰))²（带 = 16:9 边界 ±3‰，与门限同一容差）。</summary>
        /// <summary>只推屏幕内的顶点：t² &lt; (1 − 3‰)²（同门限的 3‰ 容差；直连库尾段同一常数 0.994009）。</summary>
        public const float Screen2 = (1f - 3e-3f) * (1f - 3e-3f);
        public const float BandRatio2 = (1f + 3e-3f) / (1f - 3e-3f) * ((1f + 3e-3f) / (1f - 3e-3f));
        public static (float Threshold2, float Push) Params(float k) { float e = (1f - 3e-3f) / k; return (e * e, 1f - 1f / k); }
    }
}
