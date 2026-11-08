using System;

namespace S2A.Services.Tests
{
    // 错误小程序（10-28 双人成行点建房闪退）：游戏按 Switch 流程在 appletOE 域会话里拉起 Error 小程序（nn::err::ShowError）。
    //   期望按 am / 域协议与小程序语义手写：Start 不抛、按「显示 → 玩家确定 → 回游戏」回成功并触发状态事件、GetResult 成功、不报红；
    //   域会话里的错误应答（未实现命令 / 参数异常）要是合法域应答（域出头 + SFCO + 结果），否则游戏 SF 客户端判 InvalidCmifOutHeader 后断言终止整局。
    //   修前：Start 在没有系统固件时抛 ArgumentNullException（LocalStorage(null)），且错误应答缺域出头 → 这里 ParseDomain 找不到 SFCO
    public static unsafe partial class Program
    {
        private static void ErrorAppletInDomain(uint sm)
        {
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;   // 无数据的应答：出对象号紧跟 SFCO 头

            Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
            int proxy = OutObj(Domain(opx, root));                          // OpenApplicationProxy
            int creator = OutObj(Domain(Msg.Cmif(11), proxy));              // GetLibraryAppletCreator
            int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x0E, 0)), creator));   // CreateLibraryApplet(Error, mode 0)

            // 两段入参同 SDK：公共参数 0x20 字节（版本 1、结构长 0x20）；错误头 8 字节（类型 ErrorCommonArg、MessageFlag 0 = 按结果码查文案）+ ErrorCommonArg 12 字节
            uint ldnResult = (16u << 9) | 203u;   // 模块 203（ldn）描述 16 → 标题「Error Code: 2203-0016」

            uint PushStorage(byte[] data)
            {
                int sto = OutObj(Domain(Msg.Cmif(10, Bytes((long)data.Length)), creator));   // CreateStorage
                int acc = OutObj(Domain(Msg.Cmif(0), sto));                                   // IStorage.Open
                byte* buf = _game + 0x5000;
                data.CopyTo(new Span<byte>(buf, data.Length));
                Msg w = Msg.Cmif(10, Bytes(0UL)); w.A.Add(((ulong)buf, (ulong)data.Length));   // IStorageAccessor.Write(offset 0)
                Domain(w, acc);
                Msg push = Msg.Cmif(100); push.InObjects.Add(sto);                            // PushInData(object<IStorage>)
                return Domain(push, accessor).Result;
            }

            uint p1 = PushStorage(Bytes(1u, 0x20u, 0u, 0u, 0UL, 0UL));
            uint p2 = PushStorage(Bytes(new byte[8], 0u, 0u, ldnResult));

            Reply ev = Domain(Msg.Cmif(0), accessor);   // GetAppletStateChangedEvent
            uint evh = ev.Copy.Count == 1 ? ev.Copy[0] : 0;
            bool before = evh != 0 && FakeNative.Events[FakeNative.CookieOf(evh)];

            long red0 = Red.Total;
            string start;

            try
            {
                Reply st = Domain(Msg.Cmif(10), accessor);   // Start
                bool signaled = evh != 0 && FakeNative.Events[FakeNative.CookieOf(evh)];
                Reply gr = Domain(Msg.Cmif(30), accessor);   // GetResult
                start = $"Start 0x{st.Result:X}、事件 {before}→{signaled}、GetResult 0x{gr.Result:X}、报红 +{Red.Total - red0}";
            }
            catch (InvalidOperationException e)
            {
                start = $"应答解析失败：{e.Message}、报红 +{Red.Total - red0}";
            }

            Check("错误小程序（域内 ILibraryAppletAccessor.Start，无系统固件）：入参推送 / 不抛、回成功、状态事件触发、GetResult 成功、不报红",
                "入参 0x0 / 0x0；Start 0x0、事件 False→True、GetResult 0x0、报红 +0", $"入参 0x{p1:X} / 0x{p2:X}；{start}");

            // 域会话里的未实现命令：应答仍是合法域应答（出对象 0、SFCO、未知命令结果），一行红，会话继续可用
            red0 = Red.Total;
            string unknown;

            try
            {
                Reply ur = Domain(Msg.Cmif(9999), proxy);
                Reply again = Domain(Msg.Cmif(0), accessor);   // 同一会话再取一次状态事件：会话没被带走
                unknown = $"结果 0x{ur.Result:X}、出对象 {ur.DomainOutCount}、报红 +{Red.Total - red0}、会话继续 0x{again.Result:X}";
            }
            catch (InvalidOperationException e)
            {
                unknown = $"应答解析失败：{e.Message}、报红 +{Red.Total - red0}";
            }

            Check("域会话里的未实现命令（IApplicationProxy 命令 9999）：合法域应答、回未知命令、一行红、会话继续",
                $"结果 0x{Red.ResultUnknownCommand:X}、出对象 0、报红 +1、会话继续 0x0", unknown);

            if (evh != 0)
            {
                FakeNative.HandleClose(evh);
            }

            FakeNative.HandleClose(oe);
        }
    }
}
