// 真渲染器（NxGal）缺口登记：哪个 GAL 调用还没实现（缺 C 符号 / NotImplemented / NotSupported / 类型对不上），调了几次、首条消息是什么。
// 写进 stats.json 的 nxgal_missing，首次出现时打一行 stderr，交渲染线补。
using System;
using System.Collections.Generic;

namespace RyuJudge
{
    public static class GalGuard
    {
        public sealed class Entry
        {
            public long Count;
            public string First;
        }

        public static readonly SortedDictionary<string, Entry> Gaps = new();

        static bool IsGap(Exception e) => e is EntryPointNotFoundException or DllNotFoundException or NotImplementedException
                                          or NotSupportedException or InvalidCastException;

        /// <summary>异常筛选器用：是缺口就登记并返回真（吞掉），否则返回假（照常上抛）。</summary>
        public static bool Missing(Exception e, string where)
        {
            if (!IsGap(e))
            {
                return false;
            }

            Record(where, e);
            return true;
        }

        public static void Record(string where, Exception e)
        {
            if (!Gaps.TryGetValue(where, out Entry en))
            {
                Gaps[where] = en = new Entry { First = $"{e.GetType().Name}: {e.Message}" };
                Console.Error.WriteLine($"[ryu_judge] nxgal 缺口：{where} → {en.First}");
            }

            en.Count++;
        }

        public static Dictionary<string, object> Snapshot()
        {
            Dictionary<string, object> d = new();
            foreach ((string k, Entry v) in Gaps)
            {
                d[k] = new Dictionary<string, object> { ["count"] = v.Count, ["first"] = v.First };
            }

            return d;
        }
    }
}
