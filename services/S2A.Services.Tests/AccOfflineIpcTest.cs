// SPDX-License-Identifier: Apache-2.0
// 宿主假内核 + 生产 HIPC/CMIF 分发：离线账号错误及异步对象的时序。
using System;
using System.IO;
using System.Text;
using System.Threading;
using Ryujinx.HLE.HOS.Services.Account.Acc;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--acc-offline-ipc", Booted = true)]
        static void AccountOfflineIpc()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint acc = Call(sm, Msg.Cmif(1, Name8("acc:u0"))).Move[0];
            MemoryStream uidStream = new();
            AccountManager.DefaultUserId.Write(new BinaryWriter(uidStream));
            uint manager = Call(acc, Msg.Cmif(101, uidStream.ToArray())).Move[0];
            const uint offline = (200u << 9) | 124u;
            foreach (uint id in new uint[] { 0, 1, 3, 4, 130 })
            {
                Reply result = Call(manager, Msg.Cmif(id));
                Check($"acc 离线 CMIF {id} 不回伪成功", offline, result.Result);
            }
            foreach (uint id in new uint[] { 2, 170 })
            {
                Reply start = Call(manager, Msg.Cmif(id));
                Check($"acc 异步 {id} 同步创建对象", "0 / 1", $"{start.Result} / {start.Move.Count}");
                if (start.Move.Count != 1) continue;
                uint child = start.Move[0];
                Reply ev = Call(child, Msg.Cmif(0));
                Check($"acc 异步 {id} 取事件", "0 / 1", $"{ev.Result} / {ev.Copy.Count}");
                bool done = false;
                for (int n = 0; n < 5000 && !done; n++)
                {
                    Reply state = Call(child, Msg.Cmif(2));
                    done = state.Result == 0 && state.Data[0] != 0;
                    if (!done) Thread.Sleep(1);
                }
                Check($"acc 异步 {id} HasDone", "True", done.ToString());
                Check($"acc 异步 {id} GetResult", offline, Call(child, Msg.Cmif(3)).Result);
                if (id == 170) Check("acc 许可证对象不回伪资格", offline, Call(child, Msg.Cmif(100)).Result);
                if (ev.Copy.Count == 1) FakeNative.HandleClose(ev.Copy[0]);
                FakeNative.HandleClose(child);
            }
            FakeNative.HandleClose(manager); FakeNative.HandleClose(acc); FakeNative.HandleClose(sm);
        }
    }
}
