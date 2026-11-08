// 着色器包（graphics/tools/shader_pack.sh 出包、整个目录进包 Documents/资源包/shaders/）运行时装载：渲染器初始化之后、Ryujinx 读着色器磁盘缓存之前调一次。
// ① 开离线库 gal.idx + gal.shards + 各片 metallib（函数按 SPIR-V 键直取，不现编）、管线归档 gal_pso.<GPU 架构>.bin（基础管线按描述命中，首遇只特化）；② 把包里的 Ryujinx 磁盘缓存 shcache/<程序号>/ 克隆进 Ryujinx 缓存目录
//    （guest + shared + 宿主程序二进制：加载时按二进制建程序，不重翻 Maxwell）。冷启动（S2A_COLD_START）清掉缓存后照样从包里种回 = 玩家装包首启。
// 缓存目录里记着种它的包指纹（s2a_pack.key）：包换了（指纹不同，App 升级 / 换新包的预期行为）整份换成包内的、打一行带新旧指纹的信息；目录里少了 / 截短了包里的文件、或不是包种的，也整份换、打信息（10-20 总指挥口径）；只有替换失败或替换后校验不过才报红；
// 同一个包且文件齐全则保留（运行中 Ryujinx 只往后追加新程序）。指纹取自包本身（shader_pack.key + shcache 各文件名、长度、.toc 全文），
// 不用固定兜底串——10-20 两个没带 shader_pack.key 的包都落成「无键」被当成同一个，留下翻译口径 6 的旧二进制，11028 个程序全部现翻。
// 包目录：S2A_SHADER_PACK；没给时先找文档目录 gal/<程序号>/shaders（外置着色器包，打得开才用），再到 S2A_GAME_DATA/shaders；没有包 = 只打一行日志（开发局照旧现编）。
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace S2A.Gfx
{
    static class ShaderPack
    {
        // 文档根：S2A_DOCS，否则 $HOME/Documents（iOS 沙盒）。C 侧唯一取法 runtime/include/s2a_docs.h 的 C# 同口径一份（C# 调不到 C 头），本程序集只许经它取
        static string DocsRoot()
        {
            string docs = Environment.GetEnvironmentVariable("S2A_DOCS");
            return string.IsNullOrEmpty(docs) ? Path.Combine(Environment.GetEnvironmentVariable("HOME") ?? ".", "Documents") : docs;
        }

        // 外置着色器包根：<文档根>/gal/<程序号 16 位大写>/shaders
        static string OverlayRoot()
        {
            string tid = GraphicsConfig.TitleId;
            if (string.IsNullOrEmpty(tid)) return null;
            return Path.Combine(DocsRoot(), "gal", tid.ToUpperInvariant(), "shaders");
        }

        public static void Mount()
        {
            S2AShaderCacheGuard.PackPrograms = 0;
            S2AShaderCacheGuard.WarmList = null;
            string dir = Environment.GetEnvironmentVariable("S2A_SHADER_PACK"), err = null;
            bool opened = false;
            if (string.IsNullOrEmpty(dir))
            {
                // 外置着色器包（graphics/nvn/gfx/nvn/shader_overlay.h 同一口径）：文档目录 gal/<程序号>/shaders 的离线库打得开就用它（更新着色器包不必重签），打不开退回包内
                string ov = OverlayRoot();
                if (ov != null && File.Exists(Path.Combine(ov, "gal.idx")))
                {
                    string oe = NxProgram.OpenLibrary(ov);
                    if (oe == null) { dir = ov; opened = true; Console.Error.WriteLine($"[gal] 用文档目录里的外置着色器包 {ov}"); }
                    else Console.Error.WriteLine($"[gal] 文档目录里的外置着色器包 {ov} 打不开（{oe}），用包内的");
                }
                if (!opened) { string g = Environment.GetEnvironmentVariable("S2A_GAME_DATA"); if (!string.IsNullOrEmpty(g)) dir = Path.Combine(g, "shaders"); }
            }
            if (string.IsNullOrEmpty(dir) || !File.Exists(Path.Combine(dir, "gal.idx"))) { Console.Error.WriteLine($"[gal] 无着色器包（{dir ?? "没给 S2A_GAME_DATA"}）：首遇着色器现编"); return; }
            if (!opened) err = NxProgram.OpenLibrary(dir);
            if (err != null) Console.Error.WriteLine($"[gal] 【红】着色器包开离线库失败：{err}");
            NxProgram.OpenPsoArchive(dir);   // 管线归档（第 2 步 2c）：本机架构没有时只记一行，首遇照旧现建并计数
            Seen(dir);
            string tid = GraphicsConfig.TitleId?.ToLowerInvariant();
            string src = tid == null ? null : Path.Combine(dir, "shcache", tid);
            if (src == null || !Directory.Exists(src)) { Console.Error.WriteLine($"[gal] 【红】着色器包里没有本游戏（{tid ?? "程序号未登记"}）的 Ryujinx 缓存：{src}"); return; }
            // 新翻译器会作废旧程序；不能因运行时缓存较短，再把旧包种回去覆盖本局已经学到的程序。
            if (!S2AShaderCacheGuard.HasCurrentCode(src, out uint version))
            {
                Console.Error.WriteLine($"[gal] 着色器包翻译版本 {version} ≠ 当前 {S2AShaderCacheGuard.TranslatorVersion}：不种入旧程序，保留运行时缓存；请更新着色器包");
                return;
            }
            if (!GraphicsConfig.EnableShaderCache) Console.Error.WriteLine("[gal] 【红】Ryujinx 着色器磁盘缓存没开（GraphicsConfig.EnableShaderCache = false）：包里的 Ryujinx 缓存不会被读");
            string dst = Path.Combine(AppDataManager.GamesDirPath, tid, "cache", "shader"), keyF = Path.Combine(dst, "s2a_pack.key");
            string[] files = Directory.GetFiles(src); Array.Sort(files, StringComparer.Ordinal);
            // 包里的程序数（shared.toc：32 字节头 + 每程序 8 字节偏移）：Ryujinx 缓存里序号小于它的是包内条目，首次命中核对不符时报「包内特化不符」（10-21）
            string toc = Path.Combine(src, "shared.toc");
            S2AShaderCacheGuard.PackPrograms = File.Exists(toc) ? (int)Math.Max(0, (new FileInfo(toc).Length - 32) / 8) : 0;
            string key = Fingerprint(dir, files);
            string why = null, old = null;
            if (!File.Exists(keyF))
            {
                // 目录在、没有指纹：空目录 = 冷局清过缓存 / 首次起局（预期，打信息）；有文件 = 来路不明的缓存（红）
                if (Directory.Exists(dst)) { bool empty = !Directory.EnumerateFileSystemEntries(dst).Any(); why = empty ? "首次种入（目录为空）" : "目录里的缓存不是包种的"; }
            }
            else if ((old = File.ReadAllText(keyF).Trim()) != key) { why = $"包已更新：指纹 {old[..Math.Min(12, old.Length)]} → {key[..12]}"; }   // App 升级 / 换新包：每次换包首启一次，预期行为
            else foreach (string f in files)
                {
                    var d = new FileInfo(Path.Combine(dst, Path.GetFileName(f)));
                    if (!d.Exists || d.Length < new FileInfo(f).Length) { why = $"缺 / 截短 {Path.GetFileName(f)}"; break; }
                }
            if (why == null && File.Exists(keyF)) { Console.Error.WriteLine($"[gal] 着色器包已种（指纹 {key[..12]}）：{dst}"); Warm(dir); return; }
            // 10-20 总指挥口径：自动换成包内缓存这件事本身一律是信息（换包重装后 Documents 留着旧缓存是预期）；只有替换失败或替换后校验不过才红
            if (why != null) Console.Error.WriteLine($"[gal] 着色器缓存与包不同（{why}）：整份换成包内的");
            try
            {
                if (Directory.Exists(dst)) Directory.Delete(dst, true);   // 旧包种的（或旧包下运行时追加的）整份换掉：不同包的程序序号对不上
                Directory.CreateDirectory(dst);
                long bytes = 0;
                foreach (string f in files) { File.Copy(f, Path.Combine(dst, Path.GetFileName(f))); bytes += new FileInfo(f).Length; }   // macOS / iOS 同卷 File.Copy 走 clonefile，不占空间
                File.WriteAllText(keyF, key);
                string bad = files.Select(f => (f, d: new FileInfo(Path.Combine(dst, Path.GetFileName(f))))).Where(x => !x.d.Exists || x.d.Length != new FileInfo(x.f).Length).Select(x => Path.GetFileName(x.f)).FirstOrDefault();
                if (bad != null || File.ReadAllText(keyF).Trim() != key) Console.Error.WriteLine($"[gal] 【红】着色器缓存替换后校验不过（{bad ?? "指纹没写进去"}）：{dst}");
                else { Console.Error.WriteLine($"[gal] 着色器包种入 Ryujinx 缓存：{bytes >> 20} MB → {dst}"); Warm(dir); }
            }
            catch (Exception e) { Console.Error.WriteLine($"[gal] 【红】着色器包种入失败：{e.Message}"); }
        }

        // 双轨覆盖率就绪（§12.3）：双轨包带 shaders/direct/guest_key.tsv 时，见过的着色器按它换成直连库键写 Documents/wire/<程序号>/seen_shaders.tsv
        //   （Documents = 文档根 DocsRoot，同 runtime/src/gfxmode.c；直连线的就绪判定读）。通用包没有这张表 = 不记
        static void Seen(string dir)
        {
            string t = Path.Combine(dir, "direct", "guest_key.tsv");
            if (!File.Exists(t)) return;
            if (GraphicsConfig.TitleId == null) { Console.Error.WriteLine("[gal] 【红】双轨包：程序号未登记，不记 seen_shaders.tsv"); return; }
            string seen = Path.Combine(DocsRoot(), "wire", GraphicsConfig.TitleId.ToUpperInvariant(), "seen_shaders.tsv");
            string err = S2ASeen.Open(t, seen);
            Console.Error.WriteLine(err == null ? $"[gal] 双轨覆盖率：见过的着色器记 {seen}（键表 {S2ASeen.TableCount} 条）" : $"[gal] 【红】双轨覆盖率：开 seen 失败：{err}");
        }

        // 提前热程序表（出包 shbake/psowarm.py，10-23）：Ryujinx 缓存确认是本包种的之后才登记（程序号按包内缓存对位），载完缓存由 DiskCacheHostStorage 后台按表先载一次程序、触发管线预取
        static void Warm(string dir)
        {
            string w = Path.Combine(dir, "pso_warm.tsv");
            if (!File.Exists(w)) return;
            // S2A_SHADER_WARM=0：不热（对照局 / 安全阀），其余照旧按需实化
            if (Environment.GetEnvironmentVariable("S2A_SHADER_WARM") == "0") { Console.Error.WriteLine("[gal] 提前热程序：S2A_SHADER_WARM=0，不热"); return; }
            S2AShaderCacheGuard.WarmList = w;
        }

        /// <summary>包指纹：shader_pack.key（出包键）+ shcache 各文件名与长度 + 各 .toc 全文（目录表，内容一变就变；几百 KB，起局不到 1 毫秒）。没带 shader_pack.key 报红但照样算出独立指纹。</summary>
        internal static string Fingerprint(string dir, string[] files)
        {
            using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            string kf = Path.Combine(dir, "shader_pack.key");
            if (File.Exists(kf)) h.AppendData(Encoding.UTF8.GetBytes(File.ReadAllText(kf).Trim()));
            else Console.Error.WriteLine($"[gal] 【红】着色器包没带 shader_pack.key：按 shcache 内容算指纹（{dir}）");
            foreach (string f in files)
            {
                h.AppendData(Encoding.UTF8.GetBytes($"\n{Path.GetFileName(f)}\t{new FileInfo(f).Length}\n"));
                if (f.EndsWith(".toc", StringComparison.Ordinal)) h.AppendData(File.ReadAllBytes(f));
            }
            return Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant();
        }
    }
}
