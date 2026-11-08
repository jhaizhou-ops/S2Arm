// #783 出包 Vulkan 产物单测（t_dsh_vk.sh 调）：原创合成控制段 + 手写 Maxwell 指令（VS / PS / CS 各一：存储缓冲、组合纹理、常量缓冲），
//   走 DshVk.CompileWithSpv 同键出 _b.json 与 _b.spv。期望按卡面写死，不跑被测实现推：
//   ① 每个键 _b.json 与 _b.spv 都在（两边键集合相等）；
//   ② _b.spv 里每个资源变量 DescriptorSet = 0、Binding = json 里同名成员的 arg_id × 6 + 阶段号（vs 0 / ps 4 / cs 5，#1254 直连缺陷线定；
//      本文件自己解析 SPIR-V，不用 BindToArgIds），//      组合纹理变量对的是 texture 成员，不是 …Smplr；
//   ③ 每个 _b.spv 过 spirv-val --target-env vulkan1.1。
//   反证：④ 翻译器原样的 .spv（未改写）在本夹具上至少一个资源对不上 arg_id，判据不会绿着失效；
//   ⑤ json 里删掉一个 .spv 有的成员 → BindToArgIds 报红，不静默；⑥ json 里改一个 arg_id → 改写结果跟着变，对原 json 判不一致；
//   ⑦ 把 json 里没有的 support_buffer 经 OpCopyObject 在函数体里取用一次 → 判为「用到了却没有成员」报红，不挪到空号。
//   ⑧ vs 与 ps 合在一个管线布局里不撞号：两阶段 arg_id 0 / 1 的绑定号手算为 vs 0 / 6、ps 4 / 10，两阶段全部绑定号互不相同（安卓 backend_vulkan.c 按 (set, binding) 合并）；
//   ⑨ 出包模式（DshCompiler.PackOut）：输出目录不建、json 取自 PackFiles、_b.spv 进 DshVk.PackSpv，且与落盘那份逐字节相同；
//   ⑩ gs / hs / ds 调 CompileWithSpv 报 DshError（不出 .spv）。
// 夹具：控制段 0x880 字节全零（c1 / VertexA/B / 变换反馈都空），+0x10 放阶段号只为键不同；代码区 = 0x30 前缀 + SPH（计算着色器 = 0x12345679 头 + 0x100 起指令），
//   编码按 compat/tree/src/Ryujinx.Graphics.Shader/Decoders/InstTable.cs / InstDecoders.cs；答案表 / 配对表为空表（全部按缺省答）。没有游戏内容。
// libnxgal（--nxgal，必给）：Finish 对片元调 NxgalSpvCross.ColorRound，Compile 对所有阶段交 SPIRV-Cross 前先调 NxgalSpvCross.Harden（main de14970a6，#1204 T1），
//   两者都 DllImport("nxgal")。t_dsh_vk.sh 在 Mac 给整库 libnxgal.dylib，在 Linux 给只含 gal_colorround.c + gal_spvx.c 的 build/gal/linux/libnxgal.so（#783），
//   三个键都走 CompileWithSpv。SPIRV-Cross 两边都用命令行版（CliSpvCross），--nxgal 只改上面两个 DllImport 的去处。
// 用法：dsh_vk_test <spirv-cross> <spirv-val> <工作目录> --nxgal <libnxgal>
using S2A.Dsh;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

static class Program
{
    const ulong EXIT = 0xe30000000007000fUL;
    static ulong Mov32i(int rd, uint v) => 0x0100000000000000UL | ((ulong)v << 20) | (7UL << 16) | (15UL << 12) | (ulong)rd;
    static ulong Ldc(int rd, int slot, int off, int size) => 0xef90000000000000UL | ((ulong)size << 48) | ((ulong)slot << 36) | ((ulong)off << 20) | (7UL << 16) | (255UL << 8) | (ulong)rd;   // size 4 = B32、5 = B64
    static ulong Ldg32(int rd, int ra, int off) => 0xeed4200000000000UL | ((ulong)off << 20) | (7UL << 16) | ((ulong)ra << 8) | (ulong)rd;
    static ulong Stg32(int rs, int ra, int off) => 0xeedc200000000000UL | ((ulong)off << 20) | (7UL << 16) | ((ulong)ra << 8) | (ulong)rs;
    // TEXS.2D Rd(仅 R 分量), Ra = x, Rb = y；TidB = 驱动常量段 c2 里的句柄字偏移（8 → 0x20 = 纹理槽 0）
    static ulong Texs2D(int rd, int ra, int rb, int tid) => 0xd800000000000000UL | (1UL << 53) | ((ulong)tid << 36) | (255UL << 28) | ((ulong)rb << 20) | (7UL << 16) | ((ulong)ra << 8) | (ulong)rd;

    static byte[] Bundles(byte[] head, ulong[] ops)
    {
        int n = (ops.Length + 2) / 3 * 3;
        var b = new byte[head.Length + n / 3 * 32];
        head.CopyTo(b, 0);
        for (int i = 0; i < n; i++) BitConverter.TryWriteBytes(b.AsSpan(head.Length + (i / 3 * 4 + i % 3 + 1) * 8), i < ops.Length ? ops[i] : EXIT);
        return b;
    }

    static byte[] Sph(uint word0, int omapByte)
    {
        var h = new byte[0x30 + 0x50];   // 0x30 前缀（JobFor 切掉）+ SPH
        BitConverter.TryWriteBytes(h.AsSpan(0x30), word0);
        if (omapByte >= 0) h[0x30 + 72] = (byte)omapByte;
        return h;
    }

    static (string Stage, byte[] Code, byte[] Ctl)[] Fixtures()
    {
        const uint store = (1u << 16) | (1u << 26);   // SPH DoesGlobalStore / DoesLoadOrStore
        var vs = Bundles(Sph(1 | (3 << 5) | (1 << 10) | store, -1), new[] {
            Ldc(0, 0, 0x110, 5), Ldc(2, 3, 0, 4), Stg32(2, 0, 0), EXIT });                       // c0+0x110 = 顶点阶段存储缓冲 0；c3 = 常量缓冲 0
        var ps = Bundles(Sph(2 | (3 << 5) | (5 << 10), 15), new[] {
            Mov32i(0, 0x3f000000), Mov32i(1, 0x3f000000), Texs2D(0, 0, 1, 8), Ldc(1, 3, 0, 4), Mov32i(2, 0), Mov32i(3, 0x3f800000), EXIT });
        var csHead = new byte[0x100]; BitConverter.TryWriteBytes(csHead.AsSpan(0), 0x12345679u);
        var cs = Bundles(csHead, new[] {
            Ldc(0, 0, 0x310, 5), Ldg32(2, 0, 0), Ldc(3, 3, 0, 4), Stg32(3, 0, 4), Stg32(2, 0, 8), EXIT });   // c0+0x310 = 计算阶段存储缓冲 0
        (string, byte[], byte[]) F(string st, byte[] code, byte mark) { var ctl = new byte[0x880]; ctl[0x10] = mark; return (st, code, ctl); }
        return new[] { F("vs", vs, 1), F("ps", ps, 2), F("cs", cs, 3) };
    }

    // ---- 独立的 SPIR-V 读取：资源变量名 → (DescriptorSet, Binding, 入口是否取用) ----
    static Dictionary<string, (uint Set, uint Binding, bool Used)> Resources(byte[] spv)
    {
        var w = new uint[spv.Length / 4]; Buffer.BlockCopy(spv, 0, w, 0, w.Length * 4);
        var names = new Dictionary<uint, string>(); var set = new Dictionary<uint, uint>(); var bind = new Dictionary<uint, uint>(); var vars = new Dictionary<uint, uint>();
        var touched = new HashSet<uint>();
        for (int i = 5; i < w.Length;)
        {
            int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
            if (n == 0) throw new InvalidDataException("bad SPIR-V word count");
            if (op == 5) { var bytes = new List<byte>(); for (int k = i + 2; k < i + n; k++) bytes.AddRange(BitConverter.GetBytes(w[k])); int z = bytes.IndexOf(0); names[w[i + 1]] = System.Text.Encoding.UTF8.GetString(bytes.Take(z < 0 ? bytes.Count : z).ToArray()); }
            if (op == 71 && n >= 4 && w[i + 2] == 34) set[w[i + 1]] = w[i + 3];
            if (op == 71 && n >= 4 && w[i + 2] == 33) bind[w[i + 1]] = w[i + 3];
            if (op == 59 && n >= 4) vars[w[i + 2]] = w[i + 3];
            // 取用：OpLoad 指针、OpStore 指针、Op*AccessChain / OpArrayLength / OpImageTexelPointer 的基址
            if (op == 61 && n >= 4) touched.Add(w[i + 3]);
            if (op == 62 && n >= 3) touched.Add(w[i + 1]);
            if (op is 60 or 65 or 66 or 67 or 68 && n >= 4) touched.Add(w[i + 3]);
            i += n;
        }
        return vars.Where(v => v.Value is 0 or 2 or 12 && bind.ContainsKey(v.Key))
                   .ToDictionary(v => names.GetValueOrDefault(v.Key, "%" + v.Key), v => (set.GetValueOrDefault(v.Key, uint.MaxValue), bind[v.Key], touched.Contains(v.Key)));
    }

    // 阶段号（期望表，照卡面口径手写）：绑定号 = arg_id × 6 + 阶段号
    static readonly Dictionary<string, long> StageNoOf = new() { ["vs"] = 0, ["ps"] = 4, ["cs"] = 5 };

    // 有同名成员的：(set, binding) = (0, arg_id × 6 + 阶段号)；没有的：必须入口没取用、在 set 0、落在本阶段的模 6 槽且 binding / 6 大于全部 arg_id；全部绑定号互不相同
    static List<string> Mismatch(Dictionary<string, (uint Set, uint Binding, bool Used)> res, JsonArray bindings, long stageNo)
    {
        var aid = bindings.OfType<JsonObject>().ToDictionary(o => (string)o["msl_name"], o => (long)o["arg_id"]);
        long top = aid.Count == 0 ? -1 : aid.Values.Max();
        var bad = new List<string>();
        foreach (var (name, (s, b, used)) in res)
            if (aid.TryGetValue(name, out long id)) { if (s != 0 || b != id * 6 + stageNo) bad.Add($"{name}: (set {s}, binding {b}) ≠ (0, {id} × 6 + {stageNo})"); }
            else if (used) bad.Add($"{name}: 入口取用了，但 json 里没有同名成员");
            else if (s != 0 || b % 6 != stageNo || b / 6 <= top) bad.Add($"{name}: 没取用的变量应在 set 0、binding % 6 = {stageNo}、binding / 6 > {top}，实际 (set {s}, binding {b})");
        if (res.Values.Select(r => r.Binding).Distinct().Count() != res.Count) bad.Add("绑定号有重复");
        return bad;
    }

    // 第一个函数体的第一个 OpLabel 之后插一条 OpCopyObject %指针类型 %新 id %变量（新 id 取头里的 bound）
    static byte[] InjectCopy(byte[] spv, string varName)
    {
        var w = new uint[spv.Length / 4]; Buffer.BlockCopy(spv, 0, w, 0, w.Length * 4);
        var names = new Dictionary<uint, string>(); var vars = new Dictionary<uint, uint>(); int label = -1; bool inFn = false;
        for (int i = 5; i < w.Length;)
        {
            int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
            if (op == 5) { var bytes = new List<byte>(); for (int k = i + 2; k < i + n; k++) bytes.AddRange(BitConverter.GetBytes(w[k])); int z = bytes.IndexOf(0); names[w[i + 1]] = System.Text.Encoding.UTF8.GetString(bytes.Take(z < 0 ? bytes.Count : z).ToArray()); }
            if (op == 59 && n >= 4) vars[w[i + 2]] = w[i + 1];
            if (op == 54) inFn = true;
            if (op == 248 && inFn && label < 0) label = i + n;
            i += n;
        }
        uint vid = names.First(kv => kv.Value == varName && vars.ContainsKey(kv.Key)).Key, id = w[3];
        var list = w.ToList(); list[3] = id + 1;
        list.InsertRange(label, new[] { (4u << 16) | 83, vars[vid], id, vid });
        var b = new byte[list.Count * 4]; Buffer.BlockCopy(list.ToArray(), 0, b, 0, b.Length);
        return b;
    }

    static int bad;
    static void Check(string what, bool ok, string detail = "")
    {
        Console.WriteLine((ok ? "✓ " : "✗ ") + what + (ok || detail.Length == 0 ? "" : "：" + detail));
        if (!ok) bad = 1;
    }

    static int Main(string[] args)
    {
        if (!(args.Length == 5 && args[3] == "--nxgal")) { Console.Error.WriteLine("用法：dsh_vk_test <spirv-cross> <spirv-val> <工作目录> --nxgal <libnxgal>"); return 2; }
        string val = args[1], root = args[2], tables = Path.Combine(root, "tables"), outDir = Path.Combine(root, "out"), nxgal = args[4];
        NativeLibrary.SetDllImportResolver(typeof(NxgalSpvCross).Assembly, (name, asm, path) => name == "nxgal" ? NativeLibrary.Load(nxgal) : IntPtr.Zero);
        Directory.CreateDirectory(tables); Directory.CreateDirectory(outDir);
        File.WriteAllText(Path.Combine(tables, "shader_facts.tsv"), ""); File.WriteAllText(Path.Combine(tables, "shader_pairs.tsv"), "");
        var xc = new CliSpvCross(args[0], root);
        var keys = new List<(string Key, string Stage, byte[] Code, byte[] Ctl)>();
        foreach (var (stage, code, ctl) in Fixtures())
        {
            string key = Convert.ToHexStringLower(SHA256.HashData(ctl.AsSpan(0, 0x880)))[..16];
            Console.WriteLine($"{stage} {key}: {string.Join(" ", DshVk.CompileWithSpv(key, stage, code, ctl, outDir, xc, tables, root))}");
            keys.Add((key, stage, code, ctl));
        }

        // ① 键集合
        var jsonKeys = Directory.GetFiles(outDir, "*_b.json").Select(p => Path.GetFileName(p)[..^7]).OrderBy(k => k).ToList();
        var spvKeys = Directory.GetFiles(outDir, "*_b.spv").Select(p => Path.GetFileName(p)[..^6]).OrderBy(k => k).ToList();
        Check($"① _b.spv 键集合 = _b.json 键集合（{spvKeys.Count} 个）", jsonKeys.SequenceEqual(spvKeys) && spvKeys.Count == keys.Count, string.Join(",", jsonKeys) + " / " + string.Join(",", spvKeys));

        int rawDiff = 0;
        var perStage = new Dictionary<string, (Dictionary<string, (uint Set, uint Binding, bool Used)> Res, JsonArray Bindings)>();
        foreach (var (key, stage, code, ctl) in keys)
        {
            var bindings = JsonNode.Parse(File.ReadAllText(Path.Combine(outDir, key + "_b.json")))["bindings"].AsArray();
            string spvPath = Path.Combine(outDir, key + "_b.spv");
            byte[] spv = File.ReadAllBytes(spvPath);
            var res = Resources(spv);
            var mm = Mismatch(res, bindings, StageNoOf[stage]);
            perStage[stage] = (res, bindings);
            Check($"② {stage} 每个资源变量 (set, binding) = (0, arg_id × 6 + {StageNoOf[stage]})：{string.Join(" ", res.Select(r => r.Key + "=" + r.Value.Binding))}", res.Count > 0 && mm.Count == 0, string.Join("；", mm));
            if (stage == "ps")
            {
                var tex = bindings.OfType<JsonObject>().FirstOrDefault(o => (string)o["kind"] == "tex");
                var smp = tex == null ? null : bindings.OfType<JsonObject>().FirstOrDefault(o => (string)o["msl_name"] == (string)tex["msl_name"] + "Smplr");
                Check("② ps 组合纹理变量的 binding = texture 成员的 arg_id × 6 + 4（≠ …Smplr 的）",
                    tex != null && smp != null && (long)tex["arg_id"] != (long)smp["arg_id"] && res.TryGetValue((string)tex["msl_name"], out var t) && t.Binding == (long)tex["arg_id"] * 6 + 4,
                    tex == null ? "json 里没有 tex 成员" : smp == null ? "json 里没有 …Smplr 成员" : "");
            }
            var p = Process.Start(new ProcessStartInfo(val) { ArgumentList = { "--target-env", "vulkan1.1", spvPath }, RedirectStandardError = true, RedirectStandardOutput = true });
            string err = p.StandardError.ReadToEnd() + p.StandardOutput.ReadToEnd(); p.WaitForExit();
            Check($"③ {stage} spirv-val --target-env vulkan1.1", p.ExitCode == 0, err.Trim());

            var raw = DshCompiler.TranslateForVulkan(stage, code, ctl, root).Spv;   // 同空表：与 _b.spv 同一遍翻译、未改写
            rawDiff += Mismatch(Resources(raw), bindings, StageNoOf[stage]).Count;

            if (stage == "ps")
            {
                var name = res.Keys.First(n => bindings.OfType<JsonObject>().Any(o => (string)o["msl_name"] == n && (string)o["kind"] == "tex"));
                var drop = new JsonArray(bindings.OfType<JsonObject>().Where(o => (string)o["msl_name"] != name).Select(o => o.DeepClone()).ToArray());
                string why = null;
                try { DshVk.BindToArgIds(raw, drop, "ps"); } catch (DshError e) { why = e.Detail; }
                Check("⑤ json 删掉纹理成员 → BindToArgIds 报红", why != null && why.Contains(name), why ?? "没有报错");
                var moved = bindings.DeepClone().AsArray();
                var o0 = moved.OfType<JsonObject>().First(o => (string)o["msl_name"] == name);
                o0["arg_id"] = (long)o0["arg_id"] + 40;
                var shifted = Resources(DshVk.BindToArgIds(raw, moved, "ps"));
                Check("⑥ json 改纹理成员的 arg_id → 改写结果跟着变、对原 json 判不一致",
                    shifted[name].Binding == (long)o0["arg_id"] * 6 + 4 && Mismatch(shifted, bindings, 4).Count == 1);
                string why7 = null;
                try { DshVk.BindToArgIds(InjectCopy(raw, "support_buffer"), bindings, "ps"); } catch (DshError e) { why7 = e.Detail; }
                Check("⑦ json 里没有的 support_buffer 经 OpCopyObject 取用 → 报「用到了却没有成员」", why7 != null && why7.Contains("support_buffer") && why7.Contains("用到"), why7 ?? "没有报错（被挪到空号）");
            }
        }
        Check($"④ 翻译器原样的 .spv 对不上 arg_id 的资源数 > 0（{rawDiff} 个）", rawDiff > 0);

        // ⑧ vs + ps 合进一个管线布局（安卓按 (set, binding) 合并）：期望值手算，arg_id 0 / 1 → vs 0 / 6、ps 4 / 10
        long BindOf(string st, long arg)
        {
            var (res, bindings) = perStage[st];
            var name = bindings.OfType<JsonObject>().Where(o => (long)o["arg_id"] == arg).Select(o => (string)o["msl_name"]).FirstOrDefault(res.ContainsKey);
            return name == null ? -1 : res[name].Binding;
        }
        var merged = perStage["vs"].Res.Values.Concat(perStage["ps"].Res.Values).ToList();
        Check($"⑧ vs + ps 合并布局不撞号：vs arg_id 0 / 1 → {BindOf("vs", 0)} / {BindOf("vs", 1)}（期望 0 / 6），ps → {BindOf("ps", 0)} / {BindOf("ps", 1)}（期望 4 / 10），{merged.Count} 个绑定号互不相同",
            BindOf("vs", 0) == 0 && BindOf("vs", 1) == 6 && BindOf("ps", 0) == 4 && BindOf("ps", 1) == 10
            && merged.All(r => r.Set == 0) && merged.Select(r => r.Binding).Distinct().Count() == merged.Count
            && perStage["vs"].Res.Values.All(r => r.Binding % 6 == 0) && perStage["ps"].Res.Values.All(r => r.Binding % 6 == 4));

        // ⑨ 出包模式：Compile 的产物在 PackFiles、不落盘；CompileWithSpv 从那里取 json，_b.spv 进 PackSpv
        var (pk, pst, pcode, pctl) = keys.First(k => k.Stage == "ps");
        string packDir = Path.Combine(root, "packout"), why9 = "";
        List<string> packed = null;
        DshCompiler.PackOut = true;
        try { packed = DshVk.CompileWithSpv(pk, pst, pcode, pctl, packDir, xc, tables, root); }
        catch (Exception e) { why9 = e.GetType().Name + ": " + e.Message; }
        finally { DshCompiler.PackOut = false; }
        byte[] inMem = DshVk.PackSpv?.GetValueOrDefault(pk + "_b.spv");
        Check("⑨ 出包模式（PackOut）：输出目录不建、json 取自 PackFiles、_b.spv 进 PackSpv 且与落盘那份逐字节相同",
            packed != null && packed.Contains(pk + "_b.spv") && !Directory.Exists(packDir) && DshCompiler.PackFiles?.ContainsKey(pk + "_b.json") == true
            && inMem != null && inMem.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(outDir, pk + "_b.spv"))), why9);

        // ⑩ 几何 / 曲面外壳 / 曲面域：不出 .spv，明确报红（在 Compile 之前）
        var (_, _, vcode, vctl) = keys.First(k => k.Stage == "vs");
        var refused = new List<string>();
        foreach (var st in new[] { "gs", "hs", "ds" })
        {
            try { DshVk.CompileWithSpv("refuse_" + st, st, vcode, vctl, Path.Combine(root, "refuse"), xc, tables, root); }
            catch (DshError) { refused.Add(st); }
        }
        Check($"⑩ gs / hs / ds 调 CompileWithSpv 报 DshError（{string.Join(" ", refused)}）", refused.Count == 3);
        Console.WriteLine(bad == 0 ? "dsh_vk: 全过" : "dsh_vk: 有不通");
        return bad;
    }
}
