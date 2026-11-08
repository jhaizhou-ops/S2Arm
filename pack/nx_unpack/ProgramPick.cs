// 多程序合集（一个应用里多支程序）：同一份清单（本体 / 更新 CNMT）里 Program、Control 各有多份，每份对应一个序号——
//   内容自己的程序号末位（Ryujinx Nca.ProgramIndex；ContentMetaData.GetNcaByType 按它挑，不按清单顺序）。
//   11-06 普查：索尼克×夏特 世代重启清单里序号 0 / 1 两支 Program 与两份 Control；原先取清单里第一份，序号 1 整支没解包。
// 纯函数，单测在 tests/nx_unpack_ncz（合成清单，不要密钥）。
using System;
using System.Collections.Generic;

static class ProgramPick {
    // n 份同类内容（清单顺序），indexOf(i) 回第 i 份的序号（读不出回 -1 或抛异常 = 不是任何序号）。
    //   回序号等于 want 的那份的下标；只有一份且 want = 0 时不读序号直接用（单程序款照旧，内容不在给的文件里也由调用方报红）；没有回 -1
    public static int Pick(int n, Func<int, int> indexOf, int want) {
        if (n <= 0) return -1;
        if (n == 1 && want == 0) return 0;
        for (int i = 0; i < n; i++) {
            int x; try { x = indexOf(i); } catch (Exception) { x = -1; }
            if (x == want) return i;
        }
        return -1;
    }
    // 包里几支程序：各 Program 内容的序号从 0 起连续的个数（同 Ryujinx RegisterProgramMapInfo 的 hasIndex 连续段）
    public static int Count(IEnumerable<int> indexes) {
        var has = new bool[16];
        foreach (int x in indexes) if (x >= 0 && x < has.Length) has[x] = true;
        int c = 0; while (c < has.Length && has[c]) c++;
        return c;
    }
}
