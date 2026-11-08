using System;
using System.IO;
using System.Text;
using Ryujinx.HLE.HOS.Services.Account.Acc;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void AccountLifetime()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint Account() => Call(sm, Msg.Cmif(1, Name8("acc:u0"))).Move[0];
            uint reader = Account();
            byte* users = _game + 0x3900;
            int Listed()
            {
                new Span<byte>(users, 0x80).Fill(0xEE);
                Msg list = Msg.Cmif(3); list.C.Add(((ulong)users, 0x80)); Call(reader, list);
                int n = 0;
                for (int i = 0; i < 8; i++) if (*(ulong*)(users + i * 16) != 0 || *(ulong*)(users + i * 16 + 8) != 0) n++;
                return n;
            }
            MemoryStream stream = new();
            AccountManager.DefaultUserId.Write(new BinaryWriter(stream));
            byte[] uid = stream.ToArray();
            uint Clone(uint handle, uint command)
            {
                Msg clone = Msg.Cmif(command, Bytes(0u)); clone.Type = 5;
                Reply reply = Call(handle, clone);
                Check($"acc clone CMIF {command} 返回会话", "0 / 1", $"{reply.Result} / {reply.Move.Count}");
                return reply.Move.Count == 1 ? reply.Move[0] : 0;
            }
            Reply Domain(uint handle, Msg message)
            {
                message.Write(_tlr); Svc(0x21, FakeNative.CookieOf(handle));
                if (message.DomainRequestType == 2) return new Reply(); // CloseVirtualHandle has no CMIF output header
                return Reply.ParseDomain(_tlr);
            }

            foreach (uint command in new uint[] { 2, 4 })
            foreach (bool originalFirst in new bool[] { true, false })
            {
                uint manager = Call(reader, Msg.Cmif(101, uid)).Move[0];
                uint clone = Clone(manager, command);
                int created = Listed();
                FakeNative.HandleClose(originalFirst ? manager : clone);
                int partial = Listed();
                uint alive = originalFirst ? clone : manager;
                long liveResult = Call(alive, Msg.Cmif(0)).Result;
                FakeNative.HandleClose(alive);
                Check($"acc CMIF {command} {(originalFirst ? "原件" : "clone")}先关：创建/剩一个/最终/存活请求", "1 / 1 / 0 / 102524",
                    $"{created} / {partial} / {Listed()} / {liveResult}");

                uint domain = Account();
                Msg convert = Msg.Cmif(0); convert.Type = 5;
                int rootId = *(int*)Call(domain, convert).Data;
                Msg create = Msg.Cmif(101, uid); create.DomainObject = rootId;
                Reply child = Domain(domain, create);
                Check("acc 域创建 manager", "0 / 1", $"{child.Result} / {child.DomainOutCount}");
                uint domainClone = Clone(domain, command);
                int domainCreated = Listed();
                FakeNative.HandleClose(originalFirst ? domain : domainClone);
                int domainPartial = Listed();
                FakeNative.HandleClose(originalFirst ? domainClone : domain);
                Check($"acc 域 CMIF {command} {(originalFirst ? "原件" : "clone")}先关：创建/剩一个/最终", "1 / 1 / 0",
                    $"{domainCreated} / {domainPartial} / {Listed()}");
            }

            uint explicitDomain = Account();
            Msg cv = Msg.Cmif(0); cv.Type = 5;
            int root = *(int*)Call(explicitDomain, cv).Data;
            Msg cm = Msg.Cmif(101, uid); cm.DomainObject = root;
            int childId = *(int*)Domain(explicitDomain, cm).Data;
            int beforeDelete = Listed();
            Msg delete = Msg.Cmif(0); delete.DomainObject = childId; delete.DomainRequestType = 2;
            Domain(explicitDomain, delete);
            int afterDelete = Listed();
            FakeNative.HandleClose(explicitDomain);
            Check("acc 域显式删除子对象再关最终会话", "1 / 0 / 0", $"{beforeDelete} / {afterDelete} / {Listed()}");
            int parallelFailures = 0;
            for (int iteration = 0; iteration < 8; iteration++)
            {
                uint manager = Call(reader, Msg.Cmif(101, uid)).Move[0];
                uint clone = Clone(manager, 2);
                using System.Threading.ManualResetEventSlim start = new(false);
                var first = System.Threading.Tasks.Task.Run(() => { start.Wait(); return FakeNative.HandleClose(manager); });
                var second = System.Threading.Tasks.Task.Run(() => { start.Wait(); return FakeNative.HandleClose(clone); });
                start.Set();
                if (!System.Threading.Tasks.Task.WaitAll(new System.Threading.Tasks.Task[] { first, second }, 5000))
                    throw new TimeoutException("account clone 并发关闭未完成");
                if (first.Result != 1 || second.Result != 1 || Listed() != 0) parallelFailures++;
            }
            Check("acc clone 两会话同时关闭：每次均回收", 0, parallelFailures);

            FakeNative.HandleClose(reader); FakeNative.HandleClose(sm);
        }
    }
}
