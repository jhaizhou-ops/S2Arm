// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

// 导入失败后界面的去向。只有读取器确认「通用密钥版本不足」才引导换 prod.keys；
// 无法读取、缺票据、内容截断等都不是换密钥能解决的，只显示后端消息。
public static class ImportFailureRoute
{
    public const int ShowMessage = 0;
    public const int ImportKeys = 1;
    public const int ReplaceKeys = 2;

    public static int For(string? code, bool keysReady) => code switch
    {
        "keys_missing" => ImportKeys,
        "keys_outdated" when keysReady => ReplaceKeys,
        _ => ShowMessage,
    };
}
