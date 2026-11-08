// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2A.Services;
using System;
using System.IO;
using System.Text;

namespace S2A.Services.Tests
{
    // Switch 2 服务层接口面补齐（11-04，04_服务层_报告.md）：pl:u 2000 / 2010、nfp:user 300、chat:u、Switch 2 NRR 布局、
    //   IApplicationFunctions 210（Switch 2 模式刷新事件）、glue 时区 5 / 6 / 7 / 8 / 20。
    //   事实取自 Eden-NS2（GPL，代码自写）；期望值按命令语义与本机文件长度手算，不跑被测实现。
    //   每项带负对照：越界字体类型回「无」、同一事件第二次取回 0x4E2、头字节 6 ≠ 1 的同一 NRR 回 InvalidSize、Switch 1 进程的 210 不随模式切换触发、
    //   时区事件在改名前未触发、没写权限的 7 回 PermissionDenied。
    //   独立进程跑（会切掌机 / 主机模式、改设备时区，避免污染整套）
    public static unsafe partial class Program
    {
        [SoloTest("--switch2-surface-svc", Booted = true)]
        private static void Switch2SurfaceSvc()
        {
            Host.Device.System.ServiceTable.WaitServicesReady();
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);

            uint Open(string name) { Reply r = Call(sm, Msg.Cmif(1, Name8(name))); return r.Move.Count == 1 ? r.Move[0] : 0; }
            uint Obj(Reply r) => r.Move.Count == 1 ? r.Move[0] : 0;
            ulong EventOf(uint h) => FakeNative.Handles.TryGetValue(h, out var o) ? o.Cookie : 0;

            // 每段独立：段内抛异常（如修复前服务不存在、拿到的对象号 0）记一行失败，后面的段照跑（负对照要逐项读数）
            void Section(string name, Action body)
            {
                try { body(); }
                catch (Exception e) { Check($"{name}：整段无异常", "无异常", (e.InnerException ?? e).Message); }
            }

            // ---- pl:u 2000 / 2010：内置字体（本机旧库字体目录，不进仓库；没有就记未测）----
            Section("pl:u 2000 / 2010", () =>
            {
                if (Ryujinx.HLE.S2AHooks.SharedFontDir != null)
                {
                    uint pl = Open("pl:u");
                    Reply r2000 = Call(pl, Msg.Cmif(2000));
                    Check("pl:u 2000 GetBuiltInFontSharedMemory：共享内存长 0x1100000、复制句柄 1 个", "0、0x1100000、1",
                        $"{r2000.Result}、0x{*(uint*)r2000.Data:X}、{r2000.Copy.Count}");

                    long std = new FileInfo(Path.Combine(Ryujinx.HLE.S2AHooks.SharedFontDir, "nintendo_udsg-r_std_003.bfttf")).Length;
                    long org = new FileInfo(Path.Combine(Ryujinx.HLE.S2AHooks.SharedFontDir, "nintendo_udsg-r_org_zh-cn_003.bfttf")).Length;
                    string Font(byte type)
                    {
                        Reply r = Call(pl, Msg.Cmif(2010, type, 1));
                        byte* d = r.Data;
                        return $"{r.Result}、有{d[0]}、类型{d[4]}、标志{d[5]}、偏移{*(uint*)(d + 8)}、长{*(uint*)(d + 12)}";
                    }
                    // 共享内存里字体依次排：每个 8 字节头 + 正文（.bfttf 去掉 8 字节头）；描述的偏移指正文首、长 = 正文长
                    Check("pl:u 2010(标准字体 0)", $"0、有1、类型0、标志0、偏移8、长{std - 8}", Font(0));
                    Check("pl:u 2010(简中 1)：紧跟标准字体之后", $"0、有1、类型1、标志0、偏移{std + 8}、长{org - 8}", Font(1));
                    Check("pl:u 2010(类型 6 越界，负对照)", "0、有0、类型0、标志0、偏移0、长0", Font(6));
                }
                else
                {
                    Check("pl:u 2000 / 2010 内置字体", "已测", "未测（没有字体目录）");
                }
            });

            // ---- nfp:user 300 InitializeEx：同 Initialize 的状态（GetState 19：0 未初始化 → 1 已初始化）----
            Section("nfp:user 300", () =>
            {
                {
                    uint nfp = Open("nfp:user");
                    uint user = Obj(Call(nfp, Msg.Cmif(0)));
                    uint s0 = *(uint*)Call(user, Msg.Cmif(19)).Data;
                    byte* elems = FakeNative.Alloc(0x40);
                    new Span<byte>(elems, 0x40).Clear();
                    Msg ix = Msg.Cmif(300, Bytes(7u, 0u, 0UL)); ix.SendPid = true; ix.A.Add(((ulong)elems, 0x40));
                    uint rix = Call(user, ix).Result;
                    uint s1 = *(uint*)Call(user, Msg.Cmif(19)).Data;
                    Check("nfp:user 300 InitializeEx：前状态 0（负对照）→ 结果 0 → 状态 1", "0、0、1", $"{s0}、{rix}、{s1}");
                }
            });

            // ---- chat:u：用户对象的事件各交一次（复制句柄），再要回 0x4E2；未知命令报红 ----
            Section("chat:u", () =>
            {
                {
                    uint chat = Open("chat:u");
                    uint shim = Obj(Call(chat, Msg.Cmif(0)));
                    Reply e1 = Call(shim, Msg.Cmif(1));
                    Reply e1b = Call(shim, Msg.Cmif(1));
                    Reply e10 = Call(shim, Msg.Cmif(10));
                    bool distinct = e1.Copy.Count == 1 && e10.Copy.Count == 1 && EventOf(e1.Copy[0]) != EventOf(e10.Copy[0]);
                    Check("chat:u 0 → 用户对象：事件 1 首次、事件 1 再取（负对照）、事件 10；两个事件不同", "0/1 句柄、0x4E2/0 句柄、0/1 句柄、不同",
                        $"{e1.Result}/{e1.Copy.Count} 句柄、0x{e1b.Result:X}/{e1b.Copy.Count} 句柄、{e10.Result}/{e10.Copy.Count} 句柄、{(distinct ? "不同" : "相同")}");

                    long red0 = Red.Total;
                    Msg cam = Msg.Cmif(3); cam.SendPid = true;
                    uint camObj = Obj(Call(chat, cam));
                    Reply unk = Call(camObj, Msg.Cmif(0));
                    Reply unk8 = Call(shim, Msg.Cmif(8));
                    Check("chat:u 3 → 虚拟摄像头对象；它的命令 0 与用户对象命令 8（语义未知）报红、不回成功", "对象 1、失败、失败、红 +2",
                        $"对象 {(camObj != 0 ? 1 : 0)}、{(unk.Result != 0 ? "失败" : "成功")}、{(unk8.Result != 0 ? "失败" : "成功")}、红 +{Red.Total - red0}");
                }
            });

            // ---- ldr:ro：Switch 2 NRR（头字节 6 = 1，正文从 0x4B0 起）----
            Section("ldr:ro Switch 2 NRR", () =>
            {
                {
                    Reply gro = Call(sm, Msg.Cmif(1, Name8("ldr:ro")));
                    uint ros = Obj(gro);
                    Msg rin = Msg.Cmif(4, Bytes(0UL)); rin.SendPid = true; rin.Copy.Add(0xFFFF8001);
                    Call(ros, rin);
                    byte* nro = RoBuildNro(RoWarmSz, out byte[] nroHash);
                    byte* other = RoBuildNro(RoWarmSz + 0x1000, out _);

                    byte* Nrr(byte layout)
                    {
                        byte* n = FakeNative.Alloc(0x1000);
                        new Span<byte>(n, 0x1000).Clear();
                        *(uint*)n = 0x3052524E; n[5] = 1; n[6] = layout;
                        *(uint*)(n + 0x4B8) = 0x1000; *(uint*)(n + 0x4C0) = 0x500; *(uint*)(n + 0x4C4) = 1;
                        nroHash.CopyTo(new Span<byte>(n + 0x500, 0x20));
                        return n;
                    }

                    uint LoadNrr(byte* n) { Msg m = Msg.Cmif(2, Bytes(0UL, (ulong)n, 0x1000UL)); m.SendPid = true; return Call(ros, m).Result; }
                    uint loose = LoadNrr(Nrr(0));   // 同一份字节当 Switch 1 布局读：0x338 处的大小是 0 → InvalidSize
                    uint longOk = LoadNrr(Nrr(1));
                    (long _, uint hit) = RoLoadNroAlloc(ros, (ulong)nro, RoWarmSz);
                    (long _, uint miss) = RoLoadNroAlloc(ros, (ulong)other, RoWarmSz + 0x1000);
                    const uint InvalidSize = (1026 << 9) | 22, NotRegistered = (1029 << 9) | 22;
                    Check("ldr:ro Switch 2 NRR：头字节 6 = 0 读成 Switch 1 布局（负对照）/ = 1 登记成功 / 登记过的 NRO 过哈希校验 / 没登记的 NRO",
                        $"0x{InvalidSize:X}、0、0x{RoAlreadyLoaded:X}、0x{NotRegistered:X}", $"0x{loose:X}、{longOk}、0x{hit:X}、0x{miss:X}");
                }
            });

            // ---- IApplicationFunctions 210：Switch 2 进程交模式刷新事件（掌机 / 主机切换即触发）；Switch 1 进程交的事件不触发 ----
            Section("IApplicationFunctions 210", () =>
            {
                {
                    (bool Before, bool After) Mode210(bool sw2)
                    {
                        bool was = Ryujinx.HLE.S2AHooks.Switch2;
                        Ryujinx.HLE.S2AHooks.Switch2 = sw2;
                        try
                        {
                            uint oe = Open("appletOE");
                            Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
                            uint proxy = Obj(Call(oe, opx));
                            uint funcs = Obj(Call(proxy, Msg.Cmif(20)));
                            Reply r = Call(funcs, Msg.Cmif(210));
                            ulong ev = r.Copy.Count == 1 ? EventOf(r.Copy[0]) : 0;
                            if (ev != 0) FakeNative.EventClear(ev);
                            bool before = ev != 0 && FakeNative.Events[ev];
                            bool docked = Host.Device.System.State.DockedMode;
                            Host.Device.System.ChangeDockedModeState(!docked);
                            bool after = ev != 0 && FakeNative.Events[ev];
                            Host.Device.System.ChangeDockedModeState(docked);
                            return (before, after);
                        }
                        finally { Ryujinx.HLE.S2AHooks.Switch2 = was; }
                    }

                    (bool b2, bool a2) = Mode210(true);
                    (bool b1, bool a1) = Mode210(false);
                    Check("IApplicationFunctions 210：Switch 2 切模式前未触发 → 切后触发；Switch 1（负对照）切后仍未触发", "否→是、否→否",
                        $"{(b2 ? "是" : "否")}→{(a2 ? "是" : "否")}、{(b1 ? "是" : "否")}→{(a1 ? "是" : "否")}");
                }
            });

            // ---- time:u / time:a 的时区服务（glue）5 / 6 / 7 / 8 / 20 ----
            Section("glue 时区 5 / 6 / 7 / 8 / 20", () =>
            {
                {
                    uint tu = Open("time:u");
                    uint tz = Obj(Call(tu, Msg.Cmif(3)));
                    uint ts = Open("time:s");
                    uint tzPsc = Obj(Call(ts, Msg.Cmif(3)));
                    // 应答数据指向同一块 TLS 缓冲：每次调完立刻拷出来再比
                    Reply v = Call(tz, Msg.Cmif(5)); byte[] ver = new ReadOnlySpan<byte>(v.Data, 16).ToArray();
                    Reply vPsc = Call(tzPsc, Msg.Cmif(5)); byte[] verPsc = new ReadOnlySpan<byte>(vPsc.Data, 16).ToArray();
                    bool sameVer = v.Result == 0 && vPsc.Result == 0 && ver.AsSpan().SequenceEqual(verPsc);
                    Reply ln = Call(tz, Msg.Cmif(0)); byte[] name = new ReadOnlySpan<byte>(ln.Data, 0x24).ToArray();
                    Reply lu = Call(tz, Msg.Cmif(6)); byte[] name6 = new ReadOnlySpan<byte>(lu.Data, 0x24).ToArray();
                    bool sameName = ln.Result == 0 && lu.Result == 0 && name[0] != 0 && name.AsSpan().SequenceEqual(name6);
                    byte* bin = FakeNative.Alloc(0x100);
                    Msg m7 = Msg.Cmif(7, new byte[0x24]); m7.A.Add(((ulong)bin, 0x100));
                    Msg m8 = Msg.Cmif(8); m8.A.Add(((ulong)bin, 0x100)); m8.B.Add(((ulong)FakeNative.Alloc(0x4000), 0x4000));
                    uint r7 = Call(tz, m7).Result, r8 = Call(tz, m8).Result;
                    const uint PermissionDenied = (1 << 9) | 116, NotImplemented = (990u << 9) | 116;
                    Check("time:u 时区 5（同 psc）/ 6（名同命令 0）/ 7 无写权限（负对照）/ 8 未实现", $"同、同、0x{PermissionDenied:X}、0x{NotImplemented:X}",
                        $"{(sameVer ? "同" : "不同")}、{(sameName ? "同" : "不同")}、0x{r7:X}、0x{r8:X}");

                    uint ta = Open("time:a");
                    uint tza = Obj(Call(ta, Msg.Cmif(3)));
                    Reply e20 = Call(tza, Msg.Cmif(20));
                    ulong ev = e20.Copy.Count == 1 ? EventOf(e20.Copy[0]) : 0;
                    bool before = ev != 0 && FakeNative.Events[ev];
                    Msg set = Msg.Cmif(1, name);
                    uint rs = Call(tza, set).Result;
                    bool after = ev != 0 && FakeNative.Events[ev];
                    uint r7a = Call(tza, m7).Result;
                    Check("time:a 时区 20 事件：改名前未触发（负对照）→ SetDeviceLocationName 成功后触发；有写权限的 7 回未实现", $"否、0、是、0x{NotImplemented:X}",
                        $"{(before ? "是" : "否")}、{rs}、{(after ? "是" : "否")}、0x{r7a:X}");
                }
            });
        }
    }
}
