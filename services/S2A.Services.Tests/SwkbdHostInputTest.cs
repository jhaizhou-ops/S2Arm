// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // 系统键盘桥接（11-06，GRID 输入车手名 iOS 不弹键盘）：宿主有系统输入框（TextInput 原生导出，这里用 BeginHook / CancelHook 替身）时，
    //   软键盘小程序只发起、不等，玩家确定后才交回游戏；期望按 swkbd 协议手写（同 SwkbdForegroundHeadless / SwkbdInlineHeadless）：
    //   前台：① Start 返回时未交（事件未置 / PopOutData 0x480），宿主收到一次弹框（JSON 带模式 / 长短）；② 玩家没答前 1.5 秒仍未交（不自动应答）；
    //         ③ 玩家确定「12345」→ 按最长 3 截成「123」交回（结果 0）；④ 玩家取消 → 结果 1，文本按缺省「Ryujinx」截到最长 4「Ryuj」。
    //   内嵌：① Calc 0x15 当批照旧 0 2 1，宿主弹一次框；② 玩家没答时再来一次 Calc 不重复弹框、不交 DecidedEnter；
    //         ③ 玩家确定「李雷abc」→ 当即只到 ChangedString（Shown），隔约 150 毫秒才到 DecidedEnter「李雷ab」（最长 4）→ 回 Initialized
    //           （#279 怪物猎人 崛起：改字和确定同一批到，名字框留空、键盘又弹）；④ 键盘收起后游戏发 UnsetCustomizedDictionaries → 回专门回包 12@1（不是 Default 1@1）；
    //         ⑤ 再出现一次键盘后游戏 Finalize → 宿主收框（Cancel 收到同一 id），开框标记（输入泵据此静音手柄）落回 false。
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void SwkbdForegroundHostInput()
        {
            var begun = new List<(long Id, string Json)>();
            TextInput.BeginHook = (id, json) => { lock (begun) begun.Add((id, json)); return 1; };
            TextInput.CancelHook = _ => { };
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            byte* buf = FakeNative.Alloc(0x2000);
            var evs = new List<uint>();

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;
            string[] got = new string[2];
            string json = "";

            try
            {
                Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
                int proxy = OutObj(Domain(opx, root));
                int creator = OutObj(Domain(Msg.Cmif(11), proxy));

                // 一次独立键盘，玩家在 1.5 秒后答 ok / text
                string Run(KeyboardMode mode, int min, int max, bool ok, string text)
                {
                    int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x11, 0)), creator));

                    void Push(byte[] data)
                    {
                        int sto = OutObj(Domain(Msg.Cmif(10, Bytes((long)data.Length)), creator));
                        int acc = OutObj(Domain(Msg.Cmif(0), sto));
                        data.CopyTo(new Span<byte>(buf, data.Length));
                        Msg w = Msg.Cmif(10, Bytes(0UL)); w.A.Add(((ulong)buf, (ulong)data.Length));
                        Domain(w, acc);
                        Msg p = Msg.Cmif(100); p.InObjects.Add(sto);
                        Domain(p, accessor);
                    }

                    var cfg = new SoftwareKeyboardConfig { Mode = mode, StringLengthMin = min, StringLengthMax = max, SubmitText = "", HeaderText = "", SubtitleText = "", GuideText = "" };
                    byte[] cb = new byte[Marshal.SizeOf<SoftwareKeyboardConfig>()];
                    IntPtr ptr = Marshal.AllocHGlobal(cb.Length);
                    try { Marshal.StructureToPtr(cfg, ptr, false); Marshal.Copy(ptr, cb, 0, cb.Length); } finally { Marshal.FreeHGlobal(ptr); }
                    Push(Bytes(1u, 0x20u, 0u, 0u, 0UL, 0UL));
                    Push(cb);
                    Push(new byte[0x1000]);

                    Reply ev = Domain(Msg.Cmif(0), accessor);
                    uint evh = ev.Copy.Count == 1 ? ev.Copy[0] : 0;
                    evs.Add(evh);
                    bool Signaled() => evh != 0 && FakeNative.Events[FakeNative.CookieOf(evh)];

                    string Pop()
                    {
                        Reply pop = Domain(Msg.Cmif(101), accessor);
                        if (pop.Result != 0) return $"0x{pop.Result:X}";
                        int acc = OutObj(Domain(Msg.Cmif(0), OutObj(pop)));
                        long size = *(long*)Domain(Msg.Cmif(0), acc).Data;
                        new Span<byte>(buf, 0x2000).Clear();
                        Msg rd = Msg.Cmif(11, Bytes(0UL)); rd.B.Add(((ulong)buf, (ulong)Math.Min(size, 0x2000)));
                        Domain(rd, acc);
                        return $"结果 {*(uint*)buf}「{new string((char*)(buf + 4))}」";
                    }

                    int before;
                    lock (begun) before = begun.Count;
                    Domain(Msg.Cmif(10), accessor);   // Start
                    string now = $"{Signaled()} / {Pop()}";
                    Thread.Sleep(1500);
                    string waiting = $"{Signaled()} / {Pop()}";
                    (long id, string js) = begun[^1];
                    int pops; lock (begun) pops = begun.Count - before;
                    json = js;
                    TextInput.Answer(id, ok, text);
                    Thread.Sleep(1000);
                    return $"弹框 {pops} 次；刚返回 {now}；没答 {waiting}；答后 {Signaled()} / {Pop()}";
                }

                got[0] = Run(KeyboardMode.Numeric, 2, 3, true, "12345");
                string numericJson = json;
                got[1] = Run(KeyboardMode.Default, 0, 4, false, null);
                json = numericJson;
            }
            catch (InvalidOperationException e)
            {
                got[0] = got[1] = $"应答解析失败：{e.Message}";
            }
            finally
            {
                TextInput.BeginHook = null;
                TextInput.CancelHook = null;
                foreach (uint h in evs) if (h != 0) FakeNative.HandleClose(h);
                FakeNative.Free(buf);
                FakeNative.HandleClose(oe);
                FakeNative.HandleClose(sm);
            }

            Check("独立软键盘接系统输入框：只弹一次、玩家没答不自动交、确定后按最长 3 截断交回", "弹框 1 次；刚返回 False / 0x480；没答 False / 0x480；答后 True / 结果 0「123」", got[0]);
            Check("独立软键盘接系统输入框：玩家取消 → 结果 1", "弹框 1 次；刚返回 False / 0x480；没答 False / 0x480；答后 True / 结果 1「Ryuj」", got[1]);
            Check("交给宿主的弹框参数（数字模式、最短 2、最长 3）", true, json.Contains("\"mode\":\"numeric\"") && json.Contains("\"min\":2") && json.Contains("\"max\":3"));
        }

        [SvcCase]
        private static void SwkbdInlineHostInput()
        {
            var begun = new List<long>();
            var cancelled = new List<long>();
            TextInput.BeginHook = (id, _) => { lock (begun) begun.Add(id); return 1; };
            TextInput.CancelHook = id => { lock (cancelled) cancelled.Add(id); };
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            byte* buf = FakeNative.Alloc(0x2000);

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;
            string first, waiting, changed, answered, unset, finalize;

            try
            {
                Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
                int proxy = OutObj(Domain(opx, root));
                int creator = OutObj(Domain(Msg.Cmif(11), proxy));
                int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x11, 1)), creator));

                int Storage(byte[] data)
                {
                    int sto = OutObj(Domain(Msg.Cmif(10, Bytes((long)data.Length)), creator));
                    int acc = OutObj(Domain(Msg.Cmif(0), sto));
                    data.CopyTo(new Span<byte>(buf, data.Length));
                    Msg w = Msg.Cmif(10, Bytes(0UL)); w.A.Add(((ulong)buf, (ulong)data.Length));
                    Domain(w, acc);
                    return sto;
                }

                void Push(uint cmd, byte[] data) { Msg p = Msg.Cmif(cmd); p.InObjects.Add(Storage(data)); Domain(p, accessor); }

                string Drain()
                {
                    var got = new List<string>();
                    for (int i = 0; i < 16; i++)
                    {
                        Reply pop = Domain(Msg.Cmif(104), accessor);
                        if (pop.Result != 0) break;
                        int acc = OutObj(Domain(Msg.Cmif(0), OutObj(pop)));
                        long size = *(long*)Domain(Msg.Cmif(0), acc).Data;
                        new Span<byte>(buf, 0x2000).Clear();
                        Msg rd = Msg.Cmif(11, Bytes(0UL)); rd.B.Add(((ulong)buf, (ulong)Math.Min(size, 0x2000)));
                        Domain(rd, acc);
                        uint st = *(uint*)buf, type = *(uint*)(buf + 4);
                        string s = $"{type}@{st}";
                        if (type == 5)
                        {
                            int len = *(int*)(buf + 8 + 0x3EC);
                            s += "「" + new string((char*)(buf + 8), 0, Math.Clamp(len, 0, 0x3EC / 2)) + "」";
                        }
                        got.Add(s);
                    }
                    return got.Count == 0 ? "无" : string.Join(" ", got);
                }

                byte[] Calc(KeyboardCalcFlags flags)
                {
                    var calc = new SoftwareKeyboardCalc
                    {
                        Size = (ushort)Marshal.SizeOf<SoftwareKeyboardCalc>(),
                        Flags = flags,
                        Appear = new SoftwareKeyboardAppear { KeyboardMode = KeyboardMode.Default, TextMinLength = 1, TextMaxLength = 4, OkText = "" },
                        InputText = "",
                    };
                    byte[] cb = new byte[Marshal.SizeOf<SoftwareKeyboardCalc>()];
                    IntPtr p = Marshal.AllocHGlobal(cb.Length);
                    try { Marshal.StructureToPtr(calc, p, false); Marshal.Copy(p, cb, 0, cb.Length); } finally { Marshal.FreeHGlobal(p); }
                    return Bytes(0xAu, cb);
                }

                Push(100, Bytes(1u, 0x20u, 0u, 0u, 0UL, 0UL));
                Push(100, new byte[Marshal.SizeOf<SoftwareKeyboardInitialize>()]);
                Domain(Msg.Cmif(10), accessor);   // Start
                Push(103, Bytes(0xDu));            // UseChangedStringV2

                Push(103, Calc(KeyboardCalcFlags.Initialize | KeyboardCalcFlags.Appear | KeyboardCalcFlags.SetCursorPos));
                first = $"{Drain()}；弹框 {begun.Count}；开框 {TextInput.Open}";
                Thread.Sleep(1500);
                Push(103, Calc(KeyboardCalcFlags.SetCursorPos));   // 键盘开着时游戏照常每帧 Calc
                waiting = $"{Drain()}；弹框 {begun.Count}";
                TextInput.Answer(begun[0], true, "李雷abc");
                Thread.Sleep(30);
                changed = Drain();
                Thread.Sleep(1000);
                answered = $"{Drain()}；开框 {TextInput.Open}";
                Push(103, Bytes(0xCu));            // UnsetCustomizedDictionaries
                unset = Drain();

                Push(103, Calc(KeyboardCalcFlags.Appear | KeyboardCalcFlags.SetCursorPos));   // 再出现一次
                Drain();
                long second; lock (begun) second = begun.Count == 2 ? begun[1] : -1;
                Push(103, Bytes(0x4u));            // Finalize
                Thread.Sleep(200);
                bool cancelledSecond; lock (cancelled) cancelledSecond = cancelled.Contains(second);
                finalize = $"弹框 {begun.Count}；收框 {cancelledSecond}；开框 {TextInput.Open}";
            }
            catch (InvalidOperationException e)
            {
                first = waiting = changed = answered = unset = finalize = $"应答解析失败：{e.Message}";
            }
            finally
            {
                TextInput.BeginHook = null;
                TextInput.CancelHook = null;
                FakeNative.Free(buf);
                FakeNative.HandleClose(oe);
                FakeNative.HandleClose(sm);
            }

            Check("内嵌键盘接系统输入框：出现当批照旧、弹框一次、开框标记置上", "0@0 2@3 1@3；弹框 1；开框 True", first);
            Check("内嵌键盘接系统输入框：玩家没答时再来 Calc 只回 Default、不重复弹框", "1@3；弹框 1", waiting);
            Check("内嵌键盘接系统输入框：确定「李雷abc」当即只报改字（确定不同批）", "2@3", changed);
            Check("内嵌键盘接系统输入框：改字之后再按最长 4 交回确定、回 Initialized、开框标记落下", "5@4「李雷ab」 1@4 1@1；开框 False", answered);
            Check("内嵌键盘收起后 UnsetCustomizedDictionaries 回专门回包", "12@1", unset);
            Check("内嵌键盘再出现后游戏 Finalize：宿主收框", "弹框 2；收框 True；开框 False", finalize);
        }
    }
}
