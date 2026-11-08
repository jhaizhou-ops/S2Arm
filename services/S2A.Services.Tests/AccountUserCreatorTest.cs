using System;
using System.IO;
using System.Linq;
using System.Text;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;

namespace S2A.Services.Tests
{
    // 游戏「增加新用户」（nn::account::ShowUserCreator）。11-05 测试机1 脑锻炼在「请选择用户」页点「增加新用户」稳定 Break：
    //   零售 SDK 的 ShowUserCreator 先调 IsUserRegistrationRequestPermitted（acc:u0 命令 50），回 false 就 Abort（sdk ShowUserCreator+0x90）；
    //   游戏本身不先查这个值、直接调 ShowUserCreator，说明零售机对应用回 true。上游对 acc:u0 回 false。
    //   放行后 SDK 拉起选用户小程序（psel），UiSettings 模式 1 = UserCreator，读回 0x18 字节：头 4 字节就是 ShowUserCreator 的返回结果；
    //   游戏只认 0（建好了）和 2124-0001 = 0x27C（玩家取消，与 SDK 自己在小程序异常退出时回的值相同），别的值照样 Abort。
    //   11-06 测试机1 复测：回「玩家取消」后点「增加新用户」毫无反应（host.log 每点一下一行 PlayerSelect 小程序 + 「answered as cancelled」，触点本身进了游戏）。
    //   真机上这个小程序就是建一个新用户再回 0：宿主没有昵称 / 头像界面，按真机建好后的结果应答——账户表里真加一个用户
    //   （系统缺省头像、未占用的昵称 PlayerN），回 0 + 新用户 Uid；游戏随后重新列用户，能选到它。
    //   期望照反汇编手写：命令 50 → 结果 0、bool 1；UserCreator → 0x18 字节、结果 0、Uid 是新用户（非零、不是当前用户、账户表里有、用户数 +1）；
    //   连建两次是两个不同的用户（昵称也不同）；
    //   负对照：选用户模式 0（UserSelector）照旧回成功 + 当前用户（不受本次改动影响）
    public static unsafe partial class Program
    {
        [SoloTest("--acc-user-creator", Booted = true)]
        private static void AccountUserCreator()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            Reply gacc = Call(sm, Msg.Cmif(1, Name8("acc:u0")));
            uint acc = gacc.Move.Count == 1 ? gacc.Move[0] : 0;

            Msg permitted = Msg.Cmif(50, Bytes(0L));
            permitted.SendPid = true;
            Reply p = Call(acc, permitted);
            Check("acc:u0 命令 50 IsUserRegistrationRequestPermitted（应用）", "结果 0、bool 1", $"结果 {p.Result}、bool {(p.Result == 0 ? p.Data[0] : -1)}");

            var system = Host.Device.System;
            MemoryStream us = new();
            system.AccountManager.LastOpenedUser.UserId.Write(new BinaryWriter(us));
            string current = Convert.ToHexString(us.ToArray());

            string Psel(uint mode) => PselRaw(mode).Text;
            (string Text, string Uid) PselRaw(uint mode)
            {
                var normal = new AppletSession();
                AppletSession game = normal.GetConsumer();
                game.Push(new byte[0x20]);   // 公共参数
                byte[] ui = new byte[0xA0];  // nn::account::UiSettings，头 4 字节是模式
                BitConverter.GetBytes(mode).CopyTo(ui, 0);
                game.Push(ui);
                new PlayerSelectApplet(system).Start(normal, new AppletSession());
                if (!game.TryPop(out byte[] r)) return ("无结果", "");
                string uid = r.Length >= 0x18 ? Convert.ToHexString(r, 8, 16) : "-";
                return ($"长 0x{r.Length:X}、结果 0x{BitConverter.ToUInt32(r, 0):X}、Uid {(uid == current ? "当前用户" : uid == new string('0', 32) ? "全零" : "其他")}", uid);
            }

            var users = system.AccountManager;
            int before = users.GetAllUsers().Count();
            string Created(string hex)
            {
                if (hex.Length != 32) return "无 Uid";
                // 回包里 Uid 是 High、Low 两个小端 u64（UserId.Write），换回账户表的键
                byte[] b = Convert.FromHexString(hex);
                var id = new Ryujinx.HLE.HOS.Services.Account.Acc.UserId(BitConverter.ToInt64(b, 8), BitConverter.ToInt64(b, 0));
                var p = users.GetAllUsers().FirstOrDefault(u => u.UserId == id);
                return p == null ? "账户表里没有" : $"账户表里有、昵称非空 {(!string.IsNullOrEmpty(p.Name) ? 1 : 0)}、头像非空 {(p.Image?.Length > 0 ? 1 : 0)}";
            }
            var c1 = PselRaw(1);
            Check("psel 模式 1 UserCreator（建新用户）", "长 0x18、结果 0x0、Uid 其他", c1.Text);
            Check("UserCreator 回的 Uid 已登记进账户表", "账户表里有、昵称非空 1、头像非空 1", Created(c1.Uid));
            var c2 = PselRaw(1);
            string name1 = users.GetAllUsers().FirstOrDefault(u => Convert.ToHexString(UidBytes(u.UserId)) == c1.Uid)?.Name;
            string name2 = users.GetAllUsers().FirstOrDefault(u => Convert.ToHexString(UidBytes(u.UserId)) == c2.Uid)?.Name;
            Check("连建两次：两个不同用户、昵称不同、用户数 +2", "Uid 不同 1、昵称不同 1、用户数 +2",
                $"Uid 不同 {(c1.Uid != c2.Uid ? 1 : 0)}、昵称不同 {(name1 != null && name2 != null && name1 != name2 ? 1 : 0)}、用户数 +{users.GetAllUsers().Count() - before}");
            Check("负对照：psel 模式 0 UserSelector 照旧选当前用户", "长 0x18、结果 0x0、Uid 当前用户", Psel(0));
            while (system.AppletState.Messages.TryDequeue(out _)) { }

            FakeNative.HandleClose(acc); FakeNative.HandleClose(sm);
        }

        private static byte[] UidBytes(Ryujinx.HLE.HOS.Services.Account.Acc.UserId id)
        {
            MemoryStream m = new();
            id.Write(new BinaryWriter(m));
            return m.ToArray();
        }
    }
}
