// 片元输出类型变体单测（S2A.ShBake selftest-fout [<被测 S2A.ShBake>]；graphics/tools/shbake/tests/t_fout.sh 调）：ShaderBake 5c「按观测补片元输出类型变体」。
//   手拼一个顶点 + 片元程序（片元 SPH 写渲染目标 0 的 RGBA），造抽出集（@hdr 相邻规则配成一个程序）与假特化管线表，用被测 S2A.ShBake bake（子进程、只翻译不给 --xc）出包后核产物。
//   期望值（手算 / 由运行时同一条翻译路直接翻出，不跑 5c）：
//     运行时口径的片元键 = 特化状态 FragmentOutputTypes[0] = Uint 时 Ryujinx 翻出的片元 SPIR-V 经宽屏改写后的键（与离线库函数名同口径）；顶点键同法；
//     表 4 行：① 目标 0 = 53（R32Uint）、片元 = 运行时口径键；② 同 ① 但片元键是假的；③ 目标 0 = 55（R32Float）；④ b2 行。
//     整数目标观测行 = 2（①②），匹配到程序 1，补出 1（①② 同一程序同一组类型，只翻一次），成功 1（片元键对上 ①），观测行覆盖 1/2；
//     缓存程序 2 个：原程序 FragmentOutputTypes 全 Float、变体 [0] = Uint 其余 Float；spv/<运行时片元键>.spv 在，其输出位置 0 的变量是 4 分量 32 位无符号整数。
//   反证：给旧版 S2A.ShBake（没有 5c）时缓存只有 1 个程序、补出 0、整数片元 SPIR-V 不在（本测必红）
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace S2A.ShBake
{
    static class FoutSelfTest
    {
        static int _fail, _n;
        static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "不通")} {what}"); }

        // 运行时那条路（DiskCacheGpuAccessor，同设备加载）直接翻（顶点, 片元），返回宽屏改写后的（顶点键, 片元键, 片元 SPIR-V）
        static (string vs, string fs) Oracle(byte[] vs, byte[] fs, AttributeType out0, int slot = 0)
        {
            GpuContext ctx = ShaderBake.MakeContext(out _);
            GpuChannelGraphicsState st = default;
            st.FragmentOutputTypes[slot] = out0;
            ShaderSpecializationState spec = new(ref st, null, null), ns = new(ref st, null, null);
            ResourceCounts counts = new();
            DiskCacheGpuAccessor av = new(ctx, vs, Array.Empty<byte>(), spec, ns, counts, 0, false), af = new(ctx, fs, Array.Empty<byte>(), spec, ns, counts, 4, false);
            TranslatorContext tf = ShaderCache.DecodeGraphicsShader(af, ctx.Capabilities.Api, ShaderCache.DefaultFlags, 0);
            TranslatorContext tv = ShaderCache.DecodeGraphicsShader(av, ctx.Capabilities.Api, ShaderCache.DefaultFlags, 0);
            tv.SetNextStage(tf);
            av.InitializeReservedCounts(false, false); byte[] sv = tv.Translate().BinaryCode;
            af.InitializeReservedCounts(false, false); byte[] sf = tf.Translate().BinaryCode;
            string K(byte[] b, ShaderStage s) => ShaderBake.SpvKey(S2Arm.Gfx.Widen.WidenIndex.Transform(b, (int)s, s == ShaderStage.Vertex, s == ShaderStage.Fragment, out _, true));
            return (K(sv, ShaderStage.Vertex), K(sf, ShaderStage.Fragment));
        }

        // SPIR-V 里输出位置 loc 的变量（OpVariable 存储类 Output = 3，带 Location 修饰）的元素类型：返回（分量数, 是整数, 有符号, 位宽）；找不到 = null
        static (int n, bool isInt, bool signed, int width)? OutputType(byte[] spv, int loc)
        {
            Dictionary<uint, uint> locOf = new(); Dictionary<uint, (uint sc, uint type)> ptr = new(); Dictionary<uint, (uint comp, int n)> vec = new();
            Dictionary<uint, (bool isInt, bool signed, int width)> scalar = new(); List<(uint type, uint id)> outVars = new();
            for (int i = 20; i + 4 <= spv.Length;)
            {
                uint w = BinaryPrimitives.ReadUInt32LittleEndian(spv.AsSpan(i)); int len = (int)(w >> 16), op = (int)(w & 0xFFFF);
                uint W(int k) => BinaryPrimitives.ReadUInt32LittleEndian(spv.AsSpan(i + 4 * k));
                if (len == 0) break;
                switch (op)
                {
                    case 71 when len >= 4 && W(2) == 30: locOf[W(1)] = W(3); break;                       // OpDecorate <id> Location <n>
                    case 21: scalar[W(1)] = (true, W(3) == 1, (int)W(2)); break;                           // OpTypeInt <id> 位宽 有符号
                    case 22: scalar[W(1)] = (false, true, (int)W(2)); break;                               // OpTypeFloat <id> 位宽
                    case 23: vec[W(1)] = (W(2), (int)W(3)); break;                                         // OpTypeVector <id> 分量类型 个数
                    case 32: ptr[W(1)] = (W(2), W(3)); break;                                              // OpTypePointer <id> 存储类 类型
                    case 59 when W(3) == 3: outVars.Add((W(1), W(2))); break;                              // OpVariable <类型> <id> Output
                }
                i += len * 4;
            }
            foreach (var (type, id) in outVars)
            {
                if (!locOf.TryGetValue(id, out uint l) || l != loc || !ptr.TryGetValue(type, out var p)) continue;
                if (vec.TryGetValue(p.type, out var v) && scalar.TryGetValue(v.comp, out var s)) return (v.n, s.isInt, s.signed, s.width);
                if (scalar.TryGetValue(p.type, out var s1)) return (1, s1.isInt, s1.signed, s1.width);
            }
            return null;
        }

        public static int Run(string bakeBin)
        {
            bakeBin ??= Environment.ProcessPath;
            string root = Path.Combine(Path.GetTempPath(), "s2a_fout_" + Environment.ProcessId);
            if (Directory.Exists(root)) Directory.Delete(root, true);
            try
            {
                // 顶点：AST a[0x80] ← R0、EXIT；片元：SPH 字 18 = 渲染目标 0 的 RGBA，EXIT 时 R0–R3 写出
                byte[] vs = VtgSelfTest.Guest(1 | (3 << 5) | (1 << 10), 0, 0, 0, 0, 0xEFF0000000000000UL | (0xFFUL << 39) | (0x80UL << 20) | (7UL << 16) | (0xFFUL << 8), VtgSelfTest.Exit);
                byte[] fs = VtgSelfTest.Guest(2 | (3 << 5) | (5 << 10), 0, 0, 0, 0xF, VtgSelfTest.Exit);
                var (vk, fkU) = Oracle(vs, fs, AttributeType.Uint);
                var (vk2, fkF) = Oracle(vs, fs, AttributeType.Float);
                Ck(vk == vk2 && fkU != fkF, $"前提：顶点键与输出类型无关（{vk}），片元键随输出类型变（Uint {fkU} ≠ Float {fkF}）");
                // 特化匹配只比写到的目标（ShaderSpecializationState.S2AFoutMatches）的依据：片元只写 0 号目标，没写的 3 号目标是 Uint 时翻出的片元键与全浮点逐字相同
                var (_, fk3) = Oracle(vs, fs, AttributeType.Uint, 3);
                Ck(fk3 == fkF, $"没写的 3 号目标是 Uint：片元键与全浮点相同（期望 {fkF} → 实得 {fk3}）");

                string x = Path.Combine(root, "x"), o = Path.Combine(root, "o");
                SrcPack.Append(x, "v0", new byte[0x30].Concat(vs).ToArray(), new byte[0x800]);
                SrcPack.Append(x, "p0", new byte[0x30].Concat(fs).ToArray(), new byte[0x800]);
                File.WriteAllText(Path.Combine(x, "rows.tsv"), "v0\tvs\tfout.bin@hdr0x0\t0\np0\tps\tfout.bin@hdr0x100\t0\n");
                string sp = Path.Combine(root, "spec_pipes.tsv");
                const string Att = ":15:0:0:1:0:0:1:0";
                File.WriteAllText(sp, "# 假特化管线表\n" +
                    $"v2 s{vk} s{fkU} 3 1 0 0 1 0:53{Att}\n" +
                    $"v2 s{vk} s0123456789abcdef 3 1 0 0 1 0:53{Att}\n" +
                    $"v2 s{vk} s{fkF} 3 1 0 0 1 0:55{Att}\n" +
                    $"b2 s{vk} s{fkU} 3 1 0 0 1\n");

                ProcessStartInfo psi = new(bakeBin) { RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (string a in new[] { "bake", x, o, "--title", "0100000000f0a700", "-j", "2" }) psi.ArgumentList.Add(a);
                psi.Environment["S2A_SPEC_PIPES"] = sp; psi.Environment["S2A_NO_ALPHA_VARIANTS"] = "1";
                foreach (string v in new[] { "S2A_PROG_TABLE", "S2A_PAIR_TABLE", "S2A_STAGE_ALL", "S2A_SHBAKE_PAIR_ONLY", "S2A_SHBAKE_GS_ONLY" }) psi.Environment.Remove(v);
                string log;
                using (Process pr = Process.Start(psi))
                {
                    var t1 = pr.StandardOutput.ReadToEndAsync(); var t2 = pr.StandardError.ReadToEndAsync();
                    if (!pr.WaitForExit(120_000)) { pr.Kill(true); Ck(false, "烘焙 120 秒没完"); return 1; }
                    log = t1.Result + t2.Result;
                    Ck(pr.ExitCode == 0, $"烘焙退出 0（实得 {pr.ExitCode}）");
                }
                foreach (string l in log.Split('\n').Where(l => l.Contains("片元输出类型变体") || l.Contains("【红】"))) Console.WriteLine("  | " + l.TrimEnd());

                List<ShaderSpecializationState> specs = ShaderBake.S2AReadSpecsForTest(Path.Combine(o, "shcache", "0100000000f0a700"));
                string Sig(ShaderSpecializationState s) => string.Join(",", Enumerable.Range(0, 8).Select(i => s.GraphicsState.FragmentOutputTypes[i].ToString()));
                string allF = string.Join(",", Enumerable.Repeat("Float", 8)), u0 = "Uint," + string.Join(",", Enumerable.Repeat("Float", 7));
                int nU = specs.Count(s => Sig(s) == u0);
                Ck(specs.Count == 2, $"缓存程序 2 个（原程序 + 变体；旧代码 1），实得 {specs.Count}");
                Ck(specs.Count(s => Sig(s) == allF) == 1 && nU == 1, $"缓存：全 Float 1 个、[0] = Uint 其余 Float 1 个（补出的变体；旧代码 0），实得 {nU}；各程序 {string.Join(" | ", specs.Select(Sig))}");

                string spv = Path.Combine(o, "spv", fkU + ".spv");
                Ck(File.Exists(spv), $"整数输出片元 SPIR-V 进库：spv/{fkU}.spv（旧代码没有）");
                var ot = File.Exists(spv) ? OutputType(File.ReadAllBytes(spv), 0) : null;
                Ck(ot is { n: 4, isInt: true, signed: false, width: 32 }, $"整数输出片元：位置 0 输出是 4 分量 32 位无符号整数，实得 {(ot is { } q ? $"{q.n} 分量 {(q.isInt ? (q.signed ? "有符号整数" : "无符号整数") : "浮点")} {q.width} 位" : "找不到")}");
                var otF = File.Exists(Path.Combine(o, "spv", fkF + ".spv")) ? OutputType(File.ReadAllBytes(Path.Combine(o, "spv", fkF + ".spv")), 0) : null;
                Ck(otF is { isInt: false }, "对照：原程序的片元 SPIR-V 在库、位置 0 输出是浮点（量法正对照）");

                using JsonDocument bj = JsonDocument.Parse(File.ReadAllText(Path.Combine(o, "bake.json")));
                int J(string k) => bj.RootElement.TryGetProperty("variants_fout", out var e) && e.TryGetProperty(k, out var v) ? v.GetInt32() : -1;
                Ck(J("observed_lines") == 2 && J("matched_programs") == 1 && J("added") == 1 && J("ok") == 1 && J("lines_covered") == 1 && J("key_mismatch_dropped") == 0 && J("errors") == 0,
                    $"bake.json 计数：观测 2 / 匹配程序 1 / 补出 1 / 成功 1 / 覆盖 1 / 丢弃 0 / 失败 0，实得 {J("observed_lines")} / {J("matched_programs")} / {J("added")} / {J("ok")} / {J("lines_covered")} / {J("key_mismatch_dropped")} / {J("errors")}");
            }
            catch (Exception e) { Ck(false, $"抛异常 {e.GetType().Name}: {e.Message}"); }
            finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
            Console.WriteLine($"t_fout：{_n} 项，失败 {_fail}");
            return _fail == 0 ? 0 : 1;
        }
    }
}
