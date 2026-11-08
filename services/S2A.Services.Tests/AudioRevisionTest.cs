// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Renderer.Server;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 音频渲染器版本号（11-03 火纹 Fortune's Weave：Switch 2 SDK 请求 'REv' + 16，判不支持 → Break 2153-0002）。
    //   魔数 = 'R' | 'E' << 8 | v << 16 | ('0' + 版本) << 24；Switch 1 的 v 是 'V'，Switch 2 原生是 'v'。
    //   期望手算：REv16 / REV16 / REv15 / REV15 / REV1 收；REv17 / REV17 拒（负例）；REv16 打开 REV15 的特性（分离器目标 V2b）
    static class AudioRevisionTest
    {
        static int Magic(char v, int rev) => 'R' | ('E' << 8) | (v << 16) | (('0' + rev) << 24);

        [SoloTest("--audio-revision")]
        private static int Run()
        {
            var rows = new List<(string Name, int Magic, bool Valid)>
            {
                ("REv16", Magic('v', 16), true),
                ("REV16", Magic('V', 16), true),
                ("REv15", Magic('v', 15), true),
                ("REV15", Magic('V', 15), true),
                ("REV1", Magic('V', 1), true),
                ("REv17", Magic('v', 17), false),
                ("REV17", Magic('V', 17), false),
            };

            int bad = 0;
            foreach (var (name, magic, valid) in rows)
            {
                bool actual = BehaviourInfo.CheckValidRevision(magic);
                bool ok = actual == valid;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 音频版本 {name}（0x{magic:X8}）：期望{(valid ? "收" : "拒")} → {(actual ? "收" : "拒")}");
            }

            var info = new BehaviourInfo();
            info.SetUserRevision(Magic('v', 16));
            bool feat = BehaviourInfo.CheckFeatureSupported(info.UserRevision, BehaviourInfo.BaseRevisionMagic + BehaviourInfo.Revision15);
            if (!feat) bad++;
            Console.WriteLine($"{(feat ? "✓" : "✗")} 音频版本 REv16 打开 REV15 特性：期望开 → {(feat ? "开" : "关")}");

            return bad == 0 ? 0 : 1;
        }
    }
}
