// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using MsgPack;
using Ryujinx.Horizon;
using Ryujinx.Horizon.Prepo.Types;
using S2A.Services;
using System;
using System.IO;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // prepo:u 10500（Switch 2 nn::prepo::PlayReport::Send(Uid)，时之笛 0400486024DEC000 玩法转场发）+ 回出的 IAsyncContext 0 / 1 / 2。
    //   线上格式取自时之笛 sdk（代理 0x5aba60、发送助手 0x5ac640）：域消息、类型 6、pid、X = 事件名（含 NUL）、复制句柄 1 个 = 报告缓冲的传输内存（建时权限「无」）、
    //   数据 u8 同意检查 @0、u32 传输内存长 @4、u32 报告长 @8、Uid @0x10、u64 pid 占位 @0x20；IAsyncContext 命令表取自 sdk 代理 vtable 0xe72478（0 取事件 / 1 Cancel / 2 GetResult）。
    //   期望不跑被测实现：报告是手写的 MessagePack {"a": 1}，订阅者收到的事件名 / Uid / 内容按请求手算；离线不上传 → 异步上下文已完成（事件亮）、结果 0；
    //   Uid 全零照存报告带用户（10107）回 prepo InvalidArgument (1<<9)|129；报告长超传输内存（sdk 不会这样发）报红回未知命令
    public static unsafe partial class Program
    {
        [SoloTest("--prepo-send", Booted = true)]
        private static void PrepoSend()
        {
            // 收报告要经 arp 按 pid 查应用实例（同真机）：先照 ArpApplicationTest 的夹具登记一个应用（Homebrew.npdm + 空 NACP）
            string root = Path.Combine(Path.GetTempPath(), $"s2a_prepo_send_{Environment.ProcessId}");

            try
            {
                Directory.CreateDirectory(Path.Combine(root, "exefs"));
                Directory.CreateDirectory(Path.Combine(root, "ctl"));
                Directory.CreateDirectory(Path.Combine(root, "romfs"));
                File.Copy(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")), Path.Combine(root, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(root, "ctl", "control.nacp"), new byte[0x4000]);
                Host.Device.System.ServiceTable.WaitServicesReady();
                Application.Register(Host.Device, root);
                PrepoSendCases();
            }
            finally
            {
                try { Directory.Delete(root, true); } catch { }
            }
        }

        private static void PrepoSendCases()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            Reply gp = Call(sm, Msg.Cmif(1, Name8("prepo:u")));
            uint prepo = gp.Move.Count == 1 ? gp.Move[0] : 0;
            Msg cv = Msg.Cmif(0); cv.Type = 5;
            int root = *(int*)Call(prepo, cv).Data;

            const uint Unknown = (221u << 9) | 10u;
            const uint InvalidArgument = (1u << 9) | 129u;
            const uint TmemSize = 0x4000;
            const ulong UidHigh = 0x0123456789ABCDEF, UidLow = 0x1122334455667788;

            byte* eventId = FakeNative.Alloc(0x20);
            byte[] name = Encoding.ASCII.GetBytes("s2a_send\0");
            name.CopyTo(new Span<byte>(eventId, name.Length));
            byte* report = FakeNative.Alloc((int)TmemSize);
            new Span<byte>(report, (int)TmemSize).Fill(0xCC);
            report[0] = 0x81; report[1] = 0xA1; report[2] = (byte)'a'; report[3] = 0x01;   // MessagePack {"a": 1}

            Reply Domain(Msg m, int obj)
            {
                m.Type = 6;
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(prepo));
                // 同 AudSmxTest：成功走域格式；报红的命令回不带域头的错误应答，按非域格式解。
                //   出对象号按 sdk 客户端读法取数据区 +0（发送助手 0x5ac824：SFCO 头后 +0x10），域出头的个数字段客户端不读、这里也不判
                try { return Reply.ParseDomain(_tlr); } catch (InvalidOperationException) { return Reply.Parse(_tlr); }
            }

            Reply Send(uint reportSize, ulong high, ulong low)
            {
                Msg m = Msg.Cmif(10500, Bytes(new byte[] { 1, 0, 0, 0 }, TmemSize, reportSize, 0u, high, low, 0UL));
                m.SendPid = true;
                m.X.Add(((ulong)eventId, (ulong)name.Length));
                m.Copy.Add(FakeNative.TmemCreate((ulong)report, TmemSize, 0));   // sdk 建传输内存时权限「无」
                return Domain(m, root);
            }

            // ---- 正路：时之笛同款请求 ----
            PlayReport got = default;
            int hits = 0;
            void OnReport(PlayReport r) { got = r; Interlocked.Increment(ref hits); }
            HorizonStatic.PlayReport += OnReport;
            long red0 = Red.Total;
            Reply sr = Send(4, UidHigh, UidLow);
            WaitFor(() => Volatile.Read(ref hits) > 0, 2000);
            HorizonStatic.PlayReport -= OnReport;
            int ctx = sr.Result == 0 ? *(int*)sr.Data : 0;
            Check("prepo:u 10500 Send（时之笛同款）：结果 0、回出对象（号 ≠ 0）、不报红", "0x0、≠ 0、红 +0", $"0x{sr.Result:X}、{(ctx != 0 ? "≠ 0" : "0")}、红 +{Red.Total - red0}");

            string data = hits == 1 && got.ReportData.IsDictionary && got.ReportData.AsDictionary().TryGetValue("a", out MessagePackObject a) ? $"a={a.AsInt32()}、共 {got.ReportData.AsDictionary().Count} 项" : "无";
            Check("prepo:u 10500：报告从传输内存收下（订阅者收到 1 份、事件名 / Uid / 内容按请求手算）",
                $"1、s2a_send、{UidHigh:X16}/{UidLow:X16}、a=1、共 1 项",
                $"{hits}、{got.Room?.TrimEnd('\0')}、{got.UserId?.High:X16}/{got.UserId?.Low:X16}、{data}");

            if (ctx == 0)
            {
                return;   // 没拿到异步对象：后面各行无从测，本行已记失败
            }

            red0 = Red.Total;
            Reply ev = Domain(Msg.Cmif(0), ctx);
            uint evh = ev.Copy.Count == 1 ? ev.Copy[0] : 0;
            bool signaled = evh != 0 && FakeNative.Events[FakeNative.CookieOf(evh)];
            Check("IAsyncContext 0 取完成事件：结果 0、复制句柄 1 个、事件已亮（sdk 等它后取结果）", "0x0、1、亮", $"0x{ev.Result:X}、{ev.Copy.Count}、{(signaled ? "亮" : "灭")}");
            uint gr = Domain(Msg.Cmif(2), ctx).Result;
            uint cc = Domain(Msg.Cmif(1), ctx).Result;
            uint gr2 = Domain(Msg.Cmif(2), ctx).Result;
            Check("IAsyncContext 2 GetResult / 1 Cancel / Cancel 后 2：离线不上传，照收下算成功；全程不报红", "0x0 / 0x0 / 0x0、红 +0",
                $"0x{gr:X} / 0x{cc:X} / 0x{gr2:X}、红 +{Red.Total - red0}");

            // ---- 真机语义的失败：Uid 全零（同存报告带用户 10107）----
            red0 = Red.Total;
            Reply nu = Send(4, 0, 0);
            Check("prepo:u 10500 Uid 全零：回 prepo InvalidArgument、不报红", $"0x{InvalidArgument:X}、红 +0", $"0x{nu.Result:X}、红 +{Red.Total - red0}");

            // ---- 推不出的分支：报红 + 未知命令 ----
            red0 = Red.Total;
            Reply big = Send(TmemSize + 1, UidHigh, UidLow);
            Check("prepo:u 10500 报告长超传输内存（sdk 不会这样发）：报红回未知命令", $"0x{Unknown:X}、红 +1", $"0x{big.Result:X}、红 +{Red.Total - red0}");
        }
    }
}
