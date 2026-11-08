using System;
using System.Text;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void DomainRegressionTest()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint hid = Call(sm, Msg.Cmif(1, Name8("hid"))).Move[0];
            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            try
            {
                HidInvalidParameters(hid);
                ErrorAppletInDomain(sm);
            }
            finally
            {
                InputPump.Stop();
                FakeNative.HandleClose(hid);
                FakeNative.HandleClose(sm);
            }
        }

        private static void HidInvalidParameters(uint hid)
        {
            // ---- HID 命令参数出错降级（#58 真机闪退调查副产物；补丁 0254 + HleTarget 兜底）----
            //   ① 越界手柄号取样式变更事件不抛异常：数组 MaxControllers = 9，Unknown = 9 / Auto = 10 / 乱值原先在这里 IndexOutOfRangeException
            //   ② 命令内参数异常（AcceptRumble 挂点抛）降级成一行红 + 未知命令，会话继续；修前异常穿出 HLE 边界终止整局
            {
                var npads = Host.Device.Hid.Npads;
                Ryujinx.HLE.HOS.Kernel.Threading.KEvent handheld = npads.GetStyleSetUpdateEvent(Ryujinx.HLE.HOS.Services.Hid.PlayerIndex.Handheld);
                string clamped;

                try
                {
                    clamped = string.Join(" / ", new[]
                    {
                        ReferenceEquals(handheld, npads.GetStyleSetUpdateEvent(Ryujinx.HLE.HOS.Services.Hid.PlayerIndex.Unknown)),
                        ReferenceEquals(handheld, npads.GetStyleSetUpdateEvent((Ryujinx.HLE.HOS.Services.Hid.PlayerIndex)10)),
                        ReferenceEquals(handheld, npads.GetStyleSetUpdateEvent((Ryujinx.HLE.HOS.Services.Hid.PlayerIndex)99)),
                    });
                }
                catch (Exception ex)
                {
                    clamped = ex.GetType().Name;
                }

                Check("hid 样式变更事件：手柄号 Unknown(9) / Auto(10) / 99 越界不抛、取到掌机号的事件", "True / True / True", clamped);

                var dvg = (Ryujinx.HLE.HOS.Services.Hid.VibrationDeviceHandle*)(_game + 0x3C00);
                var dvv = (Ryujinx.HLE.HOS.Services.Hid.VibrationValue*)(_game + 0x3C40);
                dvg[0] = new() { DeviceType = 3, PlayerId = 0, Position = 0 };
                dvv[0] = default;
                Msg dv = Msg.Cmif(206, Bytes(0L));
                dv.X.Add(((ulong)dvg, 4));
                dv.X.Add(((ulong)dvv, 16));
                long r0 = Red.Total;
                Action<Ryujinx.HLE.HOS.Services.Hid.PlayerIndex, Ryujinx.HLE.HOS.Services.Hid.VibrationValue, Ryujinx.HLE.HOS.Services.Hid.VibrationValue> keep = npads.RumbleAccepted;
                npads.RumbleAccepted = (_, _, _) => throw new ArgumentOutOfRangeException("测试：震动接受回调抛参数异常");
                string degraded;

                try
                {
                    Reply dr = Call(hid, dv);
                    npads.RumbleAccepted = keep;           // 还原回调后再发同一条命令：同一条会话照常应答（异常没带走整局，也没留下坏状态）
                    Reply dn = Call(hid, dv);
                    degraded = $"结果 0x{dr.Result:X}、报红 +{Red.Total - r0}、汇总{(Red.Summary().Contains("服务命令参数异常") ? "含" : "不含")}服务命令参数异常、会话继续 0x{dn.Result:X}";
                }
                catch (Exception ex)
                {
                    degraded = $"{ex.GetType().Name}：{ex.Message}";
                }
                finally
                {
                    npads.RumbleAccepted = keep;
                }

                Check("hid 命令内参数异常（AcceptRumble 挂点抛 ArgumentOutOfRangeException）降级：回未知命令、一行红、会话继续",
                    $"结果 0x{Red.ResultUnknownCommand:X}、报红 +1、汇总含服务命令参数异常、会话继续 0x0", degraded);
            }

        }
    }
}
