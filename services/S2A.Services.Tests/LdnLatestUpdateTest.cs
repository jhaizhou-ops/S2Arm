using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using System;

namespace S2A.Services.Tests
{
    // 联机节点加入 / 离开标志（11-01 全量审计 P1-25）：生产调用方是 AccessPoint / Station 的 LatestUpdates 字段，这里同样放在类字段上调两个扩展方法。
    //   期望按语义手写：节点 2 从未连到连上、节点 5 从连上到断开 → 第一次取出节点 2 = Connect、节点 5 = Disconnect、其余 None；
    //   取出即清 → 第二次取出全 None。旧代码按值传 Array8（改的是副本）→ 第一次取出就全 None，判红
    public static partial class Program
    {
        sealed class LatestUpdatesHolder { public Array8<NodeLatestUpdate> LatestUpdates = new(); }

        [SoloTest("--ldn-latest-update")]
        private static int LdnLatestUpdate()
        {
            Array8<NodeInfo> before = new(), after = new();
            before[5].IsConnected = 1;
            after[2].IsConnected = 1;
            LatestUpdatesHolder h = new();
            h.LatestUpdates.CalculateLatestUpdate(before, after);
            NodeLatestUpdate[] first = h.LatestUpdates.ConsumeLatestUpdate(8), second = h.LatestUpdates.ConsumeLatestUpdate(8);
            static string Row(NodeLatestUpdate[] a) => string.Join(",", Array.ConvertAll(a, u => u.State.ToString()));
            string expect = "None,None,Connect,None,None,Disconnect,None,None / None,None,None,None,None,None,None,None";
            string actual = $"{Row(first)} / {Row(second)}";
            bool ok = expect == actual;
            Console.WriteLine($"{(ok ? "✓" : "✗")} 联机节点更新标志（第一次取出 / 第二次取出）：{expect} → {actual}");
            return ok ? 0 : 1;
        }
    }
}
