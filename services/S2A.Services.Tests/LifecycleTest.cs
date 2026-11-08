using System;

namespace S2A.Services.Tests
{
    // 前后台 / 焦点 / 底座 / 睡眠（缺口扫描族 1 / 2，11-01 体验线）：走真实 IPC 看游戏收到什么。期望按 am / psc 语义手写：
    //   ① 游戏 SetOutOfFocusSuspendingEnabled(false) → 原生层收到 0（平台壳据此不冻结）
    //   ② 平台壳报失焦 → 游戏 ReceiveMessage 读到 FocusStateChanged(15)、GetCurrentFocusState = OutOfFocus(2)；回前台 → 15 + ChangeIntoForeground(1)、InFocus(1)
    //   ③ 平台壳切主机 → OperationModeChanged(30) + PerformanceModeChanged(31)；游戏先关了操作模式通知 → 只有 31
    //   ④ psc:m 模块初始化后 GetRequest = FullAwake(0)；平台壳报睡眠 → 事件点亮、GetRequest = SleepReady(2)；Acknowledge 后回 FullAwake
    //   ⑤⑥⑦ 焦点处理模式（P2-37）：第一个标志关通知、第三个标志与失焦暂停合成 am 的三种模式（参照 libnx appletSetFocusHandlingMode 与 yuzu 系 LifecycleManager）
    //   ⑧ psc 确认看状态（P2-38）：状态与队首不符失败且不出队，没初始化回 NotInitialized；
//      队列空时（审计 #1534 P1-76）GetRequest 读到 FullAwake，确认它（Acknowledge / AcknowledgeEx(0)）成功不出队，确认别的状态仍失败——读到什么就能确认什么
    //   修前：①③ 开关读完即弃、②③ 没有调用方游戏什么都收不到、④ psc 没有命令（未知命令）
    public static unsafe partial class Program
    {
        static int _lcFocus = 1, _lcMode = -1, _lcSleep, _lcSuspendSeen = -1;
        static int LcFocus() => _lcFocus;
        static int LcMode() => _lcMode;
        static int LcSleep() => _lcSleep;
        static void LcSuspend(int on) => _lcSuspendSeen = on;

        private static void LifecycleMessages(uint sm)
        {
            Native.HostFocused = &LcFocus; Native.ConsoleMode = &LcMode; Native.HostSleeping = &LcSleep; Native.FocusSuspendSet = &LcSuspend;
            Lifecycle.Attach();
            var system = Host.Device.System;

            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            Reply Domain(Msg m, int obj) { m.DomainObject = obj; m.Write(_tlr); Svc(0x21, FakeNative.CookieOf(oe)); return Reply.ParseDomain(_tlr); }
            int OutObj(Reply r) => *(int*)r.Data;
            Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
            int proxy = OutObj(Domain(opx, root));                 // OpenApplicationProxy
            int common = OutObj(Domain(Msg.Cmif(0), proxy));       // GetCommonStateGetter
            int self = OutObj(Domain(Msg.Cmif(1), proxy));         // GetSelfController
            string Drain()
            {
                var got = new System.Collections.Generic.List<uint>();
                for (int i = 0; i < 16; i++) { Reply r = Domain(Msg.Cmif(1), common); if (r.Result != 0) break; got.Add(*(uint*)r.Data); }   // ReceiveMessage
                return string.Join(",", got);
            }
            byte Focus() => *Domain(Msg.Cmif(9), common).Data;      // GetCurrentFocusState
            Drain();   // 起局时的 InFocus + ChangeIntoForeground

            Domain(Msg.Cmif(16, Bytes((byte)0)), self);            // SetOutOfFocusSuspendingEnabled(false)
            Check("① 游戏关失焦暂停 → 原生层收到", "0", $"{_lcSuspendSeen}");

            _lcFocus = 0; Lifecycle.Tick(system);
            Check("② 失焦 → 消息 / 焦点状态", "15 / 2", $"{Drain()} / {Focus()}");
            _lcFocus = 1; Lifecycle.Tick(system);
            Check("② 回前台 → 消息 / 焦点状态", "15,1 / 1", $"{Drain()} / {Focus()}");

            // P2-37 焦点处理模式按 am 语义生效（libnx appletSetFocusHandlingMode 的四种组合，SetFocusHandlingMode 后跟 SetOutOfFocusSuspendingEnabled）：
            //   ⑤ SuspendHomeSleep = (0,0,1) + 失焦暂停 0：不冻结、失焦焦点状态照变，但第一个标志（通知）关 → 没有焦点消息
            Domain(Msg.Cmif(13, Bytes(new byte[] { 0, 0, 1 })), self);
            Domain(Msg.Cmif(16, Bytes((byte)0)), self);
            Check("⑤ SuspendHomeSleep → 原生层失焦暂停", "0", $"{_lcSuspendSeen}");
            _lcFocus = 0; Lifecycle.Tick(system);
            Check("⑤ 通知关时失焦 → 消息 / 焦点状态", " / 2", $"{Drain()} / {Focus()}");
            _lcFocus = 1; Lifecycle.Tick(system);
            Check("⑤ 通知关时回前台 → 消息 / 焦点状态", " / 1", $"{Drain()} / {Focus()}");
            //   ⑥ AlwaysSuspend = (0,0,1) + 失焦暂停 1：平台壳冻结客机，游戏「从不知道自己失焦」→ 焦点状态不变、没有消息
            Domain(Msg.Cmif(13, Bytes(new byte[] { 0, 0, 1 })), self);
            Domain(Msg.Cmif(16, Bytes(new byte[] { 1 })), self);
            Check("⑥ AlwaysSuspend → 原生层失焦暂停", "1", $"{_lcSuspendSeen}");
            _lcFocus = 0; Lifecycle.Tick(system);
            Check("⑥ 失焦 → 消息 / 焦点状态", " / 1", $"{Drain()} / {Focus()}");
            _lcFocus = 1; Lifecycle.Tick(system);
            Check("⑥ 回前台 → 消息 / 焦点状态", " / 1", $"{Drain()} / {Focus()}");
            //   ⑦ 先开失焦暂停、再 SetFocusHandlingMode 第三个标志（暂停）= 0（libnx NoSuspend = (1,1,0)）→ 不暂停，原生层收到 0；通知开 → 失焦有消息
            Domain(Msg.Cmif(16, Bytes(new byte[] { 1 })), self);
            Domain(Msg.Cmif(13, Bytes(new byte[] { 1, 1, 0 })), self);
            Check("⑦ 暂停标志 0 覆盖先前的失焦暂停 → 原生层", "0", $"{_lcSuspendSeen}");
            _lcFocus = 0; Lifecycle.Tick(system);
            Check("⑦ NoSuspend 失焦 → 消息 / 焦点状态", "15 / 2", $"{Drain()} / {Focus()}");
            _lcFocus = 1; Lifecycle.Tick(system);
            Check("⑦ NoSuspend 回前台 → 消息 / 焦点状态", "15,1 / 1", $"{Drain()} / {Focus()}");

            _lcMode = 1; Lifecycle.Tick(system);
            Check("③ 切主机 → 消息", "30,31", Drain());
            Domain(Msg.Cmif(11, Bytes((byte)0)), self);            // SetOperationModeChangedNotification(false)
            _lcMode = 0; Lifecycle.Tick(system);
            Check("③ 游戏关了操作模式通知后切掌机 → 消息", "31", Drain());

            Reply pm = Call(sm, Msg.Cmif(1, Name8("psc:m")));
            uint pms = pm.Move.Count == 1 ? pm.Move[0] : 0;
            Reply gm = Call(pms, Msg.Cmif(0));                      // GetPmModule
            uint mod = gm.Move.Count == 1 ? gm.Move[0] : 0;
            Msg init = Msg.Cmif(0, Bytes(0x3Bu)); init.A.Add(((ulong)(_game + 0x6000), 0UL));   // Initialize(模块号, 依赖表空)
            Reply ir = Call(mod, init);
            uint ev = ir.Copy.Count == 1 ? ir.Copy[0] : 0;
            uint Req() { Reply r = Call(mod, Msg.Cmif(1)); return r.Result == 0 ? *(uint*)r.Data : 0xFFFFFFFF; }   // GetRequest
            Check("④ psc 初始化 → 结果 / 事件 / 请求", "0 / 有 / 0", $"{ir.Result} / {(ev != 0 ? "有" : "无")} / {Req()}");
            _lcSleep = 1; Lifecycle.Tick(system);
            bool lit = ev != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(ev), out bool on) && on;
            Check("④ 睡眠 → 事件点亮 / 请求", "亮 / 2", $"{(lit ? "亮" : "暗")} / {Req()}");
            Call(mod, Msg.Cmif(2));                                  // Acknowledge
            Check("④ 确认后 → 请求", "0", $"{Req()}");
            _lcSleep = 0; Lifecycle.Tick(system); Call(mod, Msg.Cmif(2));

            // P2-38 psc 确认按状态：确认的必须是队首请求（AcknowledgeEx 带状态），状态不符回失败、不出队；没初始化回 psc NotInitialized(0x68A)
            // P1-76：队列空时 GetRequest 回 FullAwake 且成功，确认这个读到的状态必须成功（不出队、不点亮），确认别的状态仍失败
            Check("⑧ 队列空时 Acknowledge → 结果 / 请求", "0 / 0", $"{Call(mod, Msg.Cmif(2)).Result} / {Req()}");
            Check("⑧ 队列空时 AcknowledgeEx(读到的 FullAwake 0) → 结果", "0", $"{Call(mod, Msg.Cmif(4, Bytes(0u))).Result}");
            Check("⑧ 队列空时 AcknowledgeEx(SleepReady 2) → 失败", "失败", Call(mod, Msg.Cmif(4, Bytes(2u))).Result != 0 ? "失败" : "成功");
            _lcSleep = 1; Lifecycle.Tick(system);
            Check("⑧ 确认错的状态 → 失败 / 请求不出队", "失败 / 2", $"{(Call(mod, Msg.Cmif(4, Bytes(0u))).Result != 0 ? "失败" : "成功")} / {Req()}");
            Check("⑧ 确认队首状态 → 结果 / 请求", "0 / 0", $"{Call(mod, Msg.Cmif(4, Bytes(2u))).Result} / {Req()}");
            Check("⑧ 已确认完再 AcknowledgeEx(0) → 结果 / 请求", "0 / 0", $"{Call(mod, Msg.Cmif(4, Bytes(0u))).Result} / {Req()}");
            _lcSleep = 0; Lifecycle.Tick(system); Call(mod, Msg.Cmif(4, Bytes(0u)));
            Reply gm2 = Call(pms, Msg.Cmif(0));
            uint mod2 = gm2.Move.Count == 1 ? gm2.Move[0] : 0;
            Check("⑧ 没初始化就 AcknowledgeEx → 结果", "0x68A", $"0x{Call(mod2, Msg.Cmif(4, Bytes(0u))).Result:X}");

            Native.HostFocused = null; Native.ConsoleMode = null; Native.HostSleeping = null; Native.FocusSuspendSet = null;
            Lifecycle.Attach();
        }
    }
}
