// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // 独立软键盘小程序无界面自动应答（族「软键盘应答不合游戏要求」，11-04）：游戏 CreateLibraryApplet(0x11) → 推公共参数 + SoftwareKeyboardConfig + 工作缓冲 →
    //   Start → 等状态事件 → PopOutData 读「结果 u32 + UTF-16 文本」。真机上玩家输入总在键盘显示之后，Start 返回时还没有结果。
    //   期望按 am / swkbd 规范与宿主规则（无初值：数字框交「0」、其余交「Player」）手写：
    //   ① Start 刚返回：状态事件未触发、PopOutData 回 NotAvailable；② 半秒后：事件触发、读到结果 0（确定）+ 文本；
    //   ③ 数字框最短 2 / 最长 3 → 「00」（不是上游的「0 0」，也不是不够长的「0」）；④ 普通框最长 4 → 「Play」。
    //   修前：① 就已触发、已有结果（Start 里同步交），③ 交「0 0」
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void SwkbdForegroundHeadless()
        {
            TextInput.BeginHook = (_, _) => 0;   // 平台没登记系统输入框（同安卓 / 开发宿主 / 无人值守）：走自动应答（单测进程没有原生库）
            try { SwkbdForegroundHeadlessBody(); } finally { TextInput.BeginHook = null; }
        }

        private static void SwkbdForegroundHeadlessBody()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;
            byte* buf = FakeNative.Alloc(0x2000);
            var evs = new System.Collections.Generic.List<uint>();

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;
            string[] got = new string[2];

            try
            {
                Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
                int proxy = OutObj(Domain(opx, root));                                  // OpenApplicationProxy
                int creator = OutObj(Domain(Msg.Cmif(11), proxy));                      // GetLibraryAppletCreator

                // 一次独立键盘：返回「Start 刚返回时 事件 / PopOutData」与「半秒后 事件 / 结果 / 文本」
                string Run(KeyboardMode mode, int min, int max)
                {
                    int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x11, 0)), creator));   // CreateLibraryApplet(SoftwareKeyboard, 前台)

                    void Push(byte[] data)
                    {
                        int sto = OutObj(Domain(Msg.Cmif(10, Bytes((long)data.Length)), creator));   // CreateStorage
                        int acc = OutObj(Domain(Msg.Cmif(0), sto));                                   // IStorage.Open
                        data.CopyTo(new Span<byte>(buf, data.Length));
                        Msg w = Msg.Cmif(10, Bytes(0UL)); w.A.Add(((ulong)buf, (ulong)data.Length));   // IStorageAccessor.Write(offset 0)
                        Domain(w, acc);
                        Msg p = Msg.Cmif(100); p.InObjects.Add(sto);                                  // PushInData
                        Domain(p, accessor);
                    }

                    var cfg = new SoftwareKeyboardConfig { Mode = mode, StringLengthMin = min, StringLengthMax = max, SubmitText = "", HeaderText = "", SubtitleText = "", GuideText = "" };
                    byte[] cb = new byte[Marshal.SizeOf<SoftwareKeyboardConfig>()];
                    IntPtr ptr = Marshal.AllocHGlobal(cb.Length);
                    try { Marshal.StructureToPtr(cfg, ptr, false); Marshal.Copy(ptr, cb, 0, cb.Length); } finally { Marshal.FreeHGlobal(ptr); }
                    Push(Bytes(1u, 0x20u, 0u, 0u, 0UL, 0UL));   // 公共参数
                    Push(cb);                                     // SoftwareKeyboardConfig
                    Push(new byte[0x1000]);                       // 工作缓冲（无初值）

                    Reply ev = Domain(Msg.Cmif(0), accessor);     // GetAppletStateChangedEvent
                    uint evh = ev.Copy.Count == 1 ? ev.Copy[0] : 0;
                    evs.Add(evh);
                    bool Signaled() => evh != 0 && FakeNative.Events[FakeNative.CookieOf(evh)];

                    // PopOutData：取到就读「结果 u32 + UTF-16 文本」，取不到回结果码
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

                    Domain(Msg.Cmif(10), accessor);               // Start
                    string now = $"{Signaled()} / {Pop()}";
                    Thread.Sleep(1500);
                    return $"刚返回 {now}；半秒后 {Signaled()} / {Pop()}";
                }

                got[0] = Run(KeyboardMode.Numeric, 2, 3);
                got[1] = Run(KeyboardMode.Default, 0, 4);
            }
            catch (InvalidOperationException e)
            {
                got[0] = got[1] = $"应答解析失败：{e.Message}";
            }
            finally
            {
                foreach (uint h in evs) if (h != 0) FakeNative.HandleClose(h);
                FakeNative.Free(buf);
                FakeNative.HandleClose(oe);
                FakeNative.HandleClose(sm);
            }

            Check("独立软键盘 数字框最短 2 / 最长 3：Start 返回时未交（事件 / PopOutData），显示后交「00」", "刚返回 False / 0x480；半秒后 True / 结果 0「00」", got[0]);
            Check("独立软键盘 普通框最长 4：显示后交「Player」截成「Play」", "刚返回 False / 0x480；半秒后 True / 结果 0「Play」", got[1]);
        }
    }
}
