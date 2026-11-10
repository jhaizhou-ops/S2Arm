// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 玩家在「游戏库 / 输出目录」里填的路径 → 规范后的绝对路径，或一个界面文案键说明为什么不行。
/// 玩家反馈（v0.2.0）：填 <c>D:\WORK\NX2Apple-windows-x64\1\</c>（末尾反斜杠、就在启动器解压目录里）点「连接或创建游戏库」闪退、位置也改不了。
/// 规则：去首尾空白和引号；转绝对路径（非法字符 / 太长 → invalid）；去掉末尾分隔符（根目录除外）；
/// 盘根 → root；落在启动器自己的目录里或包含它 → in_launcher（升级时启动器目录整个替换，库放在里面会被一起删掉）。
/// </summary>
public static class LibraryFolderInput
{
    public sealed record Result(string? Folder, string? ErrorKey);

    public static Result Normalize(string? input, string launcherDirectory)
    {
        var text = (input ?? "").Trim().Trim('"').Trim();
        if (text.Length == 0) return new(null, "library.folder_empty");
        string full;
        try { full = Path.GetFullPath(text); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or System.Security.SecurityException)
        { return new(null, "library.folder_invalid"); }
        var root = Path.GetPathRoot(full) ?? "";
        var trimmed = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (trimmed.Length < root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Length + 1)
            return new(null, "library.folder_root");
        if (Path.GetInvalidPathChars().Any(trimmed.Contains) || trimmed[root.Length..].IndexOfAny(['<', '>', '|', '"', '*', '?']) >= 0)
            return new(null, "library.folder_invalid");
        var launcher = Path.GetFullPath(launcherDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Within(trimmed, launcher) || Within(launcher, trimmed)) return new(null, "library.folder_in_launcher");
        return new(trimmed, null);
    }

    private static bool Within(string path, string parent)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return string.Equals(path, parent, comparison) || path.StartsWith(parent + Path.DirectorySeparatorChar, comparison);
    }
}
