using Microsoft.IO;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;
using System.IO;
using System.Linq;

namespace Ryujinx.HLE.HOS.Applets
{
    internal class PlayerSelectApplet : IApplet
    {
        private readonly Horizon _system;

        private AppletSession _normalSession;
#pragma warning disable IDE0052 // Remove unread private member
        private AppletSession _interactiveSession;
#pragma warning restore IDE0052

        public event EventHandler AppletStateChanged;

        public PlayerSelectApplet(Horizon system)
        {
            _system = system;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            _normalSession = normalSession;
            _interactiveSession = interactiveSession;

            // S2Arm: the second input storage is nn::account::UiSettings, mode first; mode 1 is UserCreator (ShowUserCreator).
            // On the console this applet creates a new user and answers success; the SDK hands the first word of the reply back
            // as ShowUserCreator's result and the game then lists users again. The host has no nickname / icon UI, so create the
            // user the console would end up with: the system default icon and an unused nickname. Answering "cancelled" instead
            // left "add new user" doing nothing (11-06 Brain Training); upstream opens the user selector and reports the
            // existing user as newly created, which adds no user either.
            _normalSession.TryPop(out _);
            if (_normalSession.TryPop(out byte[] uiSettings) && uiSettings.Length >= 4 && BitConverter.ToUInt32(uiSettings, 0) == UiModeUserCreator)
            {
                AccountManager accounts = _system.AccountManager;
                // count + 1 candidates against count existing names: one is always free
                string name = Enumerable.Range(accounts.GetUserCount() + 1, accounts.GetUserCount() + 1)
                    .Select(n => $"Player{n}").First(n => accounts.GetAllUsers().All(u => u.Name != n));
                UserId created = new(Guid.NewGuid().ToString("N"));
                accounts.AddUser(name, EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg"), created);
                Logger.Info?.Print(LogClass.ServiceAm, $"User creator applet created user {created} \"{name}\" (no nickname / icon UI on the host)");
                _normalSession.Push(BuildResponse(created));
                AppletStateChanged?.Invoke(this, null);
                _system.ReturnFocus();

                return ResultCode.Success;
            }

            UserProfile selected = _system.Device.UIHandler.ShowPlayerSelectDialog();
            if (selected == null)
            {
                _normalSession.Push(BuildResponse());
            }
            else if (selected.UserId == new UserId("00000000000000000000000000000080"))
            {
                _normalSession.Push(BuildGuestResponse());
            }
            else
            {
                _normalSession.Push(BuildResponse(selected));
            }

            AppletStateChanged?.Invoke(this, null);

            _system.ReturnFocus();

            return ResultCode.Success;
        }

        private static byte[] BuildResponse(UserProfile selectedUser)
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Success);

            selectedUser.UserId.Write(writer);

            return stream.ToArray();
        }

        private static byte[] BuildResponse(UserId createdUser)
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Success);

            createdUser.Write(writer);

            return stream.ToArray();
        }

        private static byte[] BuildGuestResponse()
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write(new byte());

            return stream.ToArray();
        }

        private const uint UiModeUserCreator = 1;

        private static byte[] BuildResponse()
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)PlayerSelectResult.Failure);

            return stream.ToArray();
        }
    }
}
