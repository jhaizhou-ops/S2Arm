// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 小程序编号换算（AppletIdWire，11-02 Pokopia 起名卡死）：Switch 2 SDK 传 0x01vv00ii，ii 是 Switch 1 编号；Switch 1 编号原样。
    //   期望手算：0x01020011 → 0x11 软键盘；0x0100000E → 0x0E 报错；0x01000010 → 0x10 选用户；0x0100000C → 0x0C 手柄；
    //   0x01030024 → 0x24（不在表里，仍走空壳小程序）；Switch 1 的 0x11 → 0x11、0x13 → 0x13 不变
    static class AppletIdWireTest
    {
        [SoloTest("--applet-id-wire")]
        private static int Run()
        {
            var rows = new List<(uint Raw, string Expect)>
            {
                (0x01020011, "SoftwareKeyboard"),
                (0x0100000E, "Error"),
                (0x01000010, "PlayerSelect"),
                (0x0100000C, "Controller"),
                (0x01030024, "36"),
                (0x00000011, "SoftwareKeyboard"),
                (0x00000013, "LibAppletWeb"),
            };

            int bad = 0;
            foreach (var (raw, expect) in rows)
            {
                string actual = AppletIdWire.Read(raw).ToString();
                bool ok = expect == actual;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 小程序编号换算 0x{raw:X8}：{expect} → {actual}");
            }

            return bad == 0 ? 0 : 1;
        }
    }
}
