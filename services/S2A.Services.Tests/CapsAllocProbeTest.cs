using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace S2A.Services.Tests
{
    // 截图服务的托管分配判据（#1302）。要防的是「把 3.6 MB 游戏截图缓冲拷成托管数组」（10-20 普查中风险）。
    //   原判据量整条 SaveScreenShot（含 Skia 编码）< 64 KB，可里面 48 KB 是编码器自己的：JPEG 输出数组 36.7 KB + Skia 首用初始化 11 KB，
    //   只剩 12 KB 余量；本线程上还有随时序变化的分配——异步日志队列积压时入队方分配新段（实测 1.6–17 KB）、相册同秒同名换号每次 464 B。
    //   拆成两条直接判据：① 真编码器整条路径 < 截图大小（任何一处拷贝缓冲都 ≥ 3.6 MB）；② 注入固定输出编码器，只量服务路径 < 64 KB。
    //   每次调用后清相册目录，换号循环不随调用次数增长。
    public static unsafe partial class Program
    {
        private static readonly byte[] _capsFixedJpeg = [0xFF, 0xD8, 0, 0, 0xFF, 0xD9];

        private static string CapsAlbumDir() => Path.Combine(Ryujinx.Common.Configuration.AppDataManager.BaseDirPath, "sdcard", "Nintendo", "Album");

        private static (long Total, uint Result) CapsSaveOnce(uint capsu, byte* shot, int size)
        {
            Msg ss = Msg.Cmif(203, Bytes(new byte[0x40], 0u, 0UL, 0UL)); ss.SendPid = true; ss.A.Add(((ulong)shot, (ulong)size));
            long c0 = GC.GetAllocatedBytesForCurrentThread();
            Reply r = Call(capsu, ss);
            long a = GC.GetAllocatedBytesForCurrentThread() - c0;
            try { Directory.Delete(CapsAlbumDir(), true); } catch (DirectoryNotFoundException) { }
            return (a, r.Result);
        }

        // 返回：真编码器一次（整条路径）、固定编码器一次（只含服务路径）的本线程托管分配
        private static (long Real, long Svc, uint RealResult, uint SvcResult) CapsSaveAlloc(uint capsu, byte* shot, int size)
        {
            (long real, uint r1) = CapsSaveOnce(capsu, shot, size);
            var was = Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg;
            int seen = -1;
            Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg = (rgba, w, h, q) => { seen = rgba.Length; return _capsFixedJpeg; };
            try
            {
                (long svc, uint r2) = CapsSaveOnce(capsu, shot, size);
                // 编码器必须真拿到整幅像素（服务没在编码前短路），否则「服务路径」量的不是同一条路
                return (real, seen == 1280 * 720 * 4 ? svc : long.MaxValue, r1, r2);
            }
            finally { Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg = was; }
        }

        // 相册同一秒的序号用完（UniqueId 一个字节）：原先换号循环回绕到 0 永远转下去，游戏线程卡死在 SaveScreenShot。
        //   先存一张拿到文件名里的标题哈希，再把从这一秒起 6 秒的 0–255 号全部占上（跨秒也照样满），再存一张：应回 AlbumFileCountLimit（0x32CE）、不新写文件
        [SoloTest("--caps-album-full", Booted = true)]
        private static void CapsAlbumFull()
        {
            const int Shot = 1280 * 720 * 4;
            string root = Path.Combine(Path.GetTempPath(), $"s2a_caps_full_{Environment.ProcessId}");
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "exefs"));
                Directory.CreateDirectory(Path.Combine(root, "ctl"));
                Directory.CreateDirectory(Path.Combine(root, "romfs"));
                File.Copy(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")), Path.Combine(root, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(root, "ctl", "control.nacp"), new byte[0x4000]);
                Host.Device.System.ServiceTable.WaitServicesReady();
                Application.Register(Host.Device, root);
                Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
                Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
                Reply gcs = Call(sm, Msg.Cmif(1, Name8("caps:su")));
                uint capsu = gcs.Move.Count == 1 ? gcs.Move[0] : 0;
                byte* shot = FakeNative.Alloc(Shot);
                Msg first = Msg.Cmif(203, Bytes(new byte[0x40], 0u, 0UL, 0UL)); first.SendPid = true; first.A.Add(((ulong)shot, (ulong)Shot));
                uint r0 = Call(capsu, first).Result;
                string[] made = Directory.Exists(CapsAlbumDir()) ? Directory.GetFiles(CapsAlbumDir(), "*.jpg", SearchOption.AllDirectories) : [];
                // 文件名：yyyyMMddHHmmss + 序号 {:00} + "-" + 标题哈希 + ".jpg"
                string name = made.Length == 1 ? Path.GetFileName(made[0]) : "";
                string dir = made.Length == 1 ? Path.GetDirectoryName(made[0]) : "";
                int dash = name.IndexOf('-');
                bool parsed = dash == 16 && DateTime.TryParseExact(name[..14], "yyyyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out _);
                int filled = 0;
                if (parsed)
                {
                    DateTime t0 = DateTime.ParseExact(name[..14], "yyyyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture);
                    string tail = name[dash..];
                    for (int sec = 0; sec < 6; sec++)
                        for (int id = 0; id <= byte.MaxValue; id++)
                        {
                            string f = Path.Combine(dir, $"{t0.AddSeconds(sec):yyyyMMddHHmmss}{id:00}{tail}");
                            if (!File.Exists(f)) { File.WriteAllBytes(f, []); filled++; }
                        }
                }
                int before = Directory.GetFiles(CapsAlbumDir(), "*.jpg", SearchOption.AllDirectories).Length;
                Msg full = Msg.Cmif(203, Bytes(new byte[0x40], 0u, 0UL, 0UL)); full.SendPid = true; full.A.Add(((ulong)shot, (ulong)Shot));
                uint r1 = Call(capsu, full).Result;
                int after = Directory.GetFiles(CapsAlbumDir(), "*.jpg", SearchOption.AllDirectories).Length;
                Check("截图 相册同一秒序号用完：首张结果、认出文件名、占满后再存的结果、新写文件数",
                    "0、是、0x32CE、0", $"{r0}、{(parsed ? "是" : "否")}、0x{r1:X}、{after - before}");
                try { Directory.Delete(CapsAlbumDir(), true); } catch (DirectoryNotFoundException) { }
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }

        // 守卫兼诊断：同一调用连跑 50 次，两条判据逐次都成立，并打分布（最小 / 最大）
        [SoloTest("--caps-alloc-probe", Booted = true)]
        private static void CapsAllocProbe()
        {
            const int Shot = 1280 * 720 * 4, N = 50;
            // 截图服务要客户端进程的 ProgramId：登记一个合成应用（同 ArpApplicationTest）
            string root = Path.Combine(Path.GetTempPath(), $"s2a_caps_probe_{Environment.ProcessId}");
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "exefs"));
                Directory.CreateDirectory(Path.Combine(root, "ctl"));
                Directory.CreateDirectory(Path.Combine(root, "romfs"));
                File.Copy(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")), Path.Combine(root, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(root, "ctl", "control.nacp"), new byte[0x4000]);
                Host.Device.System.ServiceTable.WaitServicesReady();
                Application.Register(Host.Device, root);
                Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
                Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
                Reply gcs = Call(sm, Msg.Cmif(1, Name8("caps:su")));
                uint capsu = gcs.Move.Count == 1 ? gcs.Move[0] : 0;
                byte* shot = FakeNative.Alloc(Shot);
                for (int i = 0; i < Shot; i++) shot[i] = (byte)i;
                List<long> real = new(), svc = new();
                int bad = 0;
                for (int k = 0; k < N; k++)
                {
                    (long r, long s, uint r1, uint r2) = CapsSaveAlloc(capsu, shot, Shot);
                    real.Add(r); svc.Add(s);
                    if (r1 != 0 || r2 != 0) bad++;
                }
                Console.WriteLine($"caps 探针 {N} 次：真编码器 最小 {real.Min()} B 最大 {real.Max()} B（首次 {real[0]} B）；固定编码器 最小 {svc.Min()} B 最大 {svc.Max()} B");
                Check($"截图 SaveScreenShotEx0 连跑 {N} 次：结果非 0 次数、真编码器每次 < 截图大小、固定编码器每次服务路径 < 64 KB",
                    "0、是、是", $"{bad}、{(real.Max() < Shot ? "是" : "否")}、{(svc.Max() < 65536 ? "是" : "否")}");
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }
    }
}
