// 参照端（galplay --ref，Ryujinx Vulkan 后端 @ MoltenVK）吃原始位顶点输入的 SPIR-V（画面·着色器线 10-21，Ryujinx 补丁 vattr-raw）。
// 原始位 SPIR-V：顶点输入一律 uvec4、名字 s2a_raw<位置>，读出的是 Maxwell 寄存器位（浮点类格式 = 转换后的浮点位，整数类 = 整数位），用处按指令类型位转换。
// 我方后端靠顶点自取（graphics/metal/gal_vpull.m s2a_vr）产出这些位；Vulkan 的顶点取数按格式转成声明类型，uvec4 配浮点类格式是未定义行为。
// 所以参照端按当次绘制的顶点格式把每个原始位输入改回类型声明，读处补回寄存器位：
//   浮点类（float / unorm / snorm / 打包浮点）：声明 vec4，读后 OpBitcast 回 uint；
//   sint：声明 ivec4，读后 OpBitcast 回 uint；uint：不改；
//   sscaled / uscaled：Vulkan@MoltenVK 不支持缩放顶点格式，参照端把格式换成同宽 sint / uint（SetVertexAttribs 后重设），
//   声明 ivec4 / uvec4，读后 OpConvertSToF / OpConvertUToF 再 OpBitcast 回 uint（= Maxwell 把缩放格式转成浮点）。
// 同一原始位程序按「各原始位位置的格式类」建变体并缓存，绘制前换上；我方后端照旧吃原样 SPIR-V。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using RyuJudge.GalRec;
using System;
using System.Collections.Generic;
using System.Text;

public static class RefRawVertex
{
    // 格式类：0 浮点类 1 sint 2 uint 3 sscaled 4 uscaled
    public const int Float = 0, Sint = 1, Uint = 2, Sscaled = 3, Uscaled = 4;

    public static int ClassOf(Format f)
    {
        string n = f.ToString();
        if (n.EndsWith("Uscaled", StringComparison.Ordinal)) return Uscaled;
        if (n.EndsWith("Sscaled", StringComparison.Ordinal)) return Sscaled;
        if (n.EndsWith("Uint", StringComparison.Ordinal)) return Uint;
        if (n.EndsWith("Sint", StringComparison.Ordinal)) return Sint;
        return Float;
    }

    /// <summary>缩放格式换成同宽整数格式（参照端 Vulkan@MoltenVK 没有缩放顶点格式）；不是缩放格式原样返回</summary>
    public static Format Unscaled(Format f)
    {
        string n = f.ToString();
        if (n.EndsWith("Uscaled", StringComparison.Ordinal)) return Enum.Parse<Format>(n[..^7] + "Uint");
        if (n.EndsWith("Sscaled", StringComparison.Ordinal)) return Enum.Parse<Format>(n[..^7] + "Sint");
        return f;
    }

    const int OpName = 5, OpTypeInt = 21, OpTypeFloat = 22, OpTypeVector = 23, OpTypePointer = 32, OpFunction = 54, OpVariable = 59, OpLoad = 61,
        OpAccessChain = 65, OpInBoundsAccessChain = 66, OpEntryPoint = 15, OpDecorate = 71, OpMemberDecorate = 72, OpMemberName = 6,
        OpConvertSToF = 111, OpConvertUToF = 112, OpBitcast = 124;
    const uint StorageInput = 1;

    static string Str(uint[] w, int at, int end)
    {
        var b = new List<byte>();
        for (int i = at; i < end; i++) for (int k = 0; k < 4; k++) { byte c = (byte)(w[i] >> (8 * k)); if (c == 0) return Encoding.UTF8.GetString(b.ToArray()); b.Add(c); }
        return Encoding.UTF8.GetString(b.ToArray());
    }

    /// <summary>原始位输入：变量号 → 位置（按 OpName s2a_raw&lt;位置&gt;）；不是 SPIR-V 或没有原始位输入返回空表</summary>
    public static Dictionary<uint, int> RawInputs(uint[] w)
    {
        var r = new Dictionary<uint, int>();
        if (w == null || w.Length < 5 || w[0] != 0x07230203) return r;
        for (int i = 5; i < w.Length;)
        {
            int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff); if (n == 0 || i + n > w.Length) break;
            if (op == OpName && n >= 3) { string s = Str(w, i + 2, i + n); if (s.StartsWith("s2a_raw", StringComparison.Ordinal) && int.TryParse(s.AsSpan(7), out int loc)) r[w[i + 1]] = loc; }
            i += n;
        }
        return r;
    }

    /// <summary>位置位图（程序缓存键用）</summary>
    public static uint RawMask(uint[] w) { uint m = 0; foreach (int l in RawInputs(w).Values) if (l >= 0 && l < 32) m |= 1u << l; return m; }

    /// <summary>按各位置格式类改写；classOf(位置) 给类。返回新字（没有要改的返回原数组），认不出的形态返回 null 并给 why</summary>
    public static uint[] Rewrite(uint[] w, Func<int, int> classOf, out string why)
    {
        why = null;
        var raw = RawInputs(w); if (raw.Count == 0) return w;
        var cls = new Dictionary<uint, int>();
        foreach (var kv in raw) { int c = classOf(kv.Value); if (c != Uint) cls[kv.Key] = c; }
        if (cls.Count == 0) return w;

        // 一遍扫：类型表、首个函数的位置、各条指令
        var ins = new List<(int at, int n, int op)>();
        uint bound = w[3];
        uint tInt = 0, tUint = 0, tFloat = 0; var vec = new Dictionary<uint, uint>(); var ptr = new Dictionary<(uint, uint), uint>();
        int firstFn = -1;
        for (int i = 5; i < w.Length;)
        {
            int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
            if (n == 0 || i + n > w.Length) { why = $"字 {i} 指令长度 {n} 越界"; return null; }
            ins.Add((i, n, op));
            if (op == OpTypeInt && w[i + 2] == 32) { if (w[i + 3] == 1) tInt = w[i + 1]; else tUint = w[i + 1]; }
            else if (op == OpTypeFloat && w[i + 2] == 32) tFloat = w[i + 1];
            else if (op == OpTypeVector && w[i + 3] == 4) vec[w[i + 2]] = w[i + 1];
            else if (op == OpTypePointer && w[i + 2] == StorageInput) ptr[(StorageInput, w[i + 3])] = w[i + 1];
            else if (op == OpFunction && firstFn < 0) firstFn = ins.Count - 1;
            i += n;
        }
        if (firstFn < 0) { why = "没有函数"; return null; }
        if (tUint == 0 || !vec.TryGetValue(tUint, out uint tV4u)) { why = "没有 uint / uvec4 类型"; return null; }

        // 需要的类型：缺的追加在首个函数前（只依赖已有或先追加的标量 / 向量类型）
        var add = new List<uint>();
        uint Emit(params uint[] a) { add.AddRange(a); return 0; }
        uint New() => bound++;
        uint Scalar(bool fl, bool sg)
        {
            if (fl) { if (tFloat == 0) { tFloat = New(); Emit((3u << 16) | OpTypeFloat, tFloat, 32); } return tFloat; }
            if (sg) { if (tInt == 0) { tInt = New(); Emit((4u << 16) | OpTypeInt, tInt, 32, 1); } return tInt; }
            return tUint;
        }
        uint Vec4(uint s) { if (!vec.TryGetValue(s, out uint v)) { v = New(); vec[s] = v; Emit((4u << 16) | OpTypeVector, v, s, 4); } return v; }
        uint Ptr(uint t) { if (!ptr.TryGetValue((StorageInput, t), out uint p)) { p = New(); ptr[(StorageInput, t)] = p; Emit((4u << 16) | OpTypePointer, p, StorageInput, t); } return p; }

        // 各类的声明标量：浮点类 float、sint / sscaled int、uscaled uint
        uint DeclScalar(int c) => c == Float ? Scalar(true, false) : (c == Sint || c == Sscaled) ? Scalar(false, true) : tUint;
        // 指针跟踪：原始位变量与它派生的访问链 → (类, 是否向量)
        var derived = new Dictionary<uint, (int c, bool v)>();
        foreach (var kv in cls) derived[kv.Key] = (kv.Value, true);
        uint ptrV4u = ptr.TryGetValue((StorageInput, tV4u), out uint pv) ? pv : 0, ptrU = ptr.TryGetValue((StorageInput, tUint), out uint pu) ? pu : 0;

        // 先把要的类型全建好（都只依赖标量 / 向量类型，放在首个函数前、所有已有类型之后），原始位变量挪到它们后面重新声明
        //   （全局变量出现在使用它的函数前即可；入口点 / 名字 / 装饰可前向引用）
        foreach (int c in cls.Values)
        {
            uint sc = DeclScalar(c); Ptr(sc); Ptr(Vec4(sc));
            if (c == Sscaled || c == Uscaled) Vec4(Scalar(true, false));
        }
        var moved = new List<uint>();
        var o = new List<uint>(w.Length + 64);
        for (int k = 0; k < 5; k++) o.Add(w[k]);
        for (int idx = 0; idx < ins.Count; idx++)
        {
            var (at, n, op) = ins[idx];
            if (idx == firstFn) { o.AddRange(add); add.Clear(); o.AddRange(moved); }
            if (op == OpVariable && derived.TryGetValue(w[at + 2], out var dv) && cls.ContainsKey(w[at + 2]))
            {
                if (w[at + 1] != ptrV4u || w[at + 3] != StorageInput) { why = $"原始位变量 {w[at + 2]} 不是 Input uvec4"; return null; }
                uint t = Ptr(Vec4(DeclScalar(dv.c)));
                moved.Add(w[at]); moved.Add(t); for (int k = 2; k < n; k++) moved.Add(w[at + k]);
                continue;
            }
            if ((op == OpAccessChain || op == OpInBoundsAccessChain) && derived.TryGetValue(w[at + 3], out var dc))
            {
                bool toScalar = w[at + 1] == ptrU && ptrU != 0, toVec = w[at + 1] == ptrV4u;
                if (!toScalar && !toVec) { why = $"原始位访问链 {w[at + 2]} 结果类型认不出"; return null; }
                uint s = DeclScalar(dc.c); uint t = Ptr(toScalar ? s : Vec4(s));
                derived[w[at + 2]] = (dc.c, toVec);
                o.Add(w[at]); o.Add(t); for (int k = 2; k < n; k++) o.Add(w[at + k]);
                continue;
            }
            if (op == OpLoad && derived.TryGetValue(w[at + 3], out var dl))
            {
                uint resT = w[at + 1], res = w[at + 2], s = DeclScalar(dl.c), lt = dl.v ? Vec4(s) : s, y = New();
                o.Add((uint)(n << 16) | OpLoad); o.Add(lt); o.Add(y); for (int k = 3; k < n; k++) o.Add(w[at + k]);
                if (dl.c == Sscaled || dl.c == Uscaled)
                {
                    uint ft = dl.v ? Vec4(Scalar(true, false)) : Scalar(true, false), z = New();
                    o.Add((4u << 16) | (uint)(dl.c == Sscaled ? OpConvertSToF : OpConvertUToF)); o.Add(ft); o.Add(z); o.Add(y);
                    y = z;
                }
                o.Add((4u << 16) | OpBitcast); o.Add(resT); o.Add(res); o.Add(y);
                continue;
            }
            // 改回类型声明的变量改名 s2a_typ<位置>（同字长）：名字 s2a_raw 是「按原始位读」的标记，我方后端（--typed-vertex）见到它会按原始位改写
            if (op == OpName && cls.ContainsKey(w[at + 1]))
            {
                o.Add(w[at]); o.Add(w[at + 1]);
                // 字 2 = 「s2a_」不动，字 3 = 「raw<首位数字>」→「typ<首位数字>」
                for (int k = 2; k < n; k++) o.Add(k == 3 ? (w[at + 3] & 0xff000000u) | (uint)'t' | ((uint)'y' << 8) | ((uint)'p' << 16) : w[at + k]);
                continue;
            }
            // 其余会拿指针当操作数的指令用到原始位指针：形态认不出（只查这些操作码——别的指令里有字面量，按字比会误认）
            if (PtrUser(op))
                for (int k = 1; k < n; k++) if (derived.ContainsKey(w[at + k])) { why = $"原始位指针 {w[at + k]} 被操作码 {op} 使用，认不出"; return null; }
            for (int k = 0; k < n; k++) o.Add(w[at + k]);
        }
        if (add.Count > 0) { why = "函数体里才缺类型（预建漏了）"; return null; }
        o[3] = bound;
        return o.ToArray();
    }

    // 会拿指针当操作数的指令：OpFunctionCall 57、OpStore 62、OpCopyMemory 63 / 64、OpPtrAccessChain 67、OpArrayLength 68、OpCopyObject 83、OpSelect 169、原子 227–242、OpPhi 245
    static bool PtrUser(int op) => op == 57 || op == 62 || op == 63 || op == 64 || op == 67 || op == 68 || op == 83 || op == 169 || (op >= 227 && op <= 242) || op == 245;

    public static uint[] Words(byte[] b) { var w = new uint[b.Length / 4]; Buffer.BlockCopy(b, 0, w, 0, w.Length * 4); return w; }
    public static byte[] Bytes(uint[] w) { var b = new byte[w.Length * 4]; Buffer.BlockCopy(w, 0, b, 0, b.Length); return b; }
}

/// <summary>回放钩子：参照端原始位程序按当次顶点格式换变体（绘制前），缩放格式换成整数格式重设</summary>
public sealed class RefRawVertexHook : GalRecReplayer.IReplayHook
{
    sealed class RawProg { public ShaderSource[] Src; public ShaderInfo Info; public uint Mask; public Dictionary<string, IProgram> Variants = new(); }
    readonly Dictionary<IProgram, RawProg> _raw = new(ReferenceEqualityComparer.Instance);
    readonly Func<ShaderSource[], ShaderSource[]> _filter;
    IProgram _cur, _set; VertexAttribDescriptor[] _attrs = Array.Empty<VertexAttribDescriptor>();
    public long RawPrograms, Variants, Failed; public readonly List<string> FailSamples = new();
    public RefRawVertexHook(Func<ShaderSource[], ShaderSource[]> filter) => _filter = filter;

    public void Before(GalRecReplayer x, uint op, R rr)
    {
        if (op != GalOps.IPipeline_Draw && op != GalOps.IPipeline_DrawIndexed && op != GalOps.IPipeline_DrawIndexedIndirect &&
            op != GalOps.IPipeline_DrawIndexedIndirectCount && op != GalOps.IPipeline_DrawIndirect && op != GalOps.IPipeline_DrawIndirectCount) return;
        if (_cur == null || !_raw.TryGetValue(_cur, out RawProg rp)) return;
        var kb = new StringBuilder(32);
        for (int l = 0; l < 32; l++) kb.Append((rp.Mask >> l & 1) != 0 ? (char)('0' + ClassAt(l)) : '-');
        string key = kb.ToString();
        if (!rp.Variants.TryGetValue(key, out IProgram v))
        {
            v = Build(x, rp, out string why);
            if (v == null) { Failed++; if (FailSamples.Count < 8) FailSamples.Add(why); v = _cur; }
            else Variants++;
            rp.Variants[key] = v;
        }
        if (!ReferenceEquals(v, _set)) { x.Target.Pipeline.SetProgram(v); _set = v; }
    }

    // 位置的格式类按录像原始格式算（缩放格式在参照端被换成整数格式，但类仍是 sscaled / uscaled，着色器里补换算）
    int ClassAt(int l) => l < _attrs.Length ? RefRawVertex.ClassOf(_attrs[l].Format) : RefRawVertex.Float;

    IProgram Build(GalRecReplayer x, RawProg rp, out string why)
    {
        why = null;
        var src = (ShaderSource[])rp.Src.Clone();
        for (int i = 0; i < src.Length; i++)
        {
            if (src[i].Stage != ShaderStage.Vertex || src[i].Language != TargetLanguage.Spirv || src[i].BinaryCode == null) continue;
            uint[] nw = RefRawVertex.Rewrite(RefRawVertex.Words(src[i].BinaryCode), ClassAt, out why);
            if (nw == null) return null;
            src[i] = new ShaderSource(src[i].Code, RefRawVertex.Bytes(nw), src[i].Stage, src[i].Language);
        }
        if (_filter != null) src = _filter(src);
        return x.Target.CreateProgram(src, new ShaderInfo(rp.Info.FragmentOutputMap, rp.Info.ResourceLayout, rp.Info.FromCache));
    }

    public void After(GalRecReplayer x, uint op, R rr)
    {
        if (op == GalOps.IRenderer_CreateProgram)
        {
            ShaderSource[] src = rr.Shaders(); ShaderInfo info = rr.ShaderInfo(); uint id = rr.U32();
            uint mask = 0;
            foreach (ShaderSource s in src) if (s.Stage == ShaderStage.Vertex && s.Language == TargetLanguage.Spirv && s.BinaryCode != null) mask |= RefRawVertex.RawMask(RefRawVertex.Words(s.BinaryCode));
            if (mask != 0 && x.Obj<IProgram>(id) is IProgram p) { _raw[p] = new RawProg { Src = src, Info = info, Mask = mask }; RawPrograms++; }
        }
        else if (op == GalOps.IPipeline_SetProgram) { _cur = x.Obj<IProgram>(rr.U32()); _set = _cur; }
        else if (op == GalOps.IPipeline_SetVertexAttribs)
        {
            _attrs = rr.Span<VertexAttribDescriptor>();
            bool scaled = false; var conv = new VertexAttribDescriptor[_attrs.Length];
            for (int i = 0; i < _attrs.Length; i++) { Format f = RefRawVertex.Unscaled(_attrs[i].Format); scaled |= f != _attrs[i].Format; conv[i] = new VertexAttribDescriptor(_attrs[i].BufferIndex, _attrs[i].Offset, _attrs[i].IsZero, f); }
            if (scaled) x.Target.Pipeline.SetVertexAttribs(conv);
        }
    }
}
