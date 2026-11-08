// 通用宽屏 · 原画框外推（10-22 八方2 色调映射暗角）：铺满画布的 2D / 全屏遍（ScaleK，没读改写矩阵）原先按「拉伸」画——片元客体 x = 真实 x ÷ k，
// UV 插值随视口横向拉伸 k 倍：暗角变椭圆、按屏幕位置取的素材横向拉开、模糊核 / 邻点偏移按客体像素走实际宽了 k 倍，中间区对 k=1 不逐点相同（八方2 差 6.68）。
// 外推语义：屏幕上真实 x 对应原画框坐标 x − pad（pad = (宽1 − 宽0)/2），两侧新区是原画框向外延伸，中间区与 16:9 逐点相同。包装层对这类绘制：
//   视口照拉伸（ScaleK）铺满放宽目标、几何不动，s2a_widen.w = pad（≠ 0 即外推开）、s2a_widen.y = 目标放宽比 k；
//   片元着色器（本文件）：
//   ① 片元坐标：Ryujinx 生成的「gl_FragCoord.x ÷ render_scale[0]」先减实际像素 pad（包装层外推时 render_scale[0] 保留原分辨率倍率 r）；
//   ② 插值：拉伸视口下真实 x 处的插值是客体坐标 x / k 处的值，原画框外推要客体坐标 x − pad 处：v + dFdx(v)·((x − pad)·k − x)（属性对屏幕 x 仿射，
//      全屏四边形上精确；10-23 起不再动顶点——旧做法收缩 + 把超门限顶点外推固定量，比屏幕大的世界面片被放大移位（丝之歌）；最坏退化就是拉伸本身）；
//   ③ 采样放宽贴图（归一化坐标）：放宽贴图内容居中排布（Hor 1:1 放宽、本语义写出的都是），原宽 w0 下的坐标 u 在放宽贴图里是 (u·w0 + off)/w1，off = (w1 − w0)/2：
//      x' = x·a + c，a = (w1 − 2·off)/w1、c = off/w1（w1 = textureSize，off 从 render_scale[1 + 缩放下标] 读：包装层外推时按所绑贴图写 off、没放宽 = 0）；
//   ④ 整数取图 / 尺寸查询：外推开时 x·r + off（按需加入真实片元相位）、(尺寸 − 2·off)/r，r 读独立 Y 数组的原纹理倍率；Y 辅助函数保持原路。
// 外推关（s2a_widen.w = 0）时与改前逐位同值：①减 0、②修正量选 0、③ a = 1 c = 0、④照原路。
// 缩放下标 = 片元贴图绑定号 − 128（Ryujinx Vulkan 口径：片元阶段号 1 × 每阶段贴图上限 64 × 2 + 静态贴图序号，GpuAccessorBase.CreateTextureBinding；
//   与辅助函数调用里的缩放下标对不上就不改）。顶点按计算着色器跑的程序（ResourceReservations：预留 2 + 32 个贴图绑定，片元贴图从 162 起）不改。改不全（片元坐标 x 有不经 ÷ render_scale[0] 的用法、插值有非常量下标读法、2D 采样认不出绑定、
//   location 31 已占用…）就不改，程序照旧按拉伸画（why 写原因）。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public static class SpirvExtrap
    {
        /// <summary>s2a_widen 的 y 分量：外推时 = 目标的放宽比 k（拉伸视口下插值按 X / k 取值，外推换算要用）。</summary>
        public const int ParamScale = 1;
        /// <summary>s2a_widen 的 w 分量：外推开时 = 目标的 pad（浮点位），关 = 0。</summary>
        public const int ParamPad = 3;
        /// <summary>片元贴图绑定号起点（见文件头）。</summary>
        public const int FragTexBase = 128;
        const int ReservedTextures = 2 + 32;

        const int OpExtInstImport = 11, OpExtInst = 12, OpCapability = 17, OpEntryPoint = 15, OpTypeBool = 20, OpTypeInt = 21, OpTypeFloat = 22, OpTypeVector = 23, OpTypeImage = 25, OpTypeSampledImage = 27,
            OpTypeStruct = 30, OpTypePointer = 32, OpTypeFunction = 33, OpConstant = 43, OpFunction = 54, OpFunctionParameter = 55, OpFunctionEnd = 56, OpVariable = 59,
            OpLoad = 61, OpStore = 62, OpAccessChain = 65, OpInBoundsAccessChain = 66, OpDecorate = 71, OpMemberDecorate = 72, OpCompositeConstruct = 80,
            OpCompositeExtract = 81, OpCompositeInsert = 82, OpCopyObject = 83, OpSampledImage = 86, OpImage = 100, OpImageQuerySizeLod = 103,
            OpConvertFToS = 110, OpConvertSToF = 111, OpBitcast = 124, OpFNegate = 127, OpIAdd = 128, OpFAdd = 129, OpISub = 130, OpFSub = 131, OpFMul = 133, OpFDiv = 136, OpFMod = 141,
            OpVectorTimesScalar = 142, OpLogicalAnd = 167, OpSelect = 169, OpIEqual = 170, OpFOrdNotEqual = 182, OpFOrdLessThan = 184, OpDPdx = 207,
            OpSelectionMerge = 247, OpLabel = 248, OpBranch = 249, OpBranchConditional = 250, OpReturnValue = 254, OpPhi = 245;
        const uint DecBuiltIn = 11, DecNoPerspective = 13, DecFlat = 14, DecLocation = 30, DecBinding = 33, BuiltInFragCoord = 15,
            ScInput = 1, ScUniform = 2, ScFunction = 7, CapImageQuery = 50, ExecFragment = 4, Dim2D = 1;

        static bool IsSample(int op) => op is >= 87 and <= 94 or 96 or 97 or >= 305 and <= 312 or 314 or 315;
        static bool IsProj(int op) => op is >= 91 and <= 94 or >= 309 and <= 312;
        static bool HasDref(int op) => op is 89 or 90 or 93 or 94 or 97 or 307 or 308 or 311 or 312 or 315;
        static bool IsGather(int op) => op is 96 or 97 or 314 or 315;
        // 函数体里没有「结果类型 + 结果」的指令
        static bool NoResult(int op) => op is 0 or 8 or 317 or OpStore or 63 or OpSelectionMerge or 246 or OpLabel or 249 or OpBranchConditional or 251 or 252 or 253 or OpReturnValue
            or 255 or 99 or 224 or 225 or 218 or 219 or OpFunctionEnd or 228 or 4416 or 5380 or 221 or 222;

        static int FindLabel(uint[] w, int from) { for (int i = from; i < w.Length;) { if ((w[i] & 0xffff) == OpLabel) return i; i += (int)(w[i] >> 16); } return -1; }

        /// <summary>片元着色器：返回改后的字节；改不了返回 null（why = 原因）。fetchScales = SpirvFetchScale 认出的取图缩放项（核对缩放下标口径）；
        /// samples = 归一化采样换算用到的 (render_scale 下标, 绑定号)，包装层外推时按所绑贴图写 off。</summary>
        public static byte[] PatchFragment(byte[] spv, int renderScaleMember, (int Index, int Binding, bool Image)[] fetchScales, out (int Index, int Binding)[] samples, out string why)
        {
            samples = Array.Empty<(int, int)>(); why = null;
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) { why = "不是 SPIR-V"; return null; }
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) { why = "不是 SPIR-V"; return null; }

            // ---------- 模块级 ----------
            uint bound = w[3], entry = 0, fl = 0, i32 = 0, bl = 0, fragCoord = 0, sbVar = 0, glsl = 0;
            int epAt = -1, firstFn = -1, annoEnd = -1, firstType = -1, sbMembers = 0;
            var caps = new HashSet<uint>(); var loc = new Dictionary<uint, uint>(); var builtin = new HashSet<uint>(); var flat = new HashSet<uint>(); var bind = new Dictionary<uint, uint>();
            var vecs = new Dictionary<(uint C, uint N), uint>(); var vecOf = new Dictionary<uint, (uint C, uint N)>();
            var ptrs = new Dictionary<(uint Sc, uint T), uint>(); var ptrOf = new Dictionary<uint, (uint Sc, uint T)>();
            var structs = new Dictionary<uint, uint[]>(); var imgT = new Dictionary<uint, (uint Dim, bool Arr, bool Ms)>(); var simgOf = new Dictionary<uint, uint>();
            var consts = new Dictionary<(uint T, uint V), uint>(); var constOf = new Dictionary<uint, uint>(); var vars = new Dictionary<uint, (uint Ptr, uint Sc)>();
            var fnTypes = new HashSet<uint>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) { why = "指令长度坏"; return null; }
                switch (op)
                {
                    case OpCapability: caps.Add(w[i + 1]); break;
                    case OpExtInstImport: if (n >= 3 && w[i + 2] == 0x4c534c47u) glsl = w[i + 1]; break;   // "GLSL.std.450" 首 4 字节
                    case OpEntryPoint: if (w[i + 1] == ExecFragment && entry == 0) { entry = w[i + 2]; epAt = i; } break;
                    case OpDecorate:
                        if (n >= 4 && w[i + 2] == DecLocation) loc[w[i + 1]] = w[i + 3];
                        else if (n >= 4 && w[i + 2] == DecBuiltIn) { builtin.Add(w[i + 1]); if (w[i + 3] == BuiltInFragCoord) fragCoord = w[i + 1]; }
                        else if (w[i + 2] == DecFlat) flat.Add(w[i + 1]);
                        else if (n >= 4 && w[i + 2] == DecBinding) bind[w[i + 1]] = w[i + 3];
                        annoEnd = i + n; break;
                    case OpMemberDecorate: case 73: case 74: case 75: case 332: case 5632: case 5633: annoEnd = i + n; break;
                    case OpTypeBool: if (bl == 0) bl = w[i + 1]; break;
                    case OpTypeInt: if (n >= 4 && w[i + 2] == 32 && w[i + 3] == 1 && i32 == 0) i32 = w[i + 1]; break;
                    case OpTypeFloat: if (n >= 3 && w[i + 2] == 32 && fl == 0) fl = w[i + 1]; break;
                    case OpTypeVector: if (n >= 4) { vecs.TryAdd((w[i + 2], w[i + 3]), w[i + 1]); vecOf[w[i + 1]] = (w[i + 2], w[i + 3]); } break;
                    case OpTypeImage: if (n >= 9) imgT[w[i + 1]] = (w[i + 3], w[i + 5] != 0, w[i + 6] != 0); break;
                    case OpTypeSampledImage: if (n >= 3) simgOf[w[i + 1]] = w[i + 2]; break;
                    case OpTypeStruct: structs[w[i + 1]] = w.AsSpan(i + 2, n - 2).ToArray(); break;
                    case OpTypePointer: if (n >= 4) { ptrs.TryAdd((w[i + 2], w[i + 3]), w[i + 1]); ptrOf[w[i + 1]] = (w[i + 2], w[i + 3]); } break;
                    case OpTypeFunction: fnTypes.Add(w[i + 1]); break;
                    case OpConstant: if (n == 4) { consts.TryAdd((w[i + 1], w[i + 3]), w[i + 2]); constOf[w[i + 2]] = w[i + 3]; } break;
                    case OpVariable: if (n >= 4) vars[w[i + 2]] = (w[i + 1], w[i + 3]); break;
                    case OpFunction: if (firstFn < 0) firstFn = i; break;
                }
                if (firstType < 0 && op is >= 19 and <= 39) firstType = i;
                i += n;
            }
            if (entry == 0 || epAt < 0) { why = "不是片元着色器"; return null; }
            foreach (var kv in vars)
                if (kv.Value.Sc == 0 && bind.TryGetValue(kv.Key, out uint tb) && tb >= FragTexBase + ReservedTextures && tb < FragTexBase + 64 && ptrOf.TryGetValue(kv.Value.Ptr, out var tp) && simgOf.ContainsKey(tp.T))
                {
                    bool low = false; foreach (var kv2 in vars) if (kv2.Value.Sc == 0 && bind.TryGetValue(kv2.Key, out uint tb2) && tb2 >= FragTexBase && tb2 < FragTexBase + ReservedTextures) low = true;
                    if (!low) { why = "顶点按计算着色器跑的程序（片元贴图绑定从 162 起）"; return null; }
                    break;
                }
            foreach (var s in fetchScales ?? Array.Empty<(int, int, bool)>())
                if (!s.Image && s.Index != 1 + s.Binding - FragTexBase) { why = $"缩放下标 {s.Index} 与绑定号 {s.Binding} 对不上口径"; return null; }
            if (fl == 0 || i32 == 0 || firstFn < 0) { why = "缺 float / int 类型"; return null; }
            foreach (var kv in vars)
                if (kv.Value.Sc == ScUniform && bind.TryGetValue(kv.Key, out uint b0) && b0 == 0 && ptrOf.TryGetValue(kv.Value.Ptr, out var pt) && structs.TryGetValue(pt.T, out uint[] mem)
                    && mem.Length >= SpirvEdgePush.MinMembers && vecOf.TryGetValue(mem[SpirvEdgePush.ParamMember(mem.Length)], out var mv) && mv.C == i32 && mv.N == 4 && mem.Length > renderScaleMember) { sbVar = kv.Key; sbMembers = mem.Length; break; }
            if (sbVar == 0) { why = "支持缓冲没有 s2a_widen"; return null; }
            // 片元输入：要修正的（浮点、非 flat、有 location、非内建）；location 31 被占用就不改
            var inputs = new List<(uint Var, uint T, uint N)>();
            foreach (var kv in vars)
            {
                if (kv.Value.Sc != ScInput || builtin.Contains(kv.Key) || !loc.TryGetValue(kv.Key, out uint l)) continue;
                if (flat.Contains(kv.Key) || !ptrOf.TryGetValue(kv.Value.Ptr, out var ip)) continue;
                if (ip.T == fl) inputs.Add((kv.Key, fl, 1));
                else if (vecOf.TryGetValue(ip.T, out var iv) && iv.C == fl) inputs.Add((kv.Key, ip.T, iv.N));
            }
            var inputSet = new HashSet<uint>(); foreach (var x in inputs) inputSet.Add(x.Var);

            // ---------- 函数：认辅助函数（读 render_scale[动态下标]），各函数入口块插入点 ----------
            var fns = new List<(int Start, uint Id, uint Ret, List<uint> Params, int Body, int End)>();
            {
                int st = -1, body = -1; uint id = 0, ret = 0; List<uint> ps = null;
                for (int i = firstFn; i < w.Length;)
                {
                    int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                    if (op == OpFunction) { st = i; id = w[i + 2]; ret = w[i + 1]; ps = new List<uint>(); body = -1; }
                    else if (op == OpFunctionParameter) ps.Add(w[i + 2]);
                    else if (op == OpLabel && body < 0) { body = i + n; while (body < w.Length && (w[body] & 0xffff) == OpVariable) body += (int)(w[body] >> 16); }
                    else if (op == OpFunctionEnd) fns.Add((st, id, ret, ps, body, i));
                    i += n;
                }
            }
            var paramTypes = new Dictionary<uint, uint>();
            for (int i = firstFn; i < w.Length;) { int n = (int)(w[i] >> 16); if ((w[i] & 0xffff) == OpFunctionParameter) paramTypes[w[i + 2]] = w[i + 1]; i += n; }
            var helpers = new Dictionary<uint, int>();   // 函数 → 参数个数（3 = TexelFetchScale 片元版、2 = TextureSizeUnscale）
            foreach (var f in fns)
                for (int i = f.Start; i < f.End;)
                {
                    int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                    if ((op == OpAccessChain || op == OpInBoundsAccessChain) && n == 6 && w[i + 3] == sbVar && constOf.TryGetValue(w[i + 4], out uint m) && m == (uint)renderScaleMember && !constOf.ContainsKey(w[i + 5]))
                    { helpers[f.Id] = f.Params.Count; break; }
                    i += n;
                }
            foreach (var h in helpers) if (h.Value != 2 && h.Value != 3) { why = $"缩放辅助函数参数 {h.Value} 个，认不出"; return null; }
            (int Start, uint Id, uint Ret, List<uint> Params, int Body, int End) main = default;
            foreach (var f in fns) if (f.Id == entry) main = f;
            if (main.Body <= 0) { why = "找不到 main"; return null; }

            // ---------- 函数体数据流 ----------
            var typeOf = new Dictionary<uint, uint>(); var defAt = new Dictionary<uint, int>();   // main 里结果 id → 定义指令位置（夹紧链回溯用）
            var store1 = new Dictionary<uint, uint>(); var storeN = new Dictionary<uint, int>();   // main 里局部变量 → 唯一一次写入的值 / 写入次数（Ryujinx 中间值经局部变量转手）
            const byte TFragX = 1, TScale = 2;
            var tag = new Dictionary<uint, byte>();            // 值或指针 → 片元坐标 x / render_scale[0]
            var fragX = new HashSet<uint>();                    // 片元坐标 x 的值（含经局部变量转手的）
            var divs = new List<(int At, uint X)>();            // FDiv(片元 x, 缩放)
            var chainIn = new Dictionary<uint, (uint Var, uint C)>();   // 指向输入分量的指针
            var inLoads = new List<(int At, uint Var, int C)>();        // 读输入（C = −1 整个读）
            var img = new Dictionary<uint, uint>();              // 采样图像 / 图像值 → 绑定号
            var samps = new List<(int At, uint Binding)>();
            var smpBind = new SortedSet<uint>();
            foreach (var f in fns)
            {
                bool isMain = f.Id == entry, isHelper = helpers.ContainsKey(f.Id);
                for (int i = f.Start; i <= f.End;)
                {
                    int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                    if (!NoResult(op) && n >= 3 && op != OpFunction) { typeOf[w[i + 2]] = w[i + 1]; if (isMain) defAt[w[i + 2]] = i; }
                    if (isHelper) { i += n; continue; }   // 辅助函数整个由④接管（读片元坐标 / 缩放都在外推关的原路里）
                    switch (op)
                    {
                        case OpAccessChain: case OpInBoundsAccessChain:
                            if (w[i + 3] == fragCoord) { if (n == 5 && constOf.TryGetValue(w[i + 4], out uint c) && c == 0) tag[w[i + 2]] = TFragX; else if (n != 5 || !constOf.ContainsKey(w[i + 4])) { why = "片元坐标非常量下标读"; return null; } }
                            else if (w[i + 3] == sbVar && n == 6 && constOf.TryGetValue(w[i + 4], out uint m) && m == (uint)renderScaleMember && constOf.TryGetValue(w[i + 5], out uint e) && e == 0) tag[w[i + 2]] = TScale;
                            else if (inputSet.Contains(w[i + 3]))
                            {
                                if (n != 5 || !constOf.TryGetValue(w[i + 4], out uint ic)) { why = "插值非常量下标读"; return null; }
                                chainIn[w[i + 2]] = (w[i + 3], ic);
                            }
                            break;
                        case OpLoad:
                            if (w[i + 3] == fragCoord) { why = "整个读片元坐标"; return null; }
                            if (tag.TryGetValue(w[i + 3], out byte t)) { tag[w[i + 2]] = t; if (t == TFragX) fragX.Add(w[i + 2]); }
                            if (inputSet.Contains(w[i + 3])) inLoads.Add((i, w[i + 3], -1));
                            else if (chainIn.TryGetValue(w[i + 3], out var ci)) inLoads.Add((i, ci.Var, (int)ci.C));
                            if (vars.ContainsKey(w[i + 3]) && bind.TryGetValue(w[i + 3], out uint bb)) img[w[i + 2]] = bb;
                            else if (img.TryGetValue(w[i + 3], out uint ib)) img[w[i + 2]] = ib;
                            break;
                        case OpStore:
                            if (isMain) { storeN[w[i + 1]] = storeN.GetValueOrDefault(w[i + 1]) + 1; store1[w[i + 1]] = w[i + 2]; }
                            if (tag.TryGetValue(w[i + 2], out byte t2)) tag[w[i + 1]] = t2; else tag.Remove(w[i + 1]);
                            if (img.TryGetValue(w[i + 2], out uint sb2)) img[w[i + 1]] = sb2;
                            break;
                        case OpCopyObject:
                            if (tag.TryGetValue(w[i + 3], out byte t3)) { tag[w[i + 2]] = t3; if (t3 == TFragX) fragX.Add(w[i + 2]); }
                            if (img.TryGetValue(w[i + 3], out uint cb)) img[w[i + 2]] = cb;
                            break;
                        case OpSampledImage: case OpImage:
                            if (img.TryGetValue(w[i + 3], out uint sib)) img[w[i + 2]] = sib;
                            break;
                        case OpFDiv:
                            if (n == 5 && fragX.Contains(w[i + 3]) && tag.TryGetValue(w[i + 4], out byte d) && d == TScale)
                            { if (!isMain) { why = "片元坐标在 main 以外的函数里换算"; return null; } divs.Add((i, w[i + 3])); }
                            break;
                    }
                    if (IsSample(op) && n >= 5)
                    {
                        uint st = typeOf.TryGetValue(w[i + 3], out uint s0) ? s0 : 0;
                        if (simgOf.TryGetValue(st, out uint it) && imgT.TryGetValue(it, out var id) && id.Dim == Dim2D && !id.Ms)
                        {
                            if (!img.TryGetValue(w[i + 3], out uint sbnd)) { why = "2D 采样认不出贴图绑定"; return null; }
                            if (!isMain) { why = "2D 采样在 main 以外的函数里"; return null; }
                            int idx = (int)sbnd - FragTexBase;
                            if (idx < 0 || 1 + idx >= 73) { why = $"采样绑定号 {sbnd} 不在片元贴图口径内"; return null; }
                            samps.Add((i, sbnd)); smpBind.Add(sbnd);
                        }
                    }
                    // 用法检查：片元坐标 x 只许被 ÷ 缩放（或转存）；插值变量 / 其分量指针只许被读
                    // （OpExtInst 第 3、4 字是扩展集与指令号字面量，跳过，免得指令号恰好等于某个 id）
                    if (op != OpLoad && op != OpStore && op != OpCopyObject && !(op == OpFDiv && n == 5 && tag.TryGetValue(w[i + 4], out byte dd) && dd == TScale))
                        for (int j = 1; j < n; j++) if ((op != OpExtInst || j > 4) && fragX.Contains(w[i + j])) { why = $"片元坐标 x 有不经 ÷ render_scale[0] 的用法（op {op}）"; return null; }
                    if (op == OpStore && fragX.Contains(w[i + 1])) { why = "往片元坐标里写"; return null; }
                    if (op != OpLoad && op != OpAccessChain && op != OpInBoundsAccessChain)
                        for (int j = 1; j < n; j++) if ((op != OpExtInst || j > 4) && (inputSet.Contains(w[i + j]) || chainIn.ContainsKey(w[i + j]))) { why = $"插值有读以外的用法（op {op}）"; return null; }
                    if ((op == OpAccessChain || op == OpInBoundsAccessChain || op == OpLoad) && !isMain && (inputSet.Contains(w[i + 3]) || chainIn.ContainsKey(w[i + 3]))) { why = "插值在 main 以外的函数里读"; return null; }
                    i += n;
                    if (op == OpFunctionEnd) break;
                }
            }
            if (divs.Count == 0 && inputs.Count == 0 && samps.Count == 0 && helpers.Count == 0) { why = "没有可改的（不读片元坐标 / 插值 / 2D 贴图）"; return null; }

            // ---------- 输出 ----------
            uint New() => bound++;
            var decl = new List<uint>(); var anno = new List<uint>();
            void D(List<uint> o, int op, params uint[] a) { o.Add((uint)((a.Length + 1) << 16 | op)); o.AddRange(a); }
            uint Ptr(uint sc, uint t) { if (ptrs.TryGetValue((sc, t), out uint id)) return id; id = New(); D(decl, OpTypePointer, id, sc, t); ptrs[(sc, t)] = id; return id; }
            uint Vec(uint c, uint nn) { if (vecs.TryGetValue((c, nn), out uint id)) return id; id = New(); D(decl, OpTypeVector, id, c, nn); vecs[(c, nn)] = id; vecOf[id] = (c, nn); return id; }
            uint K(uint t, uint v) { if (consts.TryGetValue((t, v), out uint id)) return id; id = New(); D(decl, OpConstant, t, id, v); consts[(t, v)] = id; return id; }
            uint F(float f) => K(fl, BitConverter.SingleToUInt32Bits(f));
            uint I(int v) => K(i32, (uint)v);
            if (bl == 0) { bl = New(); D(decl, OpTypeBool, bl); }
            uint pUI = Ptr(ScUniform, i32), pUF = Ptr(ScUniform, fl), v4 = Vec(fl, 4);
            uint cPM = I(SpirvEdgePush.ParamMember(sbMembers)), cPad = I(ParamPad), cK = I(ParamScale), cRS = I(renderScaleMember), f0 = F(0f), f1 = F(1f), f2 = F(2f), fh = F(0.5f), i0 = I(0), i1 = I(1);
            bool dualAxis = sbMembers > WidenShaders.RenderScaleYMember;
            uint cRY = dualAxis ? I(WidenShaders.RenderScaleYMember) : cRS;
            uint addFc = 0;   // 插值外推要片元坐标 x：着色器没声明 gl_FragCoord 就补一个内建输入（加进入口接口）
            if (inputs.Count > 0 && fragCoord == 0)
            {
                uint pIn = Ptr(ScInput, v4); addFc = fragCoord = New(); D(decl, OpVariable, pIn, fragCoord, ScInput);
                D(anno, OpDecorate, fragCoord, DecBuiltIn, BuiltInFragCoord);
            }
            var before = new Dictionary<int, List<uint>>(); var repl = new Dictionary<int, uint[]>();
            var relabel = new List<(int From, int To, uint Old, uint New)>();
            List<uint> At(int i) { if (!before.TryGetValue(i, out var l)) before[i] = l = new List<uint>(); return l; }

            // main 入口：pad / 外推开、(q, r) 修正量、各输入修正值、各 2D 采样绑定的 a / c
            // main 入口块：读 pad、外推开 isE、原插值值；外推开才进分支 E 算插值修正与各 2D 采样绑定的 a / c，汇合块用 OpPhi 取值——
            // 关时取原值（逐位同原着色器；直接算 v + dFdx(v)·0 在 GPU 上不逐位等于 v，10-22 塞尔达门禁录像 7051 像素差 7 级），平时也不付导数 / 尺寸查询的开销
            var ent = At(main.Body);
            uint P = New(), pw = New(), pwi = New(), isE = New(), lbE = New(), lbM = New();
            // 原入口块的标签要给 OpPhi 当来源：入口块首条 OpLabel 的结果 id
            uint lbEnt = w[FindLabel(w, main.Start) + 1];
            relabel.Add((main.Start, main.End, lbEnt, lbM));   // 原入口块的后半截落在汇合块：别处 OpPhi 以入口块为来源的改指汇合块
            D(ent, OpAccessChain, pUI, pw, sbVar, cPM, cPad); D(ent, OpLoad, i32, pwi, pw); D(ent, OpBitcast, fl, P, pwi); D(ent, OpFOrdNotEqual, bl, isE, P, f0);
            var orig = new Dictionary<uint, uint>();
            foreach (var (var, t, _) in inputs) { uint v = New(); D(ent, OpLoad, t, v, var); orig[var] = v; }
            var eb = new List<uint>();   // 分支 E 的指令
            var fixedE = new Dictionary<uint, uint>();
            if (inputs.Count > 0)
            {
                // 视口照拉伸（ScaleK）铺满，插值是客体坐标 g = X / k 处的值；原画框外推要 g = X − pad 处：v + dv/dX·((X − pad)·k − X)，k = s2a_widen.y（包装层外推时写目标放宽比）
                uint fcv = New(), X = New(), pk = New(), ki = New(), kk = New(), xp = New(), xk = New(), s = New();
                D(eb, OpLoad, v4, fcv, fragCoord); D(eb, OpCompositeExtract, fl, X, fcv, 0);
                D(eb, OpAccessChain, pUI, pk, sbVar, cPM, cK); D(eb, OpLoad, i32, ki, pk); D(eb, OpBitcast, fl, kk, ki);
                D(eb, OpFSub, fl, xp, X, P); D(eb, OpFMul, fl, xk, xp, kk); D(eb, OpFSub, fl, s, xk, X);
                foreach (var (var, t, nn) in inputs)
                {
                    uint v = orig[var], dv = New(), m = New(), vf = New();
                    D(eb, OpDPdx, t, dv, v);
                    if (nn == 1) D(eb, OpFMul, t, m, dv, s); else D(eb, OpVectorTimesScalar, t, m, dv, s);
                    D(eb, OpFAdd, t, vf, v, m); fixedE[var] = vf;
                }
            }
            var acE = new Dictionary<uint, (uint A, uint C)>(); var offE = new Dictionary<uint, uint>();
            bool needQuery = false;
            foreach (uint b in smpBind)
            {
                uint var = 0; foreach (var kv in vars) if (kv.Value.Sc == 0 && bind.TryGetValue(kv.Key, out uint vb) && vb == b && ptrOf.TryGetValue(kv.Value.Ptr, out var vp) && simgOf.ContainsKey(vp.T)) { var = kv.Key; break; }
                if (var == 0) { why = $"绑定 {b} 不是组合采样器变量"; return null; }
                uint st = ptrOf[vars[var].Ptr].T, it = simgOf[st]; var id = imgT[it]; uint sz = Vec(i32, id.Arr ? 3u : 2u);
                uint si = New(), im = New(), q = New(), wx = New(), w1 = New(), pr = New(), off = New(), o2 = New(), num = New(), aE = New(), cE = New();
                D(eb, OpLoad, st, si, var); D(eb, OpImage, it, im, si); D(eb, OpImageQuerySizeLod, sz, q, im, i0); D(eb, OpCompositeExtract, i32, wx, q, 0); D(eb, OpConvertSToF, fl, w1, wx);
                D(eb, OpAccessChain, pUF, pr, sbVar, cRS, I(1 + (int)b - FragTexBase)); D(eb, OpLoad, fl, off, pr);
                D(eb, OpFMul, fl, o2, off, f2); D(eb, OpFSub, fl, num, w1, o2); D(eb, OpFDiv, fl, aE, num, w1); D(eb, OpFDiv, fl, cE, off, w1);
                acE[b] = (aE, cE); offE[b] = off; needQuery = true;
            }
            var pendingPhi = new List<(uint E, uint V)>();   // ⑤ 夹紧放宽量 e：外推开取 V、关取 0
            // ⑤ 取图坐标的夹紧（10-23 八方2 左侧横条：动态分辨率常见 uv = clamp(uv, 有效矩形下沿, 上沿)，外推后两侧 uv 越出 [0,1] 被夹回边缘 → 边缘像素横向拉长）：
            //   从每个 2D 采样坐标的 x 分量往回追（isnan 选择 → 组合构造 → ÷ / × 尺寸 → FMin / FMax / FClamp），夹紧的边界在外推开时放宽：
            //   上界 + e、下界 − e。e = 原画框外多出的那截：在除以尺寸之后（归一化）= c / a = off / w0，之前（像素）= off。外推关时 e = 0（逐位同改前）。
            //   一条夹紧被几个绑定的采样共用、算出的 e 来源不一致就不动它
            var clampAt = new Dictionary<int, (uint Binding, bool Px)>(); var clampBad = new HashSet<int>();
            bool Local1(uint p, out uint v) { v = 0; return vars.TryGetValue(p, out var pv) && pv.Sc == ScFunction && storeN.GetValueOrDefault(p) == 1 && store1.TryGetValue(p, out v); }
            foreach (var (at, b) in samps)
            {
                uint node = w[at + 4]; int guard = 0;
                // 坐标向量 → x 分量
                while (guard++ < 8 && defAt.TryGetValue(node, out int di))
                {
                    int dop = (int)(w[di] & 0xffff);
                    if (dop == OpSelect) { uint o1 = w[di + 4], o2 = w[di + 5]; bool d1 = defAt.ContainsKey(o1), d2 = defAt.ContainsKey(o2); if (d1 == d2) { node = 0; break; } node = d1 ? o1 : o2; continue; }
                    if (dop == OpCopyObject) { node = w[di + 3]; continue; }
                    if (dop == OpLoad && Local1(w[di + 3], out uint sv)) { node = sv; continue; }
                    if (dop == OpCompositeConstruct) { node = w[di + 3]; break; }
                    node = 0; break;
                }
                if (node == 0 || !typeOf.TryGetValue(node, out uint nt) || nt != fl) continue;
                bool px = false; guard = 0;
                while (guard++ < 16 && defAt.TryGetValue(node, out int di))
                {
                    int dop = (int)(w[di] & 0xffff), dn = (int)(w[di] >> 16);
                    if (dop == OpCopyObject) { node = w[di + 3]; continue; }
                    if (dop == OpLoad && Local1(w[di + 3], out uint sv2)) { node = sv2; continue; }
                    if ((dop == OpFDiv || dop == OpFMul) && dn == 5) { node = w[di + 3]; px = true; continue; }   // ÷ 尺寸 / × 倒数：再往前是像素单位
                    if (dop == OpExtInst && dn >= 7 && w[di + 3] == glsl && glsl != 0)
                    {
                        uint ins = w[di + 4];
                        bool mn = ins is 37 or 79, mx = ins is 40 or 80, cl = (ins is 43 or 81) && dn == 8;
                        if (!mn && !mx && !cl) break;
                        // 链上的那个操作数：有定义且不是常量的；边界必须是浮点标量
                        uint a0 = w[di + 5], a1 = w[di + 6]; uint chain;
                        if (cl) chain = a0; else if (defAt.ContainsKey(a0) && !defAt.ContainsKey(a1)) chain = a0; else if (defAt.ContainsKey(a1) && !defAt.ContainsKey(a0)) chain = a1; else if (defAt.ContainsKey(a0)) chain = a0; else break;
                        if (clampAt.TryGetValue(di, out var prev) && (prev.Binding != b || prev.Px != px)) clampBad.Add(di); else clampAt[di] = (b, px);
                        node = chain; continue;
                    }
                    break;
                }
            }
            if (clampAt.Count > 0)
            {
                var eN = new Dictionary<uint, uint>(); var eP = new Dictionary<uint, uint>();
                uint EOf(uint b, bool px)
                {
                    var dict = px ? eP : eN; if (dict.TryGetValue(b, out uint e)) return e;
                    uint vE; if (px) vE = offE[b]; else { vE = New(); D(eb, OpFDiv, fl, vE, acE[b].C, acE[b].A); }
                    e = New(); dict[b] = e; pendingPhi.Add((e, vE)); return e;
                }
                foreach (var kv in clampAt)
                {
                    if (clampBad.Contains(kv.Key) || !acE.ContainsKey(kv.Value.Binding)) continue;
                    int di = kv.Key; int dn = (int)(w[di] >> 16); uint ins = w[di + 4];
                    uint[] r = w.AsSpan(di, dn).ToArray(); uint e = EOf(kv.Value.Binding, kv.Value.Px); var pre = At(di);
                    bool cl = ins is 43 or 81;
                    if (cl) { uint lo = New(), hi = New(); D(pre, OpFSub, fl, lo, r[6], e); D(pre, OpFAdd, fl, hi, r[7], e); r[6] = lo; r[7] = hi; }
                    else
                    {
                        int bi = defAt.ContainsKey(r[5]) && !defAt.ContainsKey(r[6]) ? 6 : defAt.ContainsKey(r[6]) && !defAt.ContainsKey(r[5]) ? 5 : 6;   // 边界那个操作数
                        if (typeOf.TryGetValue(r[bi], out uint bt) && bt != fl) continue;
                        uint nb = New(); D(pre, ins is 37 or 79 ? OpFAdd : OpFSub, fl, nb, r[bi], e); r[bi] = nb;
                    }
                    repl[di] = r;
                }
            }

            var fixedIn = new Dictionary<uint, uint>(); var ac = new Dictionary<uint, (uint A, uint C)>();
            D(ent, OpSelectionMerge, lbM, 0); D(ent, OpBranchConditional, isE, lbE, lbM);
            D(ent, OpLabel, lbE); ent.AddRange(eb); D(ent, OpBranch, lbM);
            D(ent, OpLabel, lbM);
            foreach (var (var, t, _) in inputs) { uint ph = New(); D(ent, OpPhi, t, ph, fixedE[var], lbE, orig[var], lbEnt); fixedIn[var] = ph; }
            foreach (var kv in acE) { uint pa = New(), pc = New(); D(ent, OpPhi, fl, pa, kv.Value.A, lbE, f1, lbEnt); D(ent, OpPhi, fl, pc, kv.Value.C, lbE, f0, lbEnt); ac[kv.Key] = (pa, pc); }
            foreach (var (e, v) in pendingPhi) D(ent, OpPhi, fl, e, v, lbE, f0, lbEnt);

            // ① 片元坐标 x ÷ 缩放 → (x − pad) ÷ 缩放
            foreach (var (at, x) in divs)
            {
                uint xs = New(); D(At(at), OpFSub, fl, xs, x, P);
                uint[] r = w.AsSpan(at, 5).ToArray(); r[3] = xs; repl[at] = r;
            }
            // ② 读插值 → 取修正值
            foreach (var (at, var, c) in inLoads)
                repl[at] = c < 0 ? new uint[] { (4u << 16) | OpCopyObject, w[at + 1], w[at + 2], fixedIn[var] } : new uint[] { (5u << 16) | OpCompositeExtract, w[at + 1], w[at + 2], fixedIn[var], (uint)c };
            // ③ 2D 归一化采样：x' = x·a + c（投影版 x' = x·a + c·q）；梯度的 x 分量 ×a；纹素偏移是客体纹素 = 真实纹素（1:1），不改
            foreach (var (at, b) in samps)
            {
                int n = (int)(w[at] >> 16), op = (int)(w[at] & 0xffff); uint[] r = repl.TryGetValue(at, out uint[] r0) ? r0 : w.AsSpan(at, n).ToArray();
                var (a, c) = ac[b]; var pre = At(at);
                uint coord = w[at + 4]; if (!typeOf.TryGetValue(coord, out uint ct) || !vecOf.TryGetValue(ct, out var cv) || cv.C != fl) { why = "采样坐标不是浮点向量"; return null; }
                uint x = New(), ax = New(), x2 = New(), nc = New();
                D(pre, OpCompositeExtract, fl, x, coord, 0); D(pre, OpFMul, fl, ax, x, a);
                if (IsProj(op)) { uint pq = New(), cq = New(); D(pre, OpCompositeExtract, fl, pq, coord, cv.N - 1); D(pre, OpFMul, fl, cq, c, pq); D(pre, OpFAdd, fl, x2, ax, cq); }
                else D(pre, OpFAdd, fl, x2, ax, c);
                D(pre, OpCompositeInsert, ct, nc, x2, coord, 0); r[4] = nc;
                int mi = 5 + (HasDref(op) || IsGather(op) ? 1 : 0);
                if (mi < n)
                {
                    uint mask = r[mi]; int k = mi + 1;
                    for (int bit = 0; bit < 16 && k < n; bit++)
                    {
                        if ((mask & (1u << bit)) == 0) continue;
                        if (bit == 2)   // Grad：dx、dy
                            for (int g = 0; g < 2; g++)
                            {
                                uint gid = r[k + g]; if (!typeOf.TryGetValue(gid, out uint gt) || !vecOf.ContainsKey(gt)) { why = "梯度不是向量"; return null; }
                                uint gx = New(), gm = New(), gn = New(); D(pre, OpCompositeExtract, fl, gx, gid, 0); D(pre, OpFMul, fl, gm, gx, a); D(pre, OpCompositeInsert, gt, gn, gm, gid, 0); r[k + g] = gn;
                            }
                        k += bit == 2 ? 2 : bit <= 9 ? 1 : 0;
                    }
                }
                repl[at] = r;
            }
            // ④ X 辅助函数：外推开时应用原分辨率倍率与平移，Y 辅助函数不在 helpers 表里、保持原路。
            foreach (var f in fns)
            {
                if (!helpers.TryGetValue(f.Id, out int np)) continue;
                if (f.Ret != i32) { why = "缩放辅助函数不返回 int"; return null; }
                var hb = At(f.Body);
                uint Arg(int k) { uint p = f.Params[k], pt = paramTypes[p]; if (ptrOf.TryGetValue(pt, out var pp) && pp.Sc == ScFunction) { uint v = New(); D(hb, OpLoad, pp.T, v, p); return v; } return p; }
                uint hw = New(), hwi = New(), hp = New(), he = New(), lb = New(), lc = New();
                D(hb, OpAccessChain, pUI, hw, sbVar, cPM, cPad); D(hb, OpLoad, i32, hwi, hw); D(hb, OpBitcast, fl, hp, hwi); D(hb, OpFOrdNotEqual, bl, he, hp, f0);
                D(hb, OpSelectionMerge, lc, 0); D(hb, OpBranchConditional, he, lb, lc); D(hb, OpLabel, lb);
                relabel.Add((f.Start, f.End, w[FindLabel(w, f.Start) + 1], lc));
                uint inV = Arg(0), si = Arg(1), ix = New(), pr = New(), off = New(), res = New();
                D(hb, OpIAdd, i32, ix, si, i1); D(hb, OpAccessChain, pUF, pr, sbVar, cRS, ix); D(hb, OpLoad, fl, off, pr);
                uint nativeScale = f1, nativeNegative = 0;
                if (dualAxis)
                {
                    uint yr = New(), ys = New(), neg = New(); nativeScale = New(); nativeNegative = New();
                    D(hb, OpAccessChain, pUF, yr, sbVar, cRY, ix); D(hb, OpLoad, fl, ys, yr);
                    D(hb, OpFOrdLessThan, bl, nativeNegative, ys, f0); D(hb, OpFNegate, fl, neg, ys); D(hb, OpSelect, fl, nativeScale, nativeNegative, neg, ys);
                }
                if (np == 3)
                {
                    uint cp = Arg(2), oh = New(), oi = New(), ad = New(), isX = New();
                    if (dualAxis)
                    {
                        uint input = New(), scaled = New(), shifted = New(), fc = New(), x = New(), xp = New(), phase = New(), bias = New(), biased = New();
                        D(hb, OpConvertSToF, fl, input, inV); D(hb, OpFMul, fl, scaled, input, nativeScale); D(hb, OpFAdd, fl, shifted, scaled, off);
                        D(hb, OpLoad, v4, fc, fragCoord); D(hb, OpCompositeExtract, fl, x, fc, 0); D(hb, OpFSub, fl, xp, x, hp); D(hb, OpFMod, fl, phase, xp, nativeScale);
                        D(hb, OpSelect, fl, bias, nativeNegative, phase, f0); D(hb, OpFAdd, fl, biased, shifted, bias); D(hb, OpConvertFToS, i32, ad, biased);
                    }
                    else { D(hb, OpFAdd, fl, oh, off, fh); D(hb, OpConvertFToS, i32, oi, oh); D(hb, OpIAdd, i32, ad, inV, oi); }
                    D(hb, OpIEqual, bl, isX, cp, i0); D(hb, OpSelect, i32, res, isX, ad, inV);
                }
                else
                {
                    if (dualAxis)
                    {
                        uint input = New(), o2 = New(), width = New(), unscaled = New();
                        D(hb, OpConvertSToF, fl, input, inV); D(hb, OpFMul, fl, o2, off, f2); D(hb, OpFSub, fl, width, input, o2);
                        D(hb, OpFDiv, fl, unscaled, width, nativeScale); D(hb, OpConvertFToS, i32, res, unscaled);
                    }
                    else
                    {
                        uint o2 = New(), oh = New(), oi = New(); D(hb, OpFMul, fl, o2, off, f2); D(hb, OpFAdd, fl, oh, o2, fh); D(hb, OpConvertFToS, i32, oi, oh); D(hb, OpISub, i32, res, inV, oi);
                    }
                }
                D(hb, OpReturnValue, res); D(hb, OpLabel, lc);
            }

            // 拼：能力 → 入口点接口 → 装饰 → 类型 / 常量 / 变量 → 函数体
            if (needQuery && !caps.Contains(CapImageQuery)) D(At(5), OpCapability, CapImageQuery);
            if (addFc != 0) { int n = (int)(w[epAt] >> 16); var ep = new List<uint>(w.AsSpan(epAt, n).ToArray()) { addFc }; ep[0] = (uint)(ep.Count << 16 | OpEntryPoint); repl[epAt] = ep.ToArray(); }
            if (anno.Count > 0) At(annoEnd > 0 ? annoEnd : firstType).AddRange(anno);
            At(firstFn).InsertRange(0, decl);
            var o = new List<uint>(w.Length + 1024); o.AddRange(w.AsSpan(0, 5).ToArray());
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16);
                if (before.TryGetValue(i, out var pre)) o.AddRange(pre);
                if (repl.TryGetValue(i, out uint[] r)) o.AddRange(r);
                else if ((w[i] & 0xffff) == OpPhi && relabel.Count > 0)
                {
                    uint[] ph = w.AsSpan(i, n).ToArray();
                    foreach (var (fr, to, ol, nw) in relabel) if (i > fr && i < to) for (int k = 4; k < n; k += 2) if (ph[k] == ol) ph[k] = nw;
                    o.AddRange(ph);
                }
                else o.AddRange(w.AsSpan(i, n).ToArray());
                i += n;
            }
            o[3] = bound;
            var sl = new List<(int, int)>(); foreach (uint b in smpBind) sl.Add((1 + (int)b - FragTexBase, (int)b)); samples = sl.ToArray();
            return MemoryMarshal.AsBytes(CollectionsMarshal.AsSpan(o)).ToArray();
        }
    }
}
