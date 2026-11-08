// 按需实化不等渲染线程的单测（S2A.ShBake selftest-matwait；graphics/tools/shbake/tests/t_mat_wait.sh 调）：期望值全手算，不跑被测实现推期望。
//   形态取自 10-24 测试机1 xc3 冷局第 703 帧停 12 秒：渲染线程在 WaitForProgram 里等一支首遇现编，GPU 模拟线程按需实化缓存程序时 CheckProgramLink 同步等渲染线程。
//   真的多线程渲染器（ThreadedRenderer）包假后端：CreateProgram 出的「慢程序」阻塞查询要等闸门开；先让渲染线程 SetProgram 它（WaitForProgram 卡住），再在 GPU 线程上：
//   ① 闸门关着按需实化两个缓存程序（一个后端装载成功、一个装载失败）：闸门一直关着的情况下就返回了、宿主程序已建（DiskCacheHostStorage.S2AMaterializeCore 不再同步查链接）；
//   ② 反证（旧写法的那一步）：同一形态下对新装载的程序 CheckProgramLink(true)：闸门开之前没返回、开之后才返回——GPU 模拟线程被渲染线程拖住；
//   ③ 闸门开后补查（S2AProcessPendingLink，不等渲染线程）：两个都得出结果；成功的不作废，失败的作废（S2ARejected）、交回调 1 次、只报这一个；
//   ④ 存缓存队列：要二进制的程序编完时渲染线程顺手取好，渲染线程再卡住时取结果与二进制不等它（反证：非阻塞 CheckProgramLink 闸门开前不返回）。
// 判法全按事件（10-25：原先按墙钟判 < 0.5 秒 / ≥ 1.4 秒 / 5 秒内，加上睡 200 ms 等渲染线程卡住，整机高负载下门禁整步超时，近期 46 次 12 次）：
//   「渲染线程卡住」= 假程序进了等闸门（Blocked 事件）；「不等渲染线程」= 闸门关着就做完（等它最多 30 秒只防挂死——旧写法闸门不开就永远做不完，不会误判成过）；
//   「被拖住」= 闸门开前没做完、开后做完。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace S2A.ShBake
{
    // 假后端：CreateProgram 出慢程序（阻塞查询等闸门）；LoadProgramBinary 按首字节出成功（0x01）/ 失败（0xFA）的程序；Pipeline 是空实现
    public class MwRenderer : System.Reflection.DispatchProxy
    {
        public static readonly ManualResetEventSlim Gate = new(false);
        public static readonly ManualResetEventSlim Blocked = new(false);   // 有阻塞查询进了「等闸门」（渲染线程确实卡住了）：测试按它等，不靠睡眠
        public static Capabilities Caps;
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
        {
            switch (m.Name)
            {
                case "GetCapabilities": return Caps;
                case "get_Pipeline": return Create<IPipeline, MwNoop>();
                case "CreateProgram": return MwProgram.Make(slow: true, ProgramLinkStatus.Success);
                case "LoadProgramBinary": return MwProgram.Make(slow: false, ((byte[])a[0])[0] == 0xFA ? ProgramLinkStatus.Failure : ProgramLinkStatus.Success, (byte[])a[0]);
            }
            return m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
        }
    }

    public class MwNoop : System.Reflection.DispatchProxy
    {
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a) => m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
    }

    public class MwProgram : System.Reflection.DispatchProxy
    {
        bool _slow; ProgramLinkStatus _result; byte[] _bin = Array.Empty<byte>();
        public static IProgram Make(bool slow, ProgramLinkStatus result, byte[] bin = null) { IProgram p = Create<IProgram, MwProgram>(); MwProgram m = (MwProgram)(object)p; m._slow = slow; m._result = result; m._bin = bin ?? m._bin; return p; }
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
        {
            if (m.Name == "CheckProgramLink")
            {
                if (!_slow) return _result;
                if ((bool)a[0]) { MwRenderer.Blocked.Set(); MwRenderer.Gate.Wait(); return _result; }
                return MwRenderer.Gate.IsSet ? _result : ProgramLinkStatus.Incomplete;
            }
            return m.Name == "GetBinary" ? _bin : null;
        }
    }

    static class MatWaitSelfTest
    {
        static int _fail, _n;
        static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "不通")} {what}"); }

        public static int Run()
        {
            string dir = Path.Combine(Path.GetTempPath(), "s2a_matwait_" + Environment.ProcessId);
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            int rc = 2;
            try
            {
                // 缓存里写两个图形程序（顶点 + 片元），宿主二进制首字节 0x01 = 后端装载成功、0xFA = 失败；记下各自在共享数据里的偏移，按开局登记的口径建按需程序
                GpuContext wctx = ShaderBake.MakeContext(out Capabilities caps);
                MwRenderer.Caps = caps;
                ShaderProgramInfo Vi = new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Vertex, 0, 0, 0, false, false, false, false, 0, -1);
                ShaderProgramInfo Fi = new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Fragment, 0, 0, 0, false, false, false, false, 0, 1);
                DiskCacheHostStorage hs = new(dir);
                GuestCodeAndCbData?[][] guests = new GuestCodeAndCbData?[2][];
                for (int k = 0; k < 2; k++)
                {
                    byte[] cv = Enumerable.Range(0, 64).Select(i => (byte)(i + k)).ToArray(), cf = Enumerable.Range(0, 64).Select(i => (byte)(200 - i - k)).ToArray();
                    CachedShaderStage[] st = { null, new(Vi, cv, Array.Empty<byte>()), null, null, null, new(Fi, cf, Array.Empty<byte>()) };
                    GpuChannelGraphicsState gs = default;
                    hs.AddShader(wctx, new CachedShaderProgram(null, new ShaderSpecializationState(ref gs, null, null), st), new byte[] { k == 0 ? (byte)0x01 : (byte)0xFA, 2, 3, 4 });
                    guests[k] = new GuestCodeAndCbData?[] { null, new GuestCodeAndCbData(cv, Array.Empty<byte>()), null, null, null, new GuestCodeAndCbData(cf, Array.Empty<byte>()) };
                }
                byte[] toc = File.ReadAllBytes(Path.Combine(dir, "shared.toc"));
                ulong ts = BinaryPrimitives.ReadUInt64LittleEndian(toc.AsSpan(16));
                ulong[] offs = { BinaryPrimitives.ReadUInt64LittleEndian(toc.AsSpan(32)), BinaryPrimitives.ReadUInt64LittleEndian(toc.AsSpan(32 + 8)) };

                IRenderer fake = System.Reflection.DispatchProxy.Create<IRenderer, MwRenderer>();
                ThreadedRenderer tr = new(fake);
                GpuContext ctx = new(tr, new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>())) { Capabilities = caps };

                // 本线程当渲染线程（RunLoop 起 GPU 线程跑测试体），测试体结束直接退出进程
                tr.RunLoop(() =>
                {
                    try { Body(tr, ctx, hs, guests, offs, ts); }
                    catch (Exception e) { Ck(false, $"抛异常 {e.GetType().Name}: {e.Message}"); }
                    Console.WriteLine($"t_mat_wait：{_n} 项，失败 {_fail}");
                    try { Directory.Delete(dir, true); } catch { }
                    Environment.Exit(_fail == 0 ? 0 : 1);
                });
            }
            catch (Exception e) { Ck(false, $"准备抛异常 {e.GetType().Name}: {e.Message}"); Console.WriteLine($"t_mat_wait：{_n} 项，失败 {_fail}"); rc = 1; }
            finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
            return rc;
        }

        static void Body(ThreadedRenderer tr, GpuContext ctx, DiskCacheHostStorage hs, GuestCodeAndCbData?[][] guests, ulong[] offs, ulong ts)
        {
            // 渲染线程卡住：SetProgram 一个慢程序 → 渲染线程 WaitForProgram 对它阻塞查询、等闸门（现场里那支首遇现编）
            ShaderSource[] src = { new(Array.Empty<byte>(), ShaderStage.Fragment, TargetLanguage.Spirv) };
            IProgram slow = tr.CreateProgram(src, default);
            tr.Pipeline.SetProgram(slow);
            Ck(MwRenderer.Blocked.Wait(60000), "渲染线程卡进等闸门（WaitForProgram 对慢程序阻塞查询）");

            // ① 闸门关着按需实化：放到后台做，闸门不开就得做完
            CachedShaderProgram ok = null, bad = null;
            var t1 = System.Threading.Tasks.Task.Run(() => {
                ok = new S2ALazyProgram(hs, ctx, 0, offs[0], ts, false, hs.S2ARegisterGuests(guests[0])).Materialize();
                bad = new S2ALazyProgram(hs, ctx, 1, offs[1], ts, false, hs.S2ARegisterGuests(guests[1])).Materialize(); });
            bool done1 = t1.Wait(30000);
            Ck(done1 && !MwRenderer.Gate.IsSet, "① 渲染线程卡着、闸门一直关着时按需实化两个程序就做完了（旧写法要等渲染线程，闸门不开永远做不完）");
            Ck(ok?.HostProgram != null && bad?.HostProgram != null, "① 两个都建出宿主程序（装载失败的那个也先建出、留给补查）");

            // ② 反证：旧写法那一步（对新装载的程序同步查链接）：闸门开之前做不完，开之后才做完
            ProgramLinkStatus old = ProgramLinkStatus.Incomplete;
            var t2 = System.Threading.Tasks.Task.Run(() => { old = ctx.Renderer.LoadProgramBinary(new byte[] { 0x01 }, true, default).CheckProgramLink(true); });
            bool early2 = t2.Wait(300);
            MwRenderer.Gate.Set();
            bool done2 = t2.Wait(60000);
            Ck(!early2 && done2 && old == ProgramLinkStatus.Success, $"② 反证：同一形态下同步查链接，闸门开前没返回、开后返回 Success（实得 开前{(early2 ? "已" : "未")}返回、{old}）");

            // ③ 补查：渲染线程放开后 SetProgram 两个程序让它得出结果，GPU 线程这边不等渲染线程地补查，直到两个都有结果（60 秒只防挂死）
            tr.Pipeline.SetProgram(ok.HostProgram);
            tr.Pipeline.SetProgram(bad.HostProgram);
            int failed = 0, left = -1; CachedShaderProgram failedProg = null;
            Stopwatch sw = Stopwatch.StartNew();
            while ((left = hs.S2AProcessPendingLink(p => { failed++; failedProg = p; })) > 0 && sw.ElapsedMilliseconds < 60000) Thread.Sleep(10);
            Ck(left == 0, $"③ 两个都得出链接结果，实得剩 {left} 个");
            Ck(!ok.SpecializationState.S2ARejected, "③ 装载成功的不作废");
            Ck(bad.SpecializationState.S2ARejected, "③ 装载失败的作废（之后查找跳过、首遇照常翻译）");
            Ck(failed == 1 && failedProg == bad, $"③ 失败回调 1 次、交的是失败那个，实得 {failed} 次");

            // ④ 存缓存队列那一步（ShaderCache.ProcessShaderCacheQueue，10-24 Mac xc3 第 1230 帧停 10 秒）：新翻的程序入队时要二进制（S2AWantBinary），
            //    渲染线程编完时顺手取好；渲染线程再次卡住、闸门关着时，GPU 线程取链接结果与二进制就做完、二进制就是后端给的那份；反证：非阻塞 CheckProgramLink 闸门开前不返回
            //    入队与要二进制都在渲染线程卡着时做（闸门钉顺序）：渲染线程跑程序队列（处理 ③ 留下的命令时就会跑）只能在要二进制之后得出它的结果。
            //    原先入队后才设要二进制，高负载下渲染线程恰在两步之间得出 Success、没取二进制，后面取二进制退回发命令等渲染线程，闸门关着做不完（11-02 全套门禁偶发红）
            MwRenderer.Gate.Reset(); MwRenderer.Blocked.Reset();
            tr.Pipeline.SetProgram(tr.CreateProgram(src, default));
            Ck(MwRenderer.Blocked.Wait(60000), "④ 入队前渲染线程先卡进等闸门");
            byte[] want = { 0x01, 0x5A, 0xA5, 0x77 };
            IProgram saved = ctx.Renderer.LoadProgramBinary(want, true, default);
            ThreadedRenderer.S2AWantBinary(saved);
            tr.Pipeline.SetProgram(saved);
            MwRenderer.Gate.Set();
            sw.Restart();
            while (ThreadedRenderer.S2ALinkStatusNoWait(saved) == ProgramLinkStatus.Incomplete && sw.ElapsedMilliseconds < 60000) Thread.Sleep(10);
            MwRenderer.Gate.Reset(); MwRenderer.Blocked.Reset();
            tr.Pipeline.SetProgram(tr.CreateProgram(src, default));   // 渲染线程再卡在一个慢程序上
            Ck(MwRenderer.Blocked.Wait(60000), "④ 渲染线程再次卡进等闸门");
            ProgramLinkStatus st = ProgramLinkStatus.Incomplete; byte[] got = null;
            var t4 = System.Threading.Tasks.Task.Run(() => { st = ThreadedRenderer.S2ALinkStatusNoWait(saved); got = ThreadedRenderer.S2ABinary(saved); });
            bool done4 = t4.Wait(30000);
            Ck(done4 && !MwRenderer.Gate.IsSet && st == ProgramLinkStatus.Success && got != null && got.SequenceEqual(want),
               $"④ 渲染线程卡着、闸门关着时取链接结果与二进制就做完、二进制原样，实得 {(done4 ? "做完" : "没做完")}、{st}、{(got == null ? "空" : Convert.ToHexString(got))}");
            ProgramLinkStatus old2 = ProgramLinkStatus.Incomplete;
            var t5 = System.Threading.Tasks.Task.Run(() => { old2 = saved.CheckProgramLink(false); });
            bool early5 = t5.Wait(300);
            MwRenderer.Gate.Set();
            bool done5 = t5.Wait(60000);
            Ck(!early5 && done5 && old2 == ProgramLinkStatus.Success, $"④ 反证：同一形态下非阻塞 CheckProgramLink（原先存缓存队列的查法），闸门开前没返回、开后返回 Success（实得 开前{(early5 ? "已" : "未")}返回、{old2}）");
        }
    }
}
