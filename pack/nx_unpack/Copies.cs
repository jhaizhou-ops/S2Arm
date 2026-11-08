// 多份择一：同一内容（同一个 32 位内容号）在给的文件里有多份、或同一程序同一最高版本有多份清单（程序内容号不同）时选哪份（10-26 普查：泡泡龙4 一起给了卡带镜像和 NSP 两份本体，
//   NSP 那份数据块哈希不对；原先取最后一份 = 坏的 NSP，RomFS 读到一半 Hash error 崩溃）。
// 规则：按给的顺序逐份完整校验，取第一份校验通过的；都不通过就取最后一份（与原先一样），交给后面的读取按「源文件数据哈希校验不过」报红。
//   只有一份时不校验（不多花时间）。纯函数，单测在 tests/nx_unpack_ncz。
using System;
using System.Collections.Generic;

static class CopyPick {
    // 返回选中的下标与校验不过的下标（按给的顺序）；verify 抛异常当不通过
    public static (int Pick, List<int> Bad) Pick(int n, Func<int, bool> verify) {
        var bad = new List<int>();
        if (n <= 1) return (0, bad);
        for (int i = 0; i < n; i++) {
            bool ok; try { ok = verify(i); } catch (Exception) { ok = false; }
            if (ok) return (i, bad);
            bad.Add(i);
        }
        return (n - 1, bad);
    }
}
