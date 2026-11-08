// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2A.Services;
using System;
using System.IO;
using System.Text;

namespace S2A.Services.Tests
{
    // pl:u 2100 RequestLoadNxFont + IFontService 0 / 1（Switch 2，时之笛 0400486024DEC000 开局前置；sdk 失败即 AbortImpl）。
    //   线上格式取自时之笛 sdk：2100 非域、复制句柄 1 个（传输内存）、数据 u8 @0 + u32 长度 @4、回出对象；IFontService 0 与 pl:u 2010 同格式。
    //   期望值不跑被测实现：偏移 / 长度按本机 .bfttf 文件长度手算（每个字体占「8 字节头 + 正文」，正文长 = 文件长 − 8，依次排），
    //   正文按 BFTTF 公开格式独立解密（每 4 字节异或 0x06186249）后逐字节比；推不出的分支（首字节非 0、类型 6、命令 1、放不下）期望报红 + 未知命令
    public static unsafe partial class Program
    {
        [SoloTest("--pl-nxfont", Booted = true)]
        private static void PlNxFont()
        {
            if (Ryujinx.HLE.S2AHooks.SharedFontDir == null)
            {
                Check("pl:u 2100 / IFontService", "已测", "未测（没有字体目录）");
                return;
            }

            Host.Device.System.ServiceTable.WaitServicesReady();
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            Reply gp = Call(sm, Msg.Cmif(1, Name8("pl:u")));
            uint pl = gp.Move.Count == 1 ? gp.Move[0] : 0;

            const uint NxSize = 0x1300000;
            const uint Unknown = (221u << 9) | 10u;
            string[] files = ["nintendo_udsg-r_std_003.bfttf", "nintendo_udsg-r_org_zh-cn_003.bfttf", "nintendo_udsg-r_ext_zh-cn_003.bfttf",
                              "nintendo_udjxh-db_zh-tw_003.bfttf", "nintendo_udsg-r_ko_003.bfttf", "nintendo_ext_003.bfttf"];

            Reply Load(byte mode, uint size, byte* buf, uint tmemSize)
            {
                Msg m = Msg.Cmif(2100, Bytes(new byte[] { mode, 0, 0, 0 }, size));
                m.Copy.Add(FakeNative.TmemCreate((ulong)buf, tmemSize, 1));   // sdk 建传输内存时自己只留读权限（MemoryPermission 1）
                return Call(pl, m);
            }

            // ---- 正路：时之笛同款请求（首字节 0、长 0x1300000）----
            byte* buf = FakeNative.Alloc((int)NxSize);
            new Span<byte>(buf, (int)NxSize).Fill(0xCC);
            long red0 = Red.Total;
            Reply ld = Load(0, NxSize, buf, NxSize);
            uint fs = ld.Move.Count == 1 ? ld.Move[0] : 0;
            Check("pl:u 2100 RequestLoadNxFont(0, 0x1300000, 传输内存)：结果 0、回出对象 1 个、不报红", "0x0、1、红 +0", $"0x{ld.Result:X}、{ld.Move.Count}、红 +{Red.Total - red0}");
            if (fs == 0)
            {
                return;   // 没拿到对象：后面各行无从测，本行已记失败
            }

            long next = 0;
            for (int t = 0; t < files.Length; t++)
            {
                byte[] raw = File.ReadAllBytes(Path.Combine(Ryujinx.HLE.S2AHooks.SharedFontDir, files[t]));
                long offset = next + 8, size = raw.Length - 8;
                next += raw.Length;

                Reply r = Call(fs, Msg.Cmif(0, (byte)t, 0));
                byte* d = r.Data;
                uint gotOff = *(uint*)(d + 8), gotLen = *(uint*)(d + 12);
                bool same = r.Result == 0 && gotOff == offset && gotLen == size;
                for (long i = 0; same && i < size; i += 4)
                {
                    same = *(uint*)(buf + offset + i) == (BitConverter.ToUInt32(raw, (int)(8 + i)) ^ 0x06186249u);
                }
                Check($"IFontService 0 GetBuiltInFontData(类型 {t}，{files[t]})：有、偏移 / 长按文件长手算、传输内存里的正文 = 独立解密结果",
                    $"0、有1、类型{t}、标志0、偏移{offset}、长{size}、正文一致",
                    $"{r.Result}、有{d[0]}、类型{d[4]}、标志{d[5]}、偏移{gotOff}、长{gotLen}、正文{(same ? "一致" : "不一致")}");
            }
            Check("pl:u 2100：字体区之后的传输内存未被写（末字体正文之后一字节仍是 0xCC）", "0xCC", $"0x{buf[next]:X2}");

            // ---- 推不出的分支：报红 + 未知命令，不假装成功 ----
            red0 = Red.Total;
            uint r6 = Call(fs, Msg.Cmif(0, 6, 0)).Result;
            Check("IFontService 0(类型 6，客户端集合上限 7 类、我方只有 6 类)：报红", $"0x{Unknown:X}、红 +1", $"0x{r6:X}、红 +{Red.Total - red0}");

            red0 = Red.Total;
            byte* types = FakeNative.Alloc(0x10);
            byte* outs = FakeNative.Alloc(0x60);
            Msg set = Msg.Cmif(1, Bytes(0UL, 0UL)); set.A.Add(((ulong)types, 1)); set.B.Add(((ulong)outs, 12));
            uint r1 = Call(fs, set).Result;
            Check("IFontService 1 GetBuiltInFontDataSet（挑选 / 排序规则不知道）：报红", $"0x{Unknown:X}、红 +1", $"0x{r1:X}、红 +{Red.Total - red0}");

            red0 = Red.Total;
            Reply m1 = Load(1, NxSize, buf, NxSize);
            Check("pl:u 2100 首字节 1（含义不知道）：报红、不回对象", $"0x{Unknown:X}、0、红 +1", $"0x{m1.Result:X}、{m1.Move.Count}、红 +{Red.Total - red0}");

            red0 = Red.Total;
            byte* small = FakeNative.Alloc(0x4000);
            Reply sm1 = Load(0, 0x4000, small, 0x4000);
            Check("pl:u 2100 传输内存 0x4000 放不下字体：报红、不回对象", $"0x{Unknown:X}、0、红 +1", $"0x{sm1.Result:X}、{sm1.Move.Count}、红 +{Red.Total - red0}");
        }
    }
}
