using Ryujinx.Graphics.GAL;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger;
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 族 17（缺口扫描 11-01）：会把局打崩的未实现改回失败码、照旧报红。期望按 nvmap 旧号 / Android binder 语义手写：
    //   ① nvdrv：nvhost-ctrl 上设备 switch 里没有的 ioctl 号 0xFF → IPC 结果 0、NvResult NotSupported（2）、报红 +1。
    //      旧代码抛 NvIoctlNotImplementedException（不在 HleTarget 接住的几类里）穿出 HLE 边界，本模式进程异常退出 → 红
    //   ② nvnflinger：IGraphicBufferProducer 未知事务号 99 → 不抛、应答首个 int32 = UNKNOWN_TRANSACTION（-74）、报红 +1；旧代码抛 NotImplementedException
    //   ③ 像素格式：R8（合成路径没有的格式）转换失败、不抛；已知 A8B8G8R8 → R8G8B8A8Unorm（旧代码只有抛异常的 ConvertColorFormat，编不过 → 红）
    public static unsafe partial class Program
    {
        [SoloTest("--unimpl-fail", Booted = true)]
        private static void UnimplementedFail()
        {
            // ① 起 nvdrv 会话、打开 nvhost-ctrl（同 Run() 里的序列）
            byte* port = _game;
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(port, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)port).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            Reply gs = Call(sm, Msg.Cmif(1, Name8("nvdrv")));
            uint nv = gs.Move.Count == 1 ? gs.Move[0] : 0;
            uint tmem = FakeNative.TmemCreate((ulong)(_game + 0x8000), 0x4000, 3);
            Msg ni = Msg.Cmif(3, Bytes((long)0x4000));
            ni.Copy.Add(0xFFFF8001);
            ni.Copy.Add(tmem);
            Call(nv, ni);
            byte* path = _game + 0x100;
            byte[] ctrl = Encoding.ASCII.GetBytes("/dev/nvhost-ctrl");
            ctrl.CopyTo(new Span<byte>(path, ctrl.Length));
            Msg op = Msg.Cmif(0);
            op.A.Add(((ulong)path, (ulong)ctrl.Length));
            int fd = *(int*)Call(nv, op).Data;

            byte* io = _game + 0x200;
            *(ulong*)io = 0;
            long red0 = Red.Total;
            Msg ioc = Msg.Cmif(1, Bytes(fd, 0xC00800FFu));   // _IOWR(0, 0xFF, 8)：nvhost-ctrl 没有的号
            ioc.A.Add(((ulong)io, 8));
            ioc.B.Add(((ulong)io, 8));
            Reply ior = Call(nv, ioc);
            Check("族 17 ① nvdrv 未实现 ioctl（nvhost-ctrl 号 0xFF）", "结果 0、NvResult 2、报红 +1", $"结果 {ior.Result}、NvResult {*(uint*)ior.Data}、报红 +{Red.Total - red0}");

            // ④ 审计 #1534 P1-62：没有实现事件查询的设备（nvmap 不覆盖 QueryEvent）上调 QueryEvent(4) → 与未实现 ioctl 同一条路：
            //   IPC 结果 0、NvResult NotSupported（2）、不发句柄、报红 +1。旧代码抛 NvQueryEventNotImplementedException 穿出 HLE 边界，本模式进程异常退出 → 红
            byte[] nvmap = Encoding.ASCII.GetBytes("/dev/nvmap");
            nvmap.CopyTo(new Span<byte>(path, nvmap.Length));
            Msg opm = Msg.Cmif(0);
            opm.A.Add(((ulong)path, (ulong)nvmap.Length));
            int fdMap = *(int*)Call(nv, opm).Data;
            red0 = Red.Total;
            Reply qe = Call(nv, Msg.Cmif(4, Bytes(fdMap, 1u)));
            Check("P1-62 ④ nvmap 上 QueryEvent（事件 1，设备未实现）", "结果 0、NvResult 2、句柄 0、报红 +1", $"结果 {qe.Result}、NvResult {*(uint*)qe.Data}、句柄 {qe.Copy.Count}、报红 +{Red.Total - red0}");

            // ② 未知事务号
            BufferQueue.CreateBufferQueue(Dispatcher.Instance.Device, 0, out BufferQueueProducer producer, out _);
            red0 = Red.Total;
            string got;
            try
            {
                using Parcel input = new(0x10, 0);
                using Parcel output = new(0x40, 0);
                producer.OnTransact(99, 0, input, output);
                got = $"状态 {new Parcel(output.Finish()).ReadInt32()}、报红 +{Red.Total - red0}";
            }
            catch (Exception e)
            {
                got = $"抛 {e.GetType().Name}";
            }
            Check("族 17 ② nvnflinger 未知事务号 99", "状态 -74、报红 +1", got);

            // ③ 像素格式
            bool bad = SurfaceFlinger.TryConvertColorFormat(ColorFormat.R8, out _);
            bool good = SurfaceFlinger.TryConvertColorFormat(ColorFormat.A8B8G8R8, out Format f);
            Check("族 17 ③ 像素格式 R8 / A8B8G8R8", "失败 / 成功 R8G8B8A8Unorm", $"{(bad ? "成功" : "失败")} / {(good ? "成功" : "失败")} {f}");
        }
    }
}
