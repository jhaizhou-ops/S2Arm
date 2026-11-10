// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

/// <summary>「游戏库 / 输出目录」输入规范（LibraryFolderInput）：期望按规则手写；按当前系统的路径写法各测一遍。</summary>
internal static class LibraryFolderCases
{
    public static void Run(Action<bool, string> check)
    {
        var win = OperatingSystem.IsWindows();
        var launcher = win ? @"D:\WORK\NX2Apple-windows-x64" : "/work/NX2Apple-windows-x64";
        string P(string w, string u) => win ? w : u;
        void Expect(string? input, string? folder, string? error, string what)
        {
            var r = LibraryFolderInput.Normalize(input, launcher);
            check(r.Folder == folder && r.ErrorKey == error, $"{what}: {input} → ({r.Folder}, {r.ErrorKey})");
        }
        // 玩家截图原样：启动器解压目录下的子目录、末尾带分隔符 → 拒绝（升级会整个替换启动器目录）
        Expect(P(@"D:\WORK\NX2Apple-windows-x64\1\", "/work/NX2Apple-windows-x64/1/"), null, "library.folder_in_launcher", "库在启动器目录里");
        Expect(P(@"D:\WORK\NX2Apple-windows-x64", "/work/NX2Apple-windows-x64"), null, "library.folder_in_launcher", "库就是启动器目录");
        Expect(P(@"D:\WORK", "/work"), null, "library.folder_in_launcher", "库包含启动器目录");
        // 末尾分隔符、首尾空白与引号去掉；大小写不同的同名兄弟目录不算在启动器里
        Expect(P(@"  ""E:\Games\S2Arm\"" ", " \"/games/S2Arm/\" "), P(@"E:\Games\S2Arm", "/games/S2Arm"), null, "末尾分隔符与引号");
        Expect(P(@"D:\WORK\NX2Apple-windows-x64-lib", "/work/NX2Apple-windows-x64-lib"), P(@"D:\WORK\NX2Apple-windows-x64-lib", "/work/NX2Apple-windows-x64-lib"), null, "前缀相同的兄弟目录");
        Expect("", null, "library.folder_empty", "空");
        Expect("   ", null, "library.folder_empty", "只有空白");
        Expect(P(@"E:\", "/"), null, "library.folder_root", "盘根");
        Expect(P(@"E:\a<b", "/a|b\0c"), null, "library.folder_invalid", "非法字符");
    }
}
