using System;
using System.IO;
using System.Text;
using Ryujinx.HLE.HOS.Services.Account.Acc;

namespace S2A.Services.Tests
{
    // acc:u0 命令 52 TrySelectUserWithoutInteraction（19.0.0+；同版把命令 51 改名 TrySelectUserWithoutInteractionDeprecated，
    //   入参 u8 isNetworkServiceAccountRequired、出参 Uid，见 switchbrew Account_services）。11-04 测试机1 FC26 在 logo 页
    //   每秒十余次调 52、拿到未知命令后一直重试，卡在账号步骤。
    //   期望照真机语义手写：有用户时回成功 + 第一个用户的 Uid（夹具只有缺省用户 → AccountManager.DefaultUserId），两种入参一致；
    //   负对照：同接口真机有、我方没实现的命令 6 GetProfileDigest 照旧回 2010-0221（未知命令）并报红 +1
    public static unsafe partial class Program
    {
        [SoloTest("--acc-select-user", Booted = true)]
        private static void AccountSelectUser()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            Reply gacc = Call(sm, Msg.Cmif(1, Name8("acc:u0")));
            uint acc = gacc.Move.Count == 1 ? gacc.Move[0] : 0;

            MemoryStream us = new();
            AccountManager.DefaultUserId.Write(new BinaryWriter(us));
            string want = Convert.ToHexString(us.ToArray());

            string Select(uint command, byte required)
            {
                long red0 = Red.Total;
                Reply r = Call(acc, Msg.Cmif(command, new byte[] { required, 0, 0, 0, 0, 0, 0, 0 }));
                string uid = r.Result == 0 ? Convert.ToHexString(new ReadOnlySpan<byte>(r.Data, 16)) : "-";
                return $"结果 {r.Result}、Uid {(uid == want ? "缺省用户" : uid)}、报红 +{Red.Total - red0}";
            }

            Check("acc:u0 命令 52 TrySelectUserWithoutInteraction(false)", "结果 0、Uid 缺省用户、报红 +0", Select(52, 0));
            Check("acc:u0 命令 52 TrySelectUserWithoutInteraction(true)", "结果 0、Uid 缺省用户、报红 +0", Select(52, 1));
            Check("acc:u0 命令 51 TrySelectUserWithoutInteractionDeprecated(false)（与 52 同语义）", "结果 0、Uid 缺省用户、报红 +0", Select(51, 0));

            long redNeg = Red.Total;
            Reply neg = Call(acc, Msg.Cmif(6, us.ToArray()));
            Check("负对照：acc:u0 命令 6 GetProfileDigest（未实现）", $"结果 {Red.ResultUnknownCommand}、报红 +1", $"结果 {neg.Result}、报红 +{Red.Total - redNeg}");

            FakeNative.HandleClose(acc); FakeNative.HandleClose(sm);
        }
    }
}
